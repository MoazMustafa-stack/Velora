use std::{
    sync::{Arc, Mutex},
    time::{Instant, SystemTime, UNIX_EPOCH},
};

use tokio::sync::watch;
use tracing::warn;
use velora_protocol::{DEFAULT_TELEMETRY_INTERVAL_MS, TelemetrySnapshot};

use super::{cpu, disk, memory, network};
use crate::config::TelemetryPolicy;

const PROC_STAT: &str = "/proc/stat";
const PROC_LOADAVG: &str = "/proc/loadavg";
const PROC_MEMINFO: &str = "/proc/meminfo";
const PROC_DISKSTATS: &str = "/proc/diskstats";
const PROC_NET_DEV: &str = "/proc/net/dev";

#[derive(Default)]
pub struct TelemetryStore(Mutex<Option<Arc<TelemetrySnapshot>>>);

impl TelemetryStore {
    pub fn current(&self) -> Option<Arc<TelemetrySnapshot>> {
        self.0.lock().unwrap().clone()
    }
    fn publish(&self, snapshot: TelemetrySnapshot) {
        *self.0.lock().unwrap() = Some(Arc::new(snapshot));
    }
}

pub async fn run(
    store: Arc<TelemetryStore>,
    policy: TelemetryPolicy,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut ticker = tokio::time::interval(policy.interval);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut previous = Previous::default();
    loop {
        tokio::select! {
            _ = shutdown.changed() => return,
            _ = ticker.tick() => match sample(&mut previous, policy).await {
                Ok(snapshot) => store.publish(snapshot),
                Err(error) => warn!(%error, "telemetry sample failed; retaining last good snapshot"),
            },
        }
    }
}

#[derive(Default)]
struct Previous {
    sequence: u64,
    sampled_at: Option<Instant>,
    cpu: Option<cpu::CpuCounters>,
    disk: Option<disk::DiskCountersSnapshot>,
    network: Option<network::NetworkCountersSnapshot>,
}

async fn sample(
    previous: &mut Previous,
    policy: TelemetryPolicy,
) -> anyhow::Result<TelemetrySnapshot> {
    let (stat, loadavg, meminfo, diskstats, net_dev) = tokio::try_join!(
        tokio::fs::read_to_string(PROC_STAT),
        tokio::fs::read_to_string(PROC_LOADAVG),
        tokio::fs::read_to_string(PROC_MEMINFO),
        tokio::fs::read_to_string(PROC_DISKSTATS),
        tokio::fs::read_to_string(PROC_NET_DEV),
    )?;
    let now = Instant::now();
    let elapsed = previous
        .sampled_at
        .map(|then| now.duration_since(then))
        .unwrap_or(policy.interval);
    let cpu_counters = cpu::parse_proc_stat(&stat)?;
    let disk_counters = disk::parse_diskstats(&diskstats, policy.max_devices)?;
    let network_counters = network::parse_net_dev(&net_dev, policy.max_interfaces)?;
    previous.sequence += 1;
    let snapshot = TelemetrySnapshot {
        sequence: previous.sequence,
        sampled_at_unix_ms: SystemTime::now()
            .duration_since(UNIX_EPOCH)?
            .as_millis()
            .try_into()
            .unwrap_or(u64::MAX),
        sample_interval_ms: u32::try_from(policy.interval.as_millis())
            .unwrap_or(DEFAULT_TELEMETRY_INTERVAL_MS),
        cpu: cpu::calculate_cpu_telemetry(
            previous.cpu.as_ref(),
            &cpu_counters,
            cpu::parse_loadavg(&loadavg)?,
        ),
        memory: memory::parse_meminfo(&meminfo)?,
        disk: disk::calculate_disk_telemetry(previous.disk.as_ref(), &disk_counters, elapsed),
        network: network::calculate_network_telemetry(
            previous.network.as_ref(),
            &network_counters,
            elapsed,
        ),
    };
    snapshot.validate()?;
    previous.sampled_at = Some(now);
    previous.cpu = Some(cpu_counters);
    previous.disk = Some(disk_counters);
    previous.network = Some(network_counters);
    Ok(snapshot)
}

#[cfg(test)]
mod tests {
    use super::*;
    use velora_protocol::{
        CpuTelemetry, DiskTelemetry, MemoryTelemetry, NetworkTelemetry, TelemetryAvailability,
    };

    fn test_snapshot(sequence: u64) -> TelemetrySnapshot {
        TelemetrySnapshot {
            sequence,
            sampled_at_unix_ms: 1_777_777_777_000,
            sample_interval_ms: 1_000,
            cpu: CpuTelemetry {
                availability: TelemetryAvailability::Available,
                utilization_basis_points: Some(3_725),
                logical_cpu_count: 8,
                load_1m_milli: 750,
                load_5m_milli: 1_250,
                load_15m_milli: 2_000,
            },
            memory: MemoryTelemetry {
                availability: TelemetryAvailability::Available,
                total_bytes: 16 * 1024 * 1024 * 1024,
                available_bytes: 10 * 1024 * 1024 * 1024,
                used_bytes: 6 * 1024 * 1024 * 1024,
                cached_bytes: 2 * 1024 * 1024 * 1024,
                swap_total_bytes: 4 * 1024 * 1024 * 1024,
                swap_used_bytes: 512 * 1024 * 1024,
            },
            disk: DiskTelemetry {
                availability: TelemetryAvailability::Available,
                read_bytes_per_second: 1_048_576,
                write_bytes_per_second: 524_288,
                device_count: 2,
            },
            network: NetworkTelemetry {
                availability: TelemetryAvailability::WarmingUp,
                receive_bytes_per_second: 0,
                transmit_bytes_per_second: 0,
                interface_count: 1,
            },
        }
    }

    #[test]
    fn store_starts_empty() {
        let store = TelemetryStore::default();
        assert!(store.current().is_none());
    }

    #[test]
    fn publish_makes_current_available() {
        let store = TelemetryStore::default();
        store.publish(test_snapshot(1));
        let current = store.current().unwrap();
        assert_eq!(current.sequence, 1);
        assert_eq!(current.cpu.logical_cpu_count, 8);
    }

    #[test]
    fn publish_overwrites_previous() {
        let store = TelemetryStore::default();
        store.publish(test_snapshot(1));
        store.publish(test_snapshot(2));
        let current = store.current().unwrap();
        assert_eq!(current.sequence, 2);
    }

    #[test]
    fn published_snapshot_is_shared_arc() {
        let store = TelemetryStore::default();
        store.publish(test_snapshot(5));
        let first = store.current().unwrap();
        let second = store.current().unwrap();
        assert!(Arc::ptr_eq(&first, &second));
    }
}
