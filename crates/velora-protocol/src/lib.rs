use serde::{Deserialize, Serialize};
use std::{env, path::PathBuf};
use thiserror::Error;

pub const PROTOCOL_VERSION: u8 = 2;
pub const MAX_MESSAGE_BYTES: usize = 64 * 1024;
pub const HANDSHAKE_TIMEOUT_SECONDS: u64 = 5;
pub const CLIENT_NAME: &str = "velora-godot";
pub const SERVER_NAME: &str = "velora-core";

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Application {
    pub id: String,
    pub name: String,
    pub exec: String,
    pub icon: Option<String>,
    pub categories: Vec<String>,
    pub terminal: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    Hello {
        protocol_version: u8,
        client_name: String,
        client_version: String,
    },
    Ping {
        protocol_version: u8,
        request_id: u64,
    },
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    Welcome {
        protocol_version: u8,
        server_name: String,
        server_version: String,
    },
    Pong {
        protocol_version: u8,
        request_id: u64,
    },
    Error {
        protocol_version: u8,
        code: String,
        message: String,
        retryable: bool,
    },
}

impl Request {
    pub fn protocol_version(&self) -> u8 {
        match self {
            Self::Hello {
                protocol_version, ..
            }
            | Self::Ping {
                protocol_version, ..
            } => *protocol_version,
        }
    }
}

impl Response {
    pub fn error(code: &str, message: impl Into<String>, retryable: bool) -> Self {
        Self::Error {
            protocol_version: PROTOCOL_VERSION,
            code: code.to_owned(),
            message: message.into(),
            retryable,
        }
    }
}

#[derive(Debug, Error)]
pub enum SocketPathError {
    #[error("XDG_RUNTIME_DIR and UID are unavailable")]
    MissingRuntimeIdentity,
    #[error("UID is not numeric")]
    InvalidUid,
}

pub fn default_socket_path() -> Result<PathBuf, SocketPathError> {
    if let Some(path) = env::var_os("VELORA_SOCKET") {
        return Ok(PathBuf::from(path));
    }
    if let Some(runtime_dir) = env::var_os("XDG_RUNTIME_DIR") {
        return Ok(PathBuf::from(runtime_dir).join("velora.sock"));
    }
    let uid = env::var("UID").map_err(|_| SocketPathError::MissingRuntimeIdentity)?;
    let uid = uid
        .parse::<u32>()
        .map_err(|_| SocketPathError::InvalidUid)?;
    Ok(PathBuf::from(format!("/tmp/velora-{uid}.sock")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serializes_hello_fixture() {
        let value = serde_json::to_string(&Request::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_name: CLIENT_NAME.to_owned(),
            client_version: "0.2.0".to_owned(),
        })
        .unwrap();
        assert_eq!(
            value,
            r#"{"type":"hello","protocol_version":2,"client_name":"velora-godot","client_version":"0.2.0"}"#
        );
    }

    #[test]
    fn round_trips_pong() {
        let response = Response::Pong {
            protocol_version: PROTOCOL_VERSION,
            request_id: 42,
        };
        let json = serde_json::to_string(&response).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), response);
    }

    #[test]
    fn error_constructor_uses_current_protocol() {
        assert_eq!(
            Response::error("handshake_required", "send hello first", false),
            Response::Error {
                protocol_version: PROTOCOL_VERSION,
                code: "handshake_required".to_owned(),
                message: "send hello first".to_owned(),
                retryable: false,
            }
        );
    }
}
