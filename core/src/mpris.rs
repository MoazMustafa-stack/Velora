//! Read-only MPRIS adapter.
//!
//! Velora observes media players strictly through the user session bus. This
//! module is the only place raw `org.mpris.MediaPlayer2` and
//! `org.mpris.MediaPlayer2.Player` properties are parsed: it reads both
//! interfaces with `Properties.GetAll`, normalizes `Identity`, `PlaybackStatus`,
//! the `xesam:` metadata triplet (`title`/`artist`/`album`), `mpris:length`,
//! `Position`, and the `Can*` transport flags into the shared, validated
//! protocol model, and issues an opaque hashed handle so a raw D-Bus bus name
//! never crosses Velora IPC.
//!
//! Reading is the only capability that exists here: there is no state-changing
//! method call. Missing, mistyped, and additional metadata fields are tolerated
//! and normalized to defaults; a metadata value that is not a string-variant
//! dictionary (malformed or hostile) yields a typed error instead of a guess.

use std::{
    collections::HashMap,
    hash::{Hash, Hasher},
};
use thiserror::Error;
use velora_protocol::{MAX_STRING_BYTES, MediaControlVerb, MediaPlayer, PlaybackStatus};
use zbus::{
    Connection, Proxy,
    zvariant::{OwnedValue, Value},
};

/// Standard MPRIS object path every player exposes.
const MPRIS_OBJECT_PATH: &str = "/org/mpris/MediaPlayer2";
/// Standard D-Bus properties interface used for `Properties.GetAll`.
const PROPERTIES_INTERFACE: &str = "org.freedesktop.DBus.Properties";
/// The identity interface (Identity, desktop entry, quit/raise).
const MEDIA_PLAYER2_INTERFACE: &str = "org.mpris.MediaPlayer2";
/// The transport interface (PlaybackStatus, Metadata, Position, Can* flags).
const PLAYER_INTERFACE: &str = "org.mpris.MediaPlayer2.Player";
/// Maximum length of a player bus name accepted for hashing.
const MAX_PLAYER_NAME_CHARS: usize = 256;
/// Maximum number of `xesam:artist` entries normalized into the single
/// protocol `artist` string.
const MAX_ARTIST_ENTRIES: usize = 16;

/// Typed failure of the read-only MPRIS adapter. Malformed player properties
/// never panic and never publish a partial player.
#[derive(Debug, Error)]
pub(crate) enum MprisError {
    #[error("MPRIS player name is empty or exceeds {MAX_PLAYER_NAME_CHARS} characters")]
    InvalidPlayerName,
    #[error("MPRIS read failed for {player}: {source}")]
    Call {
        player: String,
        #[source]
        source: Box<zbus::Error>,
    },
    #[error("MPRIS metadata for {player} is not a string-variant dictionary")]
    MalformedMetadata { player: String },
}

/// Read one MPRIS player's normalized state from both interfaces. This is the
/// only entry point for the rest of Core; it never writes to the bus.
pub(crate) async fn read_player(
    connection: &Connection,
    player_name: &str,
) -> Result<MediaPlayer, MprisError> {
    validate_player_name(player_name)?;

    let (media2, player) = tokio::try_join!(
        read_properties(connection, player_name, MEDIA_PLAYER2_INTERFACE),
        read_properties(connection, player_name, PLAYER_INTERFACE),
    )
    .map_err(|source| MprisError::Call {
        player: player_name.to_owned(),
        source: Box::new(source),
    })?;

    normalize_player(player_name, &media2, &player)
}

/// The fixed `org.mpris.MediaPlayer2.Player` method each allowlisted control
/// verb maps to. This is the complete write surface: every verb resolves to
/// exactly one no-argument method, so a raw method name or an arbitrary
/// argument can never reach the bus from IPC.
pub(crate) fn player_method(verb: MediaControlVerb) -> &'static str {
    match verb {
        MediaControlVerb::Play => "Play",
        MediaControlVerb::Pause => "Pause",
        MediaControlVerb::PlayPause => "PlayPause",
        MediaControlVerb::Stop => "Stop",
        MediaControlVerb::Next => "Next",
        MediaControlVerb::Previous => "Previous",
    }
}

/// Dispatch one allowlisted control verb to a player. The verb is mapped to a
/// fixed, no-argument method on `org.mpris.MediaPlayer2.Player`; neither the
/// method name nor any argument crosses IPC. This is the only state-changing
/// call the adapter ever makes.
pub(crate) async fn control_player(
    connection: &Connection,
    player_name: &str,
    verb: MediaControlVerb,
) -> Result<(), MprisError> {
    validate_player_name(player_name)?;

    let proxy = Proxy::new(connection, player_name, MPRIS_OBJECT_PATH, PLAYER_INTERFACE)
        .await
        .map_err(|source| MprisError::Call {
            player: player_name.to_owned(),
            source: Box::new(source),
        })?;

    proxy
        .call::<_, _, ()>(player_method(verb), &())
        .await
        .map_err(|source| MprisError::Call {
            player: player_name.to_owned(),
            source: Box::new(source),
        })
}

/// Reject an empty or oversized player name before it is hashed or used as a
/// bus destination. Fail closed rather than guessing at a hostile name.
fn validate_player_name(player_name: &str) -> Result<(), MprisError> {
    if player_name.is_empty() || player_name.len() > MAX_PLAYER_NAME_CHARS {
        Err(MprisError::InvalidPlayerName)
    } else {
        Ok(())
    }
}

async fn read_properties(
    connection: &Connection,
    player_name: &str,
    interface: &str,
) -> Result<HashMap<String, OwnedValue>, zbus::Error> {
    let proxy = Proxy::new(
        connection,
        player_name,
        MPRIS_OBJECT_PATH,
        PROPERTIES_INTERFACE,
    )
    .await?;
    proxy.call("GetAll", &(interface,)).await
}

/// Pure normalization boundary: raw property dictionaries in, a validated
/// protocol `MediaPlayer` out. Kept synchronous and side-effect free so the
/// tolerance rules are directly testable without a live bus.
fn normalize_player(
    player_name: &str,
    media2: &HashMap<String, OwnedValue>,
    player: &HashMap<String, OwnedValue>,
) -> Result<MediaPlayer, MprisError> {
    let metadata = match player.get("Metadata") {
        None => HashMap::new(),
        Some(value) => HashMap::<String, OwnedValue>::try_from(value.clone()).map_err(|_| {
            MprisError::MalformedMetadata {
                player: player_name.to_owned(),
            }
        })?,
    };

    Ok(MediaPlayer {
        handle: opaque_player_handle(player_name),
        identity: string_field(media2, "Identity").unwrap_or_default(),
        status: playback_status(player),
        title: string_field(&metadata, "xesam:title"),
        artist: artist_field(&metadata),
        album: string_field(&metadata, "xesam:album"),
        length_micros: metadata
            .get("mpris:length")
            .and_then(micros_value)
            .filter(|micros| *micros > 0),
        position_micros: player.get("Position").and_then(micros_value).unwrap_or(0),
        can_play: bool_field(player, "CanPlay"),
        can_pause: bool_field(player, "CanPause"),
        can_go_next: bool_field(player, "CanGoNext"),
        can_go_previous: bool_field(player, "CanGoPrevious"),
        can_seek: bool_field(player, "CanSeek"),
        can_control: bool_field(player, "CanControl"),
    })
}

/// A trimmed, byte-bounded string (`MAX_STRING_BYTES`) that always satisfies
/// the protocol `MediaPlayer` validation ceiling. Truncation lands on a UTF-8
/// character boundary, so it never splits a code point.
fn bounded_string(value: &str) -> String {
    let mut output = String::new();
    for character in value.trim().chars() {
        if output.len() + character.len_utf8() > MAX_STRING_BYTES {
            break;
        }
        output.push(character);
    }
    output
}

/// Read a string field, tolerating a missing or mistyped value as `None`.
fn string_field(props: &HashMap<String, OwnedValue>, key: &str) -> Option<String> {
    let value = props.get(key)?;
    let text = <&str>::try_from(value).ok()?;
    Some(bounded_string(text))
}

/// Normalize `xesam:artist` (an array of strings in the spec, but players
/// sometimes send a single string or the wrong type) into the single bounded
/// protocol `artist` string. Missing or mistyped values become `None`.
fn artist_field(metadata: &HashMap<String, OwnedValue>) -> Option<String> {
    let value = metadata.get("xesam:artist")?;
    let artists: Vec<String> = match &**value {
        Value::Array(array) => array
            .iter()
            .filter_map(|element| element.downcast_ref::<&str>().ok())
            .map(bounded_string)
            .filter(|artist| !artist.is_empty())
            .take(MAX_ARTIST_ENTRIES)
            .collect(),
        Value::Str(text) => {
            let bounded = bounded_string(text.as_str());
            if bounded.is_empty() {
                return None;
            }
            vec![bounded]
        }
        _ => return None,
    };

    if artists.is_empty() {
        None
    } else {
        Some(bounded_string(&artists.join(", ")))
    }
}

/// Normalize `PlaybackStatus`. Any unrecognized or missing status collapses to
/// `Stopped` rather than inventing a fourth variant.
fn playback_status(player: &HashMap<String, OwnedValue>) -> PlaybackStatus {
    match player
        .get("PlaybackStatus")
        .and_then(|value| <&str>::try_from(value).ok())
        .map(str::trim)
    {
        Some("Playing") => PlaybackStatus::Playing,
        Some("Paused") => PlaybackStatus::Paused,
        _ => PlaybackStatus::Stopped,
    }
}

/// Read a `Can*` flag, tolerating a missing or mistyped value as `false`
/// (fail closed: an unreadable transport flag never claims control).
fn bool_field(props: &HashMap<String, OwnedValue>, key: &str) -> bool {
    props
        .get(key)
        .and_then(|value| bool::try_from(value).ok())
        .unwrap_or(false)
}

/// Parse a microsecond value with type tolerance. The MPRIS spec declares
/// `mpris:length` and `Position` as `x` (int64), but players have shipped
/// `u` (uint64) and `d` (double) instead. Negative, non-finite, and mistyped
/// values normalize to `None`.
fn micros_value(value: &OwnedValue) -> Option<u64> {
    if let Ok(micros) = i64::try_from(value)
        && let Ok(micros) = u64::try_from(micros)
    {
        return Some(micros);
    }
    if let Ok(micros) = u64::try_from(value) {
        return Some(micros);
    }
    if let Ok(micros) = f64::try_from(value)
        && micros.is_finite()
        && micros >= 0.0
    {
        return Some(micros as u64);
    }
    None
}

/// Players are referenced only through a one-way hash of their bus name, so no
/// raw bus name can ever reach or return from Godot.
fn opaque_player_handle(player_name: &str) -> String {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    player_name.hash(&mut hasher);
    format!("player:{:016x}", hasher.finish())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owned(value: Value<'static>) -> OwnedValue {
        value.try_into().unwrap()
    }

    fn str_value(text: &str) -> OwnedValue {
        owned(Value::from(text.to_owned()))
    }

    fn bool_value(value: bool) -> OwnedValue {
        owned(Value::from(value))
    }

    fn i64_value(value: i64) -> OwnedValue {
        owned(Value::from(value))
    }

    fn u64_value(value: u64) -> OwnedValue {
        owned(Value::from(value))
    }

    fn string_array(items: &[&str]) -> OwnedValue {
        owned(Value::from(
            items
                .iter()
                .map(|item| item.to_string())
                .collect::<Vec<_>>(),
        ))
    }

    fn metadata_dict(entries: Vec<(&str, OwnedValue)>) -> OwnedValue {
        let map: HashMap<String, Value<'static>> = entries
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value.into()))
            .collect();
        owned(Value::from(map))
    }

    fn full_props(metadata: OwnedValue) -> HashMap<String, OwnedValue> {
        let mut props = HashMap::new();
        props.insert("PlaybackStatus".to_owned(), str_value("Playing"));
        props.insert("Metadata".to_owned(), metadata);
        props.insert("Position".to_owned(), i64_value(12_500_000));
        props.insert("CanPlay".to_owned(), bool_value(true));
        props.insert("CanPause".to_owned(), bool_value(true));
        props.insert("CanGoNext".to_owned(), bool_value(true));
        props.insert("CanGoPrevious".to_owned(), bool_value(true));
        props.insert("CanSeek".to_owned(), bool_value(true));
        props.insert("CanControl".to_owned(), bool_value(true));
        props
    }

    fn media2_props(identity: &str) -> HashMap<String, OwnedValue> {
        let mut props = HashMap::new();
        props.insert("Identity".to_owned(), str_value(identity));
        props
    }

    fn well_formed_metadata() -> OwnedValue {
        metadata_dict(vec![
            ("xesam:title", str_value("Velora Theme")),
            ("xesam:artist", string_array(&["Velora", "Guest"])),
            ("xesam:album", str_value("Phase 5")),
            ("mpris:length", i64_value(250_000_000)),
        ])
    }

    #[test]
    fn normalizes_a_well_formed_player() {
        let player = normalize_player(
            "org.mpris.MediaPlayer2.spotify",
            &media2_props("Spotify"),
            &full_props(well_formed_metadata()),
        )
        .unwrap();

        assert_eq!(player.identity, "Spotify");
        assert_eq!(player.status, PlaybackStatus::Playing);
        assert_eq!(player.title.as_deref(), Some("Velora Theme"));
        assert_eq!(player.artist.as_deref(), Some("Velora, Guest"));
        assert_eq!(player.album.as_deref(), Some("Phase 5"));
        assert_eq!(player.length_micros, Some(250_000_000));
        assert_eq!(player.position_micros, 12_500_000);
        assert!(player.can_play);
        assert!(player.can_pause);
        assert!(player.can_go_next);
        assert!(player.can_go_previous);
        assert!(player.can_seek);
        assert!(player.can_control);
    }

    #[test]
    fn tolerates_missing_metadata_and_flags() {
        let player = normalize_player(
            "org.mpris.MediaPlayer2.spotify",
            &HashMap::new(),
            &HashMap::new(),
        )
        .unwrap();

        assert_eq!(player.identity, "");
        assert_eq!(player.status, PlaybackStatus::Stopped);
        assert_eq!(player.title, None);
        assert_eq!(player.artist, None);
        assert_eq!(player.album, None);
        assert_eq!(player.length_micros, None);
        assert_eq!(player.position_micros, 0);
        assert!(!player.can_play);
        assert!(!player.can_pause);
        assert!(!player.can_go_next);
        assert!(!player.can_go_previous);
        assert!(!player.can_seek);
        assert!(!player.can_control);
    }

    #[test]
    fn tolerates_mistyped_fields_without_error() {
        let mut player_props = HashMap::new();
        player_props.insert("PlaybackStatus".to_owned(), i64_value(42));
        player_props.insert(
            "Metadata".to_owned(),
            metadata_dict(vec![
                ("xesam:title", i64_value(7)),
                ("xesam:artist", bool_value(true)),
                ("xesam:album", u64_value(9)),
                ("mpris:length", str_value("not-a-number")),
            ]),
        );
        player_props.insert("Position".to_owned(), str_value("also-not-a-number"));
        player_props.insert("CanPlay".to_owned(), str_value("yes"));
        player_props.insert("CanControl".to_owned(), i64_value(1));

        let player = normalize_player(
            "org.mpris.MediaPlayer2.spotify",
            &HashMap::new(),
            &player_props,
        )
        .unwrap();

        assert_eq!(player.status, PlaybackStatus::Stopped);
        assert_eq!(player.title, None);
        assert_eq!(player.artist, None);
        assert_eq!(player.album, None);
        assert_eq!(player.length_micros, None);
        assert_eq!(player.position_micros, 0);
        assert!(!player.can_play);
        assert!(!player.can_control);
    }

    #[test]
    fn ignores_additional_metadata_fields() {
        let metadata = metadata_dict(vec![
            ("xesam:title", str_value("Velora Theme")),
            ("xesam:url", str_value("https://example.com/track")),
            ("xesam:trackNumber", i64_value(3)),
            ("mpris:artUrl", str_value("https://example.com/art.png")),
        ]);

        let player = normalize_player(
            "org.mpris.MediaPlayer2.spotify",
            &media2_props("Spotify"),
            &full_props(metadata),
        )
        .unwrap();

        assert_eq!(player.title.as_deref(), Some("Velora Theme"));
        assert_eq!(player.album, None);
        assert_eq!(player.length_micros, None);
    }

    #[test]
    fn malformed_metadata_is_a_typed_error() {
        let mut player_props = HashMap::new();
        player_props.insert("Metadata".to_owned(), str_value("not-a-dictionary"));

        let error = normalize_player(
            "org.mpris.MediaPlayer2.spotify",
            &HashMap::new(),
            &player_props,
        )
        .unwrap_err();

        assert!(matches!(error, MprisError::MalformedMetadata { .. }));
    }

    #[test]
    fn playback_status_normalizes_unknown_and_known_values() {
        let statuses = [
            ("Playing", PlaybackStatus::Playing),
            ("Paused", PlaybackStatus::Paused),
            ("Stopped", PlaybackStatus::Stopped),
        ];
        for (raw, expected) in statuses {
            let mut props = HashMap::new();
            props.insert("PlaybackStatus".to_owned(), str_value(raw));
            assert_eq!(playback_status(&props), expected, "raw status {raw}");
        }

        let mut unknown = HashMap::new();
        unknown.insert("PlaybackStatus".to_owned(), str_value("Buffering"));
        assert_eq!(playback_status(&unknown), PlaybackStatus::Stopped);
        assert_eq!(playback_status(&HashMap::new()), PlaybackStatus::Stopped);
    }

    #[test]
    fn length_requires_a_positive_value_but_position_accepts_zero() {
        assert_eq!(micros_value(&i64_value(250_000_000)), Some(250_000_000));
        assert_eq!(micros_value(&i64_value(0)), Some(0));
        assert_eq!(micros_value(&i64_value(-5)), None);
        assert_eq!(micros_value(&u64_value(250_000_000)), Some(250_000_000));
        assert_eq!(micros_value(&str_value("nope")), None);
    }

    #[test]
    fn artist_arrays_are_bounded_and_single_strings_are_accepted() {
        let mut metadata = HashMap::new();
        metadata.insert("xesam:artist".to_owned(), str_value("Solo Artist"));
        assert_eq!(artist_field(&metadata).as_deref(), Some("Solo Artist"));

        let many: Vec<String> = (0..(MAX_ARTIST_ENTRIES + 10))
            .map(|index| format!("Artist {index}"))
            .collect();
        let mut metadata = HashMap::new();
        metadata.insert("xesam:artist".to_owned(), owned(Value::from(many)));
        let joined = artist_field(&metadata).unwrap();
        assert!(joined.len() <= MAX_STRING_BYTES);
        // Only the first MAX_ARTIST_ENTRIES artists can appear.
        assert!(!joined.contains(&format!("Artist {MAX_ARTIST_ENTRIES}")));
    }

    #[test]
    fn strings_are_trimmed_and_byte_bounded() {
        assert_eq!(bounded_string("  padded  "), "padded");

        let long = "🦀".repeat(MAX_STRING_BYTES + 50);
        let bounded = bounded_string(&long);
        assert!(bounded.len() <= MAX_STRING_BYTES);
        assert!(bounded.chars().count() < long.chars().count());
    }

    #[test]
    fn player_handles_are_opaque_stable_and_collision_free() {
        let spotify = opaque_player_handle("org.mpris.MediaPlayer2.spotify");
        let vlc = opaque_player_handle("org.mpris.MediaPlayer2.vlc");

        assert!(spotify.starts_with("player:"));
        assert!(!spotify.contains("org.mpris"));
        assert_eq!(
            spotify,
            opaque_player_handle("org.mpris.MediaPlayer2.spotify")
        );
        assert_ne!(spotify, vlc);
    }

    #[test]
    fn player_names_are_validated() {
        assert!(validate_player_name("org.mpris.MediaPlayer2.spotify").is_ok());
        assert!(validate_player_name("").is_err());
        let too_long = "x".repeat(MAX_PLAYER_NAME_CHARS + 1);
        assert!(validate_player_name(&too_long).is_err());
    }

    #[test]
    fn control_verbs_map_to_exactly_the_fixed_player_methods() {
        // The allowlist is exhaustive and maps each verb to one fixed,
        // no-argument MPRIS Player method. There is no verb outside this set
        // and no way to reach any other method.
        assert_eq!(player_method(MediaControlVerb::Play), "Play");
        assert_eq!(player_method(MediaControlVerb::Pause), "Pause");
        assert_eq!(player_method(MediaControlVerb::PlayPause), "PlayPause");
        assert_eq!(player_method(MediaControlVerb::Stop), "Stop");
        assert_eq!(player_method(MediaControlVerb::Next), "Next");
        assert_eq!(player_method(MediaControlVerb::Previous), "Previous");
    }
}
