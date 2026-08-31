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
