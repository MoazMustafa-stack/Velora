use thiserror::Error;
use velora_protocol::{CpuTelemetry, TelemetryAvailability};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CpuCounters {
    pub busy_ticks: u64,
    pub idle_ticks: u64,
    pub total_ticks: u64,
    pub logical_cpu_count: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LoadAverages {
    pub one_milli: u32,
    pub five_milli: u32,
    pub fifteen_milli: u32,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum CpuParseError {
    #[error("/proc/stat does not contain an aggregate CPU line")]
    MissingAggregate,
    #[error("/proc/stat does not contain a logical CPU")]
    MissingLogicalCpu,
    #[error("aggregate CPU line has too few counters")]
    TruncatedAggregate,
    #[error("CPU counter is not an unsigned integer")]
    InvalidCounter,
    #[error("CPU counter total overflowed")]
    CounterOverflow,
    #[error("logical CPU count exceeds the protocol limit")]
    CpuCountOverflow,
    #[error("/proc/loadavg does not contain three load averages")]
    TruncatedLoadAverage,
    #[error("load average is not a supported non-negative decimal")]
    InvalidLoadAverage,
    #[error("fixed-point load average overflowed")]
    LoadAverageOverflow,
}

pub fn parse_proc_stat(input: &str) -> Result<CpuCounters, CpuParseError> {
    let aggregate = input
        .lines()
        .find(|line| line.split_ascii_whitespace().next() == Some("cpu"))
        .ok_or(CpuParseError::MissingAggregate)?;
    let fields: Vec<_> = aggregate.split_ascii_whitespace().skip(1).collect();
    if fields.len() < 4 {
        return Err(CpuParseError::TruncatedAggregate);
    }

    let counter = |index: usize| -> Result<u64, CpuParseError> {
        fields
            .get(index)
            .unwrap_or(&"0")
            .parse::<u64>()
            .map_err(|_| CpuParseError::InvalidCounter)
    };
    let add = |left: u64, right: u64| {
        left.checked_add(right)
            .ok_or(CpuParseError::CounterOverflow)
    };

    let user = counter(0)?;
    let nice = counter(1)?;
    let system = counter(2)?;
    let idle = counter(3)?;
    let iowait = counter(4)?;
    let irq = counter(5)?;
    let softirq = counter(6)?;
    let steal = counter(7)?;

    // Linux reports guest and guest_nice as time already included in user and
    // nice. Deliberately ignoring fields 8 and 9 prevents double counting.
    let busy_ticks = add(
        add(add(user, nice)?, add(system, irq)?)?,
        add(softirq, steal)?,
    )?;
    let idle_ticks = add(idle, iowait)?;
    let total_ticks = add(busy_ticks, idle_ticks)?;

    let logical_cpu_count = input
        .lines()
        .filter_map(|line| line.split_ascii_whitespace().next())
        .filter(|label| {
            label.strip_prefix("cpu").is_some_and(|suffix| {
                !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit())
            })
        })
        .count();
    if logical_cpu_count == 0 {
        return Err(CpuParseError::MissingLogicalCpu);
    }
    let logical_cpu_count =
        u16::try_from(logical_cpu_count).map_err(|_| CpuParseError::CpuCountOverflow)?;

    Ok(CpuCounters {
        busy_ticks,
        idle_ticks,
        total_ticks,
        logical_cpu_count,
    })
}

pub fn parse_loadavg(input: &str) -> Result<LoadAverages, CpuParseError> {
    let mut fields = input.split_ascii_whitespace();
    let one = fields.next().ok_or(CpuParseError::TruncatedLoadAverage)?;
    let five = fields.next().ok_or(CpuParseError::TruncatedLoadAverage)?;
    let fifteen = fields.next().ok_or(CpuParseError::TruncatedLoadAverage)?;
    Ok(LoadAverages {
        one_milli: parse_decimal_milli(one)?,
        five_milli: parse_decimal_milli(five)?,
        fifteen_milli: parse_decimal_milli(fifteen)?,
    })
}

fn parse_decimal_milli(value: &str) -> Result<u32, CpuParseError> {
    if value.is_empty() || value.starts_with('-') {
        return Err(CpuParseError::InvalidLoadAverage);
    }
    let (whole, fraction) = match value.split_once('.') {
        Some((whole, fraction)) => (whole, fraction),
        None => (value, ""),
    };
    if whole.is_empty()
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
        || fraction.len() > 3
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(CpuParseError::InvalidLoadAverage);
    }

    let whole = whole
        .parse::<u32>()
        .map_err(|_| CpuParseError::InvalidLoadAverage)?;
    let fraction = match fraction.len() {
        0 => 0,
        1 => fraction.parse::<u32>().unwrap_or(0) * 100,
        2 => fraction.parse::<u32>().unwrap_or(0) * 10,
        3 => fraction.parse::<u32>().unwrap_or(0),
        _ => unreachable!(),
    };
    whole
        .checked_mul(1_000)
        .and_then(|scaled| scaled.checked_add(fraction))
        .ok_or(CpuParseError::LoadAverageOverflow)
}

pub fn calculate_cpu_telemetry(
    previous: Option<&CpuCounters>,
    current: &CpuCounters,
    load: LoadAverages,
) -> CpuTelemetry {
    let utilization_basis_points = previous.and_then(|previous| {
        if previous.logical_cpu_count != current.logical_cpu_count
            || current.total_ticks < previous.total_ticks
            || current.busy_ticks < previous.busy_ticks
        {
            return None;
        }
        let total_delta = current.total_ticks - previous.total_ticks;
        let busy_delta = current.busy_ticks - previous.busy_ticks;
        if total_delta == 0 {
            return None;
        }
        let basis_points = u128::from(busy_delta) * 10_000 / u128::from(total_delta);
        Some(u16::try_from(basis_points.min(10_000)).unwrap_or(10_000))
    });

    CpuTelemetry {
        availability: if utilization_basis_points.is_some() {
            TelemetryAvailability::Available
        } else {
            TelemetryAvailability::WarmingUp
        },
        utilization_basis_points,
        logical_cpu_count: current.logical_cpu_count,
        load_1m_milli: load.one_milli,
        load_5m_milli: load.five_milli,
        load_15m_milli: load.fifteen_milli,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROC_STAT: &str = "cpu  100 20 30 400 10 5 6 7 90 8\n\
cpu0 50 10 15 200 5 2 3 3 45 4\n\
cpu1 50 10 15 200 5 3 3 4 45 4\n\
intr 12345\n";

    fn counters(busy: u64, idle: u64, cpus: u16) -> CpuCounters {
        CpuCounters {
            busy_ticks: busy,
            idle_ticks: idle,
            total_ticks: busy + idle,
            logical_cpu_count: cpus,
        }
    }

    fn loads() -> LoadAverages {
        LoadAverages {
            one_milli: 500,
            five_milli: 1_250,
            fifteen_milli: 2_000,
        }
    }

    #[test]
    fn parses_aggregate_counters_without_double_counting_guest_time() {
        let parsed = parse_proc_stat(PROC_STAT).unwrap();
        assert_eq!(parsed.busy_ticks, 168);
        assert_eq!(parsed.idle_ticks, 410);
        assert_eq!(parsed.total_ticks, 578);
        assert_eq!(parsed.logical_cpu_count, 2);

        let tab_separated = parse_proc_stat("cpu\t1 2 3 4\ncpu0 1 2 3 4\n").unwrap();
        assert_eq!(tab_separated.total_ticks, 10);
    }

    #[test]
    fn rejects_missing_truncated_and_invalid_cpu_data() {
        assert_eq!(
            parse_proc_stat("intr 1\n"),
            Err(CpuParseError::MissingAggregate)
        );
        assert_eq!(
            parse_proc_stat("cpu 1 2 3\ncpu0 1\n"),
            Err(CpuParseError::TruncatedAggregate)
        );
        assert_eq!(
            parse_proc_stat("cpu 1 x 3 4\ncpu0 1\n"),
            Err(CpuParseError::InvalidCounter)
        );
        assert_eq!(
            parse_proc_stat("cpu 1 2 3 4\n"),
            Err(CpuParseError::MissingLogicalCpu)
        );
    }

    #[test]
    fn parses_load_averages_as_fixed_point_integers() {
        assert_eq!(
            parse_loadavg("0.50 1.25 2.000 1/100 42\n").unwrap(),
            loads()
        );
        assert_eq!(
            parse_loadavg("0.1234 1.0 2.0"),
            Err(CpuParseError::InvalidLoadAverage)
        );
        assert_eq!(
            parse_loadavg("-1.0 1.0 2.0"),
            Err(CpuParseError::InvalidLoadAverage)
        );
        assert_eq!(
            parse_loadavg("1.0 2.0"),
            Err(CpuParseError::TruncatedLoadAverage)
        );
    }

    #[test]
    fn first_sample_warms_up_instead_of_inventing_utilization() {
        let telemetry = calculate_cpu_telemetry(None, &counters(400, 600, 8), loads());
        assert_eq!(telemetry.availability, TelemetryAvailability::WarmingUp);
        assert_eq!(telemetry.utilization_basis_points, None);
        assert_eq!(telemetry.load_5m_milli, 1_250);
    }

    #[test]
    fn calculates_bounded_utilization_from_counter_deltas() {
        let previous = counters(400, 600, 8);
        let current = counters(500, 700, 8);
        let telemetry = calculate_cpu_telemetry(Some(&previous), &current, loads());
        assert_eq!(telemetry.availability, TelemetryAvailability::Available);
        assert_eq!(telemetry.utilization_basis_points, Some(5_000));
    }

    #[test]
    fn reset_zero_delta_and_hotplug_restart_the_baseline() {
        let previous = counters(400, 600, 8);
        for current in [
            counters(300, 500, 8),
            counters(400, 600, 8),
            counters(500, 700, 12),
        ] {
            let telemetry = calculate_cpu_telemetry(Some(&previous), &current, loads());
            assert_eq!(telemetry.availability, TelemetryAvailability::WarmingUp);
            assert_eq!(telemetry.utilization_basis_points, None);
        }
    }
}
