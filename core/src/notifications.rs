//! Narrow notification observer and privacy-gated, memory-only feed.
//!
//! Core observes notifications strictly through a `BecomeMonitor` eavesdrop
//! connection whose match rule is narrowed to
//! `interface='org.freedesktop.Notifications'`. The broker filters
//! non-matching traffic before it ever reaches Core, so unrelated desktop
//! traffic is never read — the narrowing is an architectural privacy control,
//! not a client-side filter.
//!
//! What is observed:
//!
//! * `Notify` method calls: the positional `app_name`, `summary`, and `body`
//!   strings plus the `urgency` hint (byte `0` low, `1` normal, `2` critical).
//!   `replaces_id`, `app_icon`, `actions`, and `expire_timeout` are never
//!   retained, and the raw daemon id never crosses Velora IPC.
//! * `NotificationClosed` / `ActionInvoked` signals are unicast daemon replies
//!   with no display content; they are recognized and ignored.
//!
//! The feed is memory-only (nothing is written to disk), bounded to
//! [`MAX_NOTIFICATIONS`] entries with drop-oldest semantics, and every string
//! is bounded to [`MAX_STRING_BYTES`] bytes. Each entry carries an opaque,
//! feed-issued handle and a Core-generated timestamp.
//!
//! The observer is gated behind `VELORA_NOTIFICATIONS_ENABLED` (see
//! [`crate::config::NotificationsPolicy`]). A broker that refuses `BecomeMonitor`
//! degrades to the typed [`NotificationAvailability::Restricted`] result with no
//! retry storm; any other setup failure degrades to
//! [`NotificationAvailability::Unavailable`].

use std::{
    collections::{HashMap, VecDeque},
    env,
    ffi::OsStr,
    future::poll_fn,
    pin::Pin,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use futures_core::Stream;
use thiserror::Error;
use tokio::{sync::watch, time::timeout};
use tracing::{debug, info, warn};
use velora_protocol::{
    MAX_NOTIFICATIONS, MAX_STRING_BYTES, Notification, NotificationFeed, NotificationUrgency,
};
use zbus::{
    Connection, MatchRule, Message, MessageStream, fdo::MonitoringProxy, message::Type,
    zvariant::OwnedValue,
};

use crate::dbus::NotificationAvailability;

/// Session-bus address override used by tests, mirroring the `VELORA_SOCKET`
/// and `VELORA_SESSION_BUS_ADDRESS` rules in the D-Bus probe.
const SESSION_BUS_ADDRESS_ENV: &str = "VELORA_SESSION_BUS_ADDRESS";
const NOTIFICATIONS_INTERFACE: &str = "org.freedesktop.Notifications";
const NOTIFY_MEMBER: &str = "Notify";
/// Maximum wall-clock time allowed to connect and become a monitor. A present
/// but hung session-bus socket must never keep a monitor task stuck forever.
const MONITOR_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// One normalized notification observation extracted from a `Notify` call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct NotifyObservation {
    pub app_name: String,
    pub summary: String,
    pub body: String,
    pub urgency: NotificationUrgency,
}

/// The bounded, memory-only notification feed served to the frontend.
pub(crate) struct NotificationStore {
    inner: Mutex<FeedState>,
}

struct FeedState {
    sequence: u64,
    next_handle: u64,
    notifications: VecDeque<Notification>,
    availability: NotificationAvailability,
}

impl NotificationStore {
    pub(crate) fn new() -> Self {
        Self {
            inner: Mutex::new(FeedState {
                sequence: 0,
                next_handle: 1,
                notifications: VecDeque::new(),
                availability: NotificationAvailability::Unavailable,
            }),
        }
    }

    /// The current feed, or `None` when no notification has been observed yet.
    /// The last-good feed is retained in memory even across a monitor failure,
    /// but it is only served while the monitor reports `Available`.
    pub(crate) fn current(&self) -> Option<Arc<NotificationFeed>> {
        let state = self.inner.lock().unwrap();
        if state.notifications.is_empty() {
            return None;
        }
        Some(Arc::new(NotificationFeed {
            sequence: state.sequence,
            notifications: state.notifications.iter().cloned().collect(),
        }))
    }

    pub(crate) fn availability(&self) -> NotificationAvailability {
        self.inner.lock().unwrap().availability
    }

    pub(crate) fn set_availability(&self, availability: NotificationAvailability) {
        self.inner.lock().unwrap().availability = availability;
    }

    /// Insert one observed notification: issue an opaque feed handle, bound its
    /// strings, and drop the oldest entry once the bound is reached.
    pub(crate) fn observe(&self, observation: NotifyObservation, timestamp_unix_ms: u64) {
        let mut state = self.inner.lock().unwrap();
        state.sequence += 1;
        let handle = format!("notification:{}", state.next_handle);
        state.next_handle += 1;
        let notification = Notification {
            handle,
            app_name: bounded_string(&observation.app_name, MAX_STRING_BYTES),
            summary: bounded_string(&observation.summary, MAX_STRING_BYTES),
            body: bounded_string(&observation.body, MAX_STRING_BYTES),
            urgency: observation.urgency,
            timestamp_unix_ms,
        };
        state.notifications.push_back(notification);
        if state.notifications.len() > MAX_NOTIFICATIONS {
            state.notifications.pop_front();
        }
    }
}

/// Run the narrow monitor until shutdown. Spawned only when the privacy gate
/// (`VELORA_NOTIFICATIONS_ENABLED`) is open; every failure degrades to a typed
/// availability with no retry storm.
pub(crate) async fn run(store: Arc<NotificationStore>, shutdown: watch::Receiver<bool>) {
    let address = env::var_os(SESSION_BUS_ADDRESS_ENV);
    let connection =
        match establish_monitor_with_timeout(address.as_deref(), MONITOR_CONNECT_TIMEOUT).await {
            Ok(connection) => connection,
            Err(error) => {
                warn!(%error, "notification monitor could not start");
                store.set_availability(monitor_error_availability(&error));
                return;
            }
        };

    store.set_availability(NotificationAvailability::Available);
    info!("notification monitor active (match rule narrowed to the Notifications interface)");
    run_stream(store, connection, shutdown).await;
}

async fn run_stream(
    store: Arc<NotificationStore>,
    connection: Connection,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut stream = MessageStream::from(connection);
    loop {
        tokio::select! {
            _ = shutdown.changed() => return,
            message = next_message(&mut stream) => match message {
                Some(Ok(message)) => handle_message(&store, message),
                Some(Err(error)) => {
                    warn!(%error, "notification monitor stream failed");
                    store.set_availability(NotificationAvailability::Unavailable);
                    return;
                }
                None => {
                    // The bus closed the monitor connection.
                    store.set_availability(NotificationAvailability::Unavailable);
                    info!("notification monitor stream closed");
                    return;
                }
            },
        }
    }
}

/// Poll the next monitor message. `MessageStream` implements
/// `futures_core::Stream`, so this avoids pulling in `futures-util`.
async fn next_message(stream: &mut MessageStream) -> Option<zbus::Result<Message>> {
    poll_fn(|cx| Pin::new(&mut *stream).poll_next(cx)).await
}

fn handle_message(store: &NotificationStore, message: Message) {
    match parse_notify(&message) {
        Ok(Some(observation)) => {
            let timestamp_unix_ms = unix_time_millis();
            store.observe(observation, timestamp_unix_ms);
            debug!("notification observed and appended to the feed");
        }
        Ok(None) => {
            // NotificationClosed / ActionInvoked / unrelated traffic: ignored.
        }
        Err(error) => {
            // Fail closed: malformed external notification data is dropped
            // rather than guessed at, and never reaches the feed.
            warn!(%error, "dropping malformed notification");
        }
    }
}

/// Extract a normalized observation from a `Notify` method call. `Ok(None)`
/// means the message is not a `Notify` call and carries no feed content.
fn parse_notify(message: &Message) -> Result<Option<NotifyObservation>, NotifyParseError> {
    if message.message_type() != Type::MethodCall {
        return Ok(None);
    }
    if message
        .header()
        .member()
        .is_none_or(|member| member.as_str() != NOTIFY_MEMBER)
    {
        return Ok(None);
    }
    // Defense in depth: the match rule already narrows the interface, but a
    // non-conforming broker could deliver other traffic.
    if message
        .header()
        .interface()
        .is_none_or(|interface| interface.as_str() != NOTIFICATIONS_INTERFACE)
    {
        return Ok(None);
    }

    let (app_name, _replaces_id, _app_icon, summary, body, _actions, hints, _expire_timeout) =
        message
            .body()
            .deserialize::<(
                String,
                u32,
                String,
                String,
                String,
                Vec<String>,
                HashMap<String, OwnedValue>,
                i32,
            )>()
            .map_err(NotifyParseError::MalformedBody)?;

    let urgency = urgency_from_hints(&hints)?;

    Ok(Some(NotifyObservation {
        app_name,
        summary,
        body,
        urgency,
    }))
}

fn urgency_from_hints(
    hints: &HashMap<String, OwnedValue>,
) -> Result<NotificationUrgency, NotifyParseError> {
    let Some(hint) = hints.get("urgency") else {
        // Per the spec the hint is optional; absence defaults to normal.
        return Ok(NotificationUrgency::Normal);
    };
    match hint.downcast_ref::<u8>() {
        Ok(0) => Ok(NotificationUrgency::Low),
        Ok(1) => Ok(NotificationUrgency::Normal),
        Ok(2) => Ok(NotificationUrgency::Critical),
        _ => Err(NotifyParseError::MalformedUrgency),
    }
}

async fn establish_monitor_with_timeout(
    address: Option<&OsStr>,
    budget: Duration,
) -> Result<Connection, MonitorError> {
    match timeout(budget, establish_monitor(address)).await {
        Ok(result) => result,
        Err(_) => Err(MonitorError::TimedOut),
    }
}

async fn establish_monitor(address: Option<&OsStr>) -> Result<Connection, MonitorError> {
    let connection = connect(address).await?;
    become_monitor(&connection).await?;
    Ok(connection)
}

async fn connect(address: Option<&OsStr>) -> Result<Connection, MonitorError> {
    match address {
        Some(address) => {
            let address = address.to_str().ok_or(MonitorError::InvalidAddress)?;
            zbus::connection::Builder::address(address)
                .map_err(MonitorError::Connect)?
                .build()
                .await
                .map_err(MonitorError::Connect)
        }
        None => Connection::session().await.map_err(MonitorError::Connect),
    }
}

async fn become_monitor(connection: &Connection) -> Result<(), MonitorError> {
    let proxy = MonitoringProxy::new(connection)
        .await
        .map_err(MonitorError::Call)?;
    let rules = [monitor_match_rule()];
    proxy
        .become_monitor(&rules, 0)
        .await
        .map_err(map_fdo_error)?;
    Ok(())
}

/// The monitor match rule: narrowed to the Notifications interface only. The
/// broker enforces this before any message reaches Core.
fn monitor_match_rule() -> MatchRule<'static> {
    MatchRule::builder()
        .interface(NOTIFICATIONS_INTERFACE)
        .expect("org.freedesktop.Notifications is a valid interface name")
        .build()
}

fn map_fdo_error(error: zbus::fdo::Error) -> MonitorError {
    match error {
        zbus::fdo::Error::AccessDenied(_) => MonitorError::AccessDenied,
        other => MonitorError::Call(other.into()),
    }
}

fn monitor_error_availability(error: &MonitorError) -> NotificationAvailability {
    match error {
        MonitorError::AccessDenied => NotificationAvailability::Restricted,
        _ => NotificationAvailability::Unavailable,
    }
}

fn bounded_string(value: &str, max_bytes: usize) -> String {
    let trimmed = value.trim();
    if trimmed.len() <= max_bytes {
        return trimmed.to_owned();
    }
    // Step back to a UTF-8 character boundary so the slice stays valid.
    let mut end = max_bytes;
    while end > 0 && !trimmed.is_char_boundary(end) {
        end -= 1;
    }
    trimmed[..end].to_owned()
}

fn unix_time_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|elapsed| u64::try_from(elapsed.as_millis()).ok())
        .unwrap_or(u64::MAX)
}

#[derive(Debug, Error)]
enum MonitorError {
    #[error("session bus address override is not valid UTF-8")]
    InvalidAddress,
    #[error("failed to connect to the session bus: {0}")]
    Connect(#[source] zbus::Error),
    #[error("monitoring call failed: {0}")]
    Call(#[source] zbus::Error),
    #[error("monitoring was denied by the bus")]
    AccessDenied,
    #[error("notification monitor setup timed out")]
    TimedOut,
}

#[derive(Debug, Error)]
enum NotifyParseError {
    #[error("notification body could not be decoded: {0}")]
    MalformedBody(#[source] zbus::Error),
    #[error("notification urgency hint is malformed")]
    MalformedUrgency,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;

    fn observation(app_name: &str) -> NotifyObservation {
        NotifyObservation {
            app_name: app_name.to_owned(),
            summary: "Summary".to_owned(),
            body: "Body".to_owned(),
            urgency: NotificationUrgency::Normal,
        }
    }

    fn notify_message(app_name: &str, summary: &str, body: &str, urgency: Option<u8>) -> Message {
        let mut hints = HashMap::<String, OwnedValue>::new();
        if let Some(urgency) = urgency {
            hints.insert("urgency".to_owned(), OwnedValue::from(urgency));
        }
        let payload = (
            app_name.to_owned(),
            0u32,
            String::new(),
            summary.to_owned(),
            body.to_owned(),
            Vec::<String>::new(),
            hints,
            -1i32,
        );
        Message::method_call("/org/freedesktop/Notifications", NOTIFY_MEMBER)
            .unwrap()
            .interface(NOTIFICATIONS_INTERFACE)
            .unwrap()
            .build(&payload)
            .unwrap()
    }

    #[test]
    fn feed_is_bounded_with_drop_oldest() {
        let store = NotificationStore::new();
        for index in 0..(MAX_NOTIFICATIONS + 5) {
            store.observe(observation(&format!("app-{index}")), index as u64);
        }

        let feed = store.current().unwrap();
        assert_eq!(feed.notifications.len(), MAX_NOTIFICATIONS);
        // The oldest five entries were dropped.
        assert_eq!(feed.notifications[0].app_name, "app-5");
        assert_eq!(
            feed.notifications.last().unwrap().app_name,
            format!("app-{}", MAX_NOTIFICATIONS + 4)
        );
        feed.validate().unwrap();
    }

    #[test]
    fn handles_are_feed_issued_and_unique() {
        let store = NotificationStore::new();
        store.observe(observation("a"), 1);
        store.observe(observation("b"), 2);

        let feed = store.current().unwrap();
        assert_eq!(feed.notifications[0].handle, "notification:1");
        assert_eq!(feed.notifications[1].handle, "notification:2");
        assert_ne!(feed.notifications[0].handle, feed.notifications[1].handle);
    }

    #[test]
    fn observation_strings_are_bounded() {
        let store = NotificationStore::new();
        let mut observation = observation("app");
        observation.summary = "s".repeat(MAX_STRING_BYTES + 100);
        store.observe(observation, 1);

        let feed = store.current().unwrap();
        assert_eq!(feed.notifications[0].summary.len(), MAX_STRING_BYTES);
        feed.validate().unwrap();
    }

    #[test]
    fn empty_feed_has_no_current() {
        let store = NotificationStore::new();
        assert!(store.current().is_none());
    }

    #[test]
    fn availability_transitions() {
        let store = NotificationStore::new();
        assert_eq!(store.availability(), NotificationAvailability::Unavailable);

        store.set_availability(NotificationAvailability::Available);
        assert_eq!(store.availability(), NotificationAvailability::Available);

        store.set_availability(NotificationAvailability::Restricted);
        assert_eq!(store.availability(), NotificationAvailability::Restricted);
    }

    #[test]
    fn parses_a_valid_notify_method_call() {
        let message = notify_message("App", "Summary", "Body", Some(2));
        let observation = parse_notify(&message).unwrap().unwrap();
        assert_eq!(observation.app_name, "App");
        assert_eq!(observation.summary, "Summary");
        assert_eq!(observation.body, "Body");
        assert_eq!(observation.urgency, NotificationUrgency::Critical);
    }

    #[test]
    fn missing_urgency_defaults_to_normal() {
        let message = notify_message("App", "Summary", "Body", None);
        let observation = parse_notify(&message).unwrap().unwrap();
        assert_eq!(observation.urgency, NotificationUrgency::Normal);
    }

    #[test]
    fn urgency_boundaries_map_to_typed_levels() {
        for (byte, expected) in [
            (0, NotificationUrgency::Low),
            (1, NotificationUrgency::Normal),
            (2, NotificationUrgency::Critical),
        ] {
            let message = notify_message("App", "Summary", "Body", Some(byte));
            assert_eq!(parse_notify(&message).unwrap().unwrap().urgency, expected);
        }
    }

    #[test]
    fn ignores_non_notify_members_and_signals() {
        let method_call = Message::method_call("/org/freedesktop/Notifications", "GetCapabilities")
            .unwrap()
            .interface(NOTIFICATIONS_INTERFACE)
            .unwrap()
            .build(&())
            .unwrap();
        assert!(parse_notify(&method_call).unwrap().is_none());

        let signal = Message::signal(
            "/org/freedesktop/Notifications",
            NOTIFICATIONS_INTERFACE,
            "NotificationClosed",
        )
        .unwrap()
        .build(&(0u32, 1u32))
        .unwrap();
        assert!(parse_notify(&signal).unwrap().is_none());
    }

    #[test]
    fn malformed_body_fails_closed() {
        let message = Message::method_call("/org/freedesktop/Notifications", NOTIFY_MEMBER)
            .unwrap()
            .interface(NOTIFICATIONS_INTERFACE)
            .unwrap()
            .build(&(1u32, "wrong shape"))
            .unwrap();
        assert!(matches!(
            parse_notify(&message),
            Err(NotifyParseError::MalformedBody(_))
        ));
    }

    #[test]
    fn malformed_urgency_fails_closed() {
        let mut hints = HashMap::<String, OwnedValue>::new();
        hints.insert(
            "urgency".to_owned(),
            zbus::zvariant::Value::from("high").try_into().unwrap(),
        );
        let payload = (
            "App".to_owned(),
            0u32,
            String::new(),
            "Summary".to_owned(),
            "Body".to_owned(),
            Vec::<String>::new(),
            hints,
            -1i32,
        );
        let message = Message::method_call("/org/freedesktop/Notifications", NOTIFY_MEMBER)
            .unwrap()
            .interface(NOTIFICATIONS_INTERFACE)
            .unwrap()
            .build(&payload)
            .unwrap();
        assert_eq!(
            parse_notify(&message).unwrap_err().to_string(),
            NotifyParseError::MalformedUrgency.to_string()
        );
    }

    #[tokio::test]
    async fn unreachable_bus_is_a_typed_unavailable() {
        let error = establish_monitor(Some(OsStr::new(
            "unix:path=/nonexistent/velora-test-notifications-bus",
        )))
        .await
        .unwrap_err();
        assert_eq!(
            monitor_error_availability(&error),
            NotificationAvailability::Unavailable
        );
    }

    #[tokio::test]
    async fn non_utf8_address_is_a_typed_unavailable() {
        let address = OsStr::from_bytes(&[0xff, 0xfe, 0xfd]);
        let error = establish_monitor(Some(address)).await.unwrap_err();
        assert!(matches!(error, MonitorError::InvalidAddress));
        assert_eq!(
            monitor_error_availability(&error),
            NotificationAvailability::Unavailable
        );
    }

    #[tokio::test]
    async fn denied_monitoring_classifies_as_restricted() {
        assert_eq!(
            monitor_error_availability(&MonitorError::AccessDenied),
            NotificationAvailability::Restricted
        );
    }

    #[tokio::test]
    async fn hung_bus_socket_times_out() {
        use std::os::unix::net::UnixListener as StdUnixListener;

        let directory = tempfile::tempdir().unwrap();
        let socket_path = directory.path().join("hung-notifications-bus");
        let listener = StdUnixListener::bind(&socket_path).unwrap();

        let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();
        let server = std::thread::spawn(move || {
            let (_stream, _address) = listener.accept().unwrap();
            let _ = stop_rx.recv();
        });

        let address = format!("unix:path={}", socket_path.display());
        let result =
            establish_monitor_with_timeout(Some(OsStr::new(&address)), Duration::from_millis(100))
                .await;

        let _ = stop_tx.send(());
        server.join().unwrap();

        assert!(matches!(result, Err(MonitorError::TimedOut)));
    }

    #[test]
    fn strings_are_trimmed_and_byte_bounded() {
        assert_eq!(bounded_string("  padded  ", 8), "padded");
        assert_eq!(bounded_string("short", 100), "short");

        let multibyte = "🦀".repeat(MAX_STRING_BYTES);
        let bounded = bounded_string(&multibyte, MAX_STRING_BYTES);
        assert!(bounded.len() <= MAX_STRING_BYTES);
        assert!(std::str::from_utf8(bounded.as_bytes()).is_ok());
    }
}
