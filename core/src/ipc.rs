use crate::{
    apps,
    config::CoreConfig,
    protocol::{PROTOCOL_VERSION, Request, Response},
};
use anyhow::{Context, Result};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
};
use tracing::{info, warn};

pub async fn serve(config: CoreConfig) -> Result<()> {
    if config.socket_path.exists() {
        std::fs::remove_file(&config.socket_path).with_context(|| {
            format!(
                "cannot remove stale socket {}",
                config.socket_path.display()
            )
        })?;
    }
    let listener = UnixListener::bind(&config.socket_path)
        .with_context(|| format!("cannot bind {}", config.socket_path.display()))?;
    info!(socket = %config.socket_path.display(), "socket ready");

    loop {
        tokio::select! {
            result = listener.accept() => match result {
                Ok((stream, _)) => { tokio::spawn(handle_connection(stream)); }
                Err(error) => warn!(%error, "failed to accept frontend connection"),
            },
            signal = tokio::signal::ctrl_c() => {
                signal.context("failed to listen for shutdown signal")?;
                info!("Velora Core shutting down");
                break;
            }
        }
    }
    std::fs::remove_file(&config.socket_path).ok();
    Ok(())
}

async fn handle_connection(stream: UnixStream) {
    info!("frontend connected");
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let response = match serde_json::from_str::<Request>(&line) {
            Ok(request) if request.protocol_version() != PROTOCOL_VERSION => Response::Error {
                protocol_version: PROTOCOL_VERSION,
                message: format!(
                    "unsupported protocol version {}",
                    request.protocol_version()
                ),
            },
            Ok(Request::Ping { .. }) => Response::Pong {
                protocol_version: PROTOCOL_VERSION,
            },
            Ok(Request::LaunchApp { desktop_id, .. }) => match apps::launch(&desktop_id).await {
                Ok(()) => Response::ApplicationState {
                    protocol_version: PROTOCOL_VERSION,
                    desktop_id,
                    running: true,
                },
                Err(error) => Response::Error {
                    protocol_version: PROTOCOL_VERSION,
                    message: error.to_string(),
                },
            },
            Err(error) => Response::Error {
                protocol_version: PROTOCOL_VERSION,
                message: format!("invalid request: {error}"),
            },
        };
        match serde_json::to_string(&response) {
            Ok(json)
                if writer
                    .write_all(format!("{json}\n").as_bytes())
                    .await
                    .is_err() =>
            {
                break;
            }
            Ok(_) => {}
            Err(error) => warn!(%error, "failed to serialize response"),
        }
    }
    info!("frontend disconnected");
}
