mod apps;
mod config;
mod dbus;
mod hyprland;
mod hyprland_events;
#[cfg(test)]
mod hyprland_integration;
mod ipc;
mod launch;
mod mpris;
mod mpris_events;
mod notifications;
mod session_store;
pub mod telemetry;

use anyhow::Result;
use std::sync::Arc;
use tokio::sync::watch;
use tracing::{debug, info};
use velora_protocol::HyprlandAvailability;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_target(false)
        .init();

    let config = config::CoreConfig::from_environment()?;
    let hyprland_capabilities = hyprland::probe_from_environment().await;
    let dbus_capabilities = dbus::probe_from_environment().await;
    let application_directories = apps::application_directories()?;
    let desktop_files = apps::discover_desktop_files(&application_directories)?;
    let applications = apps::load_applications(&desktop_files);
    let launch_paths = apps::launch_paths(&desktop_files, &applications);
    let launcher = Arc::new(launch::LaunchService::new(&applications, launch_paths));

    info!(?application_directories, "application search path resolved");
    info!(
        desktop_files = desktop_files.len(),
        applications = applications.len(),
        "desktop applications loaded"
    );
    for application in applications.iter().take(5) {
        debug!(
            desktop_id = %application.id,
            name = %application.name,
            terminal = application.terminal,
            "application registered"
        );
    }
    info!(socket = %config.socket_path.display(), "Velora Core starting");
    info!(
        telemetry_interval_ms = config.telemetry.interval.as_millis(),
        telemetry_max_devices = config.telemetry.max_devices,
        telemetry_max_interfaces = config.telemetry.max_interfaces,
        "telemetry sampling policy resolved"
    );
    info!(
        ?hyprland_capabilities,
        "Hyprland capability probe completed"
    );
    info!(?dbus_capabilities, "D-Bus capability probe completed");

    let session_runtime = start_session_store(&hyprland_capabilities);
    let telemetry_enabled = config.telemetry.enabled;
    let telemetry_runtime = start_telemetry_sampler(config.telemetry);
    let notifications_enabled = config.notifications.enabled;
    let notifications_runtime = start_notification_monitor(config.notifications);
    let result = ipc::serve(
        config,
        applications.into(),
        launcher,
        hyprland_capabilities,
        session_runtime
            .as_ref()
            .map(|runtime| Arc::clone(&runtime.store)),
        Arc::clone(&telemetry_runtime.store),
        telemetry_enabled,
        Arc::clone(&notifications_runtime.store),
        notifications_enabled,
    )
    .await;
    drop(session_runtime);
    drop(telemetry_runtime);
    drop(notifications_runtime);
    result
}

fn start_telemetry_sampler(policy: config::TelemetryPolicy) -> TelemetryRuntime {
    let store = Arc::new(telemetry::runtime::TelemetryStore::default());
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    if policy.enabled {
        tokio::spawn(telemetry::runtime::run(
            Arc::clone(&store),
            policy,
            shutdown_rx,
        ));
    }
    TelemetryRuntime { store, shutdown_tx }
}

/// When the privacy gate is open, keep the narrow notification monitor active
/// for Core's lifetime. The monitor's typed availability is published into the
/// shared store so the IPC handler can report Restricted/Unavailable.
fn start_notification_monitor(policy: config::NotificationsPolicy) -> NotificationRuntime {
    let store = Arc::new(notifications::NotificationStore::new());
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    if policy.enabled {
        tokio::spawn(notifications::run(Arc::clone(&store), shutdown_rx));
    }
    NotificationRuntime { store, shutdown_tx }
}

/// When Hyprland is fully available, keep an authoritative snapshot warm in
/// the background. The shutdown sender is held by Core for its lifetime.
fn start_session_store(
    capabilities: &velora_protocol::HyprlandCapabilities,
) -> Option<SessionRuntime> {
    if capabilities.availability != HyprlandAvailability::Available {
        return None;
    }
    let (command_socket, event_socket) = hyprland::instance_sockets_from_environment()?;
    let store = Arc::new(session_store::SessionStore::new(command_socket));
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let runner = Arc::clone(&store);
    tokio::spawn(runner.run_with_event_listener(
        event_socket,
        shutdown_rx,
        hyprland_events::ListenerConfig::production(),
    ));
    Some(SessionRuntime { store, shutdown_tx })
}

/// Owns the event-refresh task's shutdown sender for the Core lifetime.
struct SessionRuntime {
    store: Arc<session_store::SessionStore>,
    shutdown_tx: watch::Sender<bool>,
}

impl Drop for SessionRuntime {
    fn drop(&mut self) {
        let _ = self.shutdown_tx.send(true);
    }
}

struct TelemetryRuntime {
    store: Arc<telemetry::runtime::TelemetryStore>,
    shutdown_tx: watch::Sender<bool>,
}

impl Drop for TelemetryRuntime {
    fn drop(&mut self) {
        let _ = self.shutdown_tx.send(true);
    }
}

struct NotificationRuntime {
    store: Arc<notifications::NotificationStore>,
    shutdown_tx: watch::Sender<bool>,
}

impl Drop for NotificationRuntime {
    fn drop(&mut self) {
        let _ = self.shutdown_tx.send(true);
    }
}
