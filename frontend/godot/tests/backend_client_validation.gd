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
	var capability_request := _message_at(bridge, bridge.sent_lines.size() - 2)
	var snapshot_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	_check(
		capability_request.get("type") == "get_hyprland_capabilities"
		and snapshot_request.get("type") == "get_workspace_snapshot",
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

	backend.queue_free()
	await process_frame
	if failures.is_empty():
		print("P2.10 BackendClient validation passed.")
		quit(0)
	else:
		push_error("P2.10 BackendClient validation failed: %s" % [failures])
		quit(1)
