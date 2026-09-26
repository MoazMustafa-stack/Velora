use anyhow::{Context, Result, bail};
use std::{env, path::PathBuf, time::Duration};
use velora_protocol::{
    DEFAULT_TELEMETRY_INTERVAL_MS, MAX_TELEMETRY_DEVICES, MAX_TELEMETRY_INTERFACES,
    MAX_TELEMETRY_INTERVAL_MS, MIN_TELEMETRY_INTERVAL_MS, default_socket_path,
};

const TELEMETRY_INTERVAL_ENV: &str = "VELORA_TELEMETRY_INTERVAL_MS";
const TELEMETRY_ENABLED_ENV: &str = "VELORA_TELEMETRY_ENABLED";
const MEDIA_ENABLED_ENV: &str = "VELORA_MEDIA_ENABLED";
const NOTIFICATIONS_ENABLED_ENV: &str = "VELORA_NOTIFICATIONS_ENABLED";

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

/// Privacy gate for the notification observer. Monitoring every notification
/// is the most privacy-sensitive capability Core has, so it is explicitly
/// toggleable; when disabled Core never opens a monitor connection and answers
/// notification requests with a typed unavailable result.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct NotificationsPolicy {
    pub enabled: bool,
}

impl NotificationsPolicy {
    fn from_environment() -> Result<Self> {
        Ok(Self {
            enabled: match env::var(NOTIFICATIONS_ENABLED_ENV) {
                Ok(value) => value.parse::<bool>().with_context(|| {
                    format!("{NOTIFICATIONS_ENABLED_ENV} must be true or false")
                })?,
                Err(env::VarError::NotPresent) => Self::default().enabled,
                Err(env::VarError::NotUnicode(_)) => {
                    bail!("{NOTIFICATIONS_ENABLED_ENV} must contain valid UTF-8")
                }
            },
        })
    }
}

/// Capability gate for MPRIS media observation and control. Media remains
/// enabled by default for the desktop experience, but tests and privacy-aware
/// sessions can disable every session-bus media connection explicitly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MediaPolicy {
    pub enabled: bool,
}

impl Default for MediaPolicy {
    fn default() -> Self {
        Self { enabled: true }
    }
}

impl MediaPolicy {
    fn from_environment() -> Result<Self> {
        Ok(Self {
            enabled: match env::var(MEDIA_ENABLED_ENV) {
                Ok(value) => value
                    .parse::<bool>()
                    .with_context(|| format!("{MEDIA_ENABLED_ENV} must be true or false"))?,
                Err(env::VarError::NotPresent) => Self::default().enabled,
                Err(env::VarError::NotUnicode(_)) => {
                    bail!("{MEDIA_ENABLED_ENV} must contain valid UTF-8")
                }
            },
        })
    }
}

#[derive(Debug, Clone)]
pub struct CoreConfig {
    pub socket_path: PathBuf,
    pub telemetry: TelemetryPolicy,
    pub media: MediaPolicy,
    pub notifications: NotificationsPolicy,
}

impl CoreConfig {
    pub fn from_environment() -> Result<Self> {
        Ok(Self {
            socket_path: default_socket_path()?,
            telemetry: TelemetryPolicy::from_environment()?,
            media: MediaPolicy::from_environment()?,
            notifications: NotificationsPolicy::from_environment()?,
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

    #[test]
    fn enabled_env_var_defaults_to_true() {
        let policy = TelemetryPolicy::from_interval_text(None).unwrap();
        assert!(policy.enabled);
    }

    #[test]
    fn enabled_env_var_parses_true_and_false() {
        unsafe {
            env::set_var(TELEMETRY_ENABLED_ENV, "true");
            let policy = TelemetryPolicy::from_environment().unwrap();
            assert!(policy.enabled);

            env::set_var(TELEMETRY_ENABLED_ENV, "false");
            let policy = TelemetryPolicy::from_environment().unwrap();
            assert!(!policy.enabled);

            env::set_var(TELEMETRY_ENABLED_ENV, "maybe");
            assert!(TelemetryPolicy::from_environment().is_err());

            env::remove_var(TELEMETRY_ENABLED_ENV);
        }
    }

    #[test]
    fn notifications_policy_defaults_to_disabled() {
        let policy = NotificationsPolicy::default();
        assert!(!policy.enabled);
    }

    #[test]
    fn notifications_env_var_parses_true_and_false() {
        unsafe {
            env::remove_var(NOTIFICATIONS_ENABLED_ENV);
            let policy = NotificationsPolicy::from_environment().unwrap();
            assert!(!policy.enabled);

            env::set_var(NOTIFICATIONS_ENABLED_ENV, "false");
            let policy = NotificationsPolicy::from_environment().unwrap();
            assert!(!policy.enabled);

            env::set_var(NOTIFICATIONS_ENABLED_ENV, "true");
            let policy = NotificationsPolicy::from_environment().unwrap();
            assert!(policy.enabled);

            env::set_var(NOTIFICATIONS_ENABLED_ENV, "maybe");
            assert!(NotificationsPolicy::from_environment().is_err());

            env::remove_var(NOTIFICATIONS_ENABLED_ENV);
        }
    }

    #[test]
    fn media_policy_defaults_to_enabled_and_parses_the_environment() {
        unsafe {
            env::remove_var(MEDIA_ENABLED_ENV);
            assert!(MediaPolicy::from_environment().unwrap().enabled);

            env::set_var(MEDIA_ENABLED_ENV, "false");
            assert!(!MediaPolicy::from_environment().unwrap().enabled);

            env::set_var(MEDIA_ENABLED_ENV, "true");
            assert!(MediaPolicy::from_environment().unwrap().enabled);

            env::set_var(MEDIA_ENABLED_ENV, "maybe");
            assert!(MediaPolicy::from_environment().is_err());

            env::remove_var(MEDIA_ENABLED_ENV);
        }
    }
}
