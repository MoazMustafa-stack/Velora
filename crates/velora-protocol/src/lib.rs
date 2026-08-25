use serde::{Deserialize, Serialize};
use std::{env, path::PathBuf};
use thiserror::Error;

/// Phase 3 adds the Hyprland capability contract and typed workspace/window
/// snapshot model. Core and Godot intentionally require an exact match.
pub const PROTOCOL_VERSION: u8 = 3;
pub const MAX_MESSAGE_BYTES: usize = 64 * 1024;
pub const HANDSHAKE_TIMEOUT_SECONDS: u64 = 5;
pub const DEFAULT_APPLICATION_PAGE_SIZE: u16 = 32;
pub const MAX_APPLICATION_PAGE_SIZE: u16 = 64;
pub const MAX_WORKSPACES: usize = 128;
pub const MAX_WINDOWS: usize = 1024;
pub const CLIENT_NAME: &str = "velora-godot";
pub const SERVER_NAME: &str = "velora-core";

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HyprlandAvailability {
    Available,
    Unavailable,
    Incompatible,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct HyprlandCapabilities {
    pub availability: HyprlandAvailability,
    pub version: Option<String>,
    pub can_query_workspaces: bool,
    pub can_query_windows: bool,
    pub can_query_active_workspace: bool,
    pub can_query_active_window: bool,
    pub can_receive_events: bool,
}

impl HyprlandCapabilities {
    pub fn unavailable() -> Self {
        Self {
            availability: HyprlandAvailability::Unavailable,
            version: None,
            can_query_workspaces: false,
            can_query_windows: false,
            can_query_active_workspace: false,
            can_query_active_window: false,
            can_receive_events: false,
        }
    }

    pub fn incompatible() -> Self {
        Self {
            availability: HyprlandAvailability::Incompatible,
            ..Self::unavailable()
        }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Workspace {
    /// Opaque, snapshot-issued identifier. Godot must not manufacture this.
    pub handle: String,
    pub name: String,
    pub index: i32,
    pub monitor: Option<String>,
    pub window_count: u16,
    pub is_active: bool,
    pub is_special: bool,
    pub is_urgent: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Window {
    /// Opaque, snapshot-issued identifier. This is never a raw compositor selector.
    pub handle: String,
    pub workspace_handle: String,
    pub title: String,
    pub class: String,
    pub is_active: bool,
    pub is_floating: bool,
    pub is_fullscreen: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct WorkspaceSnapshot {
    /// Monotonically increasing within one Core session. Clients ignore older values.
    pub sequence: u64,
    pub workspaces: Vec<Workspace>,
    pub windows: Vec<Window>,
    pub active_workspace_handle: Option<String>,
    pub active_window_handle: Option<String>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SnapshotValidationError {
    #[error("workspace snapshot contains more than {MAX_WORKSPACES} workspaces")]
    TooManyWorkspaces,
    #[error("workspace snapshot contains more than {MAX_WINDOWS} windows")]
    TooManyWindows,
    #[error("workspace snapshot contains an empty or duplicate workspace handle")]
    InvalidWorkspaceHandle,
    #[error("workspace snapshot contains an empty or duplicate window handle")]
    InvalidWindowHandle,
    #[error("window references an unknown workspace handle")]
    UnknownWindowWorkspace,
    #[error("active workspace handle is not in the snapshot")]
    UnknownActiveWorkspace,
    #[error("active window handle is not in the snapshot")]
    UnknownActiveWindow,
}

impl WorkspaceSnapshot {
    pub fn is_newer_than(&self, sequence: u64) -> bool {
        self.sequence > sequence
    }

    pub fn validate(&self) -> Result<(), SnapshotValidationError> {
        if self.workspaces.len() > MAX_WORKSPACES {
            return Err(SnapshotValidationError::TooManyWorkspaces);
        }
        if self.windows.len() > MAX_WINDOWS {
            return Err(SnapshotValidationError::TooManyWindows);
        }

        let mut workspace_handles = std::collections::HashSet::new();
        for workspace in &self.workspaces {
            if workspace.handle.is_empty() || !workspace_handles.insert(&workspace.handle) {
                return Err(SnapshotValidationError::InvalidWorkspaceHandle);
            }
        }

        let mut window_handles = std::collections::HashSet::new();
        for window in &self.windows {
            if window.handle.is_empty() || !window_handles.insert(&window.handle) {
                return Err(SnapshotValidationError::InvalidWindowHandle);
            }
            if !workspace_handles.contains(&window.workspace_handle) {
                return Err(SnapshotValidationError::UnknownWindowWorkspace);
            }
        }

        if self
            .active_workspace_handle
            .as_ref()
            .is_some_and(|handle| !workspace_handles.contains(handle))
        {
            return Err(SnapshotValidationError::UnknownActiveWorkspace);
        }
        if self
            .active_window_handle
            .as_ref()
            .is_some_and(|handle| !window_handles.contains(handle))
        {
            return Err(SnapshotValidationError::UnknownActiveWindow);
        }

        Ok(())
    }
}

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
    ListApplications {
        protocol_version: u8,
        request_id: u64,
        offset: u32,
        limit: u16,
    },
    LaunchApplication {
        protocol_version: u8,
        request_id: u64,
        desktop_id: String,
    },
    GetHyprlandCapabilities {
        protocol_version: u8,
        request_id: u64,
    },
    GetWorkspaceSnapshot {
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
    Applications {
        protocol_version: u8,
        request_id: u64,
        applications: Vec<Application>,
        next_offset: Option<u32>,
        total: u32,
    },
    Error {
        protocol_version: u8,
        code: String,
        message: String,
        retryable: bool,
    },
    LaunchAccepted {
        protocol_version: u8,
        request_id: u64,
        desktop_id: String,
        process_id: u32,
    },
    LaunchRejected {
        protocol_version: u8,
        request_id: u64,
        desktop_id: String,
        code: String,
        message: String,
        retryable: bool,
    },
    HyprlandCapabilities {
        protocol_version: u8,
        request_id: u64,
        capabilities: HyprlandCapabilities,
    },
    WorkspaceSnapshot {
        protocol_version: u8,
        request_id: u64,
        snapshot: WorkspaceSnapshot,
    },
    WorkspaceSnapshotRejected {
        protocol_version: u8,
        request_id: u64,
        code: WorkspaceSnapshotError,
        retryable: bool,
    },
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceSnapshotError {
    HyprlandUnavailable,
    HyprlandIncompatible,
    SnapshotNotReady,
}

impl Request {
    pub fn protocol_version(&self) -> u8 {
        match self {
            Self::Hello {
                protocol_version, ..
            }
            | Self::Ping {
                protocol_version, ..
            }
            | Self::ListApplications {
                protocol_version, ..
            }
            | Self::LaunchApplication {
                protocol_version, ..
            }
            | Self::GetHyprlandCapabilities {
                protocol_version, ..
            }
            | Self::GetWorkspaceSnapshot {
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
            r#"{"type":"hello","protocol_version":3,"client_name":"velora-godot","client_version":"0.2.0"}"#
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

    #[test]
    fn round_trips_an_application_page() {
        let response = Response::Applications {
            protocol_version: PROTOCOL_VERSION,
            request_id: 9,
            applications: vec![Application {
                id: "org.example.Editor.desktop".to_owned(),
                name: "Editor".to_owned(),
                exec: "editor %F".to_owned(),
                icon: Some("editor".to_owned()),
                categories: vec!["Development".to_owned()],
                terminal: false,
            }],
            next_offset: Some(32),
            total: 40,
        };

        let json = serde_json::to_string(&response).unwrap();

        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), response);
    }

    #[test]
    fn round_trips_launch_request() {
        let request = Request::LaunchApplication {
            protocol_version: PROTOCOL_VERSION,
            request_id: 12,
            desktop_id: "velora-test.desktop".to_owned(),
        };

        let json = serde_json::to_string(&request).unwrap();
        assert_eq!(serde_json::from_str::<Request>(&json).unwrap(), request);
    }

    #[test]
    fn round_trips_application_list_request() {
        let request = Request::ListApplications {
            protocol_version: PROTOCOL_VERSION,
            request_id: 11,
            offset: 32,
            limit: MAX_APPLICATION_PAGE_SIZE,
        };

        let json = serde_json::to_string(&request).unwrap();
        assert_eq!(serde_json::from_str::<Request>(&json).unwrap(), request);
        assert_eq!(request.protocol_version(), PROTOCOL_VERSION);
    }

    #[test]
    fn round_trips_correlated_launch_acceptance() {
        let response = Response::LaunchAccepted {
            protocol_version: PROTOCOL_VERSION,
            request_id: 14,
            desktop_id: "editor.desktop".to_owned(),
            process_id: 4242,
        };

        let json = serde_json::to_string(&response).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), response);
    }

    #[test]
    fn round_trips_correlated_launch_rejection() {
        let response = Response::LaunchRejected {
            protocol_version: PROTOCOL_VERSION,
            request_id: 13,
            desktop_id: "missing.desktop".to_owned(),
            code: "unknown_application".to_owned(),
            message: "application is not present in the registry".to_owned(),
            retryable: false,
        };

        let json = serde_json::to_string(&response).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), response);
    }

    fn test_snapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot {
            sequence: 7,
            workspaces: vec![Workspace {
                handle: "workspace:1".to_owned(),
                name: "1".to_owned(),
                index: 1,
                monitor: Some("eDP-1".to_owned()),
                window_count: 1,
                is_active: true,
                is_special: false,
                is_urgent: false,
            }],
            windows: vec![Window {
                handle: "window:opaque-1".to_owned(),
                workspace_handle: "workspace:1".to_owned(),
                title: "Editor".to_owned(),
                class: "code".to_owned(),
                is_active: true,
                is_floating: false,
                is_fullscreen: false,
            }],
            active_workspace_handle: Some("workspace:1".to_owned()),
            active_window_handle: Some("window:opaque-1".to_owned()),
        }
    }

    #[test]
    fn round_trips_hyprland_capabilities_and_workspace_snapshot() {
        let capabilities = HyprlandCapabilities {
            availability: HyprlandAvailability::Available,
            version: Some("0.56.2".to_owned()),
            can_query_workspaces: true,
            can_query_windows: true,
            can_query_active_workspace: true,
            can_query_active_window: true,
            can_receive_events: true,
        };
        let response = Response::WorkspaceSnapshot {
            protocol_version: PROTOCOL_VERSION,
            request_id: 99,
            snapshot: test_snapshot(),
        };

        let capabilities_json = serde_json::to_string(&capabilities).unwrap();
        assert_eq!(
            serde_json::from_str::<HyprlandCapabilities>(&capabilities_json).unwrap(),
            capabilities
        );
        let json = serde_json::to_string(&response).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), response);
    }

    #[test]
    fn snapshot_validation_rejects_unknown_handles_and_detects_stale_sequences() {
        let mut snapshot = test_snapshot();
        assert!(snapshot.validate().is_ok());
        assert!(snapshot.is_newer_than(6));
        assert!(!snapshot.is_newer_than(7));

        snapshot.windows[0].workspace_handle = "workspace:missing".to_owned();
        assert_eq!(
            snapshot.validate(),
            Err(SnapshotValidationError::UnknownWindowWorkspace)
        );
    }
}
