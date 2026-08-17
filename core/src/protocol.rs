use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u8 = 1;

#[derive(Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    Ping {
        protocol_version: u8,
    },
    LaunchApp {
        protocol_version: u8,
        desktop_id: String,
    },
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    Pong {
        protocol_version: u8,
    },
    ApplicationState {
        protocol_version: u8,
        desktop_id: String,
        running: bool,
    },
    Error {
        protocol_version: u8,
        message: String,
    },
}

impl Request {
    pub fn protocol_version(&self) -> u8 {
        match self {
            Self::Ping { protocol_version }
            | Self::LaunchApp {
                protocol_version, ..
            } => *protocol_version,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serializes_ping() {
        let value = serde_json::to_string(&Request::Ping {
            protocol_version: PROTOCOL_VERSION,
        })
        .unwrap();
        assert_eq!(value, r#"{"type":"ping","protocol_version":1}"#);
    }
}
