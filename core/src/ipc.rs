use crate::config::CoreConfig;
use anyhow::{Context, Result, bail};
use std::{
    fs, io,
    os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    time::timeout,
};
use tracing::{info, warn};
use velora_protocol::{
    Application, HANDSHAKE_TIMEOUT_SECONDS, MAX_APPLICATION_PAGE_SIZE, MAX_MESSAGE_BYTES,
    PROTOCOL_VERSION, Request, Response, SERVER_NAME,
};

pub async fn serve(config: CoreConfig, applications: Arc<[Application]>) -> Result<()> {
    prepare_socket_path(&config.socket_path).await?;
    let listener = UnixListener::bind(&config.socket_path)
        .with_context(|| format!("cannot bind {}", config.socket_path.display()))?;
    fs::set_permissions(&config.socket_path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("cannot secure {}", config.socket_path.display()))?;
    let _socket_guard = SocketGuard::new(config.socket_path.clone())?;
    info!(socket = %config.socket_path.display(), "socket ready");

    loop {
        tokio::select! {
            result = listener.accept() => match result {
                Ok((stream, _)) => {
                    let applications = Arc::clone(&applications);
                    tokio::spawn(async move {
                        if let Err(error) = handle_connection(stream, applications).await {
                            warn!(%error, "frontend connection failed");
                        }
                    });
                }
                Err(error) => warn!(%error, "failed to accept frontend connection"),
            },
            signal = tokio::signal::ctrl_c() => {
                signal.context("failed to listen for shutdown signal")?;
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

async fn handle_connection(stream: UnixStream, applications: Arc<[Application]>) -> Result<()> {
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

    loop {
        let Some(line) = frame_to_line(read_frame(&mut reader).await?, &mut writer).await? else {
            break;
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
        write_response(&mut writer, &response).await?;
        if should_close {
            break;
        }
    }
    info!("frontend disconnected");
    Ok(())
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
    let mut end = start;

    while end < requested_end {
        let candidate = application_page_response(applications, request_id, start, end + 1, total);
        let encoded_size = serde_json::to_vec(&candidate)
            .context("failed to size application page")?
            .len();
        if encoded_size > MAX_MESSAGE_BYTES {
            break;
        }
        end += 1;
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
    use std::{os::unix::fs::symlink, os::unix::net::UnixListener as StdUnixListener};
    use tempfile::tempdir;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

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
        let server_task = tokio::spawn(handle_connection(server, Arc::from([])));
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
        let server_task = tokio::spawn(handle_connection(server, Arc::from([])));
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
        let server_task = tokio::spawn(handle_connection(server, applications));

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
}
