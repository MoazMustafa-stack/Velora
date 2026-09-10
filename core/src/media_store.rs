//! Authoritative media snapshot store.
//!
//! The MPRIS listener (P5.04) only marks state dirty; this store is the single
//! place that rebuilds the authoritative [`MediaSnapshot`] by re-reading every
//! player with `Properties.GetAll` (`mpris::read_player`). It keeps exactly one
//! snapshot — no history, no unbounded collection — and publishes it only when
//! its content actually changed, so a player whose state is unchanged (same
//! metadata, status, flags, and playback position) never churns the frontend.
//!
//! Failures retain the last-good snapshot and record explicit health
//! (successful/failed refresh counts plus the most recent error) exactly like
//! the Hyprland session store. A full disconnect is handled cleanly: the next
//! successful refresh lists whatever players remain, so a vanished player is
//! dropped and an empty bus publishes an empty snapshot rather than stale
//! players lingering forever.
//!
//! Live serving is on-demand: the IPC handler reads the cached snapshot and,
//! when none exists yet, triggers one refresh. Signal-driven refreshes are
//! coalesced by the capacity-1 invalidation channel and retried with capped
//! backoff, mirroring `session_store`.
//!
//! Every refresh is bounded by [`REFRESH_TIMEOUT`] (connect, discovery, and
//! per-player reads together), so a hung bus or wedged player can never hold
//! the refresh lock forever and block shutdown or the on-demand IPC path. Every
//! published snapshot is also bounded to [`MAX_MEDIA_PAYLOAD_BYTES`] by
//! truncating metadata and the human-readable identity (longest first); an
//! unfittable candidate is rejected rather than ever emitting an oversized
//! snapshot.

use std::{
    env,
    ffi::OsStr,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use thiserror::Error;
use tokio::sync::{mpsc, watch};
use tracing::{debug, info, warn};
use velora_protocol::{
    MAX_MEDIA_PAYLOAD_BYTES, MAX_MEDIA_PLAYERS, MediaPlayer, MediaSnapshot, PlaybackStatus,
};
use zbus::Connection;

use crate::{dbus, mpris, mpris_events};

/// Session-bus address override used by tests, mirroring the `VELORA_SOCKET`
/// and `VELORA_SESSION_BUS_ADDRESS` rules in the D-Bus probe.
const SESSION_BUS_ADDRESS_ENV: &str = "VELORA_SESSION_BUS_ADDRESS";
/// Maximum wall-clock time allowed for one full refresh (connect, discovery,
/// and per-player reads). Bounds how long the refresh lock can be held, so a
/// hung bus or a wedged player can never block shutdown or the on-demand IPC
/// path indefinitely.
const REFRESH_TIMEOUT: Duration = Duration::from_secs(5);
/// Base and ceiling for the capped refresh-retry backoff, mirroring the
/// session store so a flapping bus never produces a busy loop.
const REFRESH_BACKOFF_BASE: Duration = Duration::from_millis(250);
const REFRESH_BACKOFF_MAX: Duration = Duration::from_secs(4);

/// Explicit store health, recorded on every refresh. Kept out of the wire
/// model: the snapshot stays pure state, and health is diagnostics-only.
#[derive(Debug, Default, Clone)]
pub(crate) struct StoreHealth {
    pub has_state: bool,
    pub successful_refreshes: u64,
    pub failed_refreshes: u64,
    pub last_success: Option<Instant>,
    pub last_error: Option<String>,
}

/// Typed failure of the media store. A missing bus, a denied read, or an
/// invalid snapshot never panics and never publishes partial state.
#[derive(Debug, Error)]
pub(crate) enum MediaStoreError {
    #[error("session bus address override is not valid UTF-8")]
    InvalidAddress,
    #[error("failed to connect to the session bus: {0}")]
    Connect(#[source] zbus::Error),
    #[error("failed to list MPRIS players: {0}")]
    ListPlayers(#[source] dbus::DbusError),
    #[error("built media snapshot failed validation: {0}")]
    InvalidSnapshot(#[source] velora_protocol::MediaSnapshotValidationError),
    #[error("media snapshot exceeds the {MAX_MEDIA_PAYLOAD_BYTES}-byte payload budget")]
    PayloadTooLarge,
    #[error("media snapshot refresh timed out")]
    TimedOut,
}

pub(crate) struct MediaStore {
    address: Option<std::ffi::OsString>,
    /// Serializes the entire read-and-apply refresh. The slow D-Bus reads
    /// (`connect`, `list_players`, `read_player`) happen outside the state
    /// mutex, so without this guard two concurrent refreshes (the signal loop
    /// and the on-demand IPC path) could interleave and apply out of order,
    /// regressing the published sequence.
    refresh_lock: tokio::sync::Mutex<()>,
    state: Mutex<MediaState>,
    /// Latest changed snapshot for IPC clients. `watch` deliberately coalesces
    /// intermediate changes: clients only need the newest authoritative state
    /// and the sequence fences stale data.
    updates: watch::Sender<Option<Arc<MediaSnapshot>>>,
}

#[derive(Default)]
struct MediaState {
    sequence: u64,
    snapshot: Option<Arc<MediaSnapshot>>,
    health: StoreHealth,
}

impl MediaStore {
    /// Build a store for a specific session-bus address. `None` falls back to
    /// the default session bus via zbus.
    pub(crate) fn new(address: Option<std::ffi::OsString>) -> Self {
        let (updates, _) = watch::channel(None);
        Self {
            address,
            refresh_lock: tokio::sync::Mutex::new(()),
            state: Mutex::new(MediaState::default()),
            updates,
        }
    }

    /// Production entry point: read the `VELORA_SESSION_BUS_ADDRESS` override.
    pub(crate) fn from_environment() -> Self {
        Self::new(env::var_os(SESSION_BUS_ADDRESS_ENV))
    }

    /// The cached authoritative snapshot, or `None` before the first refresh.
    pub(crate) fn current(&self) -> Option<Arc<MediaSnapshot>> {
        self.state.lock().unwrap().snapshot.clone()
    }

    /// Subscribe to changed snapshots for one IPC client. The receiver holds
    /// the most recent snapshot and coalesces bursts safely. The poll-based
    /// media client reads `current()` today; this surface is the changed-only
    /// publication boundary and is exercised by the store tests.
    #[allow(dead_code)]
    pub(crate) fn subscribe(&self) -> watch::Receiver<Option<Arc<MediaSnapshot>>> {
        self.updates.subscribe()
    }

    /// Diagnostics-only health record. Last-good state is independent of it.
    #[allow(dead_code)]
    pub(crate) fn health(&self) -> StoreHealth {
        self.state.lock().unwrap().health.clone()
    }

    /// One full refresh: connect, list players, re-read each, and replace the
    /// authoritative snapshot. Returns whether the published content changed.
    /// The whole read-and-apply cycle is serialized so concurrent refreshes
    /// cannot publish out of order, and bounded by [`REFRESH_TIMEOUT`] so a
    /// hung bus or wedged player can never block shutdown or the on-demand IPC
    /// path while holding the refresh lock. Failures record health and retain
    /// last-good state; an unreadable individual player is skipped (fail
    /// closed: omit rather than guess), so a vanished player is dropped cleanly.
    pub(crate) async fn refresh(&self) -> Result<bool, MediaStoreError> {
        self.refresh_with_timeout(REFRESH_TIMEOUT).await
    }

    /// Like [`MediaStore::refresh`] but with an explicit bound, so tests can
    /// shrink the budget instead of waiting out the production timeout.
    async fn refresh_with_timeout(&self, budget: Duration) -> Result<bool, MediaStoreError> {
        // Hold the refresh lock across the slow reads AND the apply, so the
        // signal loop and the on-demand IPC path can never interleave.
        let _guard = self.refresh_lock.lock().await;
        match tokio::time::timeout(budget, self.refresh_inner()).await {
            Ok(result) => result,
            Err(_) => {
                self.record_failure(&MediaStoreError::TimedOut.to_string());
                Err(MediaStoreError::TimedOut)
            }
        }
    }

    async fn refresh_inner(&self) -> Result<bool, MediaStoreError> {
        let connection = match connect(self.address.as_deref()).await {
            Ok(connection) => connection,
            Err(error) => {
                self.record_failure(&error.to_string());
                return Err(error);
            }
        };
        let result = self.read_and_apply(&connection).await;
        if let Err(error) = &result
            && matches!(error, MediaStoreError::ListPlayers(_))
        {
            // Discovery is connection-level; an unreadable player never
            // reaches here (it is skipped), and a validation failure records
            // its own health.
            self.record_failure(&error.to_string());
        }
        result
    }

    async fn read_and_apply(&self, connection: &Connection) -> Result<bool, MediaStoreError> {
        let mut names = dbus::list_players(connection)
            .await
            .map_err(MediaStoreError::ListPlayers)?;
        // Deterministic order: sorted names give a stable snapshot and a
        // stable focused-player choice across refreshes.
        names.sort();
        names.truncate(MAX_MEDIA_PLAYERS);

        let mut players = Vec::with_capacity(names.len());
        for name in &names {
            match mpris::read_player(connection, name).await {
                Ok(player) => players.push(player),
                Err(error) => debug!(%error, player = %name, "skipping unreadable MPRIS player"),
            }
        }
        self.apply(players)
    }

    /// Replace the authoritative snapshot from a freshly-read player list.
    /// Returns true only when the published content changed. Pure and
    /// side-effect free except for publication, so tests exercise it directly.
    pub(crate) fn apply(&self, mut players: Vec<MediaPlayer>) -> Result<bool, MediaStoreError> {
        // A stable sort key makes changed-only detection order-insensitive.
        players.sort_by(|left, right| left.handle.cmp(&right.handle));

        let mut state = self.state.lock().unwrap();
        let next_sequence = state.sequence + 1;
        let previous_focused = state
            .snapshot
            .as_ref()
            .and_then(|snapshot| snapshot.active_player_handle.as_deref());
        let active_player_handle = select_focused(&players, previous_focused);

        let fresh = MediaSnapshot {
            sequence: next_sequence,
            players,
            active_player_handle,
        };
        if let Err(error) = fresh.validate() {
            state.health.failed_refreshes += 1;
            state.health.last_error = Some(error.to_string());
            return Err(MediaStoreError::InvalidSnapshot(error));
        }

        // Enforce the 4 KiB Core payload budget before anything is published or
        // served. Metadata and the human-readable identity are truncated
        // (longest first) to fit; a snapshot that cannot fit even when fully
        // truncated fails closed and retains the last-good snapshot.
        let Some(fresh) = bound_payload(fresh) else {
            let error = MediaStoreError::PayloadTooLarge;
            state.health.failed_refreshes += 1;
            state.health.last_error = Some(error.to_string());
            return Err(error);
        };

        let changed = state
            .snapshot
            .as_ref()
            .is_none_or(|current| !content_eq(current, &fresh));
        if changed {
            state.sequence = next_sequence;
            let fresh = Arc::new(fresh);
            state.snapshot = Some(Arc::clone(&fresh));
            self.updates.send_replace(Some(fresh));
            debug!(sequence = next_sequence, "published new media snapshot");
        } else {
            debug!(sequence = next_sequence - 1, "media content unchanged");
        }
        state.health.has_state = true;
        state.health.successful_refreshes += 1;
        state.health.last_success = Some(Instant::now());
        state.health.last_error = None;
        Ok(changed)
    }

    /// Record a failed refresh while retaining the last-good snapshot.
    fn record_failure(&self, error: &str) {
        let mut state = self.state.lock().unwrap();
        state.health.failed_refreshes += 1;
        state.health.last_error = Some(error.to_owned());
    }

    /// Consume coalesced invalidation signals forever, refreshing on each and
    /// retrying with capped backoff so one dirty mark always converges even
    /// across outages. The read connection is re-established per refresh, so a
    /// dropped bus is replaced by whatever players are present next time.
    pub(crate) async fn run(
        self: Arc<Self>,
        mut invalidation_rx: mpsc::Receiver<()>,
        mut shutdown: watch::Receiver<bool>,
    ) {
        'signals: loop {
            tokio::select! {
                _ = shutdown.changed() => return,
                signal = invalidation_rx.recv() => {
                    if signal.is_none() {
                        return;
                    }
                    // Drain any signals that piled up behind this one.
                    while invalidation_rx.try_recv().is_ok() {}

                    let mut backoff = REFRESH_BACKOFF_BASE;
                    loop {
                        match self.refresh().await {
                            Ok(_) => continue 'signals,
                            Err(error) => {
                                warn!(%error, "media snapshot refresh failed");
                                tokio::select! {
                                    _ = shutdown.changed() => return,
                                    _ = tokio::time::sleep(backoff) => {}
                                }
                                backoff = (backoff * 2).min(REFRESH_BACKOFF_MAX);
                            }
                        }
                    }
                }
            }
        }
    }

    /// One initial refresh plus signal-driven refreshes until shutdown. Spawns
    /// the MPRIS discovery/signal listener (P5.04) against the same bus address
    /// and consumes its coalesced invalidation hints.
    pub(crate) async fn run_with_listener(
        self: Arc<Self>,
        shutdown: watch::Receiver<bool>,
        listener_config: mpris_events::ListenerConfig,
    ) {
        if let Err(error) = self.refresh().await {
            info!(%error, "initial media snapshot refresh failed");
        }

        let (invalidation_tx, invalidation_rx) = mpsc::channel(1);
        let address = self.address.clone();
        let listener_shutdown = shutdown.clone();
        let listener = tokio::spawn(async move {
            mpris_events::run_listener(
                address.as_deref(),
                invalidation_tx,
                listener_shutdown,
                listener_config,
            )
            .await;
        });

        self.run(invalidation_rx, shutdown).await;
        listener.abort();
    }
}

/// Choose the focused player deterministically. Preference order: a player
/// that is currently `Playing`; otherwise the previously focused player if it
/// is still present; otherwise the first player (already in a stable order).
fn select_focused(players: &[MediaPlayer], previous_focused: Option<&str>) -> Option<String> {
    if let Some(playing) = players
        .iter()
        .find(|player| player.status == PlaybackStatus::Playing)
    {
        return Some(playing.handle.clone());
    }
    if let Some(handle) = previous_focused
        && players.iter().any(|player| player.handle == handle)
    {
        return Some(handle.to_owned());
    }
    players.first().map(|player| player.handle.clone())
}
/// Two snapshots are equal only when every field that the wire model exposes is
/// identical. This intentionally includes [`MediaPlayer::position_micros`]:
/// playback position is authoritative state in the protocol snapshot, so a
/// position change (track advancing) is a meaningful publication, not noise.
fn content_eq(current: &MediaSnapshot, fresh: &MediaSnapshot) -> bool {
    current.players == fresh.players && current.active_player_handle == fresh.active_player_handle
}

/// A truncatable string field on a [`MediaPlayer`]. [`StringField::Identity`]
/// is a required (non-optional) but purely human-readable string, while
/// `Title`/`Artist`/`Album` are genuinely optional metadata; all four are safe
/// to shrink to fit the payload budget. Handles, status, and numeric/bool
/// fields are authoritative and never touched.
#[derive(Clone, Copy, PartialEq, Eq)]
enum StringField {
    Identity,
    Title,
    Artist,
    Album,
}

impl StringField {
    fn len(self, player: &MediaPlayer) -> usize {
        match self {
            StringField::Identity => player.identity.len(),
            StringField::Title => player.title.as_ref().map_or(0, String::len),
            StringField::Artist => player.artist.as_ref().map_or(0, String::len),
            StringField::Album => player.album.as_ref().map_or(0, String::len),
        }
    }

    fn shrink(self, player: &mut MediaPlayer) {
        let text: &mut String = match self {
            StringField::Identity => &mut player.identity,
            StringField::Title => player.title.as_mut().expect("non-empty metadata field"),
            StringField::Artist => player.artist.as_mut().expect("non-empty metadata field"),
            StringField::Album => player.album.as_mut().expect("non-empty metadata field"),
        };
        let half = text.len() / 2;
        let mut end = half;
        while end > 0 && !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
}

/// Bound a snapshot to [`MAX_MEDIA_PAYLOAD_BYTES`] by repeatedly halving the
/// longest truncatable string (optional metadata or the human-readable
/// identity) until it fits. Deterministic for identical input, so changed-only
/// detection stays stable. Returns `None` when even a fully-truncated snapshot
/// cannot fit — callers must fail closed rather than ever emit an oversized
/// snapshot.
fn bound_payload(mut snapshot: MediaSnapshot) -> Option<MediaSnapshot> {
    while encoded_len(&snapshot) > MAX_MEDIA_PAYLOAD_BYTES {
        let (index, field) = longest_optional_field(&snapshot)?;
        field.shrink(&mut snapshot.players[index]);
    }
    Some(snapshot)
}

fn longest_optional_field(snapshot: &MediaSnapshot) -> Option<(usize, StringField)> {
    let mut longest: Option<(usize, StringField, usize)> = None;
    for (index, player) in snapshot.players.iter().enumerate() {
        for field in [
            StringField::Identity,
            StringField::Title,
            StringField::Artist,
            StringField::Album,
        ] {
            let len = field.len(player);
            if len > 0 && longest.is_none_or(|(_, _, max)| len > max) {
                longest = Some((index, field, len));
            }
        }
    }
    longest.map(|(index, field, _)| (index, field))
}

fn encoded_len(snapshot: &MediaSnapshot) -> usize {
    serde_json::to_string(snapshot).map_or(usize::MAX, |encoded| encoded.len())
}

async fn connect(address: Option<&OsStr>) -> Result<Connection, MediaStoreError> {
    match address {
        Some(address) => {
            let address = address.to_str().ok_or(MediaStoreError::InvalidAddress)?;
            zbus::connection::Builder::address(address)
                .map_err(MediaStoreError::Connect)?
                .build()
                .await
                .map_err(MediaStoreError::Connect)
        }
        None => Connection::session()
            .await
            .map_err(MediaStoreError::Connect),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        collections::HashMap,
        io::{BufRead, BufReader},
        process::{Child, Command, Stdio},
        sync::atomic::{AtomicU64, Ordering},
    };
    use tokio::sync::mpsc;
    use velora_protocol::MAX_STRING_BYTES;
    use zbus::zvariant::{OwnedValue, Value};

    fn player(handle: &str, status: PlaybackStatus) -> MediaPlayer {
        MediaPlayer {
            handle: handle.to_owned(),
            identity: format!("Player {handle}"),
            status,
            title: None,
            artist: None,
            album: None,
            length_micros: None,
            position_micros: 0,
            can_play: true,
            can_pause: true,
            can_go_next: true,
            can_go_previous: true,
            can_seek: true,
            can_control: true,
        }
    }

    #[test]
    fn apply_populates_a_monotonic_snapshot() {
        let store = MediaStore::new(None);
        assert!(
            store
                .apply(vec![player("player:1", PlaybackStatus::Playing)])
                .unwrap()
        );
        let snapshot = store.current().unwrap();
        assert_eq!(snapshot.sequence, 1);
        assert_eq!(snapshot.players.len(), 1);
        assert_eq!(snapshot.active_player_handle.as_deref(), Some("player:1"));
        snapshot.validate().unwrap();
        assert!(store.health().has_state);
        assert_eq!(store.health().successful_refreshes, 1);
    }

    #[test]
    fn unchanged_content_keeps_the_published_sequence() {
        let store = MediaStore::new(None);
        assert!(
            store
                .apply(vec![player("player:1", PlaybackStatus::Playing)])
                .unwrap()
        );
        assert!(
            !store
                .apply(vec![player("player:1", PlaybackStatus::Playing)])
                .unwrap()
        );
        assert_eq!(store.current().unwrap().sequence, 1);
        assert_eq!(store.health().successful_refreshes, 2);
    }

    #[test]
    fn changed_content_bumps_the_sequence_and_publishes() {
        let store = MediaStore::new(None);
        let mut updates = store.subscribe();
        assert!(
            store
                .apply(vec![player("player:1", PlaybackStatus::Playing)])
                .unwrap()
        );
        assert!(updates.has_changed().unwrap());
        updates.borrow_and_update();

        assert!(
            store
                .apply(vec![player("player:1", PlaybackStatus::Paused)])
                .unwrap()
        );
        assert!(updates.has_changed().unwrap());

        assert_eq!(store.current().unwrap().sequence, 2);
        assert_eq!(
            store.current().unwrap().players[0].status,
            PlaybackStatus::Paused
        );
    }

    #[test]
    fn identical_content_is_not_republished() {
        let store = MediaStore::new(None);
        let mut updates = store.subscribe();
        assert!(
            store
                .apply(vec![player("player:1", PlaybackStatus::Playing)])
                .unwrap()
        );
        assert!(updates.has_changed().unwrap());
        updates.borrow_and_update();

        // Same content, different input order: still suppressed.
        assert!(
            !store
                .apply(vec![player("player:1", PlaybackStatus::Playing)])
                .unwrap()
        );
        assert!(!updates.has_changed().unwrap());
    }

    #[test]
    fn vanished_players_are_replaced_cleanly() {
        let store = MediaStore::new(None);
        store
            .apply(vec![
                player("player:1", PlaybackStatus::Playing),
                player("player:2", PlaybackStatus::Paused),
            ])
            .unwrap();
        assert_eq!(store.current().unwrap().players.len(), 2);

        // One player disconnects: the next refresh drops it.
        store
            .apply(vec![player("player:2", PlaybackStatus::Paused)])
            .unwrap();
        let snapshot = store.current().unwrap();
        assert_eq!(snapshot.players.len(), 1);
        assert_eq!(snapshot.players[0].handle, "player:2");

        // Everything disconnects: the snapshot becomes empty, not stale.
        store.apply(vec![]).unwrap();
        let snapshot = store.current().unwrap();
        assert!(snapshot.players.is_empty());
        assert_eq!(snapshot.active_player_handle, None);
        snapshot.validate().unwrap();
    }

    #[test]
    fn invalid_snapshot_retains_last_good_and_records_health() {
        let store = MediaStore::new(None);
        store
            .apply(vec![player("player:1", PlaybackStatus::Playing)])
            .unwrap();

        // Duplicate handles violate protocol validation and must fail closed.
        let error = store
            .apply(vec![
                player("player:dup", PlaybackStatus::Playing),
                player("player:dup", PlaybackStatus::Paused),
            ])
            .unwrap_err();
        assert!(matches!(error, MediaStoreError::InvalidSnapshot(_)));

        // Last good snapshot retained, failure recorded.
        assert_eq!(store.current().unwrap().sequence, 1);
        assert_eq!(store.health().failed_refreshes, 1);
        assert!(store.health().last_error.is_some());
    }

    #[test]
    fn record_failure_retains_last_good_state() {
        let store = MediaStore::new(None);
        store
            .apply(vec![player("player:1", PlaybackStatus::Playing)])
            .unwrap();

        store.record_failure("boom");
        assert_eq!(store.current().unwrap().sequence, 1);
        assert_eq!(store.health().failed_refreshes, 1);
        assert_eq!(store.health().last_error.as_deref(), Some("boom"));
    }

    #[test]
    fn focused_player_prefers_playing_then_previous_then_first() {
        let paused = player("player:a", PlaybackStatus::Paused);
        let playing = player("player:b", PlaybackStatus::Playing);

        // Playing wins over previous focus and order.
        assert_eq!(
            select_focused(&[paused.clone(), playing.clone()], Some("player:a")).as_deref(),
            Some("player:b")
        );

        // Nothing playing: keep the previously focused player.
        assert_eq!(
            select_focused(
                &[paused.clone(), player("player:c", PlaybackStatus::Stopped)],
                Some("player:c")
            )
            .as_deref(),
            Some("player:c")
        );

        // Previous focus gone: fall back to the first player.
        assert_eq!(
            select_focused(std::slice::from_ref(&paused), Some("player:missing")).as_deref(),
            Some("player:a")
        );

        // No players: no focus.
        assert_eq!(select_focused(&[], None), None);
    }

    #[tokio::test]
    async fn unreachable_bus_refresh_is_a_typed_failure_and_retains_last_good() {
        use std::os::unix::ffi::OsStringExt;
        let address =
            std::ffi::OsString::from_vec(b"unix:path=/nonexistent/velora-test-media-bus".to_vec());
        let store = MediaStore::new(Some(address));

        assert!(store.refresh().await.is_err());
        assert!(store.current().is_none());
        assert_eq!(store.health().failed_refreshes, 1);
        assert!(store.health().last_error.is_some());
    }

    #[tokio::test]
    async fn non_utf8_address_is_a_typed_unavailable() {
        use std::os::unix::ffi::OsStringExt;
        let address = std::ffi::OsString::from_vec(vec![0xff, 0xfe, 0xfd]);
        let store = MediaStore::new(Some(address));

        assert!(matches!(
            store.refresh().await.unwrap_err(),
            MediaStoreError::InvalidAddress
        ));
    }

    #[tokio::test]
    async fn hung_bus_refresh_times_out_and_records_health() {
        use std::os::unix::net::UnixListener as StdUnixListener;

        let directory = tempfile::tempdir().unwrap();
        let socket_path = directory.path().join("hung-media-bus");
        let listener = StdUnixListener::bind(&socket_path).unwrap();

        // Accept the client and hold the stream open without completing the
        // D-Bus auth handshake, so the refresh must time out instead of
        // blocking forever while holding the refresh lock.
        let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();
        let server = std::thread::spawn(move || {
            let (_stream, _address) = listener.accept().unwrap();
            let _ = stop_rx.recv();
        });

        let address = format!("unix:path={}", socket_path.display());
        let store = MediaStore::new(Some(std::ffi::OsString::from(address)));

        let result = store.refresh_with_timeout(Duration::from_millis(100)).await;

        let _ = stop_tx.send(());
        server.join().unwrap();

        assert!(matches!(result, Err(MediaStoreError::TimedOut)));
        assert_eq!(store.health().failed_refreshes, 1);
        assert!(store.health().last_error.is_some());
    }

    #[test]
    fn store_is_bounded_to_a_single_snapshot() {
        // The store keeps exactly one snapshot; there is no history to grow.
        let store = MediaStore::new(None);
        for index in 0..100 {
            store
                .apply(vec![player(
                    &format!("player:{index}"),
                    PlaybackStatus::Playing,
                )])
                .unwrap();
        }
        assert_eq!(store.current().unwrap().players.len(), 1);
        assert_eq!(store.health().successful_refreshes, 100);
    }

    #[test]
    fn position_changes_are_meaningful_publications() {
        // `position_micros` is authoritative wire state, so a position change
        // is a real change and must bump the sequence (see `content_eq`).
        let store = MediaStore::new(None);
        let mut track = player("player:1", PlaybackStatus::Playing);
        track.position_micros = 1_000;
        assert!(store.apply(vec![track.clone()]).unwrap());

        let mut advanced = track;
        advanced.position_micros = 2_000;
        assert!(
            store.apply(vec![advanced]).unwrap(),
            "a position change must republish"
        );
        assert_eq!(store.current().unwrap().sequence, 2);
        assert_eq!(store.current().unwrap().players[0].position_micros, 2_000);
    }

    fn full_width_player(handle: &str) -> MediaPlayer {
        MediaPlayer {
            handle: handle.to_owned(),
            identity: "i".repeat(MAX_STRING_BYTES),
            status: PlaybackStatus::Playing,
            title: Some("t".repeat(MAX_STRING_BYTES)),
            artist: Some("a".repeat(MAX_STRING_BYTES)),
            album: Some("l".repeat(MAX_STRING_BYTES)),
            length_micros: Some(250_000_000),
            position_micros: 0,
            can_play: true,
            can_pause: true,
            can_go_next: true,
            can_go_previous: true,
            can_seek: true,
            can_control: true,
        }
    }

    #[test]
    fn payload_budget_truncates_optional_metadata() {
        let store = MediaStore::new(None);
        let players: Vec<MediaPlayer> = (0..MAX_MEDIA_PLAYERS)
            .map(|index| full_width_player(&format!("player:{index}")))
            .collect();
        // Sixteen full-width players far exceed the 4 KiB budget.
        assert!(store.apply(players).unwrap());

        let snapshot = store.current().unwrap();
        let encoded = serde_json::to_string(&*snapshot).unwrap();
        assert!(
            encoded.len() <= MAX_MEDIA_PAYLOAD_BYTES,
            "served snapshot must never exceed the payload budget"
        );
        // Optional metadata was truncated (strictly below the 256-byte ceiling).
        assert!(
            snapshot.players[0].title.as_ref().unwrap().len() < MAX_STRING_BYTES,
            "oversized metadata must be truncated to fit"
        );
        snapshot.validate().unwrap();
    }

    #[test]
    fn payload_budget_leaves_small_snapshots_untouched() {
        let store = MediaStore::new(None);
        let mut track = player("player:1", PlaybackStatus::Playing);
        track.title = Some("Velora Theme".to_owned());
        track.artist = Some("Velora".to_owned());
        assert!(store.apply(vec![track]).unwrap());

        let snapshot = store.current().unwrap();
        assert_eq!(snapshot.players[0].title.as_deref(), Some("Velora Theme"));
        assert_eq!(snapshot.players[0].artist.as_deref(), Some("Velora"));
        assert!(serde_json::to_string(&*snapshot).unwrap().len() <= MAX_MEDIA_PAYLOAD_BYTES);
    }

    #[test]
    fn bound_payload_rejects_a_candidate_that_cannot_fit() {
        // `bound_payload` is agnostic to the structural player ceiling. Feed it
        // a candidate whose non-truncatable fields alone overflow the budget
        // (empty identity, no metadata to shrink) to prove the fail-closed
        // `None` path.
        let players: Vec<MediaPlayer> = (0..64)
            .map(|index| MediaPlayer {
                handle: format!("player:{index:04x}"),
                identity: String::new(),
                status: PlaybackStatus::Stopped,
                title: None,
                artist: None,
                album: None,
                length_micros: None,
                position_micros: 0,
                can_play: true,
                can_pause: true,
                can_go_next: true,
                can_go_previous: true,
                can_seek: true,
                can_control: true,
            })
            .collect();
        let snapshot = MediaSnapshot {
            sequence: 1,
            players,
            active_player_handle: None,
        };
        assert!(
            encoded_len(&snapshot) > MAX_MEDIA_PAYLOAD_BYTES,
            "fixture must actually overflow the budget"
        );
        assert!(bound_payload(snapshot).is_none());
    }

    /// A private `dbus-daemon` on a temporary address. Never the live session
    /// bus. The child is killed and reaped on drop.
    struct PrivateBus {
        address: String,
        child: Child,
    }

    impl PrivateBus {
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

    const TEST_PLAYER: &str = "org.mpris.MediaPlayer2.velora_test";

    struct MediaPlayer2Props;

    #[zbus::interface(name = "org.mpris.MediaPlayer2")]
    impl MediaPlayer2Props {
        #[zbus(property)]
        fn identity(&self) -> String {
            "Test Player".to_owned()
        }
    }

    struct PlayerProps {
        served: mpsc::UnboundedSender<()>,
        release: tokio::sync::Mutex<Option<mpsc::Receiver<()>>>,
        calls: AtomicU64,
    }

    #[zbus::interface(name = "org.mpris.MediaPlayer2.Player")]
    impl PlayerProps {
        #[zbus(property)]
        fn playback_status(&self) -> String {
            "Playing".to_owned()
        }

        #[zbus(property)]
        async fn metadata(&self) -> HashMap<String, OwnedValue> {
            let call = self.calls.fetch_add(1, Ordering::SeqCst);
            // Block the very first Player read so the test can prove a second
            // refresh queues behind the first instead of applying out of order.
            if call == 0 {
                let receiver = self.release.lock().await.take();
                if let Some(mut receiver) = receiver {
                    let _ = self.served.send(());
                    let _ = receiver.recv().await;
                }
            }
            let mut map = HashMap::new();
            let title: OwnedValue = Value::from(format!("title-{call}")).try_into().unwrap();
            map.insert("xesam:title".to_owned(), title);
            map
        }
    }

    #[tokio::test]
    async fn concurrent_refreshes_are_serialized() {
        let Some(bus) = PrivateBus::spawn() else {
            eprintln!("dbus-daemon unavailable; skipping");
            return;
        };
        let player = bus.connect().await;
        let (served_tx, mut served_rx) = mpsc::unbounded_channel();
        let (release_tx, release_rx) = mpsc::channel(1);
        let player_props = PlayerProps {
            served: served_tx,
            release: tokio::sync::Mutex::new(Some(release_rx)),
            calls: AtomicU64::new(0),
        };
        let server = player.object_server();
        server
            .at("/org/mpris/MediaPlayer2", MediaPlayer2Props)
            .await
            .unwrap();
        server
            .at("/org/mpris/MediaPlayer2", player_props)
            .await
            .unwrap();
        player.request_name(TEST_PLAYER).await.unwrap();

        let store = Arc::new(MediaStore::new(Some(std::ffi::OsString::from(
            bus.address.clone(),
        ))));

        // Refresh A: blocks inside the first Player `GetAll`.
        let refresh_a = tokio::spawn({
            let store = Arc::clone(&store);
            async move { store.refresh().await }
        });

        // Wait until A's blocking read has been reached.
        tokio::time::timeout(Duration::from_secs(2), served_rx.recv())
            .await
            .unwrap()
            .unwrap();

        // Refresh B: must queue behind A's refresh lock, not apply first.
        let refresh_b = tokio::spawn({
            let store = Arc::clone(&store);
            async move { store.refresh().await }
        });

        // B cannot publish while A holds the lock.
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(
            store.current().is_none(),
            "refresh B must wait for A instead of applying out of order"
        );

        // Release A: it publishes `title-0`, then B publishes `title-1`.
        release_tx.send(()).await.unwrap();
        let changed_a = tokio::time::timeout(Duration::from_secs(2), refresh_a)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let changed_b = tokio::time::timeout(Duration::from_secs(2), refresh_b)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(changed_a && changed_b);

        // The last-applied snapshot is B's (`title-1`), never the stale A read.
        let snapshot = store.current().unwrap();
        assert_eq!(snapshot.sequence, 2);
        assert_eq!(snapshot.players.len(), 1);
        assert_eq!(snapshot.players[0].title.as_deref(), Some("title-1"));
    }
}
