use std::{
    collections::HashMap,
    env,
    ffi::OsStr,
    hash::{Hash, Hasher},
    io,
    os::unix::fs::FileTypeExt,
    path::{Component, Path, PathBuf},
    time::Duration,
};
use thiserror::Error;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
    time::timeout,
};
use velora_protocol::{
    HyprlandAvailability, HyprlandCapabilities, MAX_MESSAGE_BYTES, MAX_WINDOWS, MAX_WORKSPACES,
    Window, Workspace, WorkspaceSnapshot,
};

const COMMAND_SOCKET_NAME: &str = ".socket.sock";
const EVENT_SOCKET_NAME: &str = ".socket2.sock";
const VERSION_REQUEST: &[u8] = b"j/version";
const WORKSPACES_REQUEST: &[u8] = b"j/workspaces";
const WINDOWS_REQUEST: &[u8] = b"j/clients";
const ACTIVE_WORKSPACE_REQUEST: &[u8] = b"j/activeworkspace";
const ACTIVE_WINDOW_REQUEST: &[u8] = b"j/activewindow";
const QUERY_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_WORKSPACE_NAME_CHARS: usize = 128;
const MAX_WINDOW_TITLE_CHARS: usize = 256;
const MAX_WINDOW_CLASS_CHARS: usize = 128;
const MAX_MONITOR_NAME_CHARS: usize = 64;

/// Typed failure of a read-only session query. Malformed compositor output
/// never panics and never publishes a partial snapshot.
#[derive(Debug, Error)]
pub(crate) enum AdapterError {
    #[error("Hyprland command socket query failed: {0}")]
    Query(#[source] io::Error),
    #[error("Hyprland reports more than {MAX_WORKSPACES} workspaces")]
    TooManyWorkspaces,
    #[error("Hyprland reports more than {MAX_WINDOWS} windows")]
    TooManyWindows,
}

/// Probe only documented Hyprland runtime state. This module never reads
/// compositor configuration and never issues a state-changing command.
pub(crate) async fn probe_from_environment() -> HyprlandCapabilities {
    probe_with_environment(
        env::var_os("XDG_RUNTIME_DIR").as_deref(),
        env::var_os("HYPRLAND_INSTANCE_SIGNATURE").as_deref(),
    )
    .await
}

async fn probe_with_environment(
    runtime_dir: Option<&OsStr>,
    instance_signature: Option<&OsStr>,
) -> HyprlandCapabilities {
    let Some(runtime_dir) = runtime_dir.and_then(absolute_path) else {
        return HyprlandCapabilities::unavailable();
    };
    let Some(instance_signature) = instance_signature.and_then(valid_instance_signature) else {
        return HyprlandCapabilities::unavailable();
    };

    let instance_directory = runtime_dir.join("hypr").join(instance_signature);
    let command_socket = instance_directory.join(COMMAND_SOCKET_NAME);
    let event_socket = instance_directory.join(EVENT_SOCKET_NAME);
    if !is_socket(&command_socket) || !is_socket(&event_socket) {
        return HyprlandCapabilities::incompatible();
    }

    let Ok(version) = query_version(&command_socket).await else {
        return HyprlandCapabilities::incompatible();
    };

    let can_query_workspaces = query_json(&command_socket, WORKSPACES_REQUEST)
        .await
        .is_ok();
    let can_query_windows = query_json(&command_socket, WINDOWS_REQUEST).await.is_ok();
    let can_query_active_workspace = query_json(&command_socket, ACTIVE_WORKSPACE_REQUEST)
        .await
        .is_ok();
    let can_query_active_window = query_json(&command_socket, ACTIVE_WINDOW_REQUEST)
        .await
        .is_ok();
    let can_receive_events = is_socket(&event_socket);
    let availability = if can_query_workspaces
        && can_query_windows
        && can_query_active_workspace
        && can_query_active_window
        && can_receive_events
    {
        HyprlandAvailability::Available
    } else {
        HyprlandAvailability::Incompatible
    };

    HyprlandCapabilities {
        availability,
        version: Some(version),
        can_query_workspaces,
        can_query_windows,
        can_query_active_workspace,
        can_query_active_window,
        can_receive_events,
    }
}

fn absolute_path(value: &OsStr) -> Option<PathBuf> {
    let path = PathBuf::from(value);
    path.is_absolute().then_some(path)
}

fn valid_instance_signature(value: &OsStr) -> Option<&str> {
    let value = value.to_str()?;
    if value.is_empty() || value.len() > 128 {
        return None;
    }

    (matches!(
        Path::new(value).components().next(),
        Some(Component::Normal(_))
    ) && Path::new(value).components().count() == 1)
        .then_some(value)
}

fn is_socket(path: &Path) -> bool {
    std::fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_socket())
        .unwrap_or(false)
}

async fn query_version(path: &Path) -> Result<String, io::Error> {
    let response = query_json(path, VERSION_REQUEST).await?;
    parse_version_value(response).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Hyprland version response does not contain a version",
        )
    })
}

async fn query_json(path: &Path, request: &[u8]) -> Result<serde_json::Value, io::Error> {
    timeout(QUERY_TIMEOUT, async {
        let mut stream = UnixStream::connect(path).await?;
        stream.write_all(request).await?;
        stream.shutdown().await?;

        let mut response = Vec::new();
        let mut buffer = [0_u8; 4096];
        loop {
            let read = stream.read(&mut buffer).await?;
            if read == 0 {
                break;
            }
            if response.len() + read > MAX_MESSAGE_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Hyprland probe response exceeds the transport limit",
                ));
            }
            response.extend_from_slice(&buffer[..read]);
        }
        serde_json::from_slice(&response).map_err(|error| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid Hyprland probe response: {error}"),
            )
        })
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "Hyprland version query timed out"))?
}

fn parse_version_value(value: serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(version) if !version.trim().is_empty() => {
            Some(version.trim().to_owned())
        }
        serde_json::Value::Object(fields) => ["tag", "version"]
            .into_iter()
            .find_map(|field| fields.get(field).and_then(|value| value.as_str()))
            .map(str::trim)
            .filter(|version| !version.is_empty())
            .map(str::to_owned),
        _ => None,
    }
}

/// Read-only session query. This is the only place raw Hyprland JSON is
/// parsed; every value that leaves this function belongs to the shared,
/// validated protocol model. No state-changing command exists here.
#[allow(dead_code)]
pub(crate) async fn read_session_snapshot(
    command_socket: &Path,
    sequence: u64,
) -> Result<WorkspaceSnapshot, AdapterError> {
    let raw_workspaces = query_json(command_socket, WORKSPACES_REQUEST)
        .await
        .map_err(AdapterError::Query)?;
    let raw_windows = query_json(command_socket, WINDOWS_REQUEST)
        .await
        .map_err(AdapterError::Query)?;
    let raw_active_workspace = query_json(command_socket, ACTIVE_WORKSPACE_REQUEST)
        .await
        .map_err(AdapterError::Query)?;
    let raw_active_window = query_json(command_socket, ACTIVE_WINDOW_REQUEST)
        .await
        .map_err(AdapterError::Query)?;

    normalize_session_snapshot(
        sequence,
        &raw_workspaces,
        &raw_windows,
        &raw_active_workspace,
        &raw_active_window,
    )
}

fn normalize_session_snapshot(
    sequence: u64,
    raw_workspaces: &serde_json::Value,
    raw_windows: &serde_json::Value,
    raw_active_workspace: &serde_json::Value,
    raw_active_window: &serde_json::Value,
) -> Result<WorkspaceSnapshot, AdapterError> {
    let mut workspaces = parse_workspaces(raw_workspaces)?;
    if workspaces.len() > MAX_WORKSPACES {
        return Err(AdapterError::TooManyWorkspaces);
    }

    let mut clients = parse_clients(raw_windows)?;
    if clients.len() > MAX_WINDOWS {
        return Err(AdapterError::TooManyWindows);
    }

    clients.retain(|client| workspaces.contains_key(&client.window.workspace_handle));
    let mut windows: Vec<Window> = Vec::with_capacity(clients.len());
    let mut urgent_workspaces: HashMap<String, ()> = HashMap::new();
    for client in clients {
        if client.is_urgent {
            urgent_workspaces.insert(client.window.workspace_handle.clone(), ());
        }
        windows.push(client.window);
    }
    recompute_workspace_state(&mut workspaces, &windows);
    for workspace in workspaces.values_mut() {
        workspace.is_urgent = urgent_workspaces.contains_key(&workspace.handle);
    }
    let active_workspace_handle = parse_active_workspace(raw_active_workspace)
        .filter(|handle| workspaces.contains_key(handle));
    let active_window_handle = parse_active_window(raw_active_window)
        .filter(|handle| windows.iter().any(|window| &window.handle == handle));

    for workspace in workspaces.values_mut() {
        workspace.is_active = active_workspace_handle.as_deref() == Some(workspace.handle.as_str());
    }
    for window in &mut windows {
        window.is_active = active_window_handle.as_deref() == Some(window.handle.as_str());
    }

    let mut workspace_list: Vec<Workspace> = workspaces.into_values().collect();
    workspace_list.sort_by_key(|workspace| (workspace.is_special, workspace.index));

    let snapshot = WorkspaceSnapshot {
        sequence,
        workspaces: workspace_list,
        windows,
        active_workspace_handle,
        active_window_handle,
    };
    snapshot.validate().map_err(|_| {
        AdapterError::Query(io::Error::new(
            io::ErrorKind::InvalidData,
            "normalized session failed validation",
        ))
    })?;
    Ok(snapshot)
}

fn parse_workspaces(raw: &serde_json::Value) -> Result<HashMap<String, Workspace>, AdapterError> {
    let entries = raw
        .as_array()
        .ok_or_else(|| invalid_response("workspace listing is not an array"))?;
    let mut workspaces = HashMap::new();
    for entry in entries {
        let Some(parsed) = parse_workspace(entry) else {
            continue;
        };
        workspaces.entry(parsed.handle.clone()).or_insert(parsed);
    }
    Ok(workspaces)
}

fn parse_workspace(raw: &serde_json::Value) -> Option<Workspace> {
    let id = raw.get("id")?.as_i64()?;
    let name = bounded_string(
        raw.get("name")
            .and_then(|value| value.as_str())
            .unwrap_or_default(),
        MAX_WORKSPACE_NAME_CHARS,
    );
    let display_name = if name.is_empty() {
        id.to_string()
    } else {
        name
    };
    let is_special = id < 0 || display_name.starts_with("special:");
    let monitor = raw
        .get("monitor")
        .and_then(|value| value.as_str())
        .map(|value| bounded_string(value, MAX_MONITOR_NAME_CHARS))
        .filter(|value| !value.is_empty());

    Some(Workspace {
        handle: format!("workspace:{id}"),
        name: display_name,
        index: id.clamp(i32::MIN as i64, i32::MAX as i64) as i32,
        monitor,
        window_count: 0,
        is_active: false,
        is_special,
        is_urgent: false,
    })
}

fn parse_clients(raw: &serde_json::Value) -> Result<Vec<ParsedClient>, AdapterError> {
    let entries = raw
        .as_array()
        .ok_or_else(|| invalid_response("window listing is not an array"))?;
    let mut clients = Vec::new();
    for entry in entries {
        let Some(parsed) = parse_client(entry) else {
            continue;
        };
        clients.push(parsed);
    }
    Ok(clients)
}

struct ParsedClient {
    window: Window,
    is_urgent: bool,
}

fn parse_client(raw: &serde_json::Value) -> Option<ParsedClient> {
    let address = raw.get("address")?.as_str()?;
    if address.is_empty() {
        return None;
    }
    if let Some(mapped) = raw.get("mapped")
        && !truthy(mapped)
    {
        return None;
    }
    let workspace_id = raw
        .get("workspace")
        .and_then(|workspace| workspace.get("id"))
        .and_then(|id| id.as_i64())?;

    Some(ParsedClient {
        window: Window {
            handle: opaque_window_handle(address),
            workspace_handle: format!("workspace:{workspace_id}"),
            title: bounded_string(
                raw.get("title")
                    .and_then(|value| value.as_str())
                    .unwrap_or_default(),
                MAX_WINDOW_TITLE_CHARS,
            ),
            class: bounded_string(
                raw.get("class")
                    .and_then(|value| value.as_str())
                    .unwrap_or_default(),
                MAX_WINDOW_CLASS_CHARS,
            ),
            is_active: false,
            is_floating: raw.get("floating").is_some_and(truthy),
            is_fullscreen: raw.get("fullscreen").is_some_and(truthy),
        },
        is_urgent: raw.get("urgent").is_some_and(truthy),
    })
}

fn parse_active_workspace(raw: &serde_json::Value) -> Option<String> {
    let id = raw.get("id")?.as_i64()?;
    Some(format!("workspace:{id}"))
}

fn parse_active_window(raw: &serde_json::Value) -> Option<String> {
    let address = raw.get("address")?.as_str()?;
    (!address.is_empty()).then(|| opaque_window_handle(address))
}

fn recompute_workspace_state(workspaces: &mut HashMap<String, Workspace>, windows: &[Window]) {
    let mut counts: HashMap<&str, u16> = HashMap::new();
    for window in windows {
        *counts.entry(window.workspace_handle.as_str()).or_insert(0) += 1;
    }
    for workspace in workspaces.values_mut() {
        workspace.window_count = counts.remove(workspace.handle.as_str()).unwrap_or(0);
    }
}

/// Windows are referenced only through a one-way hash of the compositor
/// address, so no raw selector can ever reach or return from Godot.
fn opaque_window_handle(address: &str) -> String {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    address.hash(&mut hasher);
    format!("window:{:016x}", hasher.finish())
}

fn truthy(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Bool(inner) => *inner,
        serde_json::Value::Number(inner) => inner.as_f64().is_some_and(|inner| inner != 0.0),
        _ => false,
    }
}

fn bounded_string(value: &str, max_chars: usize) -> String {
    value.trim().chars().take(max_chars).collect()
}

fn invalid_response(reason: &str) -> AdapterError {
    AdapterError::Query(io::Error::new(
        io::ErrorKind::InvalidData,
        reason.to_owned(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        io::{Read, Write},
        os::unix::net::UnixListener as StdUnixListener,
        thread,
    };
    use tempfile::tempdir;

    #[tokio::test]
    async fn missing_runtime_identity_is_unavailable() {
        assert_eq!(
            probe_with_environment(None, None).await.availability,
            HyprlandAvailability::Unavailable
        );
    }

    #[tokio::test]
    async fn missing_or_unsafe_runtime_sockets_are_incompatible() {
        let directory = tempdir().unwrap();
        let runtime_dir = directory.path().join("runtime");
        fs::create_dir_all(&runtime_dir).unwrap();

        assert_eq!(
            probe_with_environment(Some(runtime_dir.as_os_str()), Some(OsStr::new("instance")))
                .await
                .availability,
            HyprlandAvailability::Incompatible
        );
        assert_eq!(
            probe_with_environment(
                Some(runtime_dir.as_os_str()),
                Some(OsStr::new("../not-an-instance")),
            )
            .await
            .availability,
            HyprlandAvailability::Unavailable
        );
    }

    #[tokio::test]
    async fn probe_reports_available_only_for_documented_runtime_sockets() {
        let directory = tempdir().unwrap();
        let runtime_dir = directory.path().join("runtime");
        let instance_directory = runtime_dir.join("hypr/test-instance");
        fs::create_dir_all(&instance_directory).unwrap();
        let command_path = instance_directory.join(COMMAND_SOCKET_NAME);
        let event_path = instance_directory.join(EVENT_SOCKET_NAME);
        let command_listener = StdUnixListener::bind(&command_path).unwrap();
        let _event_listener = StdUnixListener::bind(&event_path).unwrap();

        let server = thread::spawn(move || {
            for (request, response) in [
                (VERSION_REQUEST, br#"{"tag":"0.56.2"}"#.as_slice()),
                (WORKSPACES_REQUEST, br#"[]"#.as_slice()),
                (WINDOWS_REQUEST, br#"[]"#.as_slice()),
                (ACTIVE_WORKSPACE_REQUEST, br#"{}"#.as_slice()),
                (ACTIVE_WINDOW_REQUEST, br#"{}"#.as_slice()),
            ] {
                let (mut stream, _) = command_listener.accept().unwrap();
                let mut received = [0_u8; 32];
                let read = stream.read(&mut received).unwrap();
                assert_eq!(&received[..read], request);
                stream.write_all(response).unwrap();
            }
        });

        let capabilities = probe_with_environment(
            Some(runtime_dir.as_os_str()),
            Some(OsStr::new("test-instance")),
        )
        .await;
        server.join().unwrap();

        assert_eq!(capabilities.availability, HyprlandAvailability::Available);
        assert_eq!(capabilities.version.as_deref(), Some("0.56.2"));
        assert!(capabilities.can_query_workspaces);
        assert!(capabilities.can_receive_events);
    }

    #[test]
    fn parses_only_non_empty_structured_version_values() {
        assert_eq!(
            parse_version_value(serde_json::json!({"tag": " v0.56.2 "})).as_deref(),
            Some("v0.56.2")
        );
        assert_eq!(parse_version_value(serde_json::json!({"tag": ""})), None);
        assert_eq!(
            parse_version_value(serde_json::json!(["not an object"])),
            None
        );
    }

    fn fixture_workspaces() -> serde_json::Value {
        serde_json::json!([
            {
                "id": 1,
                "name": "1",
                "monitor": "eDP-1",
                "monitorId": 0,
                "windows": 1,
                "hasfullscreen": false,
                "lastwindow": "0x55f0aaaa",
                "lastwindowtitle": "Editor",
                "unknownFutureField": {"nested": true}
            },
            {
                "id": 2,
                "name": "2",
                "monitor": "DP-1",
                "windows": 1
            },
            {
                "id": -1337,
                "name": "special:notes",
                "monitor": "eDP-1",
                "windows": 0
            }
        ])
    }

    fn fixture_windows() -> serde_json::Value {
        serde_json::json!([
            {
                "address": "0x55f0aaaa",
                "mapped": true,
                "hidden": false,
                "workspace": {"id": 1, "name": "1"},
                "title": "Editor - velora",
                "class": "code",
                "floating": false,
                "fullscreen": 0,
                "urgent": false,
                "pid": 4242,
                "xwayland": false
            },
            {
                "address": "0x55f0bbbb",
                "mapped": true,
                "workspace": {"id": 2, "name": "2"},
                "title": "Terminal",
                "class": "foot",
                "floating": true,
                "fullscreen": true,
                "urgent": true
            },
            {
                "address": "0x55f0cccc",
                "mapped": false,
                "workspace": {"id": 1, "name": "1"},
                "title": "unmapped window is skipped"
            },
            {
                "address": "0x55f0dddd",
                "mapped": true,
                "workspace": {"id": 99, "name": "99"},
                "title": "orphaned workspace window is skipped"
            }
        ])
    }

    fn normalized_fixture_snapshot() -> WorkspaceSnapshot {
        normalize_session_snapshot(
            5,
            &fixture_workspaces(),
            &fixture_windows(),
            &serde_json::json!({"id": 2, "name": "2", "monitor": "DP-1"}),
            &serde_json::json!({"address": "0x55f0bbbb", "workspace": {"id": 2}}),
        )
        .unwrap()
    }

    #[test]
    fn normalizes_workspaces_windows_and_active_state() {
        let snapshot = normalized_fixture_snapshot();

        assert_eq!(snapshot.sequence, 5);
        assert_eq!(snapshot.workspaces.len(), 3);
        assert_eq!(snapshot.windows.len(), 2);

        let first = snapshot
            .workspaces
            .iter()
            .find(|workspace| workspace.handle == "workspace:1")
            .unwrap();
        assert_eq!(first.name, "1");
        assert_eq!(first.monitor.as_deref(), Some("eDP-1"));
        assert_eq!(first.window_count, 1);
        assert!(!first.is_special);

        let special = snapshot
            .workspaces
            .iter()
            .find(|workspace| workspace.handle == "workspace:-1337")
            .unwrap();
        assert!(special.is_special);
        assert_eq!(special.window_count, 0);

        let second = snapshot
            .workspaces
            .iter()
            .find(|workspace| workspace.handle == "workspace:2")
            .unwrap();
        assert!(second.is_active);
        assert!(second.is_urgent);

        let terminal = snapshot
            .windows
            .iter()
            .find(|window| window.class == "foot")
            .unwrap();
        assert_eq!(terminal.workspace_handle, "workspace:2");
        assert!(terminal.is_active);
        assert!(terminal.is_floating);
        assert!(terminal.is_fullscreen);

        let editor = snapshot
            .windows
            .iter()
            .find(|window| window.class == "code")
            .unwrap();
        assert!(!editor.is_active);
        assert_eq!(
            snapshot.active_workspace_handle.as_deref(),
            Some("workspace:2")
        );
        assert_eq!(snapshot.active_window_handle, Some(terminal.handle.clone()));
        snapshot.validate().unwrap();
    }

    #[test]
    fn tolerates_missing_and_malformed_entries() {
        let snapshot = normalize_session_snapshot(
            1,
            &serde_json::json!([
                {"id": 3},
                {"name": "no id"},
                {"id": "not-a-number", "name": "4"},
                "garbage",
                {"id": 4, "name": "", "monitor": ""}
            ]),
            &serde_json::json!([
                {"mapped": true, "workspace": {"id": 3}},
                {"address": "", "workspace": {"id": 3}},
                {"address": "0xff01", "workspace": {"id": null}},
                {"address": "0xff02", "workspace": "corrupt"},
                {"address": "0xff03", "workspace": {"id": 3}, "title": 42}
            ]),
            &serde_json::json!({}),
            &serde_json::json!({}),
        )
        .unwrap();

        assert_eq!(snapshot.workspaces.len(), 2);
        assert!(
            snapshot
                .workspaces
                .iter()
                .any(|w| w.handle == "workspace:3")
        );
        assert_eq!(snapshot.workspaces[0].name, "3");

        assert_eq!(snapshot.windows.len(), 1);
        assert_eq!(snapshot.windows[0].workspace_handle, "workspace:3");
        assert_eq!(snapshot.workspaces[0].window_count, 1);
        assert!(snapshot.active_workspace_handle.is_none());
        assert!(snapshot.active_window_handle.is_none());
    }

    #[test]
    fn malformed_top_level_responses_are_typed_errors() {
        let error = normalize_session_snapshot(
            1,
            &serde_json::json!({"unexpected": "shape"}),
            &serde_json::json!([]),
            &serde_json::json!({}),
            &serde_json::json!({}),
        )
        .unwrap_err();
        assert!(error.to_string().contains("not an array"));

        assert!(
            normalize_session_snapshot(
                1,
                &serde_json::json!([]),
                &serde_json::json!("not an array either"),
                &serde_json::json!({}),
                &serde_json::json!({}),
            )
            .is_err()
        );
    }

    #[test]
    fn oversized_collections_are_rejected() {
        let many_workspaces: Vec<_> = (0..=MAX_WORKSPACES)
            .map(|id| serde_json::json!({"id": id, "name": id.to_string()}))
            .collect();
        assert!(matches!(
            normalize_session_snapshot(
                1,
                &serde_json::json!(many_workspaces),
                &serde_json::json!([]),
                &serde_json::json!({}),
                &serde_json::json!({}),
            ),
            Err(AdapterError::TooManyWorkspaces)
        ));

        let mut workspaces = Vec::new();
        for id in 0..MAX_WORKSPACES {
            workspaces.push(serde_json::json!({"id": id, "name": id.to_string()}));
        }
        let mut clients = Vec::new();
        for id in 0..=MAX_WINDOWS {
            clients.push(serde_json::json!({
                "address": format!("0x{id:x}"),
                "mapped": true,
                "workspace": {"id": 0}
            }));
        }
        assert!(matches!(
            normalize_session_snapshot(
                1,
                &serde_json::json!(workspaces),
                &serde_json::json!(clients),
                &serde_json::json!({}),
                &serde_json::json!({}),
            ),
            Err(AdapterError::TooManyWindows)
        ));
    }

    #[test]
    fn window_handles_are_opaque_stable_and_collision_free() {
        let snapshot = normalized_fixture_snapshot();

        for window in &snapshot.windows {
            assert!(!window.handle.contains("0x"));
            assert!(window.handle.starts_with("window:"));
        }
        let again = normalized_fixture_snapshot();
        let editor = |snapshot: &WorkspaceSnapshot| {
            snapshot
                .windows
                .iter()
                .find(|window| window.class == "code")
                .unwrap()
                .handle
                .clone()
        };
        assert_eq!(editor(&snapshot), editor(&again));
        assert_ne!(
            editor(&snapshot),
            snapshot
                .windows
                .iter()
                .find(|window| window.class == "foot")
                .unwrap()
                .handle
        );
    }

    #[test]
    fn active_references_outside_the_snapshot_are_dropped() {
        let snapshot = normalize_session_snapshot(
            1,
            &fixture_workspaces(),
            &fixture_windows(),
            &serde_json::json!({"id": 77, "name": "77"}),
            &serde_json::json!({"address": "0xdeadbeef"}),
        )
        .unwrap();

        assert!(snapshot.active_workspace_handle.is_none());
        assert!(snapshot.active_window_handle.is_none());
        assert!(
            snapshot
                .workspaces
                .iter()
                .all(|workspace| !workspace.is_active)
        );
        assert!(snapshot.windows.iter().all(|window| !window.is_active));
    }

    #[test]
    fn strings_are_trimmed_and_char_bounded() {
        let long_title: String = "🦀".repeat(MAX_WINDOW_TITLE_CHARS + 50);
        let snapshot = normalize_session_snapshot(
            1,
            &serde_json::json!([{"id": 1, "name": "  padded  "}]),
            &serde_json::json!([{
                "address": "0x1",
                "mapped": true,
                "workspace": {"id": 1},
                "title": long_title,
                "class": " x "
            }]),
            &serde_json::json!({}),
            &serde_json::json!({}),
        )
        .unwrap();

        assert_eq!(snapshot.workspaces[0].name, "padded");
        assert_eq!(
            snapshot.windows[0].title.chars().count(),
            MAX_WINDOW_TITLE_CHARS
        );
        assert_eq!(snapshot.windows[0].class, "x");
    }

    #[tokio::test]
    async fn read_session_snapshot_queries_the_command_socket_only() {
        let directory = tempdir().unwrap();
        let instance_directory = directory.path().join("hypr/test-instance");
        fs::create_dir_all(&instance_directory).unwrap();
        let command_path = instance_directory.join(COMMAND_SOCKET_NAME);
        let command_listener = StdUnixListener::bind(&command_path).unwrap();

        let server = thread::spawn(move || {
            for (request, response) in [
                (
                    WORKSPACES_REQUEST,
                    fixture_workspaces().to_string().as_bytes(),
                ),
                (WINDOWS_REQUEST, fixture_windows().to_string().as_bytes()),
                (
                    ACTIVE_WORKSPACE_REQUEST,
                    br#"{"id": 2, "name": "2"}"#.as_slice(),
                ),
                (
                    ACTIVE_WINDOW_REQUEST,
                    br#"{"address": "0x55f0bbbb"}"#.as_slice(),
                ),
            ] {
                let (mut stream, _) = command_listener.accept().unwrap();
                let mut received = [0_u8; 32];
                let read = stream.read(&mut received).unwrap();
                assert_eq!(&received[..read], request);
                stream.write_all(response).unwrap();
            }
        });

        let snapshot = read_session_snapshot(&command_path, 9).await.unwrap();
        server.join().unwrap();

        assert_eq!(snapshot.sequence, 9);
        assert_eq!(snapshot.workspaces.len(), 3);
        assert_eq!(snapshot.windows.len(), 2);
        assert_eq!(
            snapshot.active_workspace_handle.as_deref(),
            Some("workspace:2")
        );
        snapshot.validate().unwrap();
    }

    #[tokio::test]
    async fn unreachable_socket_is_a_query_error() {
        let directory = tempdir().unwrap();
        let missing = directory.path().join("missing.sock");
        assert!(matches!(
            read_session_snapshot(&missing, 1).await,
            Err(AdapterError::Query(_))
        ));
    }
}
