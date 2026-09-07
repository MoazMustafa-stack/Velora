use serde::{Deserialize, Serialize};
use std::{env, path::PathBuf};
use thiserror::Error;

/// Core, the native bridge, and Godot intentionally require an exact match.
/// Phase 5 bumps the contract to v5 for the typed media and notification
/// contract. v5 is not backward compatible with v4: the exact-match handshake
/// rejects any client that does not advertise `PROTOCOL_VERSION`, so Core,
/// the bridge fixtures, and Godot move together (see the Phase 5 plan).
pub const PROTOCOL_VERSION: u8 = 5;
pub const MAX_MESSAGE_BYTES: usize = 64 * 1024;
pub const HANDSHAKE_TIMEOUT_SECONDS: u64 = 5;
pub const DEFAULT_APPLICATION_PAGE_SIZE: u16 = 32;
pub const MAX_APPLICATION_PAGE_SIZE: u16 = 64;
pub const MAX_WORKSPACES: usize = 128;
pub const MAX_WINDOWS: usize = 1024;
pub const DEFAULT_TELEMETRY_INTERVAL_MS: u32 = 1_000;
pub const MIN_TELEMETRY_INTERVAL_MS: u32 = 250;
pub const MAX_TELEMETRY_INTERVAL_MS: u32 = 10_000;
pub const MAX_TELEMETRY_DEVICES: u16 = 64;
pub const MAX_TELEMETRY_INTERFACES: u16 = 64;
pub const MAX_TELEMETRY_PAYLOAD_BYTES: usize = 4 * 1024;
/// Maximum number of MPRIS players carried in one media snapshot.
pub const MAX_MEDIA_PLAYERS: usize = 16;
/// Maximum number of notifications carried in one bounded notification feed.
pub const MAX_NOTIFICATIONS: usize = 32;
/// Maximum byte length (UTF-8) of any media/notification string field.
pub const MAX_STRING_BYTES: usize = 256;
/// Frame budget for a serialized media snapshot. This is a Core-enforced
/// production budget, not a consequence of the structural ceilings: sixteen
/// players at full-width strings can exceed 4 KiB, so Core bounds the payload
/// independently (truncating metadata) when it serves a snapshot.
pub const MAX_MEDIA_PAYLOAD_BYTES: usize = 4 * 1024;
/// Frame budget for a serialized notification feed, enforced by Core via
/// drop-oldest/truncation. The structural ceiling (`MAX_NOTIFICATIONS`) does
/// not by itself guarantee a frame fits this budget.
pub const MAX_NOTIFICATION_PAYLOAD_BYTES: usize = 4 * 1024;
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

/// Availability is explicit so zero remains a real measurement rather than an
/// error sentinel. `WarmingUp` is used while a counter-based metric waits for
/// the second sample needed to calculate a rate.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TelemetryAvailability {
    Available,
    WarmingUp,
    Offline,
    Unavailable,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct CpuTelemetry {
    pub availability: TelemetryAvailability,
    /// `10_000` basis points represents 100.00% utilization.
    pub utilization_basis_points: Option<u16>,
    pub logical_cpu_count: u16,
    /// Load averages are fixed-point values where `1_000` represents 1.0.
    pub load_1m_milli: u32,
    pub load_5m_milli: u32,
    pub load_15m_milli: u32,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct MemoryTelemetry {
    pub availability: TelemetryAvailability,
    pub total_bytes: u64,
    pub available_bytes: u64,
    pub used_bytes: u64,
    pub cached_bytes: u64,
    pub swap_total_bytes: u64,
    pub swap_used_bytes: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct DiskTelemetry {
    pub availability: TelemetryAvailability,
    pub read_bytes_per_second: u64,
    pub write_bytes_per_second: u64,
    pub device_count: u16,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NetworkTelemetry {
    pub availability: TelemetryAvailability,
    pub receive_bytes_per_second: u64,
    pub transmit_bytes_per_second: u64,
    pub interface_count: u16,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct TelemetrySnapshot {
    /// Monotonically increasing within one Core session.
    pub sequence: u64,
    pub sampled_at_unix_ms: u64,
    pub sample_interval_ms: u32,
    pub cpu: CpuTelemetry,
    pub memory: MemoryTelemetry,
    pub disk: DiskTelemetry,
    pub network: NetworkTelemetry,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum TelemetryValidationError {
    #[error("telemetry sample interval is outside the supported policy")]
    InvalidSampleInterval,
    #[error("CPU utilization exceeds 100.00%")]
    InvalidCpuUtilization,
    #[error("memory telemetry contains inconsistent byte totals")]
    InvalidMemoryTotals,
    #[error("swap telemetry contains inconsistent byte totals")]
    InvalidSwapTotals,
    #[error("telemetry contains more than {MAX_TELEMETRY_DEVICES} disk devices")]
    TooManyDevices,
    #[error("telemetry contains more than {MAX_TELEMETRY_INTERFACES} network interfaces")]
    TooManyInterfaces,
}

impl TelemetrySnapshot {
    pub fn is_newer_than(&self, sequence: u64) -> bool {
        self.sequence > sequence
    }

    pub fn validate(&self) -> Result<(), TelemetryValidationError> {
        if !(MIN_TELEMETRY_INTERVAL_MS..=MAX_TELEMETRY_INTERVAL_MS)
            .contains(&self.sample_interval_ms)
        {
            return Err(TelemetryValidationError::InvalidSampleInterval);
        }
        if self
            .cpu
            .utilization_basis_points
            .is_some_and(|value| value > 10_000)
        {
            return Err(TelemetryValidationError::InvalidCpuUtilization);
        }
        if self.memory.available_bytes > self.memory.total_bytes
            || self.memory.used_bytes > self.memory.total_bytes
            || self.memory.cached_bytes > self.memory.total_bytes
            || self.memory.used_bytes
                != self
                    .memory
                    .total_bytes
                    .saturating_sub(self.memory.available_bytes)
        {
            return Err(TelemetryValidationError::InvalidMemoryTotals);
        }
        if self.memory.swap_used_bytes > self.memory.swap_total_bytes {
            return Err(TelemetryValidationError::InvalidSwapTotals);
        }
        if self.disk.device_count > MAX_TELEMETRY_DEVICES {
            return Err(TelemetryValidationError::TooManyDevices);
        }
        if self.network.interface_count > MAX_TELEMETRY_INTERFACES {
            return Err(TelemetryValidationError::TooManyInterfaces);
        }
        Ok(())
    }
}

/// MPRIS `PlaybackStatus` values. A player that has not reported a status yet
/// is normalized to `Stopped` by Core rather than inventing a fourth variant.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackStatus {
    Playing,
    Paused,
    Stopped,
}

/// One MPRIS player normalized for the media console. The handle is opaque and
/// snapshot-issued; a raw D-Bus well-known name never crosses Velora IPC.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct MediaPlayer {
    /// Opaque, snapshot-issued identifier. Never a raw bus name.
    pub handle: String,
    /// Human-readable player identity (for example "Spotify"). Never a bus name.
    pub identity: String,
    pub status: PlaybackStatus,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    /// Track length in microseconds, when known.
    pub length_micros: Option<u64>,
    /// Playback position in microseconds.
    pub position_micros: u64,
    pub can_play: bool,
    pub can_pause: bool,
    pub can_go_next: bool,
    pub can_go_previous: bool,
    pub can_seek: bool,
    pub can_control: bool,
}

/// The single authoritative media snapshot Core serves to the frontend.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct MediaSnapshot {
    /// Monotonically increasing within one Core session. Clients ignore older
    /// values so a reconnecting or stale reader can never regress state.
    pub sequence: u64,
    pub players: Vec<MediaPlayer>,
    pub active_player_handle: Option<String>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum MediaSnapshotValidationError {
    #[error("media snapshot contains more than {MAX_MEDIA_PLAYERS} players")]
    TooManyPlayers,
    #[error("media snapshot contains an empty or duplicate player handle")]
    InvalidPlayerHandle,
    #[error("media snapshot string exceeds {MAX_STRING_BYTES} bytes")]
    StringTooLong,
    #[error("active player handle is not in the snapshot")]
    UnknownActivePlayer,
}

impl MediaSnapshot {
    pub fn is_newer_than(&self, sequence: u64) -> bool {
        self.sequence > sequence
    }

    pub fn validate(&self) -> Result<(), MediaSnapshotValidationError> {
        if self.players.len() > MAX_MEDIA_PLAYERS {
            return Err(MediaSnapshotValidationError::TooManyPlayers);
        }

        let mut handles = std::collections::HashSet::new();
        for player in &self.players {
            if player.handle.is_empty() || !handles.insert(&player.handle) {
                return Err(MediaSnapshotValidationError::InvalidPlayerHandle);
            }
            player.validate_strings()?;
        }

        if self
            .active_player_handle
            .as_ref()
            .is_some_and(|handle| !handles.contains(handle))
        {
            return Err(MediaSnapshotValidationError::UnknownActivePlayer);
        }

        Ok(())
    }
}

impl MediaPlayer {
    fn validate_strings(&self) -> Result<(), MediaSnapshotValidationError> {
        let fields = [
            Some(self.identity.as_str()),
            self.title.as_deref(),
            self.artist.as_deref(),
            self.album.as_deref(),
        ];
        if fields
            .into_iter()
            .flatten()
            .any(|field| field.len() > MAX_STRING_BYTES)
        {
            return Err(MediaSnapshotValidationError::StringTooLong);
        }
        Ok(())
    }
}

/// Notifications urgency levels (`0` low, `1` normal, `2` critical).
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NotificationUrgency {
    Low,
    Normal,
    Critical,
}

/// One observed notification. The handle is opaque and feed-issued; the raw
/// daemon replacement id never crosses Velora IPC.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Notification {
    /// Opaque, feed-issued identifier. Never a raw daemon id.
    pub handle: String,
    pub app_name: String,
    pub summary: String,
    pub body: String,
    pub urgency: NotificationUrgency,
    /// Unix timestamp in milliseconds when the notification was posted.
    pub timestamp_unix_ms: u64,
}

/// The bounded, memory-only notification feed Core serves to the frontend.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NotificationFeed {
    /// Monotonically increasing within one Core session.
    pub sequence: u64,
    pub notifications: Vec<Notification>,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum NotificationFeedValidationError {
    #[error("notification feed contains more than {MAX_NOTIFICATIONS} notifications")]
    TooManyNotifications,
    #[error("notification feed contains an empty or duplicate handle")]
    InvalidNotificationHandle,
    #[error("notification string exceeds {MAX_STRING_BYTES} bytes")]
    StringTooLong,
}

impl NotificationFeed {
    pub fn is_newer_than(&self, sequence: u64) -> bool {
        self.sequence > sequence
    }

    pub fn validate(&self) -> Result<(), NotificationFeedValidationError> {
        if self.notifications.len() > MAX_NOTIFICATIONS {
            return Err(NotificationFeedValidationError::TooManyNotifications);
        }

        let mut handles = std::collections::HashSet::new();
        for notification in &self.notifications {
            if notification.handle.is_empty() || !handles.insert(&notification.handle) {
                return Err(NotificationFeedValidationError::InvalidNotificationHandle);
            }
            notification.validate_strings()?;
        }

        Ok(())
    }
}

impl Notification {
    fn validate_strings(&self) -> Result<(), NotificationFeedValidationError> {
        let fields = [
            self.app_name.as_str(),
            self.summary.as_str(),
            self.body.as_str(),
        ];
        if fields.iter().any(|field| field.len() > MAX_STRING_BYTES) {
            return Err(NotificationFeedValidationError::StringTooLong);
        }
        Ok(())
    }
}

/// The only control verbs Godot may send. Bus names, method names, and
/// arguments never cross Velora IPC; Core re-maps this allowlisted verb onto
/// the corresponding MPRIS method for the opaque player handle.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MediaControlVerb {
    Play,
    Pause,
    PlayPause,
    Stop,
    Next,
    Previous,
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
    SwitchWorkspace {
        protocol_version: u8,
        request_id: u64,
        /// A snapshot-issued opaque handle. Raw compositor selectors are never
        /// accepted across IPC.
        workspace_handle: String,
    },
    FocusWindow {
        protocol_version: u8,
        request_id: u64,
        /// A snapshot-issued opaque handle. Never a raw selector string.
        window_handle: String,
    },
    /// Returns Core's latest cached sample. Clients cannot request a sampling
    /// frequency, so they cannot bypass the server-owned sampling policy.
    GetTelemetrySnapshot {
        protocol_version: u8,
        request_id: u64,
    },
    GetMediaSnapshot {
        protocol_version: u8,
        request_id: u64,
    },
    GetNotifications {
        protocol_version: u8,
        request_id: u64,
    },
    SendMediaControl {
        protocol_version: u8,
        request_id: u64,
        /// A snapshot-issued opaque handle. Raw bus names are never accepted.
        player_handle: String,
        verb: MediaControlVerb,
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
    SwitchAccepted {
        protocol_version: u8,
        request_id: u64,
        workspace_handle: String,
    },
    SwitchRejected {
        protocol_version: u8,
        request_id: u64,
        workspace_handle: String,
        code: WorkspaceSwitchError,
    },
    FocusAccepted {
        protocol_version: u8,
        request_id: u64,
        window_handle: String,
    },
    FocusRejected {
        protocol_version: u8,
        request_id: u64,
        window_handle: String,
        code: WindowFocusError,
    },
    TelemetrySnapshot {
        protocol_version: u8,
        request_id: u64,
        snapshot: TelemetrySnapshot,
    },
    TelemetrySnapshotRejected {
        protocol_version: u8,
        request_id: u64,
        code: TelemetrySnapshotError,
        retryable: bool,
    },
    MediaSnapshot {
        protocol_version: u8,
        request_id: u64,
        snapshot: MediaSnapshot,
    },
    MediaSnapshotRejected {
        protocol_version: u8,
        request_id: u64,
        code: MediaSnapshotError,
        retryable: bool,
    },
    Notifications {
        protocol_version: u8,
        request_id: u64,
        feed: NotificationFeed,
    },
    NotificationsRejected {
        protocol_version: u8,
        request_id: u64,
        code: NotificationsError,
        retryable: bool,
    },
    MediaControlAccepted {
        protocol_version: u8,
        request_id: u64,
        player_handle: String,
    },
    MediaControlRejected {
        protocol_version: u8,
        request_id: u64,
        player_handle: String,
        code: MediaControlError,
    },
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TelemetrySnapshotError {
    Disabled,
    SnapshotNotReady,
    SamplerUnavailable,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceSnapshotError {
    HyprlandUnavailable,
    HyprlandIncompatible,
    SnapshotNotReady,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceSwitchError {
    HyprlandUnavailable,
    HyprlandIncompatible,
    InvalidWorkspaceHandle,
    UnknownWorkspaceHandle,
    UnsupportedWorkspace,
    SwitchFailed,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WindowFocusError {
    HyprlandUnavailable,
    HyprlandIncompatible,
    UnknownWindowHandle,
    FocusFailed,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MediaSnapshotError {
    MediaUnavailable,
    SnapshotNotReady,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MediaControlError {
    MediaUnavailable,
    UnknownPlayer,
    StaleHandle,
    ControlUnavailable,
    ControlFailed,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NotificationsError {
    NotificationsUnavailable,
    MonitorRestricted,
    FeedNotReady,
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
            }
            | Self::SwitchWorkspace {
                protocol_version, ..
            }
            | Self::FocusWindow {
                protocol_version, ..
            }
            | Self::GetTelemetrySnapshot {
                protocol_version, ..
            }
            | Self::GetMediaSnapshot {
                protocol_version, ..
            }
            | Self::GetNotifications {
                protocol_version, ..
            }
            | Self::SendMediaControl {
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
            r#"{"type":"hello","protocol_version":5,"client_name":"velora-godot","client_version":"0.2.0"}"#
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
    fn round_trips_switch_requests_and_typed_outcomes() {
        let request = Request::SwitchWorkspace {
            protocol_version: PROTOCOL_VERSION,
            request_id: 21,
            workspace_handle: "workspace:3".to_owned(),
        };
        let json = serde_json::to_string(&request).unwrap();
        assert_eq!(serde_json::from_str::<Request>(&json).unwrap(), request);
        assert_eq!(request.protocol_version(), PROTOCOL_VERSION);

        let accepted = Response::SwitchAccepted {
            protocol_version: PROTOCOL_VERSION,
            request_id: 21,
            workspace_handle: "workspace:3".to_owned(),
        };
        let json = serde_json::to_string(&accepted).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), accepted);

        let rejected = Response::SwitchRejected {
            protocol_version: PROTOCOL_VERSION,
            request_id: 22,
            workspace_handle: "workspace:9999".to_owned(),
            code: WorkspaceSwitchError::UnknownWorkspaceHandle,
        };
        let json = serde_json::to_string(&rejected).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), rejected);
    }

    #[test]
    fn round_trips_focus_requests_and_typed_outcomes() {
        let request = Request::FocusWindow {
            protocol_version: PROTOCOL_VERSION,
            request_id: 31,
            window_handle: "window:abc123".to_owned(),
        };
        let json = serde_json::to_string(&request).unwrap();
        assert_eq!(serde_json::from_str::<Request>(&json).unwrap(), request);
        assert_eq!(request.protocol_version(), PROTOCOL_VERSION);

        let accepted = Response::FocusAccepted {
            protocol_version: PROTOCOL_VERSION,
            request_id: 31,
            window_handle: "window:abc123".to_owned(),
        };
        let json = serde_json::to_string(&accepted).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), accepted);

        let rejected = Response::FocusRejected {
            protocol_version: PROTOCOL_VERSION,
            request_id: 32,
            window_handle: "window:gone".to_owned(),
            code: WindowFocusError::UnknownWindowHandle,
        };
        let json = serde_json::to_string(&rejected).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), rejected);
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

    fn test_telemetry_snapshot() -> TelemetrySnapshot {
        TelemetrySnapshot {
            sequence: 8,
            sampled_at_unix_ms: 1_777_777_777_000,
            sample_interval_ms: DEFAULT_TELEMETRY_INTERVAL_MS,
            cpu: CpuTelemetry {
                availability: TelemetryAvailability::Available,
                utilization_basis_points: Some(3_725),
                logical_cpu_count: 8,
                load_1m_milli: 750,
                load_5m_milli: 1_250,
                load_15m_milli: 2_000,
            },
            memory: MemoryTelemetry {
                availability: TelemetryAvailability::Available,
                total_bytes: 16 * 1024 * 1024 * 1024,
                available_bytes: 10 * 1024 * 1024 * 1024,
                used_bytes: 6 * 1024 * 1024 * 1024,
                cached_bytes: 2 * 1024 * 1024 * 1024,
                swap_total_bytes: 4 * 1024 * 1024 * 1024,
                swap_used_bytes: 512 * 1024 * 1024,
            },
            disk: DiskTelemetry {
                availability: TelemetryAvailability::Available,
                read_bytes_per_second: 1_048_576,
                write_bytes_per_second: 524_288,
                device_count: 2,
            },
            network: NetworkTelemetry {
                availability: TelemetryAvailability::Offline,
                receive_bytes_per_second: 0,
                transmit_bytes_per_second: 0,
                interface_count: 0,
            },
        }
    }

    #[test]
    fn round_trips_telemetry_request_snapshot_and_rejection() {
        let request = Request::GetTelemetrySnapshot {
            protocol_version: PROTOCOL_VERSION,
            request_id: 41,
        };
        let json = serde_json::to_string(&request).unwrap();
        assert_eq!(serde_json::from_str::<Request>(&json).unwrap(), request);
        assert_eq!(request.protocol_version(), PROTOCOL_VERSION);

        let response = Response::TelemetrySnapshot {
            protocol_version: PROTOCOL_VERSION,
            request_id: 41,
            snapshot: test_telemetry_snapshot(),
        };
        let json = serde_json::to_string(&response).unwrap();
        assert!(json.len() <= MAX_TELEMETRY_PAYLOAD_BYTES);
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), response);

        let rejected = Response::TelemetrySnapshotRejected {
            protocol_version: PROTOCOL_VERSION,
            request_id: 42,
            code: TelemetrySnapshotError::SnapshotNotReady,
            retryable: true,
        };
        let json = serde_json::to_string(&rejected).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), rejected);

        let sampler_unavailable = Response::TelemetrySnapshotRejected {
            protocol_version: PROTOCOL_VERSION,
            request_id: 43,
            code: TelemetrySnapshotError::SamplerUnavailable,
            retryable: true,
        };
        let json = serde_json::to_string(&sampler_unavailable).unwrap();
        assert_eq!(
            serde_json::from_str::<Response>(&json).unwrap(),
            sampler_unavailable
        );

        let disabled = Response::TelemetrySnapshotRejected {
            protocol_version: PROTOCOL_VERSION,
            request_id: 44,
            code: TelemetrySnapshotError::Disabled,
            retryable: false,
        };
        let json = serde_json::to_string(&disabled).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), disabled);
    }

    #[test]
    fn max_width_snapshot_stays_under_payload_limit_and_validates() {
        let mut snapshot = test_telemetry_snapshot();
        snapshot.disk.device_count = MAX_TELEMETRY_DEVICES;
        snapshot.network.interface_count = MAX_TELEMETRY_INTERFACES;
        snapshot.cpu.utilization_basis_points = Some(10_000);
        snapshot.disk.read_bytes_per_second = u64::MAX;
        snapshot.disk.write_bytes_per_second = u64::MAX;
        snapshot.network.receive_bytes_per_second = u64::MAX;
        snapshot.network.transmit_bytes_per_second = u64::MAX;
        snapshot.memory.total_bytes = u64::MAX;
        snapshot.memory.available_bytes = u64::MAX - 1;
        snapshot.memory.used_bytes = 1;
        snapshot.memory.cached_bytes = u64::MAX / 2;
        snapshot.memory.swap_total_bytes = u64::MAX;
        snapshot.memory.swap_used_bytes = u64::MAX - 1;

        assert!(snapshot.validate().is_ok());
        let snapshot_response = Response::TelemetrySnapshot {
            protocol_version: PROTOCOL_VERSION,
            request_id: 50,
            snapshot,
        };
        let json = serde_json::to_string(&snapshot_response).unwrap();
        assert!(json.len() <= MAX_TELEMETRY_PAYLOAD_BYTES);
    }

    #[test]
    fn validates_telemetry_policy_and_bounds() {
        let mut snapshot = test_telemetry_snapshot();
        assert!(snapshot.validate().is_ok());
        assert!(snapshot.is_newer_than(7));
        assert!(!snapshot.is_newer_than(8));

        snapshot.sample_interval_ms = MIN_TELEMETRY_INTERVAL_MS - 1;
        assert_eq!(
            snapshot.validate(),
            Err(TelemetryValidationError::InvalidSampleInterval)
        );
        snapshot.sample_interval_ms = DEFAULT_TELEMETRY_INTERVAL_MS;
        snapshot.cpu.utilization_basis_points = Some(10_001);
        assert_eq!(
            snapshot.validate(),
            Err(TelemetryValidationError::InvalidCpuUtilization)
        );
        snapshot.cpu.utilization_basis_points = Some(10_000);
        snapshot.disk.device_count = MAX_TELEMETRY_DEVICES + 1;
        assert_eq!(
            snapshot.validate(),
            Err(TelemetryValidationError::TooManyDevices)
        );

        snapshot.disk.device_count = MAX_TELEMETRY_DEVICES;
        snapshot.network.interface_count = MAX_TELEMETRY_INTERFACES + 1;
        assert_eq!(
            snapshot.validate(),
            Err(TelemetryValidationError::TooManyInterfaces)
        );

        snapshot.network.interface_count = MAX_TELEMETRY_INTERFACES;
        snapshot.memory.available_bytes = snapshot.memory.total_bytes + 1;
        assert_eq!(
            snapshot.validate(),
            Err(TelemetryValidationError::InvalidMemoryTotals)
        );

        snapshot.memory.available_bytes = 10 * 1024 * 1024 * 1024;
        snapshot.memory.used_bytes = 6 * 1024 * 1024 * 1024;
        snapshot.sample_interval_ms = MAX_TELEMETRY_INTERVAL_MS + 1;
        assert_eq!(
            snapshot.validate(),
            Err(TelemetryValidationError::InvalidSampleInterval)
        );
    }

    fn test_media_player(handle: &str) -> MediaPlayer {
        MediaPlayer {
            handle: handle.to_owned(),
            identity: "Spotify".to_owned(),
            status: PlaybackStatus::Playing,
            title: Some("Velora Theme".to_owned()),
            artist: Some("Velora".to_owned()),
            album: Some("Phase 5".to_owned()),
            length_micros: Some(250_000_000),
            position_micros: 12_500_000,
            can_play: true,
            can_pause: true,
            can_go_next: true,
            can_go_previous: true,
            can_seek: true,
            can_control: true,
        }
    }

    fn test_media_snapshot() -> MediaSnapshot {
        MediaSnapshot {
            sequence: 9,
            players: vec![test_media_player("player:opaque-1")],
            active_player_handle: Some("player:opaque-1".to_owned()),
        }
    }

    fn test_notification(handle: &str) -> Notification {
        Notification {
            handle: handle.to_owned(),
            app_name: "Velora".to_owned(),
            summary: "Build complete".to_owned(),
            body: "The release gate passed.".to_owned(),
            urgency: NotificationUrgency::Normal,
            timestamp_unix_ms: 1_777_777_777_000,
        }
    }

    fn test_notification_feed() -> NotificationFeed {
        NotificationFeed {
            sequence: 5,
            notifications: vec![test_notification("notification:opaque-1")],
        }
    }

    #[test]
    fn round_trips_media_snapshot_request_response_and_rejection() {
        let request = Request::GetMediaSnapshot {
            protocol_version: PROTOCOL_VERSION,
            request_id: 61,
        };
        let json = serde_json::to_string(&request).unwrap();
        assert_eq!(serde_json::from_str::<Request>(&json).unwrap(), request);
        assert_eq!(request.protocol_version(), PROTOCOL_VERSION);

        let response = Response::MediaSnapshot {
            protocol_version: PROTOCOL_VERSION,
            request_id: 61,
            snapshot: test_media_snapshot(),
        };
        let json = serde_json::to_string(&response).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), response);

        let rejected = Response::MediaSnapshotRejected {
            protocol_version: PROTOCOL_VERSION,
            request_id: 62,
            code: MediaSnapshotError::MediaUnavailable,
            retryable: false,
        };
        let json = serde_json::to_string(&rejected).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), rejected);
    }

    #[test]
    fn round_trips_notifications_request_response_and_rejection() {
        let request = Request::GetNotifications {
            protocol_version: PROTOCOL_VERSION,
            request_id: 63,
        };
        let json = serde_json::to_string(&request).unwrap();
        assert_eq!(serde_json::from_str::<Request>(&json).unwrap(), request);
        assert_eq!(request.protocol_version(), PROTOCOL_VERSION);

        let response = Response::Notifications {
            protocol_version: PROTOCOL_VERSION,
            request_id: 63,
            feed: test_notification_feed(),
        };
        let json = serde_json::to_string(&response).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), response);

        for code in [
            NotificationsError::NotificationsUnavailable,
            NotificationsError::MonitorRestricted,
            NotificationsError::FeedNotReady,
        ] {
            let rejected = Response::NotificationsRejected {
                protocol_version: PROTOCOL_VERSION,
                request_id: 64,
                code,
                retryable: true,
            };
            let json = serde_json::to_string(&rejected).unwrap();
            assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), rejected);
        }
    }

    #[test]
    fn round_trips_media_control_request_and_typed_outcomes() {
        for verb in [
            MediaControlVerb::Play,
            MediaControlVerb::Pause,
            MediaControlVerb::PlayPause,
            MediaControlVerb::Stop,
            MediaControlVerb::Next,
            MediaControlVerb::Previous,
        ] {
            let request = Request::SendMediaControl {
                protocol_version: PROTOCOL_VERSION,
                request_id: 71,
                player_handle: "player:opaque-1".to_owned(),
                verb,
            };
            let json = serde_json::to_string(&request).unwrap();
            assert_eq!(serde_json::from_str::<Request>(&json).unwrap(), request);
            assert_eq!(request.protocol_version(), PROTOCOL_VERSION);
        }

        let accepted = Response::MediaControlAccepted {
            protocol_version: PROTOCOL_VERSION,
            request_id: 71,
            player_handle: "player:opaque-1".to_owned(),
        };
        let json = serde_json::to_string(&accepted).unwrap();
        assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), accepted);

        for code in [
            MediaControlError::MediaUnavailable,
            MediaControlError::UnknownPlayer,
            MediaControlError::StaleHandle,
            MediaControlError::ControlUnavailable,
            MediaControlError::ControlFailed,
        ] {
            let rejected = Response::MediaControlRejected {
                protocol_version: PROTOCOL_VERSION,
                request_id: 72,
                player_handle: "player:opaque-1".to_owned(),
                code,
            };
            let json = serde_json::to_string(&rejected).unwrap();
            assert_eq!(serde_json::from_str::<Response>(&json).unwrap(), rejected);
        }
    }

    #[test]
    fn media_snapshot_validation_detects_bounds_and_stale_sequences() {
        let mut snapshot = test_media_snapshot();
        assert!(snapshot.validate().is_ok());
        assert!(snapshot.is_newer_than(8));
        assert!(!snapshot.is_newer_than(9));

        snapshot.active_player_handle = Some("player:missing".to_owned());
        assert_eq!(
            snapshot.validate(),
            Err(MediaSnapshotValidationError::UnknownActivePlayer)
        );
        snapshot.active_player_handle = Some("player:opaque-1".to_owned());

        snapshot.players.push(test_media_player("player:opaque-1"));
        assert_eq!(
            snapshot.validate(),
            Err(MediaSnapshotValidationError::InvalidPlayerHandle)
        );
        snapshot.players.pop();

        snapshot.players[0].handle.clear();
        assert_eq!(
            snapshot.validate(),
            Err(MediaSnapshotValidationError::InvalidPlayerHandle)
        );
        snapshot.players[0].handle = "player:opaque-1".to_owned();

        snapshot.players[0].title = Some("t".repeat(MAX_STRING_BYTES + 1));
        assert_eq!(
            snapshot.validate(),
            Err(MediaSnapshotValidationError::StringTooLong)
        );
    }

    #[test]
    fn media_snapshot_rejects_too_many_players() {
        let mut snapshot = test_media_snapshot();
        snapshot.players = (0..=MAX_MEDIA_PLAYERS)
            .map(|index| test_media_player(&format!("player:{index}")))
            .collect();
        assert_eq!(
            snapshot.validate(),
            Err(MediaSnapshotValidationError::TooManyPlayers)
        );
    }

    #[test]
    fn notification_feed_validation_detects_bounds_and_stale_sequences() {
        let mut feed = test_notification_feed();
        assert!(feed.validate().is_ok());
        assert!(feed.is_newer_than(4));
        assert!(!feed.is_newer_than(5));

        feed.notifications
            .push(test_notification("notification:opaque-1"));
        assert_eq!(
            feed.validate(),
            Err(NotificationFeedValidationError::InvalidNotificationHandle)
        );
        feed.notifications.pop();

        feed.notifications[0].handle.clear();
        assert_eq!(
            feed.validate(),
            Err(NotificationFeedValidationError::InvalidNotificationHandle)
        );
        feed.notifications[0].handle = "notification:opaque-1".to_owned();

        feed.notifications[0].body = "b".repeat(MAX_STRING_BYTES + 1);
        assert_eq!(
            feed.validate(),
            Err(NotificationFeedValidationError::StringTooLong)
        );
    }

    #[test]
    fn notification_feed_rejects_too_many_entries() {
        let mut feed = test_notification_feed();
        feed.notifications = (0..=MAX_NOTIFICATIONS)
            .map(|index| test_notification(&format!("notification:{index}")))
            .collect();
        assert_eq!(
            feed.validate(),
            Err(NotificationFeedValidationError::TooManyNotifications)
        );
    }

    #[test]
    fn full_media_snapshot_stays_under_the_transport_limit() {
        let mut snapshot = test_media_snapshot();
        snapshot.players = (0..MAX_MEDIA_PLAYERS)
            .map(|index| {
                let handle = format!("player:{index}");
                MediaPlayer {
                    handle,
                    identity: format!("Player {index}"),
                    status: PlaybackStatus::Paused,
                    title: Some(format!("Title {index}")),
                    artist: Some(format!("Artist {index}")),
                    album: Some(format!("Album {index}")),
                    length_micros: Some(u64::MAX),
                    position_micros: u64::MAX,
                    can_play: false,
                    can_pause: false,
                    can_go_next: false,
                    can_go_previous: false,
                    can_seek: false,
                    can_control: false,
                }
            })
            .collect();
        snapshot.active_player_handle = Some("player:0".to_owned());

        assert!(snapshot.validate().is_ok());
        let response = Response::MediaSnapshot {
            protocol_version: PROTOCOL_VERSION,
            request_id: 81,
            snapshot,
        };
        let json = serde_json::to_string(&response).unwrap();
        assert!(json.len() <= MAX_MESSAGE_BYTES);
    }

    #[test]
    fn protocol_v5_bounds_are_aligned() {
        assert_eq!(PROTOCOL_VERSION, 5);
        assert_eq!(MAX_MEDIA_PLAYERS, 16);
        assert_eq!(MAX_NOTIFICATIONS, 32);
        assert_eq!(MAX_STRING_BYTES, 256);
        assert_eq!(MAX_MEDIA_PAYLOAD_BYTES, 4 * 1024);
        assert_eq!(MAX_NOTIFICATION_PAYLOAD_BYTES, 4 * 1024);
    }
}
