extends SceneTree

class FakeBridge:
	extends Node

	signal socket_connected
	signal socket_disconnected(reason: String)
	signal line_received(payload: String)
	signal transport_error(code: String, message: String)

	var sent_lines: Array[String] = []
	var connected_path := ""
	var disconnected := false

	func default_socket_path() -> String:
		return "/tmp/velora-fake.sock"

	func connect_socket(path: String) -> bool:
		connected_path = path
		return true

	func disconnect_socket() -> void:
		disconnected = true

	func send_line(payload: String) -> bool:
		sent_lines.append(payload)
		return true

var failures: Array[String] = []
var last_ux_stage := ""
var last_ux_message := ""
var last_ux_tone := ""

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func _on_ux_status(stage: String, message: String, tone: String, _seconds: float) -> void:
	last_ux_stage = stage
	last_ux_message = message
	last_ux_tone = tone

func _message_at(bridge: FakeBridge, index: int) -> Dictionary:
	if index < 0 or index >= bridge.sent_lines.size():
		return {}
	var value = JSON.parse_string(bridge.sent_lines[index])
	return value if value is Dictionary else {}

func _last_request_of_type(bridge: FakeBridge, request_type: String) -> Dictionary:
	for index in range(bridge.sent_lines.size() - 1, -1, -1):
		var candidate := _message_at(bridge, index)
		if candidate.get("type") == request_type:
			return candidate
	return {}

func _run() -> void:
	var bridge := FakeBridge.new()
	var backend := BackendClient.new()
	backend.auto_connect = false
	backend.bridge_override = bridge
	backend.ux_status_changed.connect(_on_ux_status)
	root.add_child(backend)
	await process_frame

	_check(
		backend.state == BackendClient.ConnectionState.DISCONNECTED,
		"P2.10 injected client starts offline"
	)
	backend.connect_to_core()
	_check(
		backend.state == BackendClient.ConnectionState.CONNECTING,
		"P2.10 connect request enters connecting state"
	)
	_check(
		bridge.connected_path == "/tmp/velora-fake.sock",
		"P2.10 client uses the bridge-provided socket path"
	)

	bridge.socket_connected.emit()
	_check(
		backend.state == BackendClient.ConnectionState.HANDSHAKING,
		"P2.10 socket connection enters handshaking state"
	)
	var hello := _message_at(bridge, 0)
	_check(
		hello.get("type") == "hello"
		and hello.get("protocol_version") == BackendClient.PROTOCOL_VERSION,
		"P2.10 handshake request is typed and versioned"
	)

	bridge.line_received.emit(JSON.stringify({
		"type": "welcome",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"server_name": "velora-core-test",
		"server_version": "0.2.0",
	}))
	_check(
		backend.state == BackendClient.ConnectionState.READY,
		"P2.10 welcome transitions the client to ready"
	)
	var list_request := _message_at(bridge, 1)
	_check(
		list_request.get("type") == "list_applications"
		and list_request.get("offset") == 0
		and list_request.get("limit") == BackendClient.APPLICATION_PAGE_SIZE,
		"P2.10 ready state requests the first registry page"
	)

	bridge.line_received.emit(JSON.stringify({
		"type": "applications",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": list_request.get("request_id"),
		"applications": [{
			"id": "code.desktop",
			"name": "Visual Studio Code",
			"exec": "/usr/bin/code",
			"icon": "visual-studio-code",
			"categories": ["Development"],
			"terminal": false,
		}],
		"next_offset": null,
		"total": 1,
	}))
	_check(
		backend.applications.size() == 1
		and backend.applications[0].get("id") == "code.desktop",
		"P2.10 registry response is normalized and stored"
	)

	_check(backend.launch_app("code.desktop"), "P2.10 ready client accepts a launch request")
	var launch_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	_check(
		launch_request.get("type") == "launch_application"
		and launch_request.get("protocol_version") == BackendClient.PROTOCOL_VERSION
		and int(launch_request.get("request_id", 0)) > 0
		and launch_request.get("desktop_id") == "code.desktop",
		"P2.10 launch request contains only the typed desktop ID boundary"
	)

	bridge.line_received.emit(JSON.stringify({
		"type": "launch_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": launch_request.get("request_id"),
		"desktop_id": "code.desktop",
		"code": "launch_rate_limited",
		"message": "backend detail must not leak into the compact HUD",
		"retryable": true,
	}))
	_check(
		last_ux_stage == "launch_failed"
		and last_ux_message == "PLEASE WAIT AND RETRY"
		and last_ux_tone == "failure",
		"P2.10 launch errors use concise recoverable feedback"
	)

	_check(backend.request_applications(), "P2.10 registry can be requested again")
	var malformed_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	bridge.line_received.emit(JSON.stringify({
		"type": "applications",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": malformed_request.get("request_id"),
		"applications": "not-an-array",
		"next_offset": null,
		"total": 1,
	}))
	_check(
		last_ux_stage == "registry_failed"
		and last_ux_message == "INVALID APPLICATION DATA"
		and last_ux_tone == "failure",
		"P2.10 malformed registry data produces visible concise feedback"
	)
	_check(
		backend._application_request_id == 0 and backend._pending_applications.is_empty(),
		"P2.10 malformed registry data clears pending state for retry"
	)

	bridge.socket_disconnected.emit("test disconnect")
	_check(
		backend.state == BackendClient.ConnectionState.RECONNECTING,
		"P2.10 unexpected disconnect enters reconnecting state"
	)

	var snapshot_emissions := [0]
	var availability_emissions := [0]
	var last_availability := [""]
	backend.session_snapshot_changed.connect(func(_snapshot: Dictionary) -> void:
		snapshot_emissions[0] += 1
	)
	backend.session_availability_changed.connect(func(availability: String) -> void:
		availability_emissions[0] += 1
		last_availability[0] = availability
	)

	bridge.socket_connected.emit()
	var welcome_again := _message_at(bridge, 0)
	bridge.line_received.emit(JSON.stringify({
		"type": "welcome",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"server_name": "velora-core-test",
		"server_version": "0.2.0",
	}))
	var capability_request := _last_request_of_type(bridge, "get_hyprland_capabilities")
	var snapshot_request := _last_request_of_type(bridge, "get_workspace_snapshot")
	_check(
		not capability_request.is_empty() and not snapshot_request.is_empty(),
		"P3.06 ready state requests Hyprland capabilities and a session snapshot"
	)

	bridge.line_received.emit(JSON.stringify({
		"type": "hyprland_capabilities",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": capability_request.get("request_id"),
		"capabilities": {
			"availability": "available",
			"version": "0.56.2",
			"can_query_workspaces": true,
			"can_query_windows": true,
			"can_query_active_workspace": true,
			"can_query_active_window": true,
			"can_receive_events": true,
		},
	}))
	_check(
		backend.session_availability == "available" and availability_emissions[0] == 1,
		"P3.06 available capabilities update the typed session availability"
	)

	var first_snapshot := {
		"sequence": 1,
		"workspaces": [{
			"handle": "workspace:1",
			"name": "1",
			"index": 1,
			"monitor": "eDP-1",
			"window_count": 1,
			"is_active": true,
			"is_special": false,
			"is_urgent": false,
		}],
		"windows": [{
			"handle": "window:abc",
			"workspace_handle": "workspace:1",
			"title": "Editor",
			"class": "code",
			"is_active": true,
			"is_floating": false,
			"is_fullscreen": false,
		}],
		"active_workspace_handle": "workspace:1",
		"active_window_handle": "window:abc",
	}
	bridge.line_received.emit(JSON.stringify({
		"type": "workspace_snapshot",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": snapshot_request.get("request_id"),
		"snapshot": first_snapshot,
	}))
	_check(
		backend.session_snapshot.get("sequence") == 1 and snapshot_emissions[0] == 1,
		"P3.06 valid snapshots are normalized, stored, and signalled"
	)
	_check(
		backend._session_request_id == 0,
		"P3.06 fulfilled snapshot requests clear their correlation ID"
	)

	bridge.line_received.emit(JSON.stringify({
		"type": "workspace_snapshot",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 9999,
		"snapshot": first_snapshot,
	}))
	_check(
		snapshot_emissions[0] == 1
		and backend.session_snapshot.get("sequence") == 1,
		"P3.06 stale or equal sequences are ignored as fencing tokens"
	)

	bridge.line_received.emit(JSON.stringify({
		"type": "workspace_snapshot",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 0,
		"snapshot": {"sequence": 2, "workspaces": [], "windows": [
			{"handle": "w", "workspace_handle": "workspace:missing", "title": "", "class": "",
				"is_active": false, "is_floating": false, "is_fullscreen": false},
		]},
	}))
	_check(
		last_ux_stage == "session_failed" and last_ux_message == "INVALID SESSION DATA",
		"P3.06 malformed snapshots produce concise visible feedback"
	)
	_check(
		backend.session_snapshot.get("sequence") == 1,
		"P3.06 malformed snapshots never replace last good state"
	)

	var second_snapshot = first_snapshot.duplicate(true)
	second_snapshot["sequence"] = 2
	second_snapshot["active_window_handle"] = null
	bridge.line_received.emit(JSON.stringify({
		"type": "workspace_snapshot",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 0,
		"snapshot": second_snapshot,
	}))
	_check(
		backend.session_snapshot.get("sequence") == 2 and snapshot_emissions[0] == 2,
		"P3.06 newer snapshots replace state even when unprompted"
	)

	for _attempt in 2:
		bridge.line_received.emit(JSON.stringify({
			"type": "workspace_snapshot_rejected",
			"protocol_version": BackendClient.PROTOCOL_VERSION,
			"request_id": 0,
			"code": "hyprland_unavailable",
			"retryable": true,
		}))
	_check(
		backend.session_availability == "unavailable" and availability_emissions[0] == 2,
		"P3.06 unavailability is reported once without log spam"
	)

	bridge.socket_disconnected.emit("test disconnect")
	_check(
		not backend.session_snapshot.is_empty()
		and int(backend.session_snapshot.get("sequence", 0)) == 2,
		"P3.06 reconnects preserve the last useful session state"
	)

	var switch_accepts: Array[String] = []
	var switch_rejections: Array[String] = []
	backend.switch_accepted.connect(func(handle: String) -> void:
		switch_accepts.append(handle)
	)
	backend.switch_rejected.connect(func(handle: String, _code: String, _message: String, _retryable: bool) -> void:
		switch_rejections.append(handle)
	)

	bridge.socket_connected.emit()
	bridge.line_received.emit(JSON.stringify({
		"type": "welcome",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"server_name": "velora-core-test",
		"server_version": "0.2.0",
	}))
	_check(
		backend.request_switch_workspace("workspace:3"),
		"P3.09 ready client accepts a typed switch request"
	)
	var switch_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	_check(
		switch_request.get("type") == "switch_workspace"
		and switch_request.get("workspace_handle") == "workspace:3"
		and int(switch_request.get("request_id", 0)) > 0
		and not switch_request.has("dispatcher_command"),
		"P3.09 switch requests carry only the opaque snapshot handle"
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "switch_accepted",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": switch_request.get("request_id"),
		"workspace_handle": "workspace:3",
	}))
	_check(
		switch_accepts == ["workspace:3"] and backend._switch_request_id == 0,
		"P3.09 correlated acceptance clears pending state"
	)

	_check(backend.request_switch_workspace("workspace:4"), "P3.09 a second switch can be requested")
	var second_switch := _message_at(bridge, bridge.sent_lines.size() - 1)
	bridge.line_received.emit(JSON.stringify({
		"type": "switch_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": second_switch.get("request_id"),
		"workspace_handle": "workspace:4",
		"code": "unknown_workspace_handle",
	}))
	_check(
		switch_rejections == ["workspace:4"]
		and last_ux_message == "WORKSPACE NO LONGER EXISTS",
		"P3.09 rejections surface concise recoverable feedback"
	)

	_check(
		not backend.request_switch_workspace(""),
		"P3.09 empty handles are rejected locally without a request"
	)

	var focus_accepts: Array[String] = []
	var focus_rejections: Array[String] = []
	backend.focus_accepted.connect(func(handle: String) -> void:
		focus_accepts.append(handle)
	)
	backend.focus_rejected.connect(func(handle: String, _code: String, _message: String, _retryable: bool) -> void:
		focus_rejections.append(handle)
	)
	_check(
		backend.request_focus_window("window:abc"),
		"P3.10 ready client accepts a typed focus request"
	)
	var focus_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	_check(
		focus_request.get("type") == "focus_window"
		and focus_request.get("window_handle") == "window:abc"
		and not focus_request.has("address"),
		"P3.10 focus requests carry only the opaque snapshot handle"
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "focus_accepted",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": focus_request.get("request_id"),
		"window_handle": "window:abc",
	}))
	_check(
		focus_accepts == ["window:abc"] and backend._focus_request_id == 0,
		"P3.10 correlated focus acceptance clears pending state"
	)

	_check(backend.request_focus_window("window:stale"), "P3.10 a stale-handle retry can be requested")
	var stale_focus := _message_at(bridge, bridge.sent_lines.size() - 1)
	bridge.line_received.emit(JSON.stringify({
		"type": "focus_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": stale_focus.get("request_id"),
		"window_handle": "window:stale",
		"code": "unknown_window_handle",
	}))
	_check(
		focus_rejections == ["window:stale"]
		and last_ux_message == "WINDOW NO LONGER EXISTS",
		"P3.10 stale window handles fail with concise recoverable feedback"
	)

	bridge.socket_disconnected.emit("test disconnect")
	bridge.socket_connected.emit()
	bridge.line_received.emit(JSON.stringify({
		"type": "welcome",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"server_name": "velora-core-test",
		"server_version": "0.2.0",
	}))
	_check(
		backend.request_focus_window("window:fresh"),
		"P3.10 reconnect resets pending focus state for new requests"
	)

	# --- P5.02 typed media and notification protocol v5 ---
	_check(
		BackendClient.PROTOCOL_VERSION == 5,
		"P5.02 client locks to the v5 exact-match protocol"
	)
	var media_request := _last_request_of_type(bridge, "get_media_snapshot")
	var notifications_request := _last_request_of_type(bridge, "get_notifications")
	_check(
		media_request.get("protocol_version") == 5
		and notifications_request.get("protocol_version") == 5,
		"P5.02 welcome requests typed v5 media and notification snapshots"
	)
	_check(
		not backend.request_media_snapshot() and not backend.request_notifications(),
		"P5.02 snapshot requests stay single-flight while a response is pending"
	)

	var media_availability_emissions := [0]
	var last_media_availability := [""]
	backend.media_availability_changed.connect(func(availability: String) -> void:
		media_availability_emissions[0] += 1
		last_media_availability[0] = availability
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": media_request.get("request_id"),
		"code": "media_unavailable",
		"retryable": false,
	}))
	_check(
		backend.media_availability == "unavailable" and media_availability_emissions[0] == 1,
		"P5.02 the typed media-unavailable path reports availability once"
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 424242,
		"code": "media_unavailable",
		"retryable": false,
	}))
	_check(
		media_availability_emissions[0] == 1,
		"P5.02 repeated media unavailability stays silent without log spam"
	)

	_check(backend.request_media_snapshot(), "P5.02 media snapshots can be requested on demand")
	var waiting_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 999999,
		"code": "snapshot_not_ready",
		"retryable": true,
	}))
	_check(
		backend._media_request_id != 0 and backend.media_availability == "unavailable",
		"P5.02 stale rejections are fenced while a correlated request is pending"
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": waiting_request.get("request_id"),
		"code": "snapshot_not_ready",
		"retryable": true,
	}))
	_check(
		backend.media_availability == "waiting" and media_availability_emissions[0] == 2,
		"P5.02 snapshot-not-ready maps to a waiting availability"
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 424243,
		"code": "media_unavailable",
		"retryable": false,
	}))
	_check(
		backend.media_availability == "waiting" and media_availability_emissions[0] == 2,
		"P5.02 uncorrelated media rejections never mutate availability"
	)

	_check(backend.request_media_snapshot(), "P5.02 media snapshot request can be re-issued")
	var media_snapshot_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	var media_emissions := [0]
	backend.media_snapshot_changed.connect(func(_snapshot: Dictionary) -> void:
		media_emissions[0] += 1
	)
	var media_player := {
		"handle": "player:opaque-1",
		"identity": "Velora Test Player",
		"status": "playing",
		"title": "Velora Theme",
		"artist": "Velora",
		"album": null,
		"length_micros": 250000000,
		"position_micros": 12500000,
		"can_play": true,
		"can_pause": true,
		"can_go_next": true,
		"can_go_previous": false,
		"can_seek": false,
		"can_control": true,
	}
	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": media_snapshot_request.get("request_id"),
		"snapshot": {
			"sequence": 3,
			"players": [media_player],
			"active_player_handle": "player:opaque-1",
		},
	}))
	_check(
		backend.media_snapshot.get("sequence") == 3 and media_emissions[0] == 1,
		"P5.02 valid media snapshots are normalized, stored, and signalled"
	)
	_check(
		backend._media_request_id == 0,
		"P5.02 fulfilled media requests clear their correlation ID"
	)
	_check(
		backend.media_availability == "available" and media_availability_emissions[0] == 3,
		"P5.02 a served snapshot restores the typed media availability"
	)
	_check(
		String(backend.media_snapshot["players"][0].get("status")) == "playing"
		and bool(backend.media_snapshot["players"][0].get("can_go_previous")) == false
		and String(backend.media_snapshot["players"][0].get("album")) == "",
		"P5.02 player records preserve status, flags, and absent metadata"
	)

	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 0,
		"snapshot": {
			"sequence": 3,
			"players": [media_player],
			"active_player_handle": "player:opaque-1",
		},
	}))
	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 0,
		"snapshot": {
			"sequence": 2,
			"players": [],
			"active_player_handle": null,
		},
	}))
	_check(
		media_emissions[0] == 1 and int(backend.media_snapshot.get("sequence", 0)) == 3,
		"P5.02 equal or older media sequences are ignored as fencing tokens"
	)

	var second_media_player = media_player.duplicate(true)
	second_media_player["handle"] = "player:opaque-2"
	second_media_player["identity"] = "Second Player"
	second_media_player["status"] = "paused"
	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 0,
		"snapshot": {
			"sequence": 4,
			"players": [media_player, second_media_player],
			"active_player_handle": "player:opaque-2",
		},
	}))
	_check(
		media_emissions[0] == 2
		and backend.media_snapshot["players"].size() == 2
		and String(backend.media_snapshot.get("active_player_handle")) == "player:opaque-2",
		"P5.02 newer unprompted media snapshots replace state without polling"
	)

	var media_player_missing_flag = media_player.duplicate(true)
	media_player_missing_flag.erase("can_seek")
	var too_many_players: Array = []
	for index in range(BackendClient.MAX_MEDIA_PLAYERS + 1):
		var bounded_player = media_player.duplicate(true)
		bounded_player["handle"] = "player:opaque-%d" % index
		too_many_players.append(bounded_player)
	var long_title_player = media_player.duplicate(true)
	long_title_player["title"] = "t".repeat(BackendClient.MAX_STRING_BYTES + 1)
	var malformed_media_snapshots := [
		{"sequence": 5, "players": [media_player], "active_player_handle": "player:missing"},
		{"sequence": 5, "players": [media_player, media_player], "active_player_handle": null},
		{"sequence": 5, "players": too_many_players, "active_player_handle": null},
		{"sequence": 5, "players": [media_player_missing_flag], "active_player_handle": null},
		{"sequence": 5, "players": [long_title_player], "active_player_handle": null},
	]
	for malformed_snapshot in malformed_media_snapshots:
		bridge.line_received.emit(JSON.stringify({
			"type": "media_snapshot",
			"protocol_version": BackendClient.PROTOCOL_VERSION,
			"request_id": 0,
			"snapshot": malformed_snapshot,
		}))
	_check(
		last_ux_stage == "media_failed" and last_ux_message == "INVALID MEDIA DATA",
		"P5.02 malformed media snapshots produce concise visible feedback"
	)
	_check(
		media_emissions[0] == 2 and int(backend.media_snapshot.get("sequence", 0)) == 4,
		"P5.02 malformed media snapshots never replace last good state"
	)

	var notifications_availability_emissions := [0]
	var last_notifications_availability := [""]
	backend.notifications_availability_changed.connect(func(availability: String) -> void:
		notifications_availability_emissions[0] += 1
		last_notifications_availability[0] = availability
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "notifications_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": notifications_request.get("request_id"),
		"code": "notifications_unavailable",
		"retryable": false,
	}))
	_check(
		backend.notifications_availability == "unavailable"
		and notifications_availability_emissions[0] == 1,
		"P5.02 the typed notifications-unavailable path reports availability once"
	)

	_check(backend.request_notifications(), "P5.02 notification feed can be requested on demand")
	var feed_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	bridge.line_received.emit(JSON.stringify({
		"type": "notifications_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": feed_request.get("request_id"),
		"code": "monitor_restricted",
		"retryable": true,
	}))
	_check(
		backend.notifications_availability == "restricted"
		and notifications_availability_emissions[0] == 2,
		"P5.02 monitor-restricted notification paths surface a typed availability"
	)

	_check(backend.request_notifications(), "P5.02 notification feed can be requested again")
	feed_request = _message_at(bridge, bridge.sent_lines.size() - 1)
	var feed_emissions := [0]
	backend.notification_feed_changed.connect(func(_feed: Dictionary) -> void:
		feed_emissions[0] += 1
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "notifications",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": feed_request.get("request_id"),
		"feed": {
			"sequence": 7,
			"notifications": [
				{
					"handle": "notification:opaque-1",
					"app_name": "Velora",
					"summary": "Build complete",
					"body": "The release gate passed.",
					"urgency": "normal",
					"timestamp_unix_ms": 1777777777000,
				},
				{
					"handle": "notification:opaque-2",
					"app_name": "Velora",
					"summary": "Disk space low",
					"body": "",
					"urgency": "critical",
					"timestamp_unix_ms": 1777777778000,
				},
			],
		},
	}))
	_check(
		backend.notification_feed.get("sequence") == 7 and feed_emissions[0] == 1,
		"P5.02 valid notification feeds are normalized, stored, and signalled"
	)
	_check(
		backend._notifications_request_id == 0
		and backend.notifications_availability == "available"
		and notifications_availability_emissions[0] == 3,
		"P5.02 a served feed clears its request and restores availability"
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "notifications_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 424243,
		"code": "notifications_unavailable",
		"retryable": false,
	}))
	_check(
		backend.notifications_availability == "available"
		and notifications_availability_emissions[0] == 3,
		"P5.02 uncorrelated notification rejections never mutate availability"
	)
	_check(
		backend.notification_feed["notifications"].size() == 2
		and String(backend.notification_feed["notifications"][1].get("urgency")) == "critical",
		"P5.02 notification records preserve urgency levels"
	)

	var duplicate_notification := {
		"handle": "notification:opaque-1",
		"app_name": "Velora",
		"summary": "Duplicate",
		"body": "",
		"urgency": "low",
		"timestamp_unix_ms": 1,
	}
	var bad_urgency_notification := {
		"handle": "notification:opaque-3",
		"app_name": "Velora",
		"summary": "Bad urgency",
		"body": "",
		"urgency": "silent",
		"timestamp_unix_ms": 1,
	}
	var too_many_notifications: Array = []
	for index in range(BackendClient.MAX_NOTIFICATIONS + 1):
		too_many_notifications.append({
			"handle": "notification:opaque-%d" % (index + 10),
			"app_name": "Velora",
			"summary": "Flood",
			"body": "",
			"urgency": "low",
			"timestamp_unix_ms": index,
		})
	var long_summary_notification := {
		"handle": "notification:opaque-long",
		"app_name": "Velora",
		"summary": "s".repeat(BackendClient.MAX_STRING_BYTES + 1),
		"body": "",
		"urgency": "low",
		"timestamp_unix_ms": 1,
	}
	var malformed_feeds := [
		{"sequence": 8, "notifications": [bad_urgency_notification]},
		{"sequence": 8, "notifications": [duplicate_notification, duplicate_notification]},
		{"sequence": 8, "notifications": too_many_notifications},
		{"sequence": 8, "notifications": [long_summary_notification]},
	]
	for malformed_feed in malformed_feeds:
		bridge.line_received.emit(JSON.stringify({
			"type": "notifications",
			"protocol_version": BackendClient.PROTOCOL_VERSION,
			"request_id": 0,
			"feed": malformed_feed,
		}))
	bridge.line_received.emit(JSON.stringify({
		"type": "notifications",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 0,
		"feed": {"sequence": 6, "notifications": []},
	}))
	_check(
		last_ux_stage == "notifications_failed"
		and last_ux_message == "INVALID NOTIFICATION DATA",
		"P5.02 malformed notification feeds produce concise visible feedback"
	)
	_check(
		feed_emissions[0] == 1 and int(backend.notification_feed.get("sequence", 0)) == 7,
		"P5.02 malformed or stale feeds never replace last good state"
	)

	var media_control_accepts: Array = []
	var media_control_rejections: Array = []
	backend.media_control_accepted.connect(func(player_handle: String, verb: String) -> void:
		media_control_accepts.append([player_handle, verb])
	)
	backend.media_control_rejected.connect(
		func(player_handle: String, verb: String, code: String, _message: String, _retryable: bool) -> void:
			media_control_rejections.append([player_handle, verb, code])
	)
	var sent_lines_before_control := bridge.sent_lines.size()
	_check(
		not backend.send_media_control("player:opaque-1", "open_uri"),
		"P5.02 non-allowlisted verbs are rejected locally"
	)
	_check(
		not backend.send_media_control("", "play"),
		"P5.02 empty player handles are rejected locally"
	)
	_check(
		bridge.sent_lines.size() == sent_lines_before_control
		and media_control_rejections.size() == 2,
		"P5.02 rejected verbs and handles never reach the wire"
	)

	_check(
		backend.send_media_control("player:opaque-2", "play_pause"),
		"P5.02 ready client accepts an allowlisted media control"
	)
	var control_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	_check(
		control_request.get("type") == "send_media_control"
		and control_request.get("protocol_version") == 5
		and control_request.get("player_handle") == "player:opaque-2"
		and control_request.get("verb") == "play_pause"
		and control_request.keys().size() == 5,
		"P5.02 control requests carry only the typed handle and verb boundary"
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_control_accepted",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 777777,
		"player_handle": "player:opaque-2",
	}))
	_check(
		backend._media_control_request_id != 0 and media_control_accepts.is_empty(),
		"P5.02 uncorrelated control acceptance is fenced out"
	)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_control_accepted",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": control_request.get("request_id"),
		"player_handle": "player:opaque-2",
	}))
	_check(
		media_control_accepts.size() == 1
		and media_control_accepts[0][0] == "player:opaque-2"
		and media_control_accepts[0][1] == "play_pause"
		and backend._media_control_request_id == 0,
		"P5.02 correlated acceptance clears pending state and echoes the verb"
	)

	_check(
		backend.send_media_control("player:opaque-1", "next"),
		"P5.02 a second control can be requested"
	)
	var stale_control := _message_at(bridge, bridge.sent_lines.size() - 1)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_control_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": stale_control.get("request_id"),
		"player_handle": "player:opaque-1",
		"code": "stale_handle",
	}))
	_check(
		media_control_rejections.size() == 3
		and media_control_rejections[2][2] == "stale_handle"
		and last_ux_message == "PLAYER STALE // REFRESH LIST",
		"P5.02 stale player handles fail with concise typed feedback"
	)

	_check(
		backend.send_media_control("player:opaque-1", "play"),
		"P5.02 a third control can be requested"
	)
	backend._update_launch_timeout(BackendClient.MEDIA_CONTROL_TIMEOUT_SECONDS + 0.1)
	_check(
		backend._media_control_request_id == 0
		and media_control_rejections.size() == 4
		and media_control_rejections[3][2] == "media_control_timeout",
		"P5.02 pending controls time out with retryable feedback"
	)

	_check(
		backend.send_media_control("player:gone", "stop"),
		"P5.02 control for an unknown player is sent"
	)
	var unknown_control := _message_at(bridge, bridge.sent_lines.size() - 1)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_control_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": unknown_control.get("request_id"),
		"player_handle": "player:gone",
		"code": "unknown_player",
	}))
	_check(
		media_control_rejections.size() == 5
		and media_control_rejections[4][2] == "unknown_player"
		and last_ux_message == "PLAYER NO LONGER EXISTS",
		"P5.02 unknown players fail with typed non-retryable feedback"
	)

	_check(
		backend.send_media_control("player:opaque-2", "pause"),
		"P5.02 control can be re-issued"
	)
	var unavailable_control := _message_at(bridge, bridge.sent_lines.size() - 1)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_control_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": unavailable_control.get("request_id"),
		"player_handle": "player:opaque-2",
		"code": "control_unavailable",
	}))
	_check(
		media_control_rejections.size() == 6
		and media_control_rejections[5][2] == "control_unavailable"
		and backend.media_availability == "available",
		"P5.02 control-unavailable is typed without flipping snapshot availability"
	)

	_check(
		backend.send_media_control("player:opaque-2", "next"),
		"P5.02 control while media is down can be requested"
	)
	var media_down_control := _message_at(bridge, bridge.sent_lines.size() - 1)
	bridge.line_received.emit(JSON.stringify({
		"type": "media_control_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": media_down_control.get("request_id"),
		"player_handle": "player:opaque-2",
		"code": "media_unavailable",
	}))
	_check(
		media_control_rejections.size() == 7
		and media_control_rejections[6][2] == "media_unavailable"
		and backend.media_availability == "unavailable"
		and media_availability_emissions[0] == 4,
		"P5.02 a media-unavailable control failure updates the availability"
	)

	_check(
		backend.send_media_control("player:opaque-2", "play"),
		"P5.02 a pending control can be left open"
	)
	bridge.socket_disconnected.emit("media test disconnect")
	_check(
		media_control_rejections.size() == 8
		and media_control_rejections[7][2] == "connection_lost",
		"P5.02 disconnects fail pending controls as retryable connection loss"
	)
	_check(
		not backend.media_snapshot.is_empty()
		and int(backend.media_snapshot.get("sequence", 0)) == 4
		and not backend.notification_feed.is_empty()
		and int(backend.notification_feed.get("sequence", 0)) == 7,
		"P5.02 reconnects preserve the last good media and notification state"
	)

	bridge.socket_connected.emit()
	bridge.line_received.emit(JSON.stringify({
		"type": "welcome",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"server_name": "velora-core-test",
		"server_version": "0.2.0",
	}))
	var refreshed_media_request := _last_request_of_type(bridge, "get_media_snapshot")
	var refreshed_notifications_request := _last_request_of_type(bridge, "get_notifications")
	_check(
		int(refreshed_media_request.get("request_id", 0)) > int(media_request.get("request_id", 0))
		and int(refreshed_notifications_request.get("request_id", 0)) > int(notifications_request.get("request_id", 0)),
		"P5.02 reconnect re-requests initial snapshots without adding polling"
	)

	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot",
		"protocol_version": 4,
		"request_id": 0,
		"snapshot": {"sequence": 99, "players": [], "active_player_handle": null},
	}))
	_check(
		backend.state == BackendClient.ConnectionState.INCOMPATIBLE,
		"P5.02 the exact-match handshake rejects any non-v5 media frame"
	)

	backend.queue_free()
	await process_frame
	if failures.is_empty():
		print("P2.10 BackendClient validation passed.")
		quit(0)
	else:
		push_error("P2.10 BackendClient validation failed: %s" % [failures])
		quit(1)
