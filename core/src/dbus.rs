//! Session-bus-only D-Bus capability probe.
//!
//! Velora observes media (MPRIS) and notification state strictly through the
//! user session bus. This module connects using environment/address data (with
//! a `VELORA_SESSION_BUS_ADDRESS` override so automated tests never touch the
//! live session bus), reports whether the bus is reachable, reads the
//! Notifications daemon's `GetServerInformation`, and lists MPRIS player names
//! via `org.freedesktop.DBus.ListNames` filtered to
//! `org.mpris.MediaPlayer2.*`.
//!
//! A missing bus or a denied read is never fatal: every failure degrades to a
//! typed `Unavailable` (or `Restricted`) result. This module never contacts the
//! system bus, never takes over a bus name, and never opens a full-bus monitor.

use std::{env, ffi::OsStr, time::Duration};
use thiserror::Error;
use tokio::time::timeout;
use velora_protocol::MAX_MEDIA_PLAYERS;
use zbus::{Connection, Proxy, names::OwnedBusName, names::OwnedUniqueName};

/// Session-bus address override used by tests, mirroring the `VELORA_SOCKET`
/// rule. Production falls back to `DBUS_SESSION_BUS_ADDRESS` via zbus.
const SESSION_BUS_ADDRESS_ENV: &str = "VELORA_SESSION_BUS_ADDRESS";

/// Maximum length of a reported MPRIS player name.
const MAX_MPRIS_NAME_CHARS: usize = 256;
/// Maximum length of a Notifications daemon server-information field.
const MAX_NOTIFICATION_FIELD_CHARS: usize = 256;
/// Maximum wall-clock time allowed for the entire startup probe (connect plus
/// both read-only observations). A present but hung session-bus socket must
/// never block Core startup indefinitely.
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

const NOTIFICATIONS_DESTINATION: &str = "org.freedesktop.Notifications";
const NOTIFICATIONS_PATH: &str = "/org/freedesktop/Notifications";
const NOTIFICATIONS_INTERFACE: &str = "org.freedesktop.Notifications";
const MPRIS_NAME_PREFIX: &str = "org.mpris.MediaPlayer2.";
const ACCESS_DENIED_ERROR: &str = "org.freedesktop.DBus.Error.AccessDenied";

/// Whether the session bus is reachable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BusAvailability {
    Available,
    Unavailable,
}

/// Whether MPRIS media observation is possible.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MediaAvailability {
    Available,
    Unavailable,
}

/// Whether notification observation is possible. `Restricted` means the bus
/// reached us but denied the observation attempt (monitoring access).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NotificationAvailability {
    Available,
    Unavailable,
    /// The broker/daemon refused the observation attempt (denied monitoring).
    Restricted,
}

/// The Notifications daemon's reported server information.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct NotificationsServerInfo {
    pub name: String,
    pub vendor: String,
    pub version: String,
    pub spec_version: String,
}

/// The result of the D-Bus capability probe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DbusCapabilities {
    pub bus: BusAvailability,
    pub media: MediaAvailability,
    pub notifications: NotificationAvailability,
    pub notifications_daemon: Option<NotificationsServerInfo>,
    pub mpris_players: Vec<String>,
}

impl DbusCapabilities {
    pub(crate) fn unavailable() -> Self {
        Self {
            bus: BusAvailability::Unavailable,
            media: MediaAvailability::Unavailable,
            notifications: NotificationAvailability::Unavailable,
            notifications_daemon: None,
            mpris_players: Vec::new(),
        }
    }
}

/// Typed failure of the read-only session-bus probe.
#[derive(Debug, Error)]
pub(crate) enum DbusError {
    #[error("session bus address override is not valid UTF-8")]
    InvalidAddress,
    #[error("failed to connect to the session bus: {0}")]
    Connect(#[source] zbus::Error),
    #[error("D-Bus probe call failed: {0}")]
    Call(#[source] zbus::Error),
    #[error("access to notification observation was denied")]
    AccessDenied,
}

/// Probe the session bus from environment/address data. Never fatal.
pub(crate) async fn probe_from_environment() -> DbusCapabilities {
    probe_with_address(env::var_os(SESSION_BUS_ADDRESS_ENV).as_deref()).await
}

async fn probe_with_address(override_address: Option<&OsStr>) -> DbusCapabilities {
    probe_with_address_and_timeout(override_address, PROBE_TIMEOUT).await
}

async fn probe_with_address_and_timeout(
    override_address: Option<&OsStr>,
    budget: Duration,
) -> DbusCapabilities {
    timeout(budget, probe_with_address_inner(override_address))
        .await
        .unwrap_or_else(|_| DbusCapabilities::unavailable())
}

async fn probe_with_address_inner(override_address: Option<&OsStr>) -> DbusCapabilities {
    let Ok(connection) = connect_session(override_address).await else {
        return DbusCapabilities::unavailable();
    };

    let (notifications, media) =
        tokio::join!(probe_notifications(&connection), probe_media(&connection),);

    DbusCapabilities {
        bus: BusAvailability::Available,
        media: media.availability,
        notifications: notifications.availability,
        notifications_daemon: notifications.daemon,
        mpris_players: media.players,
    }
}

async fn connect_session(override_address: Option<&OsStr>) -> Result<Connection, DbusError> {
    match override_address {
        Some(address) => {
            let address = address.to_str().ok_or(DbusError::InvalidAddress)?;
            zbus::connection::Builder::address(address)
                .map_err(DbusError::Connect)?
                .build()
                .await
                .map_err(DbusError::Connect)
        }
        None => Connection::session().await.map_err(DbusError::Connect),
    }
}

struct NotificationsProbe {
    availability: NotificationAvailability,
    daemon: Option<NotificationsServerInfo>,
}

async fn probe_notifications(connection: &Connection) -> NotificationsProbe {
    match read_server_information(connection).await {
        Ok(info) => NotificationsProbe {
            availability: NotificationAvailability::Available,
            daemon: Some(info),
        },
        Err(error) => NotificationsProbe {
            availability: classify_notifications_error(&error),
            daemon: None,
        },
    }
}

async fn read_server_information(
    connection: &Connection,
) -> Result<NotificationsServerInfo, DbusError> {
    let proxy = Proxy::new(
        connection,
        NOTIFICATIONS_DESTINATION,
        NOTIFICATIONS_PATH,
        NOTIFICATIONS_INTERFACE,
    )
    .await
    .map_err(map_call_error)?;

    let (name, vendor, version, spec_version): (String, String, String, String) = proxy
        .call("GetServerInformation", &())
        .await
        .map_err(map_call_error)?;

    Ok(NotificationsServerInfo {
        name: bounded_string(&name, MAX_NOTIFICATION_FIELD_CHARS),
        vendor: bounded_string(&vendor, MAX_NOTIFICATION_FIELD_CHARS),
        version: bounded_string(&version, MAX_NOTIFICATION_FIELD_CHARS),
        spec_version: bounded_string(&spec_version, MAX_NOTIFICATION_FIELD_CHARS),
    })
}

struct MediaProbe {
    availability: MediaAvailability,
    players: Vec<String>,
}

async fn probe_media(connection: &Connection) -> MediaProbe {
    match list_names(connection).await {
        Ok(names) => MediaProbe {
            availability: MediaAvailability::Available,
            players: mpris_player_names(names.iter().map(|name| name.as_str())),
        },
        Err(_) => MediaProbe {
            availability: MediaAvailability::Unavailable,
            players: Vec::new(),
        },
    }
}

async fn list_names(connection: &Connection) -> Result<Vec<OwnedBusName>, DbusError> {
    let proxy = zbus::fdo::DBusProxy::new(connection)
        .await
        .map_err(map_call_error)?;
    proxy.list_names().await.map_err(map_fdo_error)
}

/// List the `org.mpris.MediaPlayer2.*` well-known names currently owned on the
/// session bus. This is the media store's discovery half (P5.05): filtered and
/// bounded to [`MAX_MEDIA_PLAYERS`], so a hostile or overflowing name list can
/// never grow the snapshot unboundedly.
pub(crate) async fn list_players(connection: &Connection) -> Result<Vec<String>, DbusError> {
    let names = list_names(connection).await?;
    Ok(mpris_player_names(names.iter().map(|name| name.as_str())))
}

/// Resolve a player well-known name to its current unique owner. The media
/// store records this at refresh time and re-checks it at control-dispatch time
/// (P5.06), so a vanished player (no owner) or a replaced player (different
/// owner) always fails closed instead of dispatching to the wrong connection.
pub(crate) async fn player_owner(
    connection: &Connection,
    player_name: &str,
) -> Result<OwnedUniqueName, DbusError> {
    let proxy = Proxy::new(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )
    .await
    .map_err(map_call_error)?;

    proxy
        .call("GetNameOwner", &(player_name,))
        .await
        .map_err(map_call_error)
}

/// Keep only `org.mpris.MediaPlayer2.*` well-known names, bounded and trimmed.
fn mpris_player_names<'a>(names: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    names
        .into_iter()
        .filter(|name| name.starts_with(MPRIS_NAME_PREFIX))
        .map(|name| bounded_string(name, MAX_MPRIS_NAME_CHARS))
        .take(MAX_MEDIA_PLAYERS)
        .collect()
}

fn map_call_error(error: zbus::Error) -> DbusError {
    if is_access_denied(&error) {
        DbusError::AccessDenied
    } else {
        DbusError::Call(error)
    }
}

fn map_fdo_error(error: zbus::fdo::Error) -> DbusError {
    match error {
        zbus::fdo::Error::AccessDenied(_) => DbusError::AccessDenied,
        other => DbusError::Call(other.into()),
    }
}

fn is_access_denied(error: &zbus::Error) -> bool {
    matches!(
        error,
        zbus::Error::MethodError(name, _, _) if name.as_str() == ACCESS_DENIED_ERROR
    )
}

fn classify_notifications_error(error: &DbusError) -> NotificationAvailability {
    match error {
        DbusError::AccessDenied => NotificationAvailability::Restricted,
        _ => NotificationAvailability::Unavailable,
    }
}

fn bounded_string(value: &str, max_chars: usize) -> String {
    value.trim().chars().take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;

    /// A well-formed but unreachable session-bus address. Connecting fails
    /// immediately (no socket at this path), so no live bus is ever contacted.
    const BOGUS_BUS_ADDRESS: &str = "unix:path=/nonexistent/velora-test-bus";

    #[tokio::test]
    async fn unreachable_bus_reports_everything_unavailable() {
        let capabilities = probe_with_address(Some(OsStr::new(BOGUS_BUS_ADDRESS))).await;

        assert_eq!(capabilities.bus, BusAvailability::Unavailable);
        assert_eq!(capabilities.media, MediaAvailability::Unavailable);
        assert_eq!(
            capabilities.notifications,
            NotificationAvailability::Unavailable
        );
        assert!(capabilities.notifications_daemon.is_none());
        assert!(capabilities.mpris_players.is_empty());
    }

    #[tokio::test]
    async fn non_utf8_override_is_a_typed_unavailable() {
        let address = OsStr::from_bytes(&[0xff, 0xfe, 0xfd]);
        let capabilities = probe_with_address(Some(address)).await;

        assert_eq!(capabilities.bus, BusAvailability::Unavailable);
    }

    #[tokio::test]
    async fn hung_bus_socket_times_out_to_unavailable() {
        use std::os::unix::net::UnixListener as StdUnixListener;

        let directory = tempfile::tempdir().unwrap();
        let socket_path = directory.path().join("hung-bus");
        let listener = StdUnixListener::bind(&socket_path).unwrap();

        let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();
        let server = std::thread::spawn(move || {
            // Accept the client and hold the stream open without answering the
            // auth handshake, so the probe must time out instead of blocking.
            let (_stream, _address) = listener.accept().unwrap();
            let _ = stop_rx.recv();
        });

        let address = format!("unix:path={}", socket_path.display());
        let capabilities =
            probe_with_address_and_timeout(Some(OsStr::new(&address)), Duration::from_millis(100))
                .await;

        let _ = stop_tx.send(());
        server.join().unwrap();

        assert_eq!(capabilities.bus, BusAvailability::Unavailable);
    }

    #[test]
    fn filters_only_mpris_player_names_within_bounds() {
        let long: String = "y".repeat(MAX_MPRIS_NAME_CHARS + 100);
        let names = [
            "org.mpris.MediaPlayer2.spotify".to_string(),
            "org.freedesktop.Notifications".to_string(),
            ":1.42".to_string(),
            format!("org.mpris.MediaPlayer2.{long}"),
        ];

        let players = mpris_player_names(names.iter().map(String::as_str));

        assert_eq!(players.len(), 2);
        assert_eq!(players[0], "org.mpris.MediaPlayer2.spotify");
        assert!(players[1].starts_with("org.mpris.MediaPlayer2."));
        assert_eq!(players[1].chars().count(), MAX_MPRIS_NAME_CHARS);
    }

    #[test]
    fn caps_mpris_players_at_the_probe_limit() {
        let names: Vec<String> = (0..MAX_MEDIA_PLAYERS + 5)
            .map(|i| format!("org.mpris.MediaPlayer2.player{i}"))
            .collect();

        let players = mpris_player_names(names.iter().map(String::as_str));

        assert_eq!(players.len(), MAX_MEDIA_PLAYERS);
    }

    #[test]
    fn denied_access_classifies_as_restricted() {
        assert_eq!(
            classify_notifications_error(&DbusError::AccessDenied),
            NotificationAvailability::Restricted
        );
    }

    #[test]
    fn other_call_failures_classify_as_unavailable() {
        let io = std::io::Error::other("boom");
        let call_error = DbusError::Call(zbus::Error::InputOutput(std::sync::Arc::new(io)));

        assert_eq!(
            classify_notifications_error(&call_error),
            NotificationAvailability::Unavailable
        );
        assert_eq!(
            classify_notifications_error(&DbusError::InvalidAddress),
            NotificationAvailability::Unavailable
        );
        assert_eq!(
            classify_notifications_error(&DbusError::Connect(zbus::Error::Unsupported)),
            NotificationAvailability::Unavailable
        );
    }

    #[test]
    fn strings_are_trimmed_and_char_bounded() {
        assert_eq!(bounded_string("  padded  ", 8), "padded");

        let long = "🦀".repeat(MAX_NOTIFICATION_FIELD_CHARS + 50);
        assert_eq!(
            bounded_string(&long, MAX_NOTIFICATION_FIELD_CHARS)
                .chars()
                .count(),
            MAX_NOTIFICATION_FIELD_CHARS
        );
    }
}
