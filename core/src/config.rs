use anyhow::{Context, Result, bail};
use std::{env, path::PathBuf, time::Duration};
use velora_protocol::{
    DEFAULT_TELEMETRY_INTERVAL_MS, MAX_TELEMETRY_DEVICES, MAX_TELEMETRY_INTERFACES,
    MAX_TELEMETRY_INTERVAL_MS, MIN_TELEMETRY_INTERVAL_MS, default_socket_path,
};

const TELEMETRY_INTERVAL_ENV: &str = "VELORA_TELEMETRY_INTERVAL_MS";
const TELEMETRY_ENABLED_ENV: &str = "VELORA_TELEMETRY_ENABLED";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TelemetryPolicy {
    pub enabled: bool,
    pub interval: Duration,
    pub max_devices: u16,
    pub max_interfaces: u16,
}

impl Default for TelemetryPolicy {
    fn default() -> Self {
        Self {
            enabled: true,
            interval: Duration::from_millis(u64::from(DEFAULT_TELEMETRY_INTERVAL_MS)),
            max_devices: MAX_TELEMETRY_DEVICES,
            max_interfaces: MAX_TELEMETRY_INTERFACES,
        }
    }
}

impl TelemetryPolicy {
    fn from_interval_text(value: Option<&str>) -> Result<Self> {
        let Some(value) = value else {
            return Ok(Self::default());
        };
        let interval_ms = value.parse::<u32>().with_context(|| {
            format!("{TELEMETRY_INTERVAL_ENV} must be an integer in milliseconds")
        })?;
        if !(MIN_TELEMETRY_INTERVAL_MS..=MAX_TELEMETRY_INTERVAL_MS).contains(&interval_ms) {
            bail!(
                "{TELEMETRY_INTERVAL_ENV} must be between {MIN_TELEMETRY_INTERVAL_MS} and {MAX_TELEMETRY_INTERVAL_MS} milliseconds"
            );
        }
        Ok(Self {
            interval: Duration::from_millis(u64::from(interval_ms)),
            ..Self::default()
        })
    }

    fn from_environment() -> Result<Self> {
        let mut policy = match env::var(TELEMETRY_INTERVAL_ENV) {
            Ok(value) => Self::from_interval_text(Some(&value)),
            Err(env::VarError::NotPresent) => Self::from_interval_text(None),
            Err(env::VarError::NotUnicode(_)) => {
                bail!("{TELEMETRY_INTERVAL_ENV} must contain valid UTF-8")
            }
        }?;
        policy.enabled = match env::var(TELEMETRY_ENABLED_ENV) {
            Ok(value) => value
                .parse::<bool>()
                .with_context(|| format!("{TELEMETRY_ENABLED_ENV} must be true or false"))?,
            Err(env::VarError::NotPresent) => true,
            Err(env::VarError::NotUnicode(_)) => {
                bail!("{TELEMETRY_ENABLED_ENV} must contain valid UTF-8")
            }
        };
        Ok(policy)
    }
}

#[derive(Debug, Clone)]
pub struct CoreConfig {
    pub socket_path: PathBuf,
    pub telemetry: TelemetryPolicy,
}

impl CoreConfig {
    pub fn from_environment() -> Result<Self> {
        Ok(Self {
            socket_path: default_socket_path()?,
            telemetry: TelemetryPolicy::from_environment()?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn telemetry_policy_uses_the_bounded_default() {
        let policy = TelemetryPolicy::from_interval_text(None).unwrap();
        assert_eq!(
            policy.interval,
            Duration::from_millis(u64::from(DEFAULT_TELEMETRY_INTERVAL_MS))
        );
        assert_eq!(policy.max_devices, MAX_TELEMETRY_DEVICES);
        assert_eq!(policy.max_interfaces, MAX_TELEMETRY_INTERFACES);
    }

    #[test]
    fn telemetry_policy_accepts_both_interval_boundaries() {
        for interval_ms in [
            MIN_TELEMETRY_INTERVAL_MS,
            DEFAULT_TELEMETRY_INTERVAL_MS,
            MAX_TELEMETRY_INTERVAL_MS,
        ] {
            let text = interval_ms.to_string();
            let policy = TelemetryPolicy::from_interval_text(Some(&text)).unwrap();
            assert_eq!(
                policy.interval,
                Duration::from_millis(u64::from(interval_ms))
            );
        }
    }

    #[test]
    fn telemetry_policy_rejects_too_fast_too_slow_and_malformed_values() {
        for value in ["249", "10001", "fast", ""] {
            assert!(TelemetryPolicy::from_interval_text(Some(value)).is_err());
        }
    }
}
