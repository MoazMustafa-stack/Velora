use std::{collections::BTreeMap, time::Duration};

use thiserror::Error;
use velora_protocol::{NetworkTelemetry, TelemetryAvailability};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NetworkInterfaceCounters {
    pub received_bytes: u64,
    pub transmitted_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetworkCountersSnapshot {
    interfaces: BTreeMap<String, NetworkInterfaceCounters>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum NetworkParseError {
    #[error("network interface entry is malformed")]
    MalformedEntry,
    #[error("network counter is not an unsigned integer")]
    InvalidCounter,
    #[error("network interface limit exceeded")]
    TooManyInterfaces,
    #[error("network interface appears more than once")]
    DuplicateInterface,
}

pub fn parse_net_dev(
    input: &str,
    max_interfaces: u16,
) -> Result<NetworkCountersSnapshot, NetworkParseError> {
    let mut interfaces = BTreeMap::new();
    for line in input.lines().skip(2) {
        let Some((name, counters)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim();
        // Loopback is not meaningful desktop network activity and no device
        // identifier is ever sent through IPC.
        if name.is_empty() || name == "lo" {
            continue;
        }
        let mut fields = counters.split_ascii_whitespace();
        let received_bytes = fields
            .next()
            .ok_or(NetworkParseError::MalformedEntry)?
            .parse()
            .map_err(|_| NetworkParseError::InvalidCounter)?;
        for _ in 0..7 {
            fields.next().ok_or(NetworkParseError::MalformedEntry)?;
        }
        let transmitted_bytes = fields
            .next()
            .ok_or(NetworkParseError::MalformedEntry)?
            .parse()
            .map_err(|_| NetworkParseError::InvalidCounter)?;
        if interfaces.len() >= usize::from(max_interfaces) {
            return Err(NetworkParseError::TooManyInterfaces);
        }
        if interfaces
            .insert(
                name.to_owned(),
                NetworkInterfaceCounters {
                    received_bytes,
                    transmitted_bytes,
                },
            )
            .is_some()
        {
            return Err(NetworkParseError::DuplicateInterface);
        }
    }
    Ok(NetworkCountersSnapshot { interfaces })
}

pub fn calculate_network_telemetry(
    previous: Option<&NetworkCountersSnapshot>,
    current: &NetworkCountersSnapshot,
    elapsed: Duration,
) -> NetworkTelemetry {
    let interface_count = u16::try_from(current.interfaces.len()).unwrap_or(u16::MAX);
    let Some(previous) = previous.filter(|_| !elapsed.is_zero()) else {
        return NetworkTelemetry {
            availability: TelemetryAvailability::WarmingUp,
            receive_bytes_per_second: 0,
            transmit_bytes_per_second: 0,
            interface_count,
        };
    };
    if current.interfaces.is_empty() {
        return NetworkTelemetry {
            availability: TelemetryAvailability::Offline,
            receive_bytes_per_second: 0,
            transmit_bytes_per_second: 0,
            interface_count,
        };
    }
    let (received, transmitted) = current.interfaces.iter().fold(
        (0_u128, 0_u128),
        |(received, transmitted), (name, current)| {
            let Some(previous) = previous.interfaces.get(name) else {
                return (received, transmitted);
            };
            (
                received.saturating_add(u128::from(
                    current
                        .received_bytes
                        .saturating_sub(previous.received_bytes),
                )),
                transmitted.saturating_add(u128::from(
                    current
                        .transmitted_bytes
                        .saturating_sub(previous.transmitted_bytes),
                )),
            )
        },
    );
    let rate = |bytes: u128| {
        u64::try_from(bytes.saturating_mul(1_000_000_000) / elapsed.as_nanos()).unwrap_or(u64::MAX)
    };
    NetworkTelemetry {
        availability: TelemetryAvailability::Available,
        receive_bytes_per_second: rate(received),
        transmit_bytes_per_second: rate(transmitted),
        interface_count,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_and_rates_non_loopback_interfaces() {
        let before = parse_net_dev("Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n lo: 99 0 0 0 0 0 0 0 99 0 0 0 0 0 0 0\n wlan0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0\n", 4).unwrap();
        let after = parse_net_dev("Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n wlan0: 600 0 0 0 0 0 0 0 900 0 0 0 0 0 0 0\n", 4).unwrap();
        let telemetry = calculate_network_telemetry(Some(&before), &after, Duration::from_secs(1));
        assert_eq!(telemetry.availability, TelemetryAvailability::Available);
        assert_eq!(
            (
                telemetry.receive_bytes_per_second,
                telemetry.transmit_bytes_per_second,
                telemetry.interface_count
            ),
            (500, 700, 1)
        );
    }

    #[test]
    fn rejects_bad_entries_and_treats_churn_or_resets_as_zero_rate() {
        assert_eq!(
            parse_net_dev("header\nheader\n eth0: not-a-number\n", 4),
            Err(NetworkParseError::InvalidCounter)
        );
        assert_eq!(
            parse_net_dev("header\nheader\n eth0: 1 2\n", 4),
            Err(NetworkParseError::MalformedEntry)
        );
        let previous = parse_net_dev(
            "header\nheader\n eth0: 500 0 0 0 0 0 0 0 800 0 0 0 0 0 0 0\n",
            4,
        )
        .unwrap();
        let current = parse_net_dev("header\nheader\n wlan0: 10 0 0 0 0 0 0 0 20 0 0 0 0 0 0 0\n eth0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0\n", 4).unwrap();
        let telemetry =
            calculate_network_telemetry(Some(&previous), &current, Duration::from_secs(1));
        assert_eq!(telemetry.receive_bytes_per_second, 0);
        assert_eq!(telemetry.transmit_bytes_per_second, 0);
        assert_eq!(telemetry.interface_count, 2);
    }

    #[test]
    fn returns_offline_when_previous_exists_but_current_is_empty() {
        let previous = parse_net_dev(
            "header\nheader\n wlan0: 500 0 0 0 0 0 0 0 800 0 0 0 0 0 0 0\n",
            4,
        )
        .unwrap();
        let current = parse_net_dev(
            "header\nheader\n lo: 99 0 0 0 0 0 0 0 99 0 0 0 0 0 0 0\n",
            4,
        )
        .unwrap();
        let telemetry =
            calculate_network_telemetry(Some(&previous), &current, Duration::from_secs(1));
        assert_eq!(telemetry.availability, TelemetryAvailability::Offline);
        assert_eq!(telemetry.receive_bytes_per_second, 0);
        assert_eq!(telemetry.transmit_bytes_per_second, 0);
        assert_eq!(telemetry.interface_count, 0);
    }

    #[test]
    fn saturates_rate_when_bytes_approach_u64_boundary() {
        let previous = parse_net_dev(
            "header\nheader\n eth0: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n",
            4,
        )
        .unwrap();
        let current = parse_net_dev(
            &format!(
                "header\nheader\n eth0: {} 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n",
                u64::MAX
            ),
            4,
        )
        .unwrap();
        let telemetry =
            calculate_network_telemetry(Some(&previous), &current, Duration::from_nanos(1));
        assert_eq!(telemetry.availability, TelemetryAvailability::Available);
        assert_eq!(telemetry.receive_bytes_per_second, u64::MAX);
    }
}
