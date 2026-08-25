//! Typed parsing of Hyprland event-socket lines. Events are invalidation
//! hints only: they never build state, they only request a fresh snapshot.

use std::{
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::AsyncReadExt,
    net::UnixStream,
    sync::{mpsc, watch},
    time::sleep,
};
use tracing::{debug, warn};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionEvent {
    WorkspaceChanged,
    FocusedMonitorChanged,
    WindowOpened,
    WindowClosed,
    WindowMoved,
    ActiveWindowChanged,
}

const MAX_EVENT_LINE_BYTES: usize = 512;
const EVENT_SEPARATOR: char = '>';
const READ_CHUNK_BYTES: usize = 256;

/// Reconnect pacing. Production uses the default; tests shrink the delays.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ListenerConfig {
    pub initial_backoff: Duration,
    pub max_backoff: Duration,
}

impl ListenerConfig {
    #[allow(dead_code)]
    pub(crate) fn production() -> Self {
        Self {
            initial_backoff: Duration::from_millis(500),
            max_backoff: Duration::from_secs(8),
        }
    }
}

/// Parse one `event>>payload` line. Unknown event kinds are ignored by
/// returning None; malformed or oversized lines are ignored as well, which
/// keeps duplicate or hostile input harmless.
pub(crate) fn parse_event_line(line: &str) -> Option<SessionEvent> {
    let line = line.strip_suffix('\n').unwrap_or(line);
    if line.is_empty() || line.len() > MAX_EVENT_LINE_BYTES {
        return None;
    }

    let (kind, _payload) = line.split_once(EVENT_SEPARATOR)?;
    if !line[kind.len()..].starts_with(">>") {
        return None;
    }

    match kind {
        "workspace" | "activespecial" => Some(SessionEvent::WorkspaceChanged),
        "focusedmon" | "monitoradded" => Some(SessionEvent::FocusedMonitorChanged),
        "openwindow" => Some(SessionEvent::WindowOpened),
        "closenwindow" | "closewindow" => Some(SessionEvent::WindowClosed),
        "movewindow" | "movewindowv2" => Some(SessionEvent::WindowMoved),
        "activewindow" | "activewindowv2" => Some(SessionEvent::ActiveWindowChanged),
        _ => None,
    }
}

/// Long-running event listener. The invalidation channel must be a
/// capacity-1 slot: signals coalesce to a single "refetch needed" mark no
/// matter how large the burst. Every disconnect emits one signal because
/// events may have been missed while disconnected.
pub(crate) async fn run_event_listener(
    event_socket: PathBuf,
    invalidation_tx: mpsc::Sender<()>,
    mut shutdown: watch::Receiver<bool>,
    config: ListenerConfig,
) {
    let mut backoff = config.initial_backoff;
    loop {
        if *shutdown.borrow_and_update() {
            return;
        }

        match UnixStream::connect(&event_socket).await {
            Ok(mut stream) => {
                debug!(socket = %event_socket.display(), "Hyprland event socket connected");
                backoff = config.initial_backoff;
                loop {
                    let read = read_event_line(&mut stream);
                    let line = tokio::select! {
                        _ = shutdown.changed() => return,
                        line = read => line,
                    };
                    match line {
                        Ok(Some(line)) => {
                            if parse_event_line(&line).is_some() {
                                invalidate(&invalidation_tx);
                            }
                        }
                        Ok(None) | Err(_) => {
                            debug!("Hyprland event socket closed");
                            break;
                        }
                    }
                }
                invalidate(&invalidation_tx);
            }
            Err(error) => {
                warn!(%error, "Hyprland event socket unavailable");
            }
        }

        let delay = backoff.div_f64(2.0) + jitter(backoff.div_f64(2.0));
        tokio::select! {
            _ = shutdown.changed() => return,
            _ = sleep(delay) => {}
        }
        backoff = backoff
            .checked_mul(2)
            .map(|doubled| doubled.min(config.max_backoff))
            .unwrap_or(config.max_backoff)
            .max(config.initial_backoff);
    }
}

fn invalidate(invalidation_tx: &mpsc::Sender<()>) {
    // Full means the slot is already marked dirty; Closed means the
    // consumer stopped. Both are safe to ignore.
    let _ = invalidation_tx.try_send(());
}

/// Bounded line reader: never buffers more than MAX_EVENT_LINE_BYTES per
/// event; oversized garbage is skipped until the next newline.
async fn read_event_line(stream: &mut UnixStream) -> std::io::Result<Option<String>> {
    let mut carry = Vec::new();
    let mut chunk = [0_u8; READ_CHUNK_BYTES];
    loop {
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Ok(None);
        }
        for byte in &chunk[..read] {
            if *byte == b'\n' {
                return Ok(Some(String::from_utf8_lossy(&carry).into_owned()));
            }
            if carry.len() < MAX_EVENT_LINE_BYTES {
                carry.push(*byte);
            }
        }
    }
}

fn jitter(half_backoff: Duration) -> Duration {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since| since.subsec_nanos())
        .unwrap_or(0) as u64;
    let spread = half_backoff.as_millis() as u64;
    Duration::from_millis(nanos % (spread + 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_every_required_event_kind() {
        assert_eq!(
            parse_event_line("workspace>>2"),
            Some(SessionEvent::WorkspaceChanged)
        );
        assert_eq!(
            parse_event_line("workspace>>special:magic"),
            Some(SessionEvent::WorkspaceChanged)
        );
        assert_eq!(
            parse_event_line("activespecial>>special:magic,eDP-1"),
            Some(SessionEvent::WorkspaceChanged)
        );
        assert_eq!(
            parse_event_line("focusedmon>>eDP-1,2"),
            Some(SessionEvent::FocusedMonitorChanged)
        );
        assert_eq!(
            parse_event_line("openwindow>>0x55f0aaaa,1,code,Editor"),
            Some(SessionEvent::WindowOpened)
        );
        assert_eq!(
            parse_event_line("closenwindow>>0x55f0aaaa"),
            Some(SessionEvent::WindowClosed)
        );
        assert_eq!(
            parse_event_line("closewindow>>0x55f0aaaa"),
            Some(SessionEvent::WindowClosed)
        );
        assert_eq!(
            parse_event_line("movewindow>>0x55f0aaaa,3"),
            Some(SessionEvent::WindowMoved)
        );
        assert_eq!(
            parse_event_line("movewindowv2>>0x55f0aaaa,3"),
            Some(SessionEvent::WindowMoved)
        );
        assert_eq!(
            parse_event_line("activewindow>>,"),
            Some(SessionEvent::ActiveWindowChanged)
        );
        assert_eq!(
            parse_event_line("activewindow>>code,Editor"),
            Some(SessionEvent::ActiveWindowChanged)
        );
        assert_eq!(
            parse_event_line("activewindowv2>>0x55f0aaaa"),
            Some(SessionEvent::ActiveWindowChanged)
        );
    }

    #[test]
    fn ignores_unknown_malformed_and_oversized_lines() {
        assert_eq!(parse_event_line("configreloaded>>"), None);
        assert_eq!(parse_event_line("somerandomevent>>payload"), None);
        assert_eq!(parse_event_line(""), None);
        assert_eq!(parse_event_line("\n"), None);
        assert_eq!(parse_event_line("no separator here"), None);
        assert_eq!(parse_event_line("workspace>single"), None);
        assert_eq!(
            parse_event_line(&format!("workspace>>{}", "x".repeat(600))),
            None
        );
    }

    #[test]
    fn duplicates_are_parsed_identically_and_stay_harmless() {
        let first = parse_event_line("openwindow>>0x55f0aaaa,1,code,Editor");
        let second = parse_event_line("openwindow>>0x55f0aaaa,1,code,Editor");
        assert_eq!(first, second);
    }

    mod listener {
        use super::*;
        use std::os::unix::net::UnixListener as StdUnixListener;
        use std::sync::Arc;
        use tempfile::tempdir;
        use tokio::time::{Duration, timeout};

        fn fast_config() -> ListenerConfig {
            ListenerConfig {
                initial_backoff: Duration::from_millis(5),
                max_backoff: Duration::from_millis(40),
            }
        }

        struct FakeEventServer {
            path: PathBuf,
            listener: Arc<StdUnixListener>,
        }

        impl FakeEventServer {
            fn bind() -> Self {
                let directory = tempdir().unwrap();
                let path = directory.path().join("hypr/test/.socket2.sock");
                std::fs::create_dir_all(path.parent().unwrap()).unwrap();
                let listener = StdUnixListener::bind(&path).unwrap();
                // Keep the temporary directory alive for the whole test.
                std::mem::forget(directory);
                Self {
                    path,
                    listener: Arc::new(listener),
                }
            }

            /// Accept one connection, write the given lines, then close.
            fn serve_once(&self, lines: &[&str]) {
                let (mut stream, _) = self.listener.accept().unwrap();
                for line in lines {
                    use std::io::Write;
                    stream.write_all(line.as_bytes()).unwrap();
                }
            }
        }

        async fn spawn_listener(
            server: &FakeEventServer,
        ) -> (
            mpsc::Receiver<()>,
            watch::Sender<bool>,
            tokio::task::JoinHandle<()>,
        ) {
            let (tx, rx) = mpsc::channel(1);
            let (shutdown_tx, shutdown_rx) = watch::channel(false);
            let handle = tokio::spawn(run_event_listener(
                server.path.clone(),
                tx,
                shutdown_rx,
                fast_config(),
            ));
            (rx, shutdown_tx, handle)
        }

        #[tokio::test]
        async fn forwards_events_and_reconnects_after_restart() {
            let server = FakeEventServer::bind();
            let (mut rx, shutdown, handle) = spawn_listener(&server).await;

            std::thread::spawn(move || {
                server.serve_once(&["workspace>>1\n"]);
                // Simulate a compositor restart: connection drops, then a
                // fresh one is accepted after the backoff.
                server.serve_once(&["openwindow>>0xaa,1,c,t\n"]);
            });

            assert!(
                timeout(Duration::from_secs(5), rx.recv())
                    .await
                    .unwrap()
                    .is_some()
            );
            assert!(
                timeout(Duration::from_secs(5), rx.recv())
                    .await
                    .unwrap()
                    .is_some()
            );

            let _ = shutdown.send(true);
            handle.abort();
        }

        #[tokio::test]
        async fn bursts_coalesce_into_the_single_slot() {
            let server = FakeEventServer::bind();
            let (mut rx, shutdown, handle) = spawn_listener(&server).await;

            std::thread::spawn(move || {
                server.serve_once(&(0..500).map(|_| "workspace>>1\n").collect::<Vec<_>>());
            });

            // Drain whatever arrived within a generous window; the slot must
            // collapse the burst far below 500 signals.
            let mut received = 0;
            let drain = async {
                while rx.recv().await.is_some() {
                    received += 1;
                }
            };
            let _ = timeout(Duration::from_millis(700), drain).await;
            assert!(received >= 1);
            assert!(received < 50, "burst was not coalesced: {received} signals");

            let _ = shutdown.send(true);
            handle.abort();
        }

        #[tokio::test]
        async fn disconnect_invalidates_even_without_usable_events() {
            let server = FakeEventServer::bind();
            let (mut rx, shutdown, handle) = spawn_listener(&server).await;

            std::thread::spawn(move || {
                // Only an unknown event arrives, then the socket closes.
                server.serve_once(&["configreloaded>>\n"]);
            });

            assert!(
                timeout(Duration::from_secs(5), rx.recv())
                    .await
                    .unwrap()
                    .is_some(),
                "disconnect must emit an invalidation signal"
            );

            let _ = shutdown.send(true);
            handle.abort();
        }

        #[tokio::test]
        async fn shutdown_stops_the_listener_promptly() {
            let server = FakeEventServer::bind();
            let (_rx, shutdown, handle) = spawn_listener(&server).await;

            let _ = shutdown.send(true);
            timeout(Duration::from_secs(2), handle)
                .await
                .unwrap()
                .unwrap();
        }
    }
}
