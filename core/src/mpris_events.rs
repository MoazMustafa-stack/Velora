//! MPRIS player discovery and signal listener.
//!
//! Velora observes `org.mpris.MediaPlayer2.*` players strictly through the
//! user session bus, never taking over a bus name and never opening a
//! full-bus monitor. This module is the discovery/observation half of the
//! MPRIS adapter: it subscribes to two signal families and reduces every
//! observation to a single "state is stale" mark on a capacity-1 dirty slot.
//! It never reads or builds player state itself — that is the media store's
//! job (P5.05), which consumes the dirty slot and re-reads authority with
//! `Properties.GetAll`.
//!
//! Two signal families are watched, both narrowed broker-side so unrelated
//! desktop traffic never reaches Core:
//!
//! * `NameOwnerChanged` (from `org.freedesktop.DBus`, arg0 namespace
//!   `org.mpris.MediaPlayer2`) detects players appearing, disappearing, and
//!   changing owners.
//! * `PropertiesChanged` (from `org.freedesktop.DBus.Properties`, path
//!   namespace `/org/mpris`, arg0 namespace `org.mpris.MediaPlayer2`) is a
//!   per-player invalidation hint.
//!
//! Signals are hints, never truth: the listener only marks the slot dirty,
//! and bursts coalesce into the single slot. Every disconnect re-marks the
//! slot because signals may have been missed while disconnected. Reconnection
//! is paced with bounded exponential backoff plus jitter so a flapping bus can
//! never produce a busy loop, and a missing bus is never fatal.

use std::{
    collections::HashMap,
    ffi::OsStr,
    future::poll_fn,
    pin::Pin,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use futures_core::Stream;
use thiserror::Error;
use tokio::{
    sync::{mpsc, watch},
    time::{sleep, timeout},
};
use tracing::{debug, warn};
use zbus::{Connection, MatchRule, Message, MessageStream, message::Type, zvariant::OwnedValue};

/// The bus-driver interface and well-known name that emits `NameOwnerChanged`.
const DBUS_INTERFACE: &str = "org.freedesktop.DBus";
const DBUS_NAME: &str = "org.freedesktop.DBus";
const NAME_OWNER_CHANGED_MEMBER: &str = "NameOwnerChanged";

/// The standard D-Bus properties interface that emits `PropertiesChanged`.
const PROPERTIES_INTERFACE: &str = "org.freedesktop.DBus.Properties";
const PROPERTIES_CHANGED_MEMBER: &str = "PropertiesChanged";

/// Namespace of every MPRIS player well-known name (`org.mpris.MediaPlayer2.*`).
const MPRIS_NAME_PREFIX: &str = "org.mpris.MediaPlayer2.";
/// Namespace of every MPRIS interface (`org.mpris.MediaPlayer2` and `.Player`).
const MPRIS_INTERFACE_NAMESPACE: &str = "org.mpris.MediaPlayer2";
/// Path namespace under which every MPRIS player publishes its object.
const MPRIS_PATH_NAMESPACE: &str = "/org/mpris";

/// Maximum length of a bus or interface name accepted before it is ignored.
const MAX_NAME_CHARS: usize = 256;

/// Bounded message queue per signal stream. A burst beyond this coalesces
/// inside zbus before it ever reaches the listener.
const MAX_QUEUED_SIGNALS: usize = 1;

/// Maximum wall-clock time allowed to connect. A present but hung session-bus
/// socket must never keep the listener task stuck forever.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// A recognized MPRIS invalidation hint. Both variants are hints only: they
/// mark the shared dirty slot and never carry player state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MprisSignal {
    /// A player appeared, disappeared, or changed owners.
    PlayerChurn,
    /// A player reported changed properties.
    PlayerProperties,
}

/// Reconnect pacing. Production uses the default; tests shrink the delays.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ListenerConfig {
    pub initial_backoff: Duration,
    pub max_backoff: Duration,
}

impl ListenerConfig {
    pub(crate) fn production() -> Self {
        Self {
            initial_backoff: Duration::from_millis(500),
            max_backoff: Duration::from_secs(8),
        }
    }
}

/// Typed failure of the MPRIS listener. A missing bus, a denied read, or a
/// malformed signal never panics and never marks the slot spuriously.
#[derive(Debug, Error)]
pub(crate) enum ListenerError {
    #[error("session bus address override is not valid UTF-8")]
    InvalidAddress,
    #[error("failed to connect to the session bus: {0}")]
    Connect(#[source] zbus::Error),
    #[error("MPRIS signal subscription failed: {0}")]
    Subscribe(#[source] zbus::Error),
    #[error("MPRIS listener connection timed out")]
    TimedOut,
}

/// Long-running listener loop. Connects, subscribes, and marks the dirty slot
/// on every relevant signal until the streams close or shutdown is requested,
/// then reconnects with bounded exponential backoff plus jitter.
pub(crate) async fn run_listener(
    address: Option<&OsStr>,
    invalidation_tx: mpsc::Sender<()>,
    mut shutdown: watch::Receiver<bool>,
    config: ListenerConfig,
) {
    let mut backoff = config.initial_backoff;
    loop {
        if *shutdown.borrow_and_update() {
            return;
        }

        match connect_with_timeout(address).await {
            Ok(connection) => {
                debug!("MPRIS listener connected to the session bus");
                backoff = config.initial_backoff;
                match subscribe(&connection).await {
                    Ok((name_stream, props_stream)) => {
                        run_streams(name_stream, props_stream, &invalidation_tx, &mut shutdown)
                            .await;
                        // A disconnect may have dropped signals, so mark dirty
                        // before reconnecting.
                        invalidate(&invalidation_tx);
                    }
                    Err(error) => warn!(%error, "MPRIS signal subscription failed"),
                }
            }
            Err(error) => warn!(%error, "MPRIS session bus unavailable"),
        }

        let delay = reconnect_delay(backoff);
        tokio::select! {
            _ = shutdown.changed() => return,
            _ = sleep(delay) => {}
        }
        backoff = next_backoff(backoff, config.max_backoff);
    }
}

async fn connect_with_timeout(address: Option<&OsStr>) -> Result<Connection, ListenerError> {
    match timeout(CONNECT_TIMEOUT, connect(address)).await {
        Ok(result) => result,
        Err(_) => Err(ListenerError::TimedOut),
    }
}

async fn connect(address: Option<&OsStr>) -> Result<Connection, ListenerError> {
    match address {
        Some(address) => {
            let address = address.to_str().ok_or(ListenerError::InvalidAddress)?;
            zbus::connection::Builder::address(address)
                .map_err(ListenerError::Connect)?
                .build()
                .await
                .map_err(ListenerError::Connect)
        }
        None => Connection::session().await.map_err(ListenerError::Connect),
    }
}

/// Subscribe to both signal families with bounded queues. Each returned stream
/// registers its match rule with the bus and deregisters it on drop.
async fn subscribe(
    connection: &Connection,
) -> Result<(MessageStream, MessageStream), ListenerError> {
    let name_stream = MessageStream::for_match_rule(
        name_owner_changed_rule(),
        connection,
        Some(MAX_QUEUED_SIGNALS),
    )
    .await
    .map_err(ListenerError::Subscribe)?;
    let props_stream = MessageStream::for_match_rule(
        properties_changed_rule(),
        connection,
        Some(MAX_QUEUED_SIGNALS),
    )
    .await
    .map_err(ListenerError::Subscribe)?;
    Ok((name_stream, props_stream))
}

async fn run_streams(
    mut name_stream: MessageStream,
    mut props_stream: MessageStream,
    invalidation_tx: &mpsc::Sender<()>,
    shutdown: &mut watch::Receiver<bool>,
) {
    loop {
        tokio::select! {
            _ = shutdown.changed() => return,
            message = next_message(&mut name_stream) => match message {
                Some(Ok(message)) => {
                    if parse_name_owner_changed(&message).is_some() {
                        invalidate(invalidation_tx);
                    }
                }
                Some(Err(error)) => {
                    warn!(%error, "MPRIS name-owner stream failed");
                    return;
                }
                None => {
                    debug!("MPRIS name-owner stream closed");
                    return;
                }
            },
            message = next_message(&mut props_stream) => match message {
                Some(Ok(message)) => {
                    if parse_properties_changed(&message).is_some() {
                        invalidate(invalidation_tx);
                    }
                }
                Some(Err(error)) => {
                    warn!(%error, "MPRIS properties stream failed");
                    return;
                }
                None => {
                    debug!("MPRIS properties stream closed");
                    return;
                }
            },
        }
    }
}

/// Poll the next message from a stream. `MessageStream` implements
/// `futures_core::Stream`, so this avoids pulling in `futures-util`.
async fn next_message(stream: &mut MessageStream) -> Option<zbus::Result<Message>> {
    poll_fn(|cx| Pin::new(&mut *stream).poll_next(cx)).await
}

fn invalidate(invalidation_tx: &mpsc::Sender<()>) {
    // Full means the slot is already marked dirty; Closed means the consumer
    // stopped. Both are safe to ignore.
    let _ = invalidation_tx.try_send(());
}

/// The match rule for `NameOwnerChanged`, narrowed broker-side to the
/// bus-driver sender and the MPRIS well-known-name namespace.
fn name_owner_changed_rule() -> MatchRule<'static> {
    MatchRule::builder()
        .msg_type(Type::Signal)
        .sender(DBUS_NAME)
        .expect("org.freedesktop.DBus is a valid well-known name")
        .interface(DBUS_INTERFACE)
        .expect("org.freedesktop.DBus is a valid interface name")
        .member(NAME_OWNER_CHANGED_MEMBER)
        .expect("NameOwnerChanged is a valid member name")
        .arg0ns(MPRIS_INTERFACE_NAMESPACE)
        .expect("org.mpris.MediaPlayer2 is a valid bus-name namespace")
        .build()
}

/// The match rule for `PropertiesChanged`, narrowed broker-side to the MPRIS
/// object-path namespace and interface namespace.
fn properties_changed_rule() -> MatchRule<'static> {
    MatchRule::builder()
        .msg_type(Type::Signal)
        .interface(PROPERTIES_INTERFACE)
        .expect("org.freedesktop.DBus.Properties is a valid interface name")
        .member(PROPERTIES_CHANGED_MEMBER)
        .expect("PropertiesChanged is a valid member name")
        .path_namespace(MPRIS_PATH_NAMESPACE)
        .expect("/org/mpris is a valid object-path namespace")
        .arg0ns(MPRIS_INTERFACE_NAMESPACE)
        .expect("org.mpris.MediaPlayer2 is a valid bus-name namespace")
        .build()
}

/// Recognize an MPRIS `NameOwnerChanged` signal. `None` means the message is
/// unrelated or malformed and carries no invalidation.
fn parse_name_owner_changed(message: &Message) -> Option<MprisSignal> {
    if message.message_type() != Type::Signal {
        return None;
    }
    if message
        .header()
        .member()
        .is_none_or(|member| member.as_str() != NAME_OWNER_CHANGED_MEMBER)
    {
        return None;
    }
    if message
        .header()
        .interface()
        .is_none_or(|interface| interface.as_str() != DBUS_INTERFACE)
    {
        return None;
    }

    let (name, _old_owner, _new_owner): (String, String, String) =
        message.body().deserialize().ok()?;
    if !is_mpris_player_name(&name) {
        return None;
    }
    Some(MprisSignal::PlayerChurn)
}

/// Recognize an MPRIS `PropertiesChanged` signal. `None` means the message is
/// unrelated or malformed and carries no invalidation.
fn parse_properties_changed(message: &Message) -> Option<MprisSignal> {
    if message.message_type() != Type::Signal {
        return None;
    }
    if message
        .header()
        .member()
        .is_none_or(|member| member.as_str() != PROPERTIES_CHANGED_MEMBER)
    {
        return None;
    }
    if message
        .header()
        .interface()
        .is_none_or(|interface| interface.as_str() != PROPERTIES_INTERFACE)
    {
        return None;
    }

    let (interface, _changed, _invalidated): (String, HashMap<String, OwnedValue>, Vec<String>) =
        message.body().deserialize().ok()?;
    if !is_mpris_interface(&interface) {
        return None;
    }
    Some(MprisSignal::PlayerProperties)
}

fn is_mpris_player_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= MAX_NAME_CHARS && name.starts_with(MPRIS_NAME_PREFIX)
}

fn is_mpris_interface(interface: &str) -> bool {
    !interface.is_empty()
        && interface.len() <= MAX_NAME_CHARS
        && (interface == MPRIS_INTERFACE_NAMESPACE || interface.starts_with(MPRIS_NAME_PREFIX))
}

/// The sleep before the next reconnect attempt: half the current backoff plus
/// a jittered second half, so the delay lands in `[backoff/2, backoff]` and is
/// never zero (no busy loop).
fn reconnect_delay(backoff: Duration) -> Duration {
    let half = backoff.div_f64(2.0);
    half + jitter(half)
}

/// Grow the backoff exponentially, capped at `max`. A value that has already
/// reached the cap (or would overflow) stays at the cap.
fn next_backoff(backoff: Duration, max: Duration) -> Duration {
    backoff
        .checked_mul(2)
        .map(|doubled| doubled.min(max))
        .unwrap_or(max)
}

/// Jitter in `[0, half]` derived from the wall clock's sub-second nanos. Never
/// negative and never above `half`, so the combined delay stays within bounds.
fn jitter(half: Duration) -> Duration {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since| since.subsec_nanos())
        .unwrap_or(0) as u64;
    let spread = half.as_millis() as u64;
    Duration::from_millis(nanos % (spread + 1))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;

    const TEST_PLAYER_NAME: &str = "org.mpris.MediaPlayer2.testplayer";

    fn name_owner_changed_message(name: &str) -> Message {
        Message::signal(
            "/org/freedesktop/DBus",
            DBUS_INTERFACE,
            NAME_OWNER_CHANGED_MEMBER,
        )
        .unwrap()
        .build(&(name.to_owned(), String::new(), String::from(":1.42")))
        .unwrap()
    }

    fn properties_changed_message(interface: &str) -> Message {
        Message::signal(
            "/org/mpris/MediaPlayer2",
            PROPERTIES_INTERFACE,
            PROPERTIES_CHANGED_MEMBER,
        )
        .unwrap()
        .build(&(
            interface.to_owned(),
            HashMap::<String, OwnedValue>::new(),
            Vec::<String>::new(),
        ))
        .unwrap()
    }

    fn fast_config() -> ListenerConfig {
        ListenerConfig {
            initial_backoff: Duration::from_millis(5),
            max_backoff: Duration::from_millis(40),
        }
    }

    #[test]
    fn recognizes_mpris_name_owner_changes() {
        assert_eq!(
            parse_name_owner_changed(&name_owner_changed_message(TEST_PLAYER_NAME)),
            Some(MprisSignal::PlayerChurn)
        );
    }

    #[test]
    fn ignores_non_mpris_and_malformed_name_owner_changes() {
        assert_eq!(
            parse_name_owner_changed(&name_owner_changed_message("org.freedesktop.Notifications")),
            None
        );
        assert_eq!(
            parse_name_owner_changed(&name_owner_changed_message("")),
            None
        );

        let long = format!("org.mpris.MediaPlayer2.{}", "x".repeat(MAX_NAME_CHARS));
        assert_eq!(
            parse_name_owner_changed(&name_owner_changed_message(&long)),
            None
        );

        // Wrong member and wrong message type are ignored.
        let method_call = Message::method_call("/org/freedesktop/DBus", "ListNames")
            .unwrap()
            .interface(DBUS_INTERFACE)
            .unwrap()
            .build(&())
            .unwrap();
        assert_eq!(parse_name_owner_changed(&method_call), None);
    }

    #[test]
    fn recognizes_mpris_properties_changes_for_both_interfaces() {
        assert_eq!(
            parse_properties_changed(&properties_changed_message("org.mpris.MediaPlayer2.Player")),
            Some(MprisSignal::PlayerProperties)
        );
        assert_eq!(
            parse_properties_changed(&properties_changed_message("org.mpris.MediaPlayer2")),
            Some(MprisSignal::PlayerProperties)
        );
    }

    #[test]
    fn ignores_non_mpris_and_malformed_properties_changes() {
        assert_eq!(
            parse_properties_changed(&properties_changed_message("org.freedesktop.Notifications")),
            None
        );
        assert_eq!(
            parse_properties_changed(&properties_changed_message(
                "org.mpris.MediaPlayer2NotAPlayer"
            )),
            None
        );

        // A mistyped body fails closed rather than guessing.
        let malformed = Message::signal(
            "/org/mpris/MediaPlayer2",
            PROPERTIES_INTERFACE,
            PROPERTIES_CHANGED_MEMBER,
        )
        .unwrap()
        .build(&(42_u32, "not-a-dictionary"))
        .unwrap();
        assert_eq!(parse_properties_changed(&malformed), None);
    }

    #[test]
    fn match_rules_narrow_broker_side() {
        let name_rule = name_owner_changed_rule().to_string();
        assert!(name_rule.contains("type='signal'"));
        assert!(name_rule.contains("sender='org.freedesktop.DBus'"));
        assert!(name_rule.contains("member='NameOwnerChanged'"));
        assert!(name_rule.contains("arg0namespace='org.mpris.MediaPlayer2'"));

        let props_rule = properties_changed_rule().to_string();
        assert!(props_rule.contains("type='signal'"));
        assert!(props_rule.contains("interface='org.freedesktop.DBus.Properties'"));
        assert!(props_rule.contains("member='PropertiesChanged'"));
        assert!(props_rule.contains("path_namespace='/org/mpris'"));
        assert!(props_rule.contains("arg0namespace='org.mpris.MediaPlayer2'"));
    }

    #[test]
    fn backoff_grows_exponentially_and_is_bounded() {
        let max = Duration::from_millis(8);
        let mut backoff = Duration::from_millis(1);
        for _ in 0..10 {
            let next = next_backoff(backoff, max);
            assert!(next >= backoff);
            assert!(next <= max);
            backoff = next;
        }
        assert_eq!(backoff, max);
    }

    #[test]
    fn reconnect_delay_stays_within_bounds_and_is_never_zero() {
        for backoff in [
            Duration::from_millis(5),
            Duration::from_millis(40),
            Duration::from_secs(8),
        ] {
            let delay = reconnect_delay(backoff);
            assert!(delay >= backoff.div_f64(2.0));
            assert!(delay <= backoff);
            assert!(delay > Duration::ZERO);
        }
    }

    #[test]
    fn invalidations_coalesce_into_a_single_slot() {
        let (tx, mut rx) = mpsc::channel(1);
        for _ in 0..500 {
            invalidate(&tx);
        }
        // The capacity-1 slot collapses the burst into exactly one dirty mark.
        let mut received = 0;
        while rx.try_recv().is_ok() {
            received += 1;
        }
        assert_eq!(received, 1, "burst must coalesce into a single slot");
    }

    mod listener {
        use super::*;
        use std::io::{BufRead, BufReader};
        use std::process::{Child, Command, Stdio};

        /// A private `dbus-daemon` on a temporary address. Never the live
        /// session bus. The child is killed and reaped on drop.
        struct PrivateBus {
            address: String,
            child: Child,
        }

        impl PrivateBus {
            /// Spawn a foreground `dbus-daemon` and wait until it prints its
            /// address (which also means the socket is bound and listening).
            fn spawn() -> Option<Self> {
                let mut child = Command::new("dbus-daemon")
                    .args(["--session", "--nofork", "--print-address=1"])
                    .stdout(Stdio::piped())
                    .stderr(Stdio::null())
                    .spawn()
                    .ok()?;

                let stdout = child.stdout.take()?;
                let mut reader = BufReader::new(stdout);
                let mut address = String::new();
                reader.read_line(&mut address).ok()?;
                let address = address.trim().to_owned();
                if address.is_empty() {
                    return None;
                }
                Some(PrivateBus { address, child })
            }

            async fn connect(&self) -> Connection {
                zbus::connection::Builder::address(self.address.as_str())
                    .unwrap()
                    .build()
                    .await
                    .unwrap()
            }
        }

        impl Drop for PrivateBus {
            fn drop(&mut self) {
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }

        fn spawn_listener(
            address: &str,
        ) -> (
            mpsc::Receiver<()>,
            watch::Sender<bool>,
            tokio::task::JoinHandle<()>,
        ) {
            let address = std::ffi::OsString::from(address);
            let (tx, rx) = mpsc::channel(1);
            let (shutdown_tx, shutdown_rx) = watch::channel(false);
            let handle = tokio::spawn(async move {
                run_listener(Some(&address), tx, shutdown_rx, fast_config()).await;
            });
            (rx, shutdown_tx, handle)
        }

        async fn recv_invalidation(rx: &mut mpsc::Receiver<()>, budget: Duration) -> bool {
            matches!(timeout(budget, rx.recv()).await, Ok(Some(())))
        }

        /// Acquire/release the test name until the listener reports an
        /// invalidation, proving it has connected and subscribed. Drains the
        /// slot so the caller starts from a clean, quiet channel.
        async fn wait_until_live(player: &Connection, rx: &mut mpsc::Receiver<()>) {
            for _ in 0..200 {
                let _ = player.request_name(TEST_PLAYER_NAME).await;
                let _ = player.release_name(TEST_PLAYER_NAME).await;
                if recv_invalidation(rx, Duration::from_millis(30)).await {
                    while rx.try_recv().is_ok() {}
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            panic!("MPRIS listener never became live");
        }

        #[tokio::test]
        async fn name_owner_appearance_and_disappearance_invalidate() {
            let Some(bus) = PrivateBus::spawn() else {
                eprintln!("dbus-daemon unavailable; skipping");
                return;
            };
            let (mut rx, shutdown, handle) = spawn_listener(&bus.address);
            let player = bus.connect().await;
            wait_until_live(&player, &mut rx).await;

            player.request_name(TEST_PLAYER_NAME).await.unwrap();
            assert!(
                recv_invalidation(&mut rx, Duration::from_secs(2)).await,
                "player appearance must invalidate"
            );

            player.release_name(TEST_PLAYER_NAME).await.unwrap();
            assert!(
                recv_invalidation(&mut rx, Duration::from_secs(2)).await,
                "player disappearance must invalidate"
            );

            let _ = shutdown.send(true);
            handle.abort();
        }

        #[tokio::test]
        async fn properties_changes_invalidate() {
            let Some(bus) = PrivateBus::spawn() else {
                eprintln!("dbus-daemon unavailable; skipping");
                return;
            };
            let (mut rx, shutdown, handle) = spawn_listener(&bus.address);
            let player = bus.connect().await;
            player.request_name(TEST_PLAYER_NAME).await.unwrap();
            wait_until_live(&player, &mut rx).await;

            player
                .emit_signal(
                    None::<&str>,
                    "/org/mpris/MediaPlayer2",
                    PROPERTIES_INTERFACE,
                    PROPERTIES_CHANGED_MEMBER,
                    &(
                        "org.mpris.MediaPlayer2.Player".to_owned(),
                        HashMap::<String, OwnedValue>::new(),
                        Vec::<String>::new(),
                    ),
                )
                .await
                .unwrap();

            assert!(
                recv_invalidation(&mut rx, Duration::from_secs(2)).await,
                "PropertiesChanged must invalidate"
            );

            let _ = shutdown.send(true);
            handle.abort();
        }

        #[tokio::test]
        async fn player_churn_is_harmless() {
            let Some(bus) = PrivateBus::spawn() else {
                eprintln!("dbus-daemon unavailable; skipping");
                return;
            };
            let (mut rx, shutdown, handle) = spawn_listener(&bus.address);
            let player = bus.connect().await;
            wait_until_live(&player, &mut rx).await;

            // Rapid acquisition/release cycles must not wedge the listener.
            for _ in 0..50 {
                let _ = player.request_name(TEST_PLAYER_NAME).await;
                let _ = player.release_name(TEST_PLAYER_NAME).await;
            }
            while rx.try_recv().is_ok() {}

            // The listener still observes a subsequent change.
            let _ = player.request_name(TEST_PLAYER_NAME).await;
            while rx.try_recv().is_ok() {}
            player
                .emit_signal(
                    None::<&str>,
                    "/org/mpris/MediaPlayer2",
                    PROPERTIES_INTERFACE,
                    PROPERTIES_CHANGED_MEMBER,
                    &(
                        "org.mpris.MediaPlayer2.Player".to_owned(),
                        HashMap::<String, OwnedValue>::new(),
                        Vec::<String>::new(),
                    ),
                )
                .await
                .unwrap();

            assert!(
                recv_invalidation(&mut rx, Duration::from_secs(2)).await,
                "listener must survive player churn"
            );

            let _ = shutdown.send(true);
            handle.abort();
        }

        #[tokio::test]
        async fn unreachable_bus_still_yields_to_shutdown() {
            let (tx, _rx) = mpsc::channel(1);
            let (shutdown_tx, shutdown_rx) = watch::channel(false);
            let handle = tokio::spawn(run_listener(
                Some(OsStr::new("unix:path=/nonexistent/velora-mpris-test-bus")),
                tx,
                shutdown_rx,
                fast_config(),
            ));

            // The listener should be in its backoff sleep and respond to
            // shutdown promptly instead of spinning in a busy loop.
            let _ = shutdown_tx.send(true);
            timeout(Duration::from_secs(2), handle)
                .await
                .unwrap()
                .unwrap();
        }

        #[tokio::test]
        async fn non_utf8_address_is_a_typed_unavailable() {
            let address = OsStr::from_bytes(&[0xff, 0xfe, 0xfd]);
            assert!(matches!(
                connect(Some(address)).await.unwrap_err(),
                ListenerError::InvalidAddress
            ));
        }
    }
}
