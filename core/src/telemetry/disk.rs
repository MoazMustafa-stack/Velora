use std::{collections::BTreeMap, time::Duration};

use thiserror::Error;
use velora_protocol::{DiskTelemetry, TelemetryAvailability};

const DISKSTAT_SECTOR_BYTES: u128 = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DiskDeviceCounters {
    pub read_sectors: u64,
    pub written_sectors: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiskCountersSnapshot {
    devices: BTreeMap<String, DiskDeviceCounters>,
}

impl DiskCountersSnapshot {
    pub fn device_count(&self) -> usize {
        self.devices.len()
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DiskParseError {
    #[error("diskstats entry for an accepted device is truncated")]
    TruncatedEntry,
    #[error("diskstats entry contains an invalid counter")]
    InvalidCounter,
    #[error("diskstats contains a duplicate accepted device")]
    DuplicateDevice,
    #[error("diskstats exceeds the configured device limit")]
    TooManyDevices,
}

pub fn parse_diskstats(
    input: &str,
    max_devices: u16,
) -> Result<DiskCountersSnapshot, DiskParseError> {
    let mut devices = BTreeMap::new();
    for line in input.lines() {
        let mut fields = line.split_ascii_whitespace();
        let Some(major) = fields.next() else {
            continue;
        };
        let Some(minor) = fields.next() else {
            continue;
        };
        let Some(name) = fields.next() else {
            continue;
        };
        if !is_allowed_whole_device(name) {
            continue;
        }
        // Validate the kernel identity fields even though names remain private
        // and only aggregate rates cross IPC.
        major
            .parse::<u32>()
            .map_err(|_| DiskParseError::InvalidCounter)?;
        minor
            .parse::<u32>()
            .map_err(|_| DiskParseError::InvalidCounter)?;
        let read_sectors = fields
            .nth(2)
            .ok_or(DiskParseError::TruncatedEntry)?
            .parse::<u64>()
            .map_err(|_| DiskParseError::InvalidCounter)?;
        let written_sectors = fields
            .nth(3)
            .ok_or(DiskParseError::TruncatedEntry)?
            .parse::<u64>()
            .map_err(|_| DiskParseError::InvalidCounter)?;

        if devices.len() >= usize::from(max_devices) {
            return Err(DiskParseError::TooManyDevices);
        }
        if devices
            .insert(
                name.to_owned(),
                DiskDeviceCounters {
                    read_sectors,
                    written_sectors,
                },
            )
            .is_some()
        {
            return Err(DiskParseError::DuplicateDevice);
        }
    }
    Ok(DiskCountersSnapshot { devices })
}

fn is_allowed_whole_device(name: &str) -> bool {
    fn alphabetic_suffix(name: &str, prefix: &str) -> bool {
        name.strip_prefix(prefix).is_some_and(|suffix| {
            !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_lowercase())
        })
    }

    if ["loop", "ram", "zram", "fd", "sr", "dm-", "md"]
        .iter()
        .any(|prefix| name.starts_with(prefix))
    {
        return false;
    }
    if ["xvd", "sd", "hd", "vd"]
        .iter()
        .any(|prefix| alphabetic_suffix(name, prefix))
    {
        return true;
    }
    if let Some(rest) = name.strip_prefix("nvme") {
        return rest.split_once('n').is_some_and(|(controller, namespace)| {
            !controller.is_empty()
                && controller.bytes().all(|byte| byte.is_ascii_digit())
                && !namespace.is_empty()
                && namespace.bytes().all(|byte| byte.is_ascii_digit())
        });
    }
    if let Some(rest) = name.strip_prefix("mmcblk") {
        return !rest.is_empty() && rest.bytes().all(|byte| byte.is_ascii_digit());
    }
    false
}

pub fn calculate_disk_telemetry(
    previous: Option<&DiskCountersSnapshot>,
    current: &DiskCountersSnapshot,
    elapsed: Duration,
) -> DiskTelemetry {
    let device_count = u16::try_from(current.devices.len()).unwrap_or(u16::MAX);
    let Some(previous) = previous.filter(|_| !elapsed.is_zero()) else {
        return DiskTelemetry {
            availability: TelemetryAvailability::WarmingUp,
            read_bytes_per_second: 0,
            write_bytes_per_second: 0,
            device_count,
        };
    };

    let mut read_sectors = 0_u128;
    let mut written_sectors = 0_u128;
    for (name, current_device) in &current.devices {
        let Some(previous_device) = previous.devices.get(name) else {
            continue;
        };
        // One reset or newly replaced device must not poison the aggregate.
        if current_device.read_sectors < previous_device.read_sectors
            || current_device.written_sectors < previous_device.written_sectors
        {
            continue;
        }
        read_sectors = read_sectors.saturating_add(u128::from(
            current_device.read_sectors - previous_device.read_sectors,
        ));
        written_sectors = written_sectors.saturating_add(u128::from(
            current_device.written_sectors - previous_device.written_sectors,
        ));
    }

    DiskTelemetry {
        availability: TelemetryAvailability::Available,
        read_bytes_per_second: rate_from_sectors(read_sectors, elapsed),
        write_bytes_per_second: rate_from_sectors(written_sectors, elapsed),
        device_count,
    }
}

fn rate_from_sectors(sectors: u128, elapsed: Duration) -> u64 {
    let elapsed_nanos = elapsed.as_nanos();
    if elapsed_nanos == 0 {
        return 0;
    }
    let bytes_per_second = sectors
        .saturating_mul(DISKSTAT_SECTOR_BYTES)
        .saturating_mul(1_000_000_000)
        / elapsed_nanos;
    u64::try_from(bytes_per_second).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DISKSTATS: &str = "8 0 sda 100 0 200 0 50 0 80 0 0 0 0\n\
8 1 sda1 90 0 180 0 40 0 70 0 0 0 0\n\
259 0 nvme0n1 200 0 400 0 100 0 300 0 0 0 0\n\
259 1 nvme0n1p1 180 0 350 0 90 0 280 0 0 0 0\n\
252 0 vda 10 0 20 0 5 0 10 0 0 0 0\n\
7 0 loop0 500 0 900 0 400 0 800 0 0 0 0\n\
253 0 dm-0 400 0 700 0 300 0 600 0 0 0 0\n";

    fn snapshot(entries: &[(&str, u64, u64)]) -> DiskCountersSnapshot {
        DiskCountersSnapshot {
            devices: entries
                .iter()
                .map(|(name, read, written)| {
                    (
                        (*name).to_owned(),
                        DiskDeviceCounters {
                            read_sectors: *read,
                            written_sectors: *written,
                        },
                    )
                })
                .collect(),
        }
    }

    #[test]
    fn keeps_supported_whole_devices_and_filters_partitions_and_virtual_devices() {
        let parsed = parse_diskstats(DISKSTATS, 64).unwrap();
        assert_eq!(parsed.device_count(), 3);
        assert!(parsed.devices.contains_key("sda"));
        assert!(parsed.devices.contains_key("nvme0n1"));
        assert!(parsed.devices.contains_key("vda"));
        assert!(!parsed.devices.contains_key("sda1"));
        assert!(!parsed.devices.contains_key("nvme0n1p1"));
        assert!(!parsed.devices.contains_key("loop0"));
        assert!(!parsed.devices.contains_key("dm-0"));
    }

    #[test]
    fn recognizes_supported_names_without_accepting_path_syntax() {
        for name in ["sda", "xvdb", "vdc", "hdd", "nvme0n1", "mmcblk0"] {
            assert!(
                is_allowed_whole_device(name),
                "expected {name} to be allowed"
            );
        }
        for name in [
            "sda1",
            "nvme0n1p2",
            "mmcblk0p1",
            "loop0",
            "zram0",
            "dm-0",
            "md1",
            "../sda",
            "sda/evil",
        ] {
            assert!(
                !is_allowed_whole_device(name),
                "expected {name} to be rejected"
            );
        }
    }

    #[test]
    fn rejects_malformed_duplicate_and_excess_device_entries() {
        assert_eq!(
            parse_diskstats("8 0 sda 1 0 bad 0 1 0 2 0 0 0 0\n", 64),
            Err(DiskParseError::InvalidCounter)
        );
        assert_eq!(
            parse_diskstats("8 0 sda 1\n", 64),
            Err(DiskParseError::TruncatedEntry)
        );
        let duplicate = "8 0 sda 1 0 2 0 1 0 2 0\n8 0 sda 2 0 3 0 2 0 3 0\n";
        assert_eq!(
            parse_diskstats(duplicate, 64),
            Err(DiskParseError::DuplicateDevice)
        );
        assert_eq!(
            parse_diskstats(DISKSTATS, 2),
            Err(DiskParseError::TooManyDevices)
        );
    }

    #[test]
    fn first_sample_and_zero_elapsed_time_are_warming_up() {
        let current = snapshot(&[("sda", 100, 200)]);
        for telemetry in [
            calculate_disk_telemetry(None, &current, Duration::from_secs(1)),
            calculate_disk_telemetry(Some(&current), &current, Duration::ZERO),
        ] {
            assert_eq!(telemetry.availability, TelemetryAvailability::WarmingUp);
            assert_eq!(telemetry.read_bytes_per_second, 0);
            assert_eq!(telemetry.write_bytes_per_second, 0);
        }
    }

    #[test]
    fn calculates_aggregate_rates_from_deterministic_elapsed_time() {
        let previous = snapshot(&[("sda", 100, 200), ("vda", 50, 60)]);
        let current = snapshot(&[("sda", 300, 500), ("vda", 150, 160)]);
        let telemetry =
            calculate_disk_telemetry(Some(&previous), &current, Duration::from_millis(500));
        assert_eq!(telemetry.availability, TelemetryAvailability::Available);
        assert_eq!(telemetry.read_bytes_per_second, 300 * 512 * 2);
        assert_eq!(telemetry.write_bytes_per_second, 400 * 512 * 2);
        assert_eq!(telemetry.device_count, 2);
    }

    #[test]
    fn device_churn_and_counter_reset_do_not_create_false_spikes() {
        let previous = snapshot(&[("sda", 500, 800), ("vda", 100, 100)]);
        let current = snapshot(&[("sda", 10, 20), ("nvme0n1", 9_000, 8_000)]);
        let telemetry = calculate_disk_telemetry(Some(&previous), &current, Duration::from_secs(1));
        assert_eq!(telemetry.availability, TelemetryAvailability::Available);
        assert_eq!(telemetry.read_bytes_per_second, 0);
        assert_eq!(telemetry.write_bytes_per_second, 0);
        assert_eq!(telemetry.device_count, 2);
    }
}
