use crate::{
    config::CoreConfig,
    launch::{ApplicationLauncher, LaunchService},
};
use anyhow::{Context, Result, bail};
use std::{
    fs,
    future::Future,
    io,
    os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::watch,
    time::timeout,
};
use tracing::{info, warn};
use velora_protocol::{
    Application, HANDSHAKE_TIMEOUT_SECONDS, HyprlandAvailability, HyprlandCapabilities,
    MAX_APPLICATION_PAGE_SIZE, MAX_MESSAGE_BYTES, PROTOCOL_VERSION, Request, Response, SERVER_NAME,
    TelemetrySnapshotError, WindowFocusError, WorkspaceSnapshotError, WorkspaceSwitchError,
};

use crate::{session_store::SessionStore, telemetry::runtime::TelemetryStore};

pub(crate) async fn serve(
    config: CoreConfig,
    applications: Arc<[Application]>,
    launcher: Arc<LaunchService>,
    hyprland_capabilities: HyprlandCapabilities,
    session: Option<Arc<SessionStore>>,
    telemetry: Arc<TelemetryStore>,
) -> Result<()> {
    serve_until(
        config,
        applications,
        launcher,
        hyprland_capabilities,
        session,
        telemetry,
        async {
            tokio::signal::ctrl_c()
                .await
                .context("failed to listen for shutdown signal")
        },
    )
    .await
}

async fn serve_until<L, F>(
    config: CoreConfig,
    applications: Arc<[Application]>,
    launcher: Arc<L>,
    hyprland_capabilities: HyprlandCapabilities,
    session: Option<Arc<SessionStore>>,
    telemetry: Arc<TelemetryStore>,
    shutdown: F,
) -> Result<()>
where
    L: ApplicationLauncher + 'static,
    F: Future<Output = Result<()>> + Send,
{
    prepare_socket_path(&config.socket_path).await?;
    let listener = UnixListener::bind(&config.socket_path)
        .with_context(|| format!("cannot bind {}", config.socket_path.display()))?;
    fs::set_permissions(&config.socket_path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("cannot secure {}", config.socket_path.display()))?;
    let _socket_guard = SocketGuard::new(config.socket_path.clone())?;
    info!(socket = %config.socket_path.display(), "socket ready");
    tokio::pin!(shutdown);

    loop {
        tokio::select! {
            result = listener.accept() => match result {
                Ok((stream, _)) => {
                    let applications = Arc::clone(&applications);
                    let launcher = Arc::clone(&launcher);
                    let hyprland_capabilities = hyprland_capabilities.clone();
                    let session = session.clone();
                    let telemetry = Arc::clone(&telemetry);
                    tokio::spawn(async move {
                        if let Err(error) = handle_connection_with_services(
                            stream,
                            applications,
                            launcher,
                            hyprland_capabilities,
                            session,
                            telemetry,
                        )
                        .await
                        {
                            warn!(%error, "frontend connection failed");
                        }
                    });
                }
                Err(error) => warn!(%error, "failed to accept frontend connection"),
            },
            signal = &mut shutdown => {
                signal?;
                info!("Velora Core shutting down");
                break;
            }
        }
    }
    Ok(())
}

async fn prepare_socket_path(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error).with_context(|| format!("cannot inspect {}", path.display()));
        }
    };

    if !metadata.file_type().is_socket() {
        bail!("refusing to remove non-socket path at {}", path.display());
    }

    match UnixStream::connect(path).await {
        Ok(_) => bail!("Velora Core is already running at {}", path.display()),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
            ) =>
        {
            fs::remove_file(path)
                .with_context(|| format!("cannot remove stale socket {}", path.display()))?;
            Ok(())
        }
        Err(error) => Err(error)
            .with_context(|| format!("cannot verify existing socket at {}", path.display())),
    }
}

#[cfg(test)]
async fn handle_connection<L>(
    stream: UnixStream,
    applications: Arc<[Application]>,
    launcher: Arc<L>,
) -> Result<()>
where
    L: ApplicationLauncher + 'static,
{
    handle_connection_with_capabilities(
        stream,
        applications,
        launcher,
        HyprlandCapabilities::unavailable(),
        dead_session_store(),
    )
    .await
}

#[cfg(test)]
fn dead_session_store() -> Option<Arc<SessionStore>> {
    Some(Arc::new(SessionStore::new(PathBuf::from(
        "/tmp/velora-test-unreachable.sock",
    ))))
}

#[cfg(test)]
async fn handle_connection_with_capabilities<L>(
    stream: UnixStream,
    applications: Arc<[Application]>,
    launcher: Arc<L>,
    hyprland_capabilities: HyprlandCapabilities,
    session: Option<Arc<SessionStore>>,
) -> Result<()>
where
    L: ApplicationLauncher + 'static,
{
    handle_connection_with_services(
        stream,
        applications,
        launcher,
        hyprland_capabilities,
        session,
        Arc::new(TelemetryStore::default()),
    )
    .await
}

async fn handle_connection_with_services<L>(
    stream: UnixStream,
    applications: Arc<[Application]>,
    launcher: Arc<L>,
    hyprland_capabilities: HyprlandCapabilities,
    session: Option<Arc<SessionStore>>,
    telemetry: Arc<TelemetryStore>,
) -> Result<()>
where
    L: ApplicationLauncher + 'static,
{
    info!("frontend connected");
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);

    let first_frame = match timeout(
        Duration::from_secs(HANDSHAKE_TIMEOUT_SECONDS),
        read_frame(&mut reader),
    )
    .await
    {
        Ok(frame) => frame?,
        Err(_) => {
            write_response(
                &mut writer,
                &Response::error("handshake_timeout", "hello was not received in time", true),
            )
            .await?;
            return Ok(());
        }
    };

    let Some(first_line) = frame_to_line(first_frame, &mut writer).await? else {
        return Ok(());
    };
    let first_request = match serde_json::from_str::<Request>(&first_line) {
        Ok(request) => request,
        Err(error) => {
            write_response(
                &mut writer,
                &Response::error(
                    "invalid_request",
                    format!("invalid request: {error}"),
                    false,
                ),
            )
            .await?;
            return Ok(());
        }
    };

    match first_request {
        Request::Hello {
            protocol_version, ..
        } if protocol_version == PROTOCOL_VERSION => {
            write_response(
                &mut writer,
                &Response::Welcome {
                    protocol_version: PROTOCOL_VERSION,
                    server_name: SERVER_NAME.to_owned(),
                    server_version: env!("CARGO_PKG_VERSION").to_owned(),
                },
            )
            .await?;
        }
        Request::Hello {
            protocol_version, ..
        } => {
            write_response(
                &mut writer,
                &Response::error(
                    "protocol_mismatch",
                    format!(
                        "unsupported protocol version {protocol_version}; expected {PROTOCOL_VERSION}"
                    ),
                    false,
                ),
            )
            .await?;
            return Ok(());
        }
        _ => {
            write_response(
                &mut writer,
                &Response::error(
                    "handshake_required",
                    "send hello before other requests",
                    false,
                ),
            )
            .await?;
            return Ok(());
        }
    }

    let mut snapshot_updates = session.as_ref().map(|store| store.subscribe());
    // Do not interleave a pushed snapshot into a client that has not yet
    // requested its initial state. Once it has, every later changed snapshot
    // is delivered with request ID zero.
    let mut session_updates_enabled = false;
    loop {
        let line = tokio::select! {
            frame = read_frame(&mut reader) => {
                let Some(line) = frame_to_line(frame?, &mut writer).await? else {
                    break;
                };
                line
            }
            changed = wait_for_snapshot_update(&mut snapshot_updates) => {
                if changed.is_err() {
                    break;
                }
                let snapshot = snapshot_updates
                    .as_mut()
                    .and_then(|receiver| receiver.borrow_and_update().clone());
                if !session_updates_enabled {
                    continue;
                }
                let Some(snapshot) = snapshot else {
                    continue;
                };
                write_response(
                    &mut writer,
                    &Response::WorkspaceSnapshot {
                        protocol_version: PROTOCOL_VERSION,
                        // A zero request ID identifies a Core-published update.
                        request_id: 0,
                        snapshot: (*snapshot).clone(),
                    },
                )
                .await?;
                continue;
            }
        };
        let response = match serde_json::from_str::<Request>(&line) {
            Ok(request) if request.protocol_version() != PROTOCOL_VERSION => {
                Response::error("protocol_mismatch", "protocol version changed", false)
            }
            Ok(Request::Ping { request_id, .. }) => Response::Pong {
                protocol_version: PROTOCOL_VERSION,
                request_id,
            },
            Ok(Request::ListApplications {
                request_id,
                offset,
                limit,
                ..
            }) => match application_page(&applications, request_id, offset, limit) {
                Ok(response) => response,
                Err(error) => {
                    warn!(%error, "cannot build application registry page");
                    Response::error(
                        "application_page_failed",
                        "application registry page exceeds the transport limit",
                        false,
                    )
                }
            },
            Ok(Request::LaunchApplication {
                request_id,
                desktop_id,
                ..
            }) => match launcher.launch(&desktop_id).await {
                Ok(process_id) => Response::LaunchAccepted {
                    protocol_version: PROTOCOL_VERSION,
                    request_id,
                    desktop_id,
                    process_id,
                },
                Err(error) => Response::LaunchRejected {
                    protocol_version: PROTOCOL_VERSION,
                    request_id,
                    desktop_id,
                    code: error.code().to_owned(),
                    message: error.to_string(),
                    retryable: error.retryable(),
                },
            },
            Ok(Request::GetHyprlandCapabilities { request_id, .. }) => {
                Response::HyprlandCapabilities {
                    protocol_version: PROTOCOL_VERSION,
                    request_id,
                    capabilities: hyprland_capabilities.clone(),
                }
            }
            Ok(Request::GetWorkspaceSnapshot { request_id, .. }) => {
                workspace_snapshot_response(request_id, &hyprland_capabilities, session.as_deref())
                    .await
            }
            Ok(Request::SwitchWorkspace {
                request_id,
                workspace_handle,
                ..
            }) => {
                switch_workspace_response(
                    request_id,
                    &workspace_handle,
                    &hyprland_capabilities,
                    session.as_deref(),
                )
                .await
            }
            Ok(Request::FocusWindow {
                request_id,
                window_handle,
                ..
            }) => {
                focus_window_response(
                    request_id,
                    &window_handle,
                    &hyprland_capabilities,
                    session.as_deref(),
                )
                .await
            }
            Ok(Request::GetTelemetrySnapshot { request_id, .. }) => match telemetry.current() {
                Some(snapshot) => Response::TelemetrySnapshot {
                    protocol_version: PROTOCOL_VERSION,
                    request_id,
                    snapshot: (*snapshot).clone(),
                },
                None => Response::TelemetrySnapshotRejected {
                    protocol_version: PROTOCOL_VERSION,
                    request_id,
                    code: TelemetrySnapshotError::SnapshotNotReady,
                    retryable: true,
                },
            },
            Ok(Request::Hello { .. }) => {
                Response::error("already_handshaken", "hello has already completed", false)
            }
            Err(error) => Response::error(
                "invalid_request",
                format!("invalid request: {error}"),
                false,
            ),
        };
        let should_close = matches!(
            response,
            Response::Error { ref code, .. } if code == "protocol_mismatch"
        );
        if matches!(response, Response::WorkspaceSnapshot { .. }) {
            if let Some(receiver) = &mut snapshot_updates {
                receiver.borrow_and_update();
            }
            session_updates_enabled = true;
        }
        write_response(&mut writer, &response).await?;
        if should_close {
            break;
        }
    }
    info!("frontend disconnected");
    Ok(())
}

async fn wait_for_snapshot_update(
    receiver: &mut Option<watch::Receiver<Option<Arc<velora_protocol::WorkspaceSnapshot>>>>,
) -> Result<(), watch::error::RecvError> {
    match receiver {
        Some(receiver) => receiver.changed().await,
        None => std::future::pending().await,
    }
}

fn workspace_snapshot_rejection(request_id: u64, capabilities: &HyprlandCapabilities) -> Response {
    let code = match capabilities.availability {
        HyprlandAvailability::Unavailable => WorkspaceSnapshotError::HyprlandUnavailable,
        HyprlandAvailability::Incompatible => WorkspaceSnapshotError::HyprlandIncompatible,
        HyprlandAvailability::Available => WorkspaceSnapshotError::SnapshotNotReady,
    };
    let retryable = !matches!(code, WorkspaceSnapshotError::HyprlandIncompatible);

    Response::WorkspaceSnapshotRejected {
        protocol_version: PROTOCOL_VERSION,
        request_id,
        code,
        retryable,
    }
}

/// Serve the authoritative cached snapshot; when nothing is cached yet and
/// Hyprland is available, fall back to one on-demand refresh. Any failure
/// degrades to the typed rejection instead of an error response.
async fn workspace_snapshot_response(
    request_id: u64,
    capabilities: &HyprlandCapabilities,
    session: Option<&SessionStore>,
) -> Response {
    if capabilities.availability != HyprlandAvailability::Available {
        return workspace_snapshot_rejection(request_id, capabilities);
    }
    let Some(session) = session else {
        return workspace_snapshot_rejection(request_id, capabilities);
    };

    if session.current().is_none() {
        let _ = session.refresh().await;
    }

    match session.current() {
        Some(snapshot) => Response::WorkspaceSnapshot {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            snapshot: (*snapshot).clone(),
        },
        None => workspace_snapshot_rejection(request_id, capabilities),
    }
}

/// Fail-closed workspace switching: every uncertainty produces a typed
/// rejection, the handle must exist in the current authoritative snapshot,
/// and only plain numeric workspaces are switchable.
async fn switch_workspace_response(
    request_id: u64,
    workspace_handle: &str,
    capabilities: &HyprlandCapabilities,
    session: Option<&SessionStore>,
) -> Response {
    let reject = |code| Response::SwitchRejected {
        protocol_version: PROTOCOL_VERSION,
        request_id,
        workspace_handle: workspace_handle.to_owned(),
        code,
    };

    let availability_error = match capabilities.availability {
        HyprlandAvailability::Available => None,
        HyprlandAvailability::Unavailable => Some(WorkspaceSwitchError::HyprlandUnavailable),
        HyprlandAvailability::Incompatible => Some(WorkspaceSwitchError::HyprlandIncompatible),
    };
    if let Some(code) = availability_error {
        return reject(code);
    }

    let Some(session) = session else {
        return reject(WorkspaceSwitchError::HyprlandUnavailable);
    };
    if session.current().is_none() {
        let _ = session.refresh().await;
    }
    let Some(snapshot) = session.current() else {
        return reject(WorkspaceSwitchError::UnknownWorkspaceHandle);
    };

    let Some(workspace) = snapshot
        .workspaces
        .iter()
        .find(|workspace| workspace.handle == workspace_handle)
    else {
        return reject(WorkspaceSwitchError::UnknownWorkspaceHandle);
    };
    if workspace.is_special || !(1..=i32::MAX).contains(&workspace.index) {
        return reject(WorkspaceSwitchError::UnsupportedWorkspace);
    }

    let command_socket = session.command_socket();
    match crate::hyprland::switch_to_workspace_id(&command_socket, workspace.index).await {
        Ok(()) => Response::SwitchAccepted {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            workspace_handle: workspace_handle.to_owned(),
        },
        Err(error) => {
            warn!(%error, "workspace switch rejected by compositor");
            reject(WorkspaceSwitchError::SwitchFailed)
        }
    }
}

/// Fail-closed window focusing: only handles issued by the current snapshot
/// resolve to a compositor address, and that address is re-validated before
/// any dispatcher command is constructed.
async fn focus_window_response(
    request_id: u64,
    window_handle: &str,
    capabilities: &HyprlandCapabilities,
    session: Option<&SessionStore>,
) -> Response {
    let reject = |code| Response::FocusRejected {
        protocol_version: PROTOCOL_VERSION,
        request_id,
        window_handle: window_handle.to_owned(),
        code,
    };

    let availability_error = match capabilities.availability {
        HyprlandAvailability::Available => None,
        HyprlandAvailability::Unavailable => Some(WindowFocusError::HyprlandUnavailable),
        HyprlandAvailability::Incompatible => Some(WindowFocusError::HyprlandIncompatible),
    };
    if let Some(code) = availability_error {
        return reject(code);
    }

    let Some(session) = session else {
        return reject(WindowFocusError::HyprlandUnavailable);
    };
    if session.current().is_none() {
        let _ = session.refresh().await;
    }

    let Some(address) = session.resolve_window_address(window_handle) else {
        return reject(WindowFocusError::UnknownWindowHandle);
    };

    let command_socket = session.command_socket();
    match crate::hyprland::focus_window_by_address(&command_socket, &address).await {
        Ok(()) => {
            // Focus changed compositor state; refresh so the next snapshot
            // reflects the new active window instead of trusting the event.
            let _ = session.refresh().await;
            Response::FocusAccepted {
                protocol_version: PROTOCOL_VERSION,
                request_id,
                window_handle: window_handle.to_owned(),
            }
        }
        Err(error) => {
            warn!(%error, "window focus rejected by compositor");
            reject(WindowFocusError::FocusFailed)
        }
    }
}

fn application_page(
    applications: &[Application],
    request_id: u64,
    offset: u32,
    limit: u16,
) -> Result<Response> {
    let total = u32::try_from(applications.len()).unwrap_or(u32::MAX);
    let start = usize::try_from(offset)
        .unwrap_or(usize::MAX)
        .min(applications.len());
    let limit = usize::from(limit.clamp(1, MAX_APPLICATION_PAGE_SIZE));
    let requested_end = start.saturating_add(limit).min(applications.len());
    // Page size is monotonic with the number of entries, so binary-search the
    // largest transport-safe endpoint instead of cloning and serializing every
    // intermediate candidate.
    let mut end = start;
    let mut upper_bound = requested_end;
    while end < upper_bound {
        let candidate_end = end + (upper_bound - end).div_ceil(2);
        let candidate =
            application_page_response(applications, request_id, start, candidate_end, total);
        let encoded_size = serde_json::to_vec(&candidate)
            .context("failed to size application page")?
            .len();
        if encoded_size <= MAX_MESSAGE_BYTES {
            end = candidate_end;
        } else {
            upper_bound = candidate_end - 1;
        }
    }

    if end == start && start < requested_end {
        bail!(
            "application {} cannot fit within the 64 KiB transport limit",
            applications[start].id
        );
    }

    Ok(application_page_response(
        applications,
        request_id,
        start,
        end,
        total,
    ))
}

fn application_page_response(
    applications: &[Application],
    request_id: u64,
    start: usize,
    end: usize,
    total: u32,
) -> Response {
    let next_offset = (end < applications.len()).then(|| u32::try_from(end).unwrap_or(u32::MAX));

    Response::Applications {
        protocol_version: PROTOCOL_VERSION,
        request_id,
        applications: applications[start..end].to_vec(),
        next_offset,
        total,
    }
}

enum Frame {
    EndOfStream,
    Line(String),
    TooLarge,
    InvalidUtf8,
}

async fn read_frame<R>(reader: &mut R) -> io::Result<Frame>
where
    R: AsyncBufRead + Unpin,
{
    let mut bytes = Vec::new();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return if bytes.is_empty() {
                Ok(Frame::EndOfStream)
            } else {
                Ok(Frame::InvalidUtf8)
            };
        }

        if let Some(newline_index) = available.iter().position(|byte| *byte == b'\n') {
            if bytes.len() + newline_index > MAX_MESSAGE_BYTES {
                reader.consume(newline_index + 1);
                return Ok(Frame::TooLarge);
            }
            bytes.extend_from_slice(&available[..newline_index]);
            reader.consume(newline_index + 1);
            return Ok(match String::from_utf8(bytes) {
                Ok(line) => Frame::Line(line),
                Err(_) => Frame::InvalidUtf8,
            });
        }

        if bytes.len() + available.len() > MAX_MESSAGE_BYTES {
            let consumed = available.len();
            reader.consume(consumed);
            return Ok(Frame::TooLarge);
        }
        bytes.extend_from_slice(available);
        let consumed = available.len();
        reader.consume(consumed);
    }
}

async fn frame_to_line<W>(frame: Frame, writer: &mut W) -> Result<Option<String>>
where
    W: AsyncWrite + Unpin,
{
    match frame {
        Frame::EndOfStream => Ok(None),
        Frame::Line(line) => Ok(Some(line)),
        Frame::TooLarge => {
            write_response(
                writer,
                &Response::error("message_too_large", "message exceeds 64 KiB", false),
            )
            .await?;
            Ok(None)
        }
        Frame::InvalidUtf8 => {
            write_response(
                writer,
                &Response::error(
                    "invalid_encoding",
                    "message must be UTF-8 and newline terminated",
                    false,
                ),
            )
            .await?;
            Ok(None)
        }
    }
}

async fn write_response<W>(writer: &mut W, response: &Response) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    let mut json = serde_json::to_vec(response).context("failed to serialize response")?;
    if json.len() > MAX_MESSAGE_BYTES {
        bail!("refusing to write response larger than 64 KiB");
    }
    json.push(b'\n');
    writer
        .write_all(&json)
        .await
        .context("failed to write response")
}

struct SocketGuard {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl SocketGuard {
    fn new(path: PathBuf) -> Result<Self> {
        let metadata = fs::symlink_metadata(&path)
            .with_context(|| format!("cannot inspect created socket {}", path.display()))?;
        Ok(Self {
            path,
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        let Ok(metadata) = fs::symlink_metadata(&self.path) else {
            return;
        };
        if metadata.file_type().is_socket()
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            fs::remove_file(&self.path).ok();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::launch::LaunchError;
    use std::{
        future::ready, os::unix::fs::symlink, os::unix::net::UnixListener as StdUnixListener,
        sync::Mutex,
    };
    use tempfile::tempdir;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    use tokio::sync::oneshot;

    #[derive(Clone, Copy)]
    enum MockLaunchOutcome {
        Accepted(u32),
        UnknownApplication,
        RateLimited,
    }

    struct MockLauncher {
        outcome: MockLaunchOutcome,
        requests: Mutex<Vec<String>>,
    }

    impl MockLauncher {
        fn new(outcome: MockLaunchOutcome) -> Self {
            Self {
                outcome,
                requests: Mutex::new(Vec::new()),
            }
        }

        fn requests(&self) -> Vec<String> {
            self.requests.lock().unwrap().clone()
        }
    }

    impl ApplicationLauncher for MockLauncher {
        fn launch<'a>(
            &'a self,
            desktop_id: &'a str,
        ) -> impl Future<Output = Result<u32, LaunchError>> + Send + 'a {
            self.requests.lock().unwrap().push(desktop_id.to_owned());
            ready(match self.outcome {
                MockLaunchOutcome::Accepted(process_id) => Ok(process_id),
                MockLaunchOutcome::UnknownApplication => Err(LaunchError::UnknownApplication),
                MockLaunchOutcome::RateLimited => Err(LaunchError::RateLimited),
            })
        }
    }

    async fn send_request(reader: &mut BufReader<UnixStream>, request: &Request) -> Response {
        let request = serde_json::to_string(request).unwrap();
        reader
            .get_mut()
            .write_all(format!("{request}\n").as_bytes())
            .await
            .unwrap();
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        serde_json::from_str(line.trim()).unwrap()
    }

    async fn connect_and_handshake(path: &Path) -> BufReader<UnixStream> {
        let stream = UnixStream::connect(path).await.unwrap();
        let mut reader = BufReader::new(stream);
        let response = send_request(
            &mut reader,
            &Request::Hello {
                protocol_version: PROTOCOL_VERSION,
                client_name: "test-client".to_owned(),
                client_version: "0.2.0".to_owned(),
            },
        )
        .await;
        assert!(matches!(response, Response::Welcome { .. }));
        reader
    }

    async fn wait_for_socket(path: &Path) {
        timeout(Duration::from_secs(2), async {
            while !path.exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("server did not create its socket");
    }

    #[tokio::test]
    async fn refuses_to_remove_regular_file() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("velora.sock");
        fs::write(&path, "keep me").unwrap();
        assert!(prepare_socket_path(&path).await.is_err());
        assert_eq!(fs::read_to_string(path).unwrap(), "keep me");
    }

    #[tokio::test]
    async fn refuses_to_remove_symlink() {
        let directory = tempdir().unwrap();
        let target = directory.path().join("target");
        let path = directory.path().join("velora.sock");
        fs::write(&target, "keep me").unwrap();
        symlink(&target, &path).unwrap();
        assert!(prepare_socket_path(&path).await.is_err());
        assert!(path.exists());
    }

    #[tokio::test]
    async fn removes_verified_stale_socket() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("velora.sock");
        drop(StdUnixListener::bind(&path).unwrap());
        prepare_socket_path(&path).await.unwrap();
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn handshake_and_ping_round_trip() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let server_task = tokio::spawn(handle_connection(
            server,
            Arc::from([]),
            Arc::new(LaunchService::empty()),
        ));
        let hello = serde_json::to_string(&Request::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_name: "test-client".to_owned(),
            client_version: "0.2.0".to_owned(),
        })
        .unwrap();
        client
            .write_all(format!("{hello}\n").as_bytes())
            .await
            .unwrap();

        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        assert!(matches!(
            serde_json::from_str::<Response>(line.trim()).unwrap(),
            Response::Welcome { .. }
        ));

        let ping = serde_json::to_string(&Request::Ping {
            protocol_version: PROTOCOL_VERSION,
            request_id: 7,
        })
        .unwrap();
        reader
            .get_mut()
            .write_all(format!("{ping}\n").as_bytes())
            .await
            .unwrap();
        line.clear();
        reader.read_line(&mut line).await.unwrap();
        assert_eq!(
            serde_json::from_str::<Response>(line.trim()).unwrap(),
            Response::Pong {
                protocol_version: PROTOCOL_VERSION,
                request_id: 7,
            }
        );
        drop(reader);
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn ping_before_hello_is_rejected() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let server_task = tokio::spawn(handle_connection(
            server,
            Arc::from([]),
            Arc::new(LaunchService::empty()),
        ));
        let ping = serde_json::to_string(&Request::Ping {
            protocol_version: PROTOCOL_VERSION,
            request_id: 1,
        })
        .unwrap();
        client
            .write_all(format!("{ping}\n").as_bytes())
            .await
            .unwrap();
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        assert!(matches!(
            serde_json::from_str::<Response>(line.trim()).unwrap(),
            Response::Error { code, .. } if code == "handshake_required"
        ));
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn malformed_messages_are_reported_and_do_not_crash_the_connection() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let server_task = tokio::spawn(handle_connection(
            server,
            Arc::from([]),
            Arc::new(LaunchService::empty()),
        ));
        let hello = serde_json::to_string(&Request::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_name: "test-client".to_owned(),
            client_version: "0.2.0".to_owned(),
        })
        .unwrap();
        client
            .write_all(format!("{hello}\n").as_bytes())
            .await
            .unwrap();
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();

        reader.get_mut().write_all(b"{not-json}\n").await.unwrap();
        line.clear();
        reader.read_line(&mut line).await.unwrap();
        assert!(matches!(
            serde_json::from_str::<Response>(line.trim()).unwrap(),
            Response::Error { code, retryable: false, .. } if code == "invalid_request"
        ));

        let response = send_request(
            &mut reader,
            &Request::Ping {
                protocol_version: PROTOCOL_VERSION,
                request_id: 91,
            },
        )
        .await;
        assert_eq!(
            response,
            Response::Pong {
                protocol_version: PROTOCOL_VERSION,
                request_id: 91,
            }
        );

        drop(reader);
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn oversized_messages_are_rejected_and_close_the_connection() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let server_task = tokio::spawn(handle_connection(
            server,
            Arc::from([]),
            Arc::new(LaunchService::empty()),
        ));
        let mut oversized = vec![b'x'; MAX_MESSAGE_BYTES + 1];
        oversized.push(b'\n');
        client.write_all(&oversized).await.unwrap();

        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        assert_eq!(
            serde_json::from_str::<Response>(line.trim()).unwrap(),
            Response::error("message_too_large", "message exceeds 64 KiB", false)
        );
        line.clear();
        assert_eq!(reader.read_line(&mut line).await.unwrap(), 0);
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn invalid_utf8_is_rejected_without_panicking() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let server_task = tokio::spawn(handle_connection(
            server,
            Arc::from([]),
            Arc::new(LaunchService::empty()),
        ));
        client.write_all(&[0xff, b'\n']).await.unwrap();

        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        assert_eq!(
            serde_json::from_str::<Response>(line.trim()).unwrap(),
            Response::error(
                "invalid_encoding",
                "message must be UTF-8 and newline terminated",
                false,
            )
        );
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn returns_application_registry_in_pages() {
        let applications: Arc<[Application]> = Arc::from(
            (1..=3)
                .map(|number| Application {
                    id: format!("app-{number}.desktop"),
                    name: format!("Application {number}"),
                    exec: format!("app-{number}"),
                    icon: None,
                    categories: Vec::new(),
                    terminal: false,
                })
                .collect::<Vec<_>>(),
        );
        let (server, mut client) = UnixStream::pair().unwrap();
        let server_task = tokio::spawn(handle_connection(
            server,
            applications,
            Arc::new(LaunchService::empty()),
        ));

        let hello = serde_json::to_string(&Request::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_name: "test-client".to_owned(),
            client_version: "0.2.0".to_owned(),
        })
        .unwrap();
        client
            .write_all(format!("{hello}\n").as_bytes())
            .await
            .unwrap();
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();

        let request = serde_json::to_string(&Request::ListApplications {
            protocol_version: PROTOCOL_VERSION,
            request_id: 12,
            offset: 0,
            limit: 2,
        })
        .unwrap();
        reader
            .get_mut()
            .write_all(format!("{request}\n").as_bytes())
            .await
            .unwrap();
        line.clear();
        reader.read_line(&mut line).await.unwrap();

        assert!(matches!(
            serde_json::from_str::<Response>(line.trim()).unwrap(),
            Response::Applications {
                request_id: 12,
                applications,
                next_offset: Some(2),
                total: 3,
                ..
            } if applications.len() == 2
                && applications[0].id == "app-1.desktop"
                && applications[1].id == "app-2.desktop"
        ));

        drop(reader);
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn correlates_launch_rejections_with_the_request() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let launcher = Arc::new(MockLauncher::new(MockLaunchOutcome::UnknownApplication));
        let server_task = tokio::spawn(handle_connection(
            server,
            Arc::from([]),
            Arc::clone(&launcher),
        ));

        let hello = serde_json::to_string(&Request::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_name: "test-client".to_owned(),
            client_version: "0.2.0".to_owned(),
        })
        .unwrap();
        client
            .write_all(format!("{hello}\n").as_bytes())
            .await
            .unwrap();
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();

        let request = serde_json::to_string(&Request::LaunchApplication {
            protocol_version: PROTOCOL_VERSION,
            request_id: 27,
            desktop_id: "missing.desktop".to_owned(),
        })
        .unwrap();
        reader
            .get_mut()
            .write_all(format!("{request}\n").as_bytes())
            .await
            .unwrap();
        line.clear();
        reader.read_line(&mut line).await.unwrap();

        assert_eq!(
            serde_json::from_str::<Response>(line.trim()).unwrap(),
            Response::LaunchRejected {
                protocol_version: PROTOCOL_VERSION,
                request_id: 27,
                desktop_id: "missing.desktop".to_owned(),
                code: "unknown_application".to_owned(),
                message: "application is not present in the registry".to_owned(),
                retryable: false,
            }
        );
        assert_eq!(launcher.requests(), ["missing.desktop"]);

        drop(reader);
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn accepts_launches_through_the_mock_launcher_without_spawning() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let launcher = Arc::new(MockLauncher::new(MockLaunchOutcome::Accepted(4242)));
        let server_task = tokio::spawn(handle_connection(
            server,
            Arc::from([]),
            Arc::clone(&launcher),
        ));

        let hello = serde_json::to_string(&Request::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_name: "test-client".to_owned(),
            client_version: "0.2.0".to_owned(),
        })
        .unwrap();
        client
            .write_all(format!("{hello}\n").as_bytes())
            .await
            .unwrap();
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();

        let response = send_request(
            &mut reader,
            &Request::LaunchApplication {
                protocol_version: PROTOCOL_VERSION,
                request_id: 81,
                desktop_id: "mock.desktop".to_owned(),
            },
        )
        .await;

        assert_eq!(
            response,
            Response::LaunchAccepted {
                protocol_version: PROTOCOL_VERSION,
                request_id: 81,
                desktop_id: "mock.desktop".to_owned(),
                process_id: 4242,
            }
        );
        assert_eq!(launcher.requests(), ["mock.desktop"]);

        drop(reader);
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn marks_transient_mock_launch_failures_as_retryable() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let launcher = Arc::new(MockLauncher::new(MockLaunchOutcome::RateLimited));
        let server_task = tokio::spawn(handle_connection(server, Arc::from([]), launcher));

        let hello = serde_json::to_string(&Request::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_name: "test-client".to_owned(),
            client_version: "0.2.0".to_owned(),
        })
        .unwrap();
        client
            .write_all(format!("{hello}\n").as_bytes())
            .await
            .unwrap();
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();

        let response = send_request(
            &mut reader,
            &Request::LaunchApplication {
                protocol_version: PROTOCOL_VERSION,
                request_id: 82,
                desktop_id: "busy.desktop".to_owned(),
            },
        )
        .await;

        assert!(matches!(
            response,
            Response::LaunchRejected {
                request_id: 82,
                code,
                retryable: true,
                ..
            } if code == "launch_rate_limited"
        ));

        drop(reader);
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn temporary_server_socket_is_cleaned_and_can_be_restarted() {
        let directory = tempdir().unwrap();
        let socket_path = directory.path().join("velora.sock");
        let applications: Arc<[Application]> = Arc::from([Application {
            id: "mock.desktop".to_owned(),
            name: "Mock Application".to_owned(),
            exec: "/not/launched".to_owned(),
            icon: None,
            categories: vec!["Test".to_owned()],
            terminal: false,
        }]);

        for generation in 1..=2 {
            let config = CoreConfig {
                socket_path: socket_path.clone(),
                telemetry: crate::config::TelemetryPolicy::default(),
            };
            let launcher = Arc::new(MockLauncher::new(MockLaunchOutcome::Accepted(
                5000 + generation,
            )));
            let (shutdown_tx, shutdown_rx) = oneshot::channel();
            let server_task = tokio::spawn(serve_until(
                config,
                Arc::clone(&applications),
                Arc::clone(&launcher),
                HyprlandCapabilities::unavailable(),
                dead_session_store(),
                Arc::new(TelemetryStore::default()),
                async move {
                    shutdown_rx.await.context("test shutdown sender dropped")?;
                    Ok(())
                },
            ));

            wait_for_socket(&socket_path).await;
            let metadata = fs::metadata(&socket_path).unwrap();
            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
            assert_eq!(
                metadata.uid(),
                fs::metadata(directory.path()).unwrap().uid(),
                "the socket belongs to the current temporary runtime owner"
            );
            let mut reader = connect_and_handshake(&socket_path).await;
            assert_eq!(
                send_request(
                    &mut reader,
                    &Request::Ping {
                        protocol_version: PROTOCOL_VERSION,
                        request_id: generation.into(),
                    },
                )
                .await,
                Response::Pong {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: generation.into(),
                }
            );
            assert!(matches!(
                send_request(
                    &mut reader,
                    &Request::ListApplications {
                        protocol_version: PROTOCOL_VERSION,
                        request_id: 10 + u64::from(generation),
                        offset: 0,
                        limit: 32,
                    },
                )
                .await,
                Response::Applications {
                    applications,
                    total: 1,
                    ..
                } if applications[0].id == "mock.desktop"
            ));
            assert!(matches!(
                send_request(
                    &mut reader,
                    &Request::LaunchApplication {
                        protocol_version: PROTOCOL_VERSION,
                        request_id: 20 + u64::from(generation),
                        desktop_id: "mock.desktop".to_owned(),
                    },
                )
                .await,
                Response::LaunchAccepted { process_id, .. }
                    if process_id == 5000 + generation
            ));
            assert_eq!(launcher.requests(), ["mock.desktop"]);

            drop(reader);
            shutdown_tx.send(()).unwrap();
            server_task.await.unwrap().unwrap();
            assert!(!socket_path.exists());
        }
    }

    #[tokio::test]
    async fn reports_hyprland_capabilities_and_typed_snapshot_readiness() {
        let (server, client) = UnixStream::pair().unwrap();
        let capabilities = HyprlandCapabilities {
            availability: HyprlandAvailability::Available,
            version: Some("0.56.2".to_owned()),
            can_query_workspaces: true,
            can_query_windows: true,
            can_query_active_workspace: true,
            can_query_active_window: true,
            can_receive_events: true,
        };
        let server_task = tokio::spawn(handle_connection_with_capabilities(
            server,
            Arc::from([]),
            Arc::new(LaunchService::empty()),
            capabilities.clone(),
            dead_session_store(),
        ));
        let mut reader = BufReader::new(client);

        let hello = send_request(
            &mut reader,
            &Request::Hello {
                protocol_version: PROTOCOL_VERSION,
                client_name: "test-client".to_owned(),
                client_version: "0.3.0".to_owned(),
            },
        )
        .await;
        assert!(matches!(hello, Response::Welcome { .. }));

        assert_eq!(
            send_request(
                &mut reader,
                &Request::GetHyprlandCapabilities {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 91,
                },
            )
            .await,
            Response::HyprlandCapabilities {
                protocol_version: PROTOCOL_VERSION,
                request_id: 91,
                capabilities,
            }
        );

        assert_eq!(
            send_request(
                &mut reader,
                &Request::GetWorkspaceSnapshot {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 92,
                },
            )
            .await,
            Response::WorkspaceSnapshotRejected {
                protocol_version: PROTOCOL_VERSION,
                request_id: 92,
                code: WorkspaceSnapshotError::SnapshotNotReady,
                retryable: true,
            }
        );

        assert_eq!(
            send_request(
                &mut reader,
                &Request::GetTelemetrySnapshot {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 93,
                },
            )
            .await,
            Response::TelemetrySnapshotRejected {
                protocol_version: PROTOCOL_VERSION,
                request_id: 93,
                code: TelemetrySnapshotError::SnapshotNotReady,
                retryable: true,
            }
        );

        drop(reader);
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn serves_live_workspace_snapshots_from_the_session_store() {
        use crate::hyprland::{
            ACTIVE_WINDOW_REQUEST, ACTIVE_WORKSPACE_REQUEST, COMMAND_SOCKET_NAME, WINDOWS_REQUEST,
            WORKSPACES_REQUEST,
        };

        let directory = tempfile::tempdir().unwrap();
        let command_socket = directory.path().join(COMMAND_SOCKET_NAME);
        let hyprland_listener = std::os::unix::net::UnixListener::bind(&command_socket).unwrap();
        let hyprland_server = std::thread::spawn(move || {
            use std::io::{Read, Write};
            for (request, response) in [
                (
                    WORKSPACES_REQUEST,
                    br#"[{"id":1,"name":"1","monitor":"eDP-1","windows":1}]"#.as_slice(),
                ),
                (
                    WINDOWS_REQUEST,
                    br#"[{"address":"0xaa","mapped":true,"workspace":{"id":1},"title":"Editor","class":"code"}]"#.as_slice(),
                ),
                (ACTIVE_WORKSPACE_REQUEST, br#"{"id":1,"name":"1"}"#.as_slice()),
                (ACTIVE_WINDOW_REQUEST, br#"{"address":"0xaa"}"#.as_slice()),
            ] {
                let (mut stream, _) = hyprland_listener.accept().unwrap();
                let mut received = [0_u8; 32];
                let read = stream.read(&mut received).unwrap();
                assert_eq!(&received[..read], request);
                stream.write_all(response).unwrap();
            }
        });

        let store = Arc::new(SessionStore::new(command_socket));
        let available = HyprlandCapabilities {
            availability: HyprlandAvailability::Available,
            ..HyprlandCapabilities::unavailable()
        };
        let (server, client) = UnixStream::pair().unwrap();
        let server_task = tokio::spawn(handle_connection_with_capabilities(
            server,
            Arc::from([]),
            Arc::new(LaunchService::empty()),
            available,
            Some(Arc::clone(&store)),
        ));

        let mut reader = BufReader::new(client);
        let hello = send_request(
            &mut reader,
            &Request::Hello {
                protocol_version: PROTOCOL_VERSION,
                client_name: "test-client".to_owned(),
                client_version: "0.3.0".to_owned(),
            },
        )
        .await;
        assert!(matches!(hello, Response::Welcome { .. }));

        let snapshot_response = send_request(
            &mut reader,
            &Request::GetWorkspaceSnapshot {
                protocol_version: PROTOCOL_VERSION,
                request_id: 95,
            },
        )
        .await;

        hyprland_server.join().unwrap();
        drop(reader);
        server_task.await.unwrap().unwrap();

        let Response::WorkspaceSnapshot {
            request_id,
            snapshot,
            ..
        } = snapshot_response
        else {
            panic!("expected a live workspace snapshot");
        };
        assert_eq!(request_id, 95);
        assert_eq!(snapshot.sequence, 1);
        assert_eq!(snapshot.workspaces.len(), 1);
        assert_eq!(snapshot.workspaces[0].handle, "workspace:1");
        assert_eq!(snapshot.windows.len(), 1);
        assert_eq!(
            snapshot.active_workspace_handle.as_deref(),
            Some("workspace:1")
        );
        snapshot.validate().unwrap();

        // The incompatible-capability path must still reject cleanly.
        let (server, client) = UnixStream::pair().unwrap();
        let server_task = tokio::spawn(handle_connection_with_capabilities(
            server,
            Arc::from([]),
            Arc::new(LaunchService::empty()),
            HyprlandCapabilities::incompatible(),
            None,
        ));
        let mut reader = BufReader::new(client);
        let hello = send_request(
            &mut reader,
            &Request::Hello {
                protocol_version: PROTOCOL_VERSION,
                client_name: "test-client".to_owned(),
                client_version: "0.3.0".to_owned(),
            },
        )
        .await;
        assert!(matches!(hello, Response::Welcome { .. }));
        assert_eq!(
            send_request(
                &mut reader,
                &Request::GetWorkspaceSnapshot {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 96,
                },
            )
            .await,
            Response::WorkspaceSnapshotRejected {
                protocol_version: PROTOCOL_VERSION,
                request_id: 96,
                code: WorkspaceSnapshotError::HyprlandIncompatible,
                retryable: false,
            }
        );
        drop(reader);
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn switches_workspaces_only_through_snapshot_handles() {
        use crate::hyprland::{
            ACTIVE_WINDOW_REQUEST, ACTIVE_WORKSPACE_REQUEST, COMMAND_SOCKET_NAME, WINDOWS_REQUEST,
            WORKSPACES_REQUEST,
        };

        let directory = tempfile::tempdir().unwrap();
        let command_socket = directory.path().join(COMMAND_SOCKET_NAME);
        let hyprland_listener = std::os::unix::net::UnixListener::bind(&command_socket).unwrap();
        let server = std::thread::spawn(move || {
            use std::io::{Read, Write};
            // One warm-up snapshot refresh: the four read queries...
            for (request, response) in [
                (
                    WORKSPACES_REQUEST,
                    br#"[{"id":3,"name":"3","monitor":"eDP-1","windows":0}]"#.as_slice(),
                ),
                (WINDOWS_REQUEST, br#"[]"#.as_slice()),
                (
                    ACTIVE_WORKSPACE_REQUEST,
                    br#"{"id":1,"name":"1"}"#.as_slice(),
                ),
                (ACTIVE_WINDOW_REQUEST, br#"{}"#.as_slice()),
            ] {
                let (mut stream, _) = hyprland_listener.accept().unwrap();
                let mut received = [0_u8; 32];
                let read = stream.read(&mut received).unwrap();
                assert_eq!(&received[..read], request);
                stream.write_all(response).unwrap();
            }
            // ...then the single state-changing dispatch.
            let (mut stream, _) = hyprland_listener.accept().unwrap();
            let mut command = Vec::new();
            stream.read_to_end(&mut command).unwrap();
            assert_eq!(command, br#"dispatch hl.dsp.focus({ workspace = "3" })"#);
            stream.write_all(b"ok").unwrap();
        });

        let store = Arc::new(SessionStore::new(command_socket));
        let available = HyprlandCapabilities {
            availability: HyprlandAvailability::Available,
            ..HyprlandCapabilities::unavailable()
        };
        let (server_conn, client) = UnixStream::pair().unwrap();
        let server_task = tokio::spawn(handle_connection_with_capabilities(
            server_conn,
            Arc::from([]),
            Arc::new(LaunchService::empty()),
            available,
            Some(Arc::clone(&store)),
        ));

        let mut reader = BufReader::new(client);
        let hello = send_request(
            &mut reader,
            &Request::Hello {
                protocol_version: PROTOCOL_VERSION,
                client_name: "test-client".to_owned(),
                client_version: "0.3.0".to_owned(),
            },
        )
        .await;
        assert!(matches!(hello, Response::Welcome { .. }));

        // A handle that was never issued cannot switch anything.
        assert_eq!(
            send_request(
                &mut reader,
                &Request::SwitchWorkspace {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 41,
                    workspace_handle: "workspace:77".to_owned(),
                },
            )
            .await,
            Response::SwitchRejected {
                protocol_version: PROTOCOL_VERSION,
                request_id: 41,
                workspace_handle: "workspace:77".to_owned(),
                code: WorkspaceSwitchError::UnknownWorkspaceHandle,
            }
        );

        // A raw compositor selector is structurally invalid here.
        assert_eq!(
            send_request(
                &mut reader,
                &Request::SwitchWorkspace {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 42,
                    workspace_handle: "3".to_owned(),
                },
            )
            .await,
            Response::SwitchRejected {
                protocol_version: PROTOCOL_VERSION,
                request_id: 42,
                workspace_handle: "3".to_owned(),
                code: WorkspaceSwitchError::UnknownWorkspaceHandle,
            }
        );

        // The issued snapshot handle switches through exactly one dispatcher
        // command with a compositor-derived id.
        assert_eq!(
            send_request(
                &mut reader,
                &Request::SwitchWorkspace {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 43,
                    workspace_handle: "workspace:3".to_owned(),
                },
            )
            .await,
            Response::SwitchAccepted {
                protocol_version: PROTOCOL_VERSION,
                request_id: 43,
                workspace_handle: "workspace:3".to_owned(),
            }
        );

        server.join().unwrap();
        drop(reader);
        server_task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn focuses_windows_only_through_resolvable_handles() {
        use crate::hyprland::{
            ACTIVE_WINDOW_REQUEST, ACTIVE_WORKSPACE_REQUEST, COMMAND_SOCKET_NAME, WINDOWS_REQUEST,
            WORKSPACES_REQUEST,
        };

        let directory = tempfile::tempdir().unwrap();
        let command_socket = directory.path().join(COMMAND_SOCKET_NAME);
        let hyprland_listener = std::os::unix::net::UnixListener::bind(&command_socket).unwrap();
        let server = std::thread::spawn(move || {
            use std::io::{Read, Write};
            // Warm-up snapshot containing one mapped window at 0xaa.
            for (request, response) in [
                (WORKSPACES_REQUEST, br#"[{"id":1,"name":"1","monitor":"eDP-1","windows":1}]"#.as_slice()),
                (WINDOWS_REQUEST, br#"[{"address":"0xaa","mapped":true,"workspace":{"id":1},"title":"Editor","class":"code"}]"#.as_slice()),
                (ACTIVE_WORKSPACE_REQUEST, br#"{"id":1,"name":"1"}"#.as_slice()),
                (ACTIVE_WINDOW_REQUEST, br#"{}"#.as_slice()),
            ] {
                let (mut stream, _) = hyprland_listener.accept().unwrap();
                let mut received = [0_u8; 32];
                let read = stream.read(&mut received).unwrap();
                assert_eq!(&received[..read], request);
                stream.write_all(response).unwrap();
            }
            // The single focus dispatch, then the post-focus refresh queries.
            let (mut stream, _) = hyprland_listener.accept().unwrap();
            let mut command = Vec::new();
            stream.read_to_end(&mut command).unwrap();
            assert_eq!(
                command,
                br#"dispatch hl.dsp.focus({ window = "address:0xaa" })"#
            );
            stream.write_all(b"ok").unwrap();
            drop(stream);
            for (request, response) in [
                (WORKSPACES_REQUEST, br#"[{"id":1,"name":"1","monitor":"eDP-1","windows":1}]"#.as_slice()),
                (WINDOWS_REQUEST, br#"[{"address":"0xaa","mapped":true,"workspace":{"id":1},"title":"Editor","class":"code"}]"#.as_slice()),
                (ACTIVE_WORKSPACE_REQUEST, br#"{"id":1,"name":"1"}"#.as_slice()),
                (ACTIVE_WINDOW_REQUEST, br#"{"address":"0xaa"}"#.as_slice()),
            ] {
                let (mut stream, _) = hyprland_listener.accept().unwrap();
                let mut received = [0_u8; 32];
                let read = stream.read(&mut received).unwrap();
                assert_eq!(&received[..read], request);
                stream.write_all(response).unwrap();
            }
        });

        let store = Arc::new(SessionStore::new(command_socket));
        let available = HyprlandCapabilities {
            availability: HyprlandAvailability::Available,
            ..HyprlandCapabilities::unavailable()
        };
        let (server_conn, client) = UnixStream::pair().unwrap();
        let server_task = tokio::spawn(handle_connection_with_capabilities(
            server_conn,
            Arc::from([]),
            Arc::new(LaunchService::empty()),
            available,
            Some(Arc::clone(&store)),
        ));

        let mut reader = BufReader::new(client);
        let hello = send_request(
            &mut reader,
            &Request::Hello {
                protocol_version: PROTOCOL_VERSION,
                client_name: "test-client".to_owned(),
                client_version: "0.3.0".to_owned(),
            },
        )
        .await;
        assert!(matches!(hello, Response::Welcome { .. }));

        // Warm the snapshot so the handle map is populated.
        assert!(matches!(
            send_request(
                &mut reader,
                &Request::GetWorkspaceSnapshot {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 50,
                },
            )
            .await,
            Response::WorkspaceSnapshot { .. }
        ));

        // A raw selector string can never be used as a handle.
        assert_eq!(
            send_request(
                &mut reader,
                &Request::FocusWindow {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 51,
                    window_handle: "0xaa".to_owned(),
                },
            )
            .await,
            Response::FocusRejected {
                protocol_version: PROTOCOL_VERSION,
                request_id: 51,
                window_handle: "0xaa".to_owned(),
                code: WindowFocusError::UnknownWindowHandle,
            }
        );

        // A stale/closed window handle fails cleanly.
        assert_eq!(
            send_request(
                &mut reader,
                &Request::FocusWindow {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 52,
                    window_handle: "window:does-not-exist".to_owned(),
                },
            )
            .await,
            Response::FocusRejected {
                protocol_version: PROTOCOL_VERSION,
                request_id: 52,
                window_handle: "window:does-not-exist".to_owned(),
                code: WindowFocusError::UnknownWindowHandle,
            }
        );

        // The issued handle resolves internally and focuses exactly once.
        let snapshot_response = send_request(
            &mut reader,
            &Request::GetWorkspaceSnapshot {
                protocol_version: PROTOCOL_VERSION,
                request_id: 53,
            },
        )
        .await;
        let Response::WorkspaceSnapshot { snapshot, .. } = snapshot_response else {
            panic!("expected a workspace snapshot");
        };
        let editor_handle = String::clone(&snapshot.windows[0].handle);

        assert_eq!(
            send_request(
                &mut reader,
                &Request::FocusWindow {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: 54,
                    window_handle: editor_handle.clone(),
                },
            )
            .await,
            Response::FocusAccepted {
                protocol_version: PROTOCOL_VERSION,
                request_id: 54,
                window_handle: editor_handle.clone(),
            }
        );

        server.join().unwrap();
        drop(reader);
        server_task.await.unwrap().unwrap();
    }

    #[test]
    fn application_pages_respect_the_encoded_transport_limit() {
        let applications = (1..=2)
            .map(|number| Application {
                id: format!("large-{number}.desktop"),
                name: format!("Large Application {number}"),
                exec: "x".repeat(40 * 1024),
                icon: None,
                categories: Vec::new(),
                terminal: false,
            })
            .collect::<Vec<_>>();

        let response = application_page(&applications, 1, 0, 2).unwrap();
        let encoded = serde_json::to_vec(&response).unwrap();

        assert!(encoded.len() <= MAX_MESSAGE_BYTES);
        assert!(matches!(
            response,
            Response::Applications {
                applications,
                next_offset: Some(1),
                total: 2,
                ..
            } if applications.len() == 1
        ));
    }

    #[test]
    fn rejects_an_application_that_cannot_fit_in_one_frame() {
        let applications = vec![Application {
            id: "oversized.desktop".to_owned(),
            name: "Oversized".to_owned(),
            exec: "x".repeat(MAX_MESSAGE_BYTES),
            icon: None,
            categories: Vec::new(),
            terminal: false,
        }];

        assert!(application_page(&applications, 1, 0, 1).is_err());
    }

    #[test]
    fn paginates_a_500_entry_registry_with_bounded_frames() {
        let applications = (0..500)
            .map(|number| Application {
                id: format!("scale-{number}.desktop"),
                name: format!("Scale Application {number}"),
                exec: format!("/not/launched/scale-{number}"),
                icon: None,
                categories: vec!["Test".to_owned()],
                terminal: false,
            })
            .collect::<Vec<_>>();
        let mut offset = 0_u32;
        let mut received = 0_usize;

        loop {
            let response =
                application_page(&applications, 700, offset, MAX_APPLICATION_PAGE_SIZE).unwrap();
            assert!(serde_json::to_vec(&response).unwrap().len() <= MAX_MESSAGE_BYTES);
            let Response::Applications {
                applications,
                next_offset,
                ..
            } = response
            else {
                unreachable!()
            };
            received += applications.len();
            let Some(next_offset) = next_offset else {
                break;
            };
            assert!(next_offset > offset);
            offset = next_offset;
        }

        assert_eq!(received, 500);
    }
}
