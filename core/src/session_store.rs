//! Authoritative workspace/window session state. Events only mark the state
//! dirty; this store always rebuilds from a full command-socket snapshot and
//! publishes nothing unless the content actually changed.

use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Instant,
};
use tokio::sync::{mpsc, watch};
use tracing::{debug, info, warn};
use velora_protocol::WorkspaceSnapshot;

use crate::{hyprland::read_session, hyprland_events};

#[derive(Debug, Default, Clone)]
pub(crate) struct StoreHealth {
    pub has_state: bool,
    pub successful_refreshes: u64,
    pub failed_refreshes: u64,
    pub last_success: Option<Instant>,
    pub last_error: Option<String>,
}

pub(crate) struct SessionStore {
    command_socket: PathBuf,
    sequence: AtomicU64,
    snapshot: Mutex<Option<Arc<WorkspaceSnapshot>>>,
    /// Latest changed snapshot for IPC clients. `watch` deliberately
    /// coalesces intermediate changes: clients only need the newest
    /// authoritative state and the sequence fences stale data.
    updates: watch::Sender<Option<Arc<WorkspaceSnapshot>>>,
    // Core-private handle -> compositor address mapping for focus requests.
    // Never serialized to any frontend.
    window_addresses: Mutex<HashMap<String, String>>,
    health: Mutex<StoreHealth>,
}

impl SessionStore {
    pub(crate) fn new(command_socket: PathBuf) -> Self {
        let (updates, _) = watch::channel(None);
        Self {
            command_socket,
            sequence: AtomicU64::new(0),
            snapshot: Mutex::new(None),
            updates,
            window_addresses: Mutex::new(HashMap::new()),
            health: Mutex::new(StoreHealth::default()),
        }
    }

    /// Query the compositor for a fresh authoritative snapshot. Identical
    /// content keeps the existing sequence so clients see no change.
    pub(crate) async fn refresh(&self) -> Result<(), crate::hyprland::AdapterError> {
        let next_sequence = self.sequence.load(Ordering::SeqCst) + 1;
        match read_session(&self.command_socket, next_sequence).await {
            Ok(reading) => {
                let fresh = reading.snapshot;
                let mut stored = self.snapshot.lock().unwrap();
                let changed = stored
                    .as_ref()
                    .is_none_or(|current| !content_eq(current, &fresh));
                if changed {
                    self.sequence.store(next_sequence, Ordering::SeqCst);
                    let fresh = Arc::new(fresh);
                    *stored = Some(Arc::clone(&fresh));
                    *self.window_addresses.lock().unwrap() = reading.window_addresses;
                    self.updates.send_replace(Some(fresh));
                    debug!(sequence = next_sequence, "published new session snapshot");
                } else {
                    debug!(sequence = next_sequence - 1, "session content unchanged");
                }
                let mut health = self.health.lock().unwrap();
                health.has_state = true;
                health.successful_refreshes += 1;
                health.last_success = Some(Instant::now());
                health.last_error = None;
                Ok(())
            }
            Err(error) => {
                let mut health = self.health.lock().unwrap();
                health.failed_refreshes += 1;
                health.last_error = Some(error.to_string());
                // The last good snapshot is intentionally retained so the
                // frontend can keep showing stale-but-labelled state.
                Err(error)
            }
        }
    }

    pub(crate) fn current(&self) -> Option<Arc<WorkspaceSnapshot>> {
        self.snapshot.lock().unwrap().clone()
    }

    /// Subscribe to changed snapshots for one IPC client. The receiver holds
    /// the most recent snapshot and coalesces bursts safely.
    pub(crate) fn subscribe(&self) -> watch::Receiver<Option<Arc<WorkspaceSnapshot>>> {
        self.updates.subscribe()
    }

    pub(crate) fn command_socket(&self) -> PathBuf {
        self.command_socket.clone()
    }

    /// Resolve a previously issued opaque handle to its compositor address.
    /// Returns None for unknown or stale handles; callers must fail closed.
    pub(crate) fn resolve_window_address(&self, handle: &str) -> Option<String> {
        self.window_addresses.lock().unwrap().get(handle).cloned()
    }

    // Consumed by diagnostics/UX from P3.06 onward.
    #[allow(dead_code)]
    pub(crate) fn health(&self) -> StoreHealth {
        self.health.lock().unwrap().clone()
    }

    /// Consume coalesced invalidation signals forever. Each signal triggers
    /// refreshes that retry with capped backoff, so one dirty mark always
    /// converges to a published snapshot even across outages.
    pub(crate) async fn run(
        self: Arc<Self>,
        mut invalidation_rx: mpsc::Receiver<()>,
        mut shutdown: watch::Receiver<bool>,
    ) {
        'signals: loop {
            tokio::select! {
                _ = shutdown.changed() => return,
                signal = invalidation_rx.recv() => {
                    if signal.is_none() {
                        return;
                    }
                    // Drain any signals that piled up behind this one.
                    while invalidation_rx.try_recv().is_ok() {}

                    let mut backoff = std::time::Duration::from_millis(250);
                    loop {
                        match self.refresh().await {
                            Ok(()) => continue 'signals,
                            Err(error) => {
                                warn!(%error, "session refresh after events failed");
                                tokio::select! {
                                    _ = shutdown.changed() => return,
                                    _ = tokio::time::sleep(backoff) => {}
                                }
                                backoff = (backoff * 2).min(std::time::Duration::from_secs(4));
                            }
                        }
                    }
                }
            }
        }
    }

    /// One initial refresh plus event-driven refreshes until shutdown.
    pub(crate) async fn run_with_event_listener(
        self: Arc<Self>,
        event_socket: PathBuf,
        shutdown: watch::Receiver<bool>,
        listener_config: hyprland_events::ListenerConfig,
    ) {
        if let Err(error) = self.refresh().await {
            info!(%error, "initial Hyprland session refresh failed");
        }

        let (invalidation_tx, invalidation_rx) = mpsc::channel(1);
        let listener = tokio::spawn(hyprland_events::run_event_listener(
            event_socket,
            invalidation_tx,
            shutdown.clone(),
            listener_config,
        ));

        self.run(invalidation_rx, shutdown).await;
        listener.abort();
    }
}

fn content_eq(current: &WorkspaceSnapshot, fresh: &WorkspaceSnapshot) -> bool {
    current.workspaces == fresh.workspaces
        && current.windows == fresh.windows
        && current.active_workspace_handle == fresh.active_workspace_handle
        && current.active_window_handle == fresh.active_window_handle
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hyprland::{
        ACTIVE_WORKSPACE_REQUEST, COMMAND_SOCKET_NAME, WINDOWS_REQUEST, WORKSPACES_REQUEST,
    };
    use serde_json::json;
    use std::os::unix::net::UnixListener as StdUnixListener;
    use tempfile::tempdir;

    fn fixture_workspaces(id: i64) -> serde_json::Value {
        json!([{"id": id, "name": id.to_string(), "monitor": "eDP-1", "windows": 0}])
    }

    fn fixture_active(id: i64) -> serde_json::Value {
        json!({"id": id, "name": id.to_string()})
    }

    /// Serves exactly one full four-query refresh cycle per call.
    fn serve_refresh(
        listener: &StdUnixListener,
        workspaces: &serde_json::Value,
        active: &serde_json::Value,
    ) {
        use std::io::{Read, Write};
        for (request, response) in [
            (WORKSPACES_REQUEST, workspaces.to_string()),
            (WINDOWS_REQUEST, "[]".to_owned()),
            (ACTIVE_WORKSPACE_REQUEST, active.to_string()),
            (crate::hyprland::ACTIVE_WINDOW_REQUEST, "{}".to_owned()),
        ] {
            let (mut stream, _) = listener.accept().unwrap();
            let mut received = [0_u8; 32];
            let read = stream.read(&mut received).unwrap();
            assert_eq!(&received[..read], request);
            stream.write_all(response.as_bytes()).unwrap();
        }
    }

    fn bound_store() -> (SessionStore, StdUnixListener, tempfile::TempDir) {
        let directory = tempdir().unwrap();
        let path = directory.path().join(COMMAND_SOCKET_NAME);
        let listener = StdUnixListener::bind(&path).unwrap();
        (SessionStore::new(path), listener, directory)
    }

    #[tokio::test]
    async fn refresh_populates_the_store_with_a_monotonic_sequence() {
        let (store, listener, _directory) = bound_store();

        let server = std::thread::spawn({
            let listener = listener.try_clone().unwrap();
            move || serve_refresh(&listener, &fixture_workspaces(1), &fixture_active(1))
        });
        store.refresh().await.unwrap();
        server.join().unwrap();

        assert_eq!(store.current().unwrap().sequence, 1);
        assert_eq!(store.current().unwrap().workspaces.len(), 1);
        assert!(store.health().has_state);
        assert_eq!(store.health().successful_refreshes, 1);
    }

    #[tokio::test]
    async fn unchanged_content_keeps_the_published_sequence() {
        let (store, listener, _directory) = bound_store();

        let server = std::thread::spawn({
            let listener = listener.try_clone().unwrap();
            let workspaces = fixture_workspaces(1);
            let active = fixture_active(1);
            move || {
                serve_refresh(&listener, &workspaces, &active);
                serve_refresh(&listener, &workspaces, &active);
            }
        });
        store.refresh().await.unwrap();
        store.refresh().await.unwrap();
        server.join().unwrap();

        assert_eq!(store.current().unwrap().sequence, 1);
        assert_eq!(store.health().successful_refreshes, 2);
    }

    #[tokio::test]
    async fn changed_content_bumps_the_sequence() {
        let (store, listener, _directory) = bound_store();

        let server = std::thread::spawn({
            let listener = listener.try_clone().unwrap();
            move || {
                serve_refresh(&listener, &fixture_workspaces(1), &fixture_active(1));
                serve_refresh(&listener, &fixture_workspaces(2), &fixture_active(2));
            }
        });
        store.refresh().await.unwrap();
        store.refresh().await.unwrap();
        server.join().unwrap();

        let snapshot = store.current().unwrap();
        assert_eq!(snapshot.sequence, 2);
        assert_eq!(snapshot.workspaces[0].handle, "workspace:2");
        assert_eq!(
            snapshot.active_workspace_handle.as_deref(),
            Some("workspace:2")
        );
    }

    #[tokio::test]
    async fn failed_refresh_retains_last_good_state_and_records_health() {
        let (store, _listener, _directory) = bound_store();
        // No server is listening: every query fails.
        assert!(store.refresh().await.is_err());
        assert!(store.current().is_none());
        assert_eq!(store.health().failed_refreshes, 1);
        assert!(store.health().last_error.is_some());
    }

    #[tokio::test]
    async fn invalidation_signals_trigger_exactly_one_refresh_each() {
        let (store, listener, _directory) = bound_store();
        let store = Arc::new(store);

        let server = std::thread::spawn({
            let listener = listener.try_clone().unwrap();
            move || {
                serve_refresh(&listener, &fixture_workspaces(1), &fixture_active(1));
                serve_refresh(&listener, &fixture_workspaces(2), &fixture_active(2));
            }
        });

        let (invalidation_tx, invalidation_rx) = mpsc::channel(1);
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let runner_store = Arc::clone(&store);
        let runner = tokio::spawn(runner_store.run(invalidation_rx, shutdown_rx));

        invalidation_tx.send(()).await.unwrap();
        invalidation_tx.send(()).await.unwrap();
        let mut reached_second_snapshot = false;
        for _ in 0..200 {
            if store
                .current()
                .is_some_and(|snapshot| snapshot.sequence >= 2)
            {
                reached_second_snapshot = true;
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert!(reached_second_snapshot, "store never refreshed twice");

        let _ = shutdown_tx.send(true);
        runner.await.unwrap();
        server.join().unwrap();

        assert_eq!(store.current().unwrap().sequence, 2);
        assert_eq!(store.health().successful_refreshes, 2);
    }
}
