//! P3.11 integration coverage: the full event -> invalidation -> refresh ->
//! published snapshot chain against a fake Hyprland instance, including an
//! outage/recovery cycle. Automated tests never touch a live compositor;
//! every socket here is temporary.

use std::{
    os::unix::net::UnixListener as StdUnixListener,
    path::PathBuf,
    sync::{Arc, mpsc as std_mpsc},
    time::Duration,
};
use tokio::sync::watch;

use crate::{
    hyprland::{
        ACTIVE_WINDOW_REQUEST, ACTIVE_WORKSPACE_REQUEST, COMMAND_SOCKET_NAME, EVENT_SOCKET_NAME,
        WINDOWS_REQUEST, WORKSPACES_REQUEST,
    },
    session_store::SessionStore,
};
use velora_protocol::WorkspaceSnapshot;

fn fast_listener_config() -> crate::hyprland_events::ListenerConfig {
    crate::hyprland_events::ListenerConfig {
        initial_backoff: Duration::from_millis(5),
        max_backoff: Duration::from_millis(40),
    }
}

/// Shared mutable session content for the fake command server.
struct FakeSession {
    workspace_ids: Vec<i64>,
    active_id: i64,
    unresponsive_until: Option<std::time::Instant>,
}

/// Deterministic fake Hyprland: answers every documented read query from its
/// current session state and serves an always-accepting event socket.
struct FakeHyprland {
    _directory: tempfile::TempDir,
    command_path: PathBuf,
    event_path: PathBuf,
    _command_server: std::thread::JoinHandle<()>,
    _event_writer: std::thread::JoinHandle<()>,
    event_line_sender: std_mpsc::Sender<String>,
    session_state: Arc<std::sync::Mutex<FakeSession>>,
}

impl FakeHyprland {
    fn spawn() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let instance = directory.path().join("hypr/fake-instance");
        std::fs::create_dir_all(&instance).unwrap();
        let command_path = instance.join(COMMAND_SOCKET_NAME);
        let event_path = instance.join(EVENT_SOCKET_NAME);
        let command_listener = StdUnixListener::bind(&command_path).unwrap();
        let event_listener = StdUnixListener::bind(&event_path).unwrap();

        // Shared mutable session content; the command server answers every
        // query from this state, so timed-out or retried attempts stay safe.
        let state: Arc<std::sync::Mutex<FakeSession>> =
            Arc::new(std::sync::Mutex::new(FakeSession {
                workspace_ids: vec![],
                active_id: 1,
                unresponsive_until: None,
            }));
        let server_state = Arc::clone(&state);
        let command_server = std::thread::spawn(move || {
            use std::io::{Read, Write};
            loop {
                let Ok((mut stream, _)) = command_listener.accept() else {
                    return;
                };
                let mut received = [0_u8; 32];
                let Ok(read) = stream.read(&mut received) else {
                    continue;
                };
                if read == 0 {
                    continue;
                }
                let request = &received[..read];
                let guard = server_state.lock().unwrap();
                if guard
                    .unresponsive_until
                    .is_some_and(|until| std::time::Instant::now() < until)
                {
                    continue;
                }
                let response: String = if request == WORKSPACES_REQUEST {
                    serde_json::json!(guard
                        .workspace_ids
                        .iter()
                        .map(|id| serde_json::json!({"id": id, "name": id.to_string(), "monitor": "eDP-1"}))
                        .collect::<Vec<_>>())
                    .to_string()
                } else if request == WINDOWS_REQUEST {
                    "[]".to_owned()
                } else if request == ACTIVE_WORKSPACE_REQUEST {
                    format!(
                        r#"{{"id":{},"name":"{}"}}"#,
                        guard.active_id, guard.active_id
                    )
                } else if request == ACTIVE_WINDOW_REQUEST {
                    "{}".to_owned()
                } else {
                    continue;
                };
                stream.write_all(response.as_bytes()).ok();
                drop(stream);
            }
        });

        // Event endpoint: adopt each listener connection and forward queued
        // event lines straight into it, reconnecting whenever Velora does.
        let (line_sender, line_receiver) = std_mpsc::channel::<String>();
        let event_writer = std::thread::spawn(move || {
            use std::io::Write;
            while let Ok(mut stream) = event_listener.accept().map(|(stream, _)| stream) {
                loop {
                    match line_receiver.recv() {
                        Ok(line) => {
                            if stream.write_all(line.as_bytes()).is_err() {
                                break;
                            }
                            stream.flush().ok();
                        }
                        Err(_) => return,
                    }
                }
            }
        });

        Self {
            _directory: directory,
            command_path,
            event_path,
            _command_server: command_server,
            _event_writer: event_writer,
            event_line_sender: line_sender,
            session_state: state,
        }
    }

    /// Update the served session content; `unresponsive_ms` simulates an
    /// outage window during which queries are simply never answered.
    fn set_session(&self, workspace_ids: &[i64], active_id: i64, unresponsive_ms: Option<u64>) {
        let mut guard = self.session_state.lock().unwrap();
        guard.workspace_ids = workspace_ids.to_vec();
        guard.active_id = active_id;
        guard.unresponsive_until =
            unresponsive_ms.map(|ms| std::time::Instant::now() + Duration::from_millis(ms));
    }

    /// Deliver one event line to the listener's live connection.
    fn send_event(&self, line: &str) {
        self.event_line_sender.send(format!("{line}\n")).unwrap();
        // Give the listener a beat to consume the line.
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[allow(dead_code)]
fn workspaces_json(ids: &[i64]) -> serde_json::Value {
    serde_json::json!(
        ids.iter()
            .map(|id| serde_json::json!({"id": id, "name": id.to_string(), "monitor": "eDP-1"}))
            .collect::<Vec<_>>()
    )
}

async fn wait_for_snapshot(
    store: &SessionStore,
    predicate: impl Fn(&WorkspaceSnapshot) -> bool,
) -> WorkspaceSnapshot {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(snapshot) = store.current().filter(|snapshot| predicate(snapshot)) {
            return (*snapshot).clone();
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for a matching session snapshot"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn events_drive_refreshes_across_an_outage_end_to_end() {
    let fake = FakeHyprland::spawn();
    fake.set_session(&[1], 1, None);

    let store = Arc::new(SessionStore::new(fake.command_path.clone()));
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let runner_store = Arc::clone(&store);
    let runner = tokio::spawn(runner_store.run_with_event_listener(
        fake.event_path.clone(),
        shutdown_rx,
        fast_listener_config(),
    ));

    // 1. The initial authoritative refresh populates the store.
    let first = wait_for_snapshot(&store, |snapshot| !snapshot.workspaces.is_empty()).await;
    assert_eq!(first.workspaces.len(), 1);
    assert_eq!(first.sequence, 1);

    // 2. A compositor event marks state dirty; the refresh publishes the new
    //    authoritative content with a bumped sequence.
    fake.set_session(&[1, 2], 2, None);
    fake.send_event("workspace>>2\n");
    let second = wait_for_snapshot(&store, |snapshot| snapshot.workspaces.len() == 2).await;
    assert_eq!(second.sequence, 2);
    assert_eq!(
        second.active_workspace_handle.as_deref(),
        Some("workspace:2")
    );

    // 3. Duplicate and unknown events are harmless hints that coalesce into
    //    at most one refresh of changed state.
    fake.set_session(&[1, 2, 3], 3, None);
    fake.send_event("configreloaded>>\n");
    fake.send_event("openwindow>>0xaa,3,c,t\n");
    fake.send_event("openwindow>>0xaa,3,c,t\n");
    let third = wait_for_snapshot(&store, |snapshot| snapshot.workspaces.len() == 3).await;
    assert_eq!(third.sequence, 3);

    // 4. Outage: the compositor stops answering. The event still triggers a
    //    refresh attempt that times out against the unresponsive socket, the
    //    last good snapshot is retained, and the retry converges once the
    //    compositor answers again.
    fake.set_session(&[1, 2, 3, 4], 4, Some(1200));
    fake.send_event("workspace>>4\n");
    let fourth = wait_for_snapshot(&store, |snapshot| snapshot.workspaces.len() == 4).await;
    assert_eq!(fourth.sequence, 4);
    assert_eq!(store.health().successful_refreshes, 4);
    assert!(
        store.health().failed_refreshes >= 1,
        "the outage was recorded"
    );

    let _ = shutdown_tx.send(true);
    runner.await.unwrap();
}

#[tokio::test]
async fn failed_queries_retain_last_good_state_and_record_health() {
    let fake = FakeHyprland::spawn();
    fake.set_session(&[7], 7, None);

    let store = Arc::new(SessionStore::new(fake.command_path.clone()));
    store.refresh().await.unwrap();
    let good_sequence = store.current().unwrap().sequence;

    // A store pointed at a dead socket models a vanished compositor.
    let dead = Arc::new(SessionStore::new(dead_socket_path()));
    assert!(dead.refresh().await.is_err());
    assert!(dead.current().is_none());
    assert_eq!(dead.health().failed_refreshes, 1);
    assert!(dead.health().last_error.is_some());

    // The healthy store still serves its retained snapshot untouched.
    assert_eq!(store.current().unwrap().sequence, good_sequence);
    assert_eq!(store.health().successful_refreshes, 1);
}

fn dead_socket_path() -> PathBuf {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join(COMMAND_SOCKET_NAME);
    std::mem::forget(directory);
    path
}
