use std::collections::{HashMap, HashSet};

use thiserror::Error;
use velora_protocol::{MemoryTelemetry, TelemetryAvailability};

const KIBIBYTE_BYTES: u64 = 1024;
const INTERESTING_FIELDS: [&str; 9] = [
    "MemTotal",
    "MemFree",
    "MemAvailable",
    "Buffers",
    "Cached",
    "SReclaimable",
    "Shmem",
    "SwapTotal",
    "SwapFree",
];

#[derive(Debug, Error, PartialEq, Eq)]
pub enum MemoryParseError {
    #[error("/proc/meminfo is missing {0}")]
    MissingField(&'static str),
    #[error("/proc/meminfo contains a duplicate field")]
    DuplicateField,
    #[error("memory value is not an unsigned integer")]
    InvalidValue,
    #[error("memory value does not use the expected kB unit")]
    InvalidUnit,
    #[error("memory calculation overflowed")]
    Overflow,
}

pub fn parse_meminfo(input: &str) -> Result<MemoryTelemetry, MemoryParseError> {
    let mut values = HashMap::new();
    let mut seen = HashSet::new();

    for line in input.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if !INTERESTING_FIELDS.contains(&key) {
            continue;
        }
        if !seen.insert(key) {
            return Err(MemoryParseError::DuplicateField);
        }
        let mut fields = value.split_ascii_whitespace();
        let amount = fields
            .next()
            .ok_or(MemoryParseError::InvalidValue)?
            .parse::<u64>()
            .map_err(|_| MemoryParseError::InvalidValue)?;
        if fields.next() != Some("kB") || fields.next().is_some() {
            return Err(MemoryParseError::InvalidUnit);
        }
        values.insert(key, amount);
    }

    let required = |key: &'static str| {
        values
            .get(key)
            .copied()
            .ok_or(MemoryParseError::MissingField(key))
    };
    let optional = |key: &'static str| values.get(key).copied().unwrap_or(0);
    let checked_sum = |parts: &[u64]| {
        parts.iter().try_fold(0_u64, |sum, value| {
            sum.checked_add(*value).ok_or(MemoryParseError::Overflow)
        })
    };
    let to_bytes = |kib: u64| {
        kib.checked_mul(KIBIBYTE_BYTES)
            .ok_or(MemoryParseError::Overflow)
    };

    let total_kib = required("MemTotal")?;
    let available_kib = match values.get("MemAvailable").copied() {
        Some(available) => available,
        None => checked_sum(&[
            required("MemFree")?,
            optional("Buffers"),
            optional("Cached"),
            optional("SReclaimable"),
        ])?
        .saturating_sub(optional("Shmem")),
    }
    .min(total_kib);
    let cached_kib = checked_sum(&[optional("Cached"), optional("SReclaimable")])?
        .saturating_sub(optional("Shmem"))
        .min(total_kib);
    let swap_total_kib = optional("SwapTotal");
    let swap_free_kib = optional("SwapFree").min(swap_total_kib);

    let total_bytes = to_bytes(total_kib)?;
    let available_bytes = to_bytes(available_kib)?;
    let swap_total_bytes = to_bytes(swap_total_kib)?;

    Ok(MemoryTelemetry {
        availability: TelemetryAvailability::Available,
        total_bytes,
        available_bytes,
        used_bytes: total_bytes.saturating_sub(available_bytes),
        cached_bytes: to_bytes(cached_kib)?,
        swap_total_bytes,
        swap_used_bytes: swap_total_bytes.saturating_sub(to_bytes(swap_free_kib)?),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const MODERN: &str = "MemTotal:       16000 kB\n\
MemFree:         1000 kB\n\
MemAvailable:    6000 kB\n\
Buffers:          500 kB\n\
Cached:          3000 kB\n\
SReclaimable:     700 kB\n\
Shmem:            200 kB\n\
SwapTotal:       4000 kB\n\
SwapFree:        3000 kB\n\
HugePages_Total:    0\n";

    #[test]
    fn parses_modern_memory_and_swap_values_in_bytes() {
        let memory = parse_meminfo(MODERN).unwrap();
        assert_eq!(memory.availability, TelemetryAvailability::Available);
        assert_eq!(memory.total_bytes, 16_000 * 1024);
        assert_eq!(memory.available_bytes, 6_000 * 1024);
        assert_eq!(memory.used_bytes, 10_000 * 1024);
        assert_eq!(memory.cached_bytes, 3_500 * 1024);
        assert_eq!(memory.swap_total_bytes, 4_000 * 1024);
        assert_eq!(memory.swap_used_bytes, 1_000 * 1024);
    }

    #[test]
    fn falls_back_when_mem_available_is_absent() {
        let input = "MemTotal: 10000 kB\n\
MemFree: 1000 kB\n\
Buffers: 500 kB\n\
Cached: 2000 kB\n\
SReclaimable: 300 kB\n\
Shmem: 100 kB\n";
        let memory = parse_meminfo(input).unwrap();
        assert_eq!(memory.available_bytes, 3_700 * 1024);
        assert_eq!(memory.used_bytes, 6_300 * 1024);
        assert_eq!(memory.swap_total_bytes, 0);
        assert_eq!(memory.swap_used_bytes, 0);
    }

    #[test]
    fn tolerates_missing_optional_cache_and_swap_fields() {
        let memory = parse_meminfo("MemTotal: 1000 kB\nMemAvailable: 400 kB\n").unwrap();
        assert_eq!(memory.cached_bytes, 0);
        assert_eq!(memory.swap_total_bytes, 0);
        assert_eq!(memory.swap_used_bytes, 0);
    }

    #[test]
    fn clamps_derived_values_to_safe_totals() {
        let input = "MemTotal: 1000 kB\n\
MemAvailable: 2000 kB\n\
Cached: 3000 kB\n\
SwapTotal: 100 kB\n\
SwapFree: 200 kB\n";
        let memory = parse_meminfo(input).unwrap();
        assert_eq!(memory.available_bytes, memory.total_bytes);
        assert_eq!(memory.used_bytes, 0);
        assert_eq!(memory.cached_bytes, memory.total_bytes);
        assert_eq!(memory.swap_used_bytes, 0);
    }

    #[test]
    fn rejects_missing_malformed_duplicate_and_overflowing_values() {
        assert_eq!(
            parse_meminfo("MemAvailable: 1 kB\n"),
            Err(MemoryParseError::MissingField("MemTotal"))
        );
        assert_eq!(
            parse_meminfo("MemTotal: many kB\n"),
            Err(MemoryParseError::InvalidValue)
        );
        assert_eq!(
            parse_meminfo("MemTotal: 1 MB\n"),
            Err(MemoryParseError::InvalidUnit)
        );
        assert_eq!(
            parse_meminfo("MemTotal: 1 kB\nMemTotal: 2 kB\n"),
            Err(MemoryParseError::DuplicateField)
        );
        let overflow = format!("MemTotal: {} kB\nMemAvailable: 0 kB\n", u64::MAX);
        assert_eq!(parse_meminfo(&overflow), Err(MemoryParseError::Overflow));
    }
}
