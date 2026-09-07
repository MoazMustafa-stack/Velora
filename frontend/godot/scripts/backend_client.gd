class_name BackendClient
extends Node

signal connection_changed(message: String)
signal state_changed(state: ConnectionState)
signal latency_changed(milliseconds: int)
signal applications_changed(applications: Array)
signal application_state_changed(desktop_id: String, running: bool)
signal launch_finished(desktop_id: String, process_id: int)
signal launch_rejected(desktop_id: String, code: String, message: String, retryable: bool)
signal launch_status_changed(desktop_id: String, stage: String, message: String, retryable: bool)
signal ux_status_changed(stage: String, message: String, tone: String, transient_seconds: float)
signal session_snapshot_changed(snapshot: Dictionary)
signal session_availability_changed(availability: String)
signal switch_accepted(workspace_handle: String)
signal switch_rejected(workspace_handle: String, code: String, message: String, retryable: bool)
signal focus_accepted(window_handle: String)
signal focus_rejected(window_handle: String, code: String, message: String, retryable: bool)
signal telemetry_snapshot_changed(snapshot: Dictionary)
signal telemetry_availability_changed(availability: String)
signal media_snapshot_changed(snapshot: Dictionary)
signal media_availability_changed(availability: String)
signal media_control_accepted(player_handle: String, verb: String)
signal media_control_rejected(player_handle: String, verb: String, code: String, message: String, retryable: bool)
signal notification_feed_changed(feed: Dictionary)
signal notifications_availability_changed(availability: String)

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	HANDSHAKING,
	READY,
	RECONNECTING,
	INCOMPATIBLE,
}

# Phase 5 bumps the exact-match contract to v5 for the typed media and
# notification families. Core, the bridge, and this client move together.
const PROTOCOL_VERSION := 5
const CLIENT_NAME := "velora-godot"
const CLIENT_VERSION := "0.2.0"
const PING_INTERVAL_SECONDS := 5.0
const PONG_TIMEOUT_SECONDS := 3.0
const APPLICATION_PAGE_SIZE := 32
const LAUNCH_TIMEOUT_SECONDS := 5.0
const RECONNECT_DELAYS := [0.25, 0.5, 1.0, 2.0, 4.0]
const MAX_SESSION_WORKSPACES := 128
const MAX_SESSION_WINDOWS := 1024
const SWITCH_TIMEOUT_SECONDS := 5.0
const FOCUS_TIMEOUT_SECONDS := 5.0
const TELEMETRY_POLL_SECONDS := 1.0
const MAX_MEDIA_PLAYERS := 16
const MAX_NOTIFICATIONS := 32
const MAX_STRING_BYTES := 256
const MEDIA_CONTROL_TIMEOUT_SECONDS := 5.0
const PLAYBACK_STATUSES := ["playing", "paused", "stopped"]
const NOTIFICATION_URGENCIES := ["low", "normal", "critical"]
# The only control verbs this client may send. Core re-maps each verb onto the
# matching MPRIS method for the opaque player handle; bus names, method names,
# raw arguments, and shell commands never cross Velora IPC.
const MEDIA_CONTROL_VERBS := ["play", "pause", "play_pause", "stop", "next", "previous"]

@export var auto_connect := true

# Tests may provide a bridge with the same signal/method surface as the native
# GDExtension. Production leaves this null and instantiates VeloraSocketBridge.
var bridge_override: Node

var connected := false
var state := ConnectionState.DISCONNECTED
var last_requested_desktop_id := ""
var last_pong_request_id := 0
var welcome_received := false
var applications: Array[Dictionary] = []
# Last useful session state is intentionally kept across reconnects so the
# world keeps showing stale-but-labelled workspaces instead of going blank.
var session_snapshot: Dictionary = {}
var session_availability := "unknown"
var telemetry_snapshot: Dictionary = {}
var telemetry_availability := "unknown"
# Last good media and notification state is intentionally kept across
# reconnects so the UI keeps showing stale-but-labelled data instead of going
# blank; monotonic sequence fencing drops anything older once Core answers.
var media_snapshot: Dictionary = {}
var media_availability := "unknown"
var notification_feed: Dictionary = {}
var notifications_availability := "unknown"

var _bridge: Node
var _socket_path := ""
var _reconnect_index := 0
var _reconnect_remaining := 0.0
var _heartbeat_elapsed := 0.0
var _pong_elapsed := 0.0
var _waiting_for_pong := false
var _next_request_id := 1
var _ping_started_msec := 0
var _application_request_id := 0
var _launch_request_id := 0
var _launch_desktop_id := ""
var _launch_elapsed := 0.0
var _application_offset := 0
var _application_total := 0
var _pending_applications: Array[Dictionary] = []
var _session_request_id := 0
var _switch_request_id := 0
var _switch_handle := ""
var _switch_elapsed := 0.0
var _focus_request_id := 0
var _focus_handle := ""
var _focus_elapsed := 0.0
var _telemetry_request_id := 0
var _telemetry_elapsed := 0.0
var _media_request_id := 0
var _notifications_request_id := 0
var _media_control_request_id := 0
var _media_control_handle := ""
var _media_control_verb := ""
var _media_control_elapsed := 0.0

func _ready() -> void:
	_bridge = bridge_override
	if _bridge == null:
		_bridge = ClassDB.instantiate("VeloraSocketBridge") as Node
	if _bridge == null:
		_set_state(ConnectionState.DISCONNECTED, "CORE // BRIDGE NOT BUILT")
		return
	if _bridge.get_parent() == null:
		add_child(_bridge)
	_bridge.socket_connected.connect(_on_socket_connected)
	_bridge.socket_disconnected.connect(_on_socket_disconnected)
	_bridge.line_received.connect(_on_line_received)
	_bridge.transport_error.connect(_on_transport_error)
	_socket_path = _bridge.default_socket_path()
	if _socket_path.is_empty():
		_set_state(ConnectionState.DISCONNECTED, "CORE // SOCKET PATH ERROR")
		return
	if auto_connect:
		call_deferred("connect_to_core")
	else:
		_set_state(ConnectionState.DISCONNECTED, "CORE // OFFLINE")

func _exit_tree() -> void:
	if _bridge:
		_bridge.disconnect_socket()

func _process(delta: float) -> void:
	if state == ConnectionState.RECONNECTING:
		_reconnect_remaining -= delta
		if _reconnect_remaining <= 0.0:
			_attempt_connect()
	elif state == ConnectionState.READY:
		_update_launch_timeout(delta)
		_update_heartbeat(delta)
		_update_telemetry_poll(delta)

func connect_to_core() -> void:
	_reconnect_index = 0
	welcome_received = false
	_attempt_connect()

func disconnect_from_core() -> void:
	if _bridge:
		_bridge.disconnect_socket()
	connected = false
	welcome_received = false
	_waiting_for_pong = false
	_pending_applications.clear()
	_application_request_id = 0
	_session_request_id = 0
	_media_request_id = 0
	_notifications_request_id = 0
	if _focus_request_id != 0:
		var pending_focus := _focus_handle
		_clear_focus_request()
		_emit_focus_rejection(pending_focus, "connection_lost", "CONNECTION LOST // RETRY", true)
	if _switch_request_id != 0:
		var pending_handle := _switch_handle
		_clear_switch_request()
		_emit_switch_rejection(pending_handle, "connection_lost", "CONNECTION LOST // RETRY", true)
	_fail_pending_media_control("connection_lost")
	_fail_pending_launch("connection_lost", true)
	_set_state(ConnectionState.DISCONNECTED, "CORE // DISCONNECTED")

func request_ping() -> bool:
	if state != ConnectionState.READY:
		return false
	var request_id := _take_request_id()
	_ping_started_msec = Time.get_ticks_msec()
	_waiting_for_pong = true
	_pong_elapsed = 0.0
	return _send_message({
		"type": "ping",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
	})

func request_applications() -> bool:
	if state != ConnectionState.READY:
		return false
	_pending_applications.clear()
	_application_total = 0
	_emit_ux_status("loading_applications", "LOADING APPLICATIONS", "waiting", -1.0)
	var sent := _request_application_page(0)
	if not sent:
		_fail_registry("CORE // APPLICATION REQUEST FAILED", "APPLICATION REQUEST FAILED")
	return sent

func request_session_snapshot() -> bool:
	if state != ConnectionState.READY or _session_request_id != 0:
		return false
	var request_id := _take_request_id()
	_session_request_id = request_id
	return _send_message({
		"type": "get_workspace_snapshot",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
	})

func request_hyprland_capabilities() -> bool:
	if state != ConnectionState.READY:
		return false
	return _send_message({
		"type": "get_hyprland_capabilities",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": _take_request_id(),
	})

func request_telemetry_snapshot() -> bool:
	if state != ConnectionState.READY or _telemetry_request_id != 0:
		return false
	var request_id := _take_request_id()
	_telemetry_request_id = request_id
	return _send_message({
		"type": "get_telemetry_snapshot",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
	})

func request_media_snapshot() -> bool:
	if state != ConnectionState.READY or _media_request_id != 0:
		return false
	var request_id := _take_request_id()
	_media_request_id = request_id
	return _send_message({
		"type": "get_media_snapshot",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
	})

func request_notifications() -> bool:
	if state != ConnectionState.READY or _notifications_request_id != 0:
		return false
	var request_id := _take_request_id()
	_notifications_request_id = request_id
	return _send_message({
		"type": "get_notifications",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
	})

func _update_telemetry_poll(delta: float) -> void:
	_telemetry_elapsed += delta
	if _telemetry_elapsed >= TELEMETRY_POLL_SECONDS:
		_telemetry_elapsed = 0.0
		request_telemetry_snapshot()

func request_switch_workspace(workspace_handle: String) -> bool:
	if state != ConnectionState.READY:
		_emit_switch_rejection(
			workspace_handle,
			"core_offline",
			"WORKSPACE SWITCH OFFLINE",
			true
		)
		return false
	if workspace_handle.is_empty() or _switch_request_id != 0:
		_emit_switch_rejection(
			workspace_handle,
			"switch_busy",
			"SWITCH ALREADY IN PROGRESS",
			true
		)
		return false
	var request_id := _take_request_id()
	_switch_request_id = request_id
	_switch_handle = workspace_handle
	_switch_elapsed = 0.0
	var sent := _send_message({
		"type": "switch_workspace",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
		"workspace_handle": workspace_handle,
	})
	if not sent:
		_clear_switch_request()
		_emit_switch_rejection(workspace_handle, "send_failed", "REQUEST FAILED // RETRY", true)
		return false
	_emit_ux_status("switching_workspace", "SWITCHING WORKSPACE", "waiting", 0.0)
	return true

func request_focus_window(window_handle: String) -> bool:
	if state != ConnectionState.READY:
		_emit_focus_rejection(window_handle, "core_offline", "WINDOW FOCUS OFFLINE", true)
		return false
	if window_handle.is_empty() or _focus_request_id != 0:
		_emit_focus_rejection(window_handle, "focus_busy", "FOCUS ALREADY IN PROGRESS", true)
		return false
	var request_id := _take_request_id()
	_focus_request_id = request_id
	_focus_handle = window_handle
	_focus_elapsed = 0.0
	var sent := _send_message({
		"type": "focus_window",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
		"window_handle": window_handle,
	})
	if not sent:
		_clear_focus_request()
		_emit_focus_rejection(window_handle, "send_failed", "REQUEST FAILED // RETRY", true)
		return false
	return true

# Sends one of the six allowlisted control verbs for an opaque player handle
# issued by a media snapshot. Bus names, method names, raw arguments, and
# shell commands are not part of the request surface and are never forwarded.
func send_media_control(player_handle: String, verb: String) -> bool:
	if state != ConnectionState.READY:
		_reject_media_control(player_handle, verb, "core_offline")
		return false
	if player_handle.is_empty():
		_reject_media_control(player_handle, verb, "invalid_player_handle")
		return false
	if not MEDIA_CONTROL_VERBS.has(verb):
		_reject_media_control(player_handle, verb, "invalid_verb")
		return false
	if _media_control_request_id != 0:
		_reject_media_control(player_handle, verb, "media_busy")
		return false
	var request_id := _take_request_id()
	_media_control_request_id = request_id
	_media_control_handle = player_handle
	_media_control_verb = verb
	_media_control_elapsed = 0.0
	var sent := _send_message({
		"type": "send_media_control",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
		"player_handle": player_handle,
		"verb": verb,
	})
	if not sent:
		_clear_media_control_request()
		_reject_media_control(player_handle, verb, "send_failed")
		return false
	return true

func launch_app(desktop_id: String) -> bool:
	last_requested_desktop_id = desktop_id
	if state != ConnectionState.READY:
		connection_changed.emit("CORE // OFFLINE // IPC NOT READY")
		_emit_launch_failure(desktop_id, "core_offline", "CORE OFFLINE", true)
		return false
	if _launch_request_id != 0:
		_emit_launch_failure(desktop_id, "launch_busy", "LAUNCH ALREADY IN PROGRESS", true)
		return false
	var request_id := _take_request_id()
	_launch_request_id = request_id
	_launch_desktop_id = desktop_id
	_launch_elapsed = 0.0
	var sent := _send_message({
		"type": "launch_application",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
		"desktop_id": desktop_id,
	})
	if not sent:
		_fail_pending_launch("send_failed", true)
		return false
	var label := _application_label(desktop_id)
	launch_status_changed.emit(desktop_id, "launching_application", "LAUNCHING " + label, false)
	_emit_ux_status("launching_application", "LAUNCHING // " + label, "waiting", 0.0)
	return true

func _attempt_connect() -> void:
	if not _bridge or _socket_path.is_empty():
		return
	connected = false
	welcome_received = false
	_waiting_for_pong = false
	_application_request_id = 0
	_session_request_id = 0
	_media_request_id = 0
	_notifications_request_id = 0
	_clear_focus_request()
	_clear_switch_request()
	_clear_media_control_request()
	_set_state(ConnectionState.CONNECTING, "CORE // CONNECTING")
	_bridge.connect_socket(_socket_path)

func _on_socket_connected() -> void:
	_set_state(ConnectionState.HANDSHAKING, "CORE // HANDSHAKING")
	_send_message({
		"type": "hello",
		"protocol_version": PROTOCOL_VERSION,
		"client_name": CLIENT_NAME,
		"client_version": CLIENT_VERSION,
	})

func _on_socket_disconnected(_reason: String) -> void:
	connected = false
	welcome_received = false
	_waiting_for_pong = false
	_application_request_id = 0
	_session_request_id = 0
	_media_request_id = 0
	_notifications_request_id = 0
	if _focus_request_id != 0:
		var pending_focus := _focus_handle
		_clear_focus_request()
		_emit_focus_rejection(pending_focus, "connection_lost", "CONNECTION LOST // RETRY", true)
	if _switch_request_id != 0:
		var pending_handle := _switch_handle
		_clear_switch_request()
		_emit_switch_rejection(pending_handle, "connection_lost", "CONNECTION LOST // RETRY", true)
	_fail_pending_media_control("connection_lost")
	_fail_pending_launch("connection_lost", true)
	if state != ConnectionState.INCOMPATIBLE and state != ConnectionState.DISCONNECTED:
		_schedule_reconnect()

func _on_transport_error(code: String, _message: String) -> void:
	connection_changed.emit("CORE // TRANSPORT ERROR // " + code.to_upper())
	_emit_ux_status("launch_failed", "TRANSPORT ERROR", "failure", 3.0)

func _on_line_received(payload: String) -> void:
	var message = JSON.parse_string(payload)
	if not message is Dictionary:
		connection_changed.emit("CORE // INVALID RESPONSE")
		_emit_ux_status("launch_failed", "INVALID CORE RESPONSE", "failure", 3.0)
		return
	if int(message.get("protocol_version", -1)) != PROTOCOL_VERSION:
		_mark_incompatible()
		return

	match String(message.get("type", "")):
		"welcome":
			if state != ConnectionState.HANDSHAKING:
				return
			connected = true
			welcome_received = true
			_reconnect_index = 0
			_heartbeat_elapsed = 0.0
			_set_state(ConnectionState.READY, "CORE // READY")
			request_applications()
			request_hyprland_capabilities()
			request_telemetry_snapshot()
			# One media/notification fetch per connection: refreshes
			# stale-but-labelled state after a reconnect without ever
			# becoming a polling loop. Later refreshes are scene-driven.
			request_media_snapshot()
			request_notifications()
			if session_snapshot.is_empty():
				# Only the first fetch is client-driven; later refreshes are
				# Core's event-driven snapshots arriving unprompted or a
				# scene-requested poll.
				request_session_snapshot()
		"pong":
			var request_id := int(message.get("request_id", 0))
			if _waiting_for_pong and request_id > 0:
				_waiting_for_pong = false
				last_pong_request_id = request_id
				latency_changed.emit(Time.get_ticks_msec() - _ping_started_msec)
		"applications":
			_on_applications_page(message)
		"hyprland_capabilities":
			_on_hyprland_capabilities(message)
		"workspace_snapshot":
			_on_workspace_snapshot(message)
		"workspace_snapshot_rejected":
			_on_workspace_snapshot_rejected(message)
		"telemetry_snapshot":
			_on_telemetry_snapshot(message)
		"telemetry_snapshot_rejected":
			_on_telemetry_snapshot_rejected(message)
		"media_snapshot":
			_on_media_snapshot(message)
		"media_snapshot_rejected":
			_on_media_snapshot_rejected(message)
		"notifications":
			_on_notifications(message)
		"notifications_rejected":
			_on_notifications_rejected(message)
		"media_control_accepted":
			_on_media_control_accepted(message)
		"media_control_rejected":
			_on_media_control_rejected(message)
		"switch_accepted":
			var request_id := int(message.get("request_id", 0))
			if request_id != _switch_request_id:
				return
			var handle := String(message.get("workspace_handle", ""))
			_clear_switch_request()
			switch_accepted.emit(handle)
			_emit_ux_status("switch_successful", "WORKSPACE SWITCHED", "ready", 2.0)
		"switch_rejected":
			_on_switch_rejected(message)
		"focus_accepted":
			var accepted_id := int(message.get("request_id", 0))
			if accepted_id != _focus_request_id:
				return
			var focused := String(message.get("window_handle", ""))
			_clear_focus_request()
			focus_accepted.emit(focused)
		"focus_rejected":
			_on_focus_rejected(message)
		"launch_accepted":
			var request_id := int(message.get("request_id", 0))
			if request_id != _launch_request_id:
				connection_changed.emit("CORE // STALE LAUNCH RESPONSE")
				return
			var desktop_id := String(message.get("desktop_id", ""))
			var process_id := int(message.get("process_id", 0))
			if desktop_id != _launch_desktop_id or process_id <= 0:
				_fail_pending_launch("invalid_launch_response", true)
				return
			_clear_launch_request()
			launch_finished.emit(desktop_id, process_id)
			var label := _application_label(desktop_id)
			launch_status_changed.emit(
				desktop_id,
				"launch_successful",
				"LAUNCHED " + label,
				false
			)
			_emit_ux_status("launch_successful", "LAUNCHED // " + label, "ready", 3.0)
			connection_changed.emit("CORE // LAUNCHED // %s // PID %d" % [desktop_id, process_id])
		"launch_rejected":
			_on_launch_rejected(message)
		"error":
			if String(message.get("code", "")) == "protocol_mismatch":
				_mark_incompatible()
			else:
				var code := String(message.get("code", "error"))
				var retryable := bool(message.get("retryable", false))
				connection_changed.emit("CORE // " + code.to_upper())
				_emit_ux_status(
					"launch_failed",
					_friendly_error(code),
					"failure",
					3.0 if retryable else -1.0
				)
		_:
			connection_changed.emit("CORE // UNKNOWN RESPONSE")

func _update_heartbeat(delta: float) -> void:
	if _waiting_for_pong:
		_pong_elapsed += delta
		if _pong_elapsed >= PONG_TIMEOUT_SECONDS:
			_bridge.disconnect_socket()
			_schedule_reconnect()
		return
	_heartbeat_elapsed += delta
	if _heartbeat_elapsed >= PING_INTERVAL_SECONDS:
		_heartbeat_elapsed = 0.0
		request_ping()

func _update_launch_timeout(delta: float) -> void:
	if _launch_request_id != 0:
		_launch_elapsed += delta
		if _launch_elapsed >= LAUNCH_TIMEOUT_SECONDS:
			_fail_pending_launch("launch_timeout", true)
	if _switch_request_id != 0:
		_switch_elapsed += delta
		if _switch_elapsed >= SWITCH_TIMEOUT_SECONDS:
			var handle := _switch_handle
			_clear_switch_request()
			_emit_switch_rejection(handle, "switch_timeout", "SWITCH TIMED OUT // RETRY", true)
	if _focus_request_id != 0:
		_focus_elapsed += delta
		if _focus_elapsed >= FOCUS_TIMEOUT_SECONDS:
			var focused := _focus_handle
			_clear_focus_request()
			_emit_focus_rejection(focused, "focus_timeout", "FOCUS TIMED OUT // RETRY", true)
	if _media_control_request_id != 0:
		_media_control_elapsed += delta
		if _media_control_elapsed >= MEDIA_CONTROL_TIMEOUT_SECONDS:
			_fail_pending_media_control("media_control_timeout")

func _clear_switch_request() -> void:
	_switch_request_id = 0
	_switch_handle = ""
	_switch_elapsed = 0.0

func _on_switch_rejected(message: Dictionary) -> void:
	var request_id := int(message.get("request_id", 0))
	if request_id != _switch_request_id:
		return
	var handle := String(message.get("workspace_handle", ""))
	var code := String(message.get("code", "switch_failed"))
	_clear_switch_request()
	match code:
		"hyprland_unavailable":
			_set_session_availability("unavailable")
			_emit_switch_rejection(handle, code, "NO HYPRLAND SESSION", false)
		"hyprland_incompatible":
			_set_session_availability("incompatible")
			_emit_switch_rejection(handle, code, "SESSION INCOMPATIBLE", false)
		"invalid_workspace_handle", "unknown_workspace_handle":
			_emit_switch_rejection(handle, code, "WORKSPACE NO LONGER EXISTS", false)
		"unsupported_workspace":
			_emit_switch_rejection(handle, code, "SPECIAL WORKSPACES CANNOT SWITCH", false)
		_:
			_emit_switch_rejection(handle, code, "SWITCH FAILED // RETRY", true)

func _clear_focus_request() -> void:
	_focus_request_id = 0
	_focus_handle = ""
	_focus_elapsed = 0.0

func _on_focus_rejected(message: Dictionary) -> void:
	var request_id := int(message.get("request_id", 0))
	if request_id != _focus_request_id:
		return
	var handle := String(message.get("window_handle", ""))
	var code := String(message.get("code", "focus_failed"))
	_clear_focus_request()
	match code:
		"hyprland_unavailable":
			_set_session_availability("unavailable")
			_emit_focus_rejection(handle, code, "NO HYPRLAND SESSION", false)
		"hyprland_incompatible":
			_set_session_availability("incompatible")
			_emit_focus_rejection(handle, code, "SESSION INCOMPATIBLE", false)
		"unknown_window_handle":
			_emit_focus_rejection(handle, code, "WINDOW NO LONGER EXISTS", false)
		_:
			_emit_focus_rejection(handle, code, "FOCUS FAILED // RETRY", true)

func _emit_focus_rejection(
	window_handle: String,
	code: String,
	message: String,
	retryable: bool
) -> void:
	focus_rejected.emit(window_handle, code, message, retryable)
	_emit_ux_status("focus_failed", message, "failure", 3.0 if retryable else -1.0)

func _emit_switch_rejection(
	workspace_handle: String,
	code: String,
	message: String,
	retryable: bool
) -> void:
	switch_rejected.emit(workspace_handle, code, message, retryable)
	_emit_ux_status("switch_failed", message, "failure", 3.0 if retryable else -1.0)

func _clear_media_control_request() -> void:
	_media_control_request_id = 0
	_media_control_handle = ""
	_media_control_verb = ""
	_media_control_elapsed = 0.0

func _on_media_control_accepted(message: Dictionary) -> void:
	var request_id := int(message.get("request_id", 0))
	if request_id != _media_control_request_id:
		return
	var handle := String(message.get("player_handle", ""))
	if handle != _media_control_handle or handle.is_empty():
		_fail_pending_media_control("invalid_media_response")
		return
	var verb := _media_control_verb
	_clear_media_control_request()
	media_control_accepted.emit(handle, verb)

func _on_media_control_rejected(message: Dictionary) -> void:
	var request_id := int(message.get("request_id", 0))
	if request_id != _media_control_request_id:
		connection_changed.emit("CORE // STALE MEDIA CONTROL REJECTION")
		return
	var handle := String(message.get("player_handle", ""))
	if handle != _media_control_handle:
		_fail_pending_media_control("invalid_media_response")
		return
	var code := String(message.get("code", "control_failed"))
	var verb := _media_control_verb
	_clear_media_control_request()
	if code == "media_unavailable":
		_set_media_availability("unavailable")
	_reject_media_control(handle, verb, code)

func _fail_pending_media_control(code: String) -> void:
	if _media_control_request_id == 0:
		return
	var handle := _media_control_handle
	var verb := _media_control_verb
	_clear_media_control_request()
	_reject_media_control(handle, verb, code)

func _reject_media_control(player_handle: String, verb: String, code: String) -> void:
	var details := _media_control_error_details(code)
	media_control_rejected.emit(player_handle, verb, code, details["message"], details["retryable"])
	_emit_ux_status(
		"media_control_failed",
		details["message"],
		"failure",
		3.0 if details["retryable"] else -1.0
	)

func _media_control_error_details(code: String) -> Dictionary:
	match code:
		"media_unavailable":
			return {"message": "MEDIA PLAYBACK UNAVAILABLE", "retryable": false}
		"unknown_player":
			return {"message": "PLAYER NO LONGER EXISTS", "retryable": false}
		"stale_handle":
			return {"message": "PLAYER STALE // REFRESH LIST", "retryable": false}
		"control_unavailable":
			return {"message": "CONTROL NOT AVAILABLE", "retryable": false}
		"core_offline":
			return {"message": "MEDIA CONTROL OFFLINE", "retryable": true}
		"connection_lost":
			return {"message": "CONNECTION LOST // RETRY", "retryable": true}
		"send_failed":
			return {"message": "REQUEST FAILED // RETRY", "retryable": true}
		"media_control_timeout":
			return {"message": "CONTROL TIMED OUT // RETRY", "retryable": true}
		"media_busy":
			return {"message": "MEDIA CONTROL ALREADY IN PROGRESS", "retryable": true}
		"invalid_player_handle", "invalid_verb":
			return {"message": "INVALID MEDIA CONTROL", "retryable": false}
		"invalid_media_response":
			return {"message": "INVALID MEDIA RESPONSE", "retryable": true}
		_:
			return {"message": "MEDIA CONTROL FAILED // RETRY", "retryable": true}

func _schedule_reconnect() -> void:
	if state == ConnectionState.RECONNECTING:
		return
	var delay: float = RECONNECT_DELAYS[min(_reconnect_index, RECONNECT_DELAYS.size() - 1)]
	_reconnect_index = min(_reconnect_index + 1, RECONNECT_DELAYS.size() - 1)
	_reconnect_remaining = delay
	_set_state(ConnectionState.RECONNECTING, "CORE // RECONNECTING")

func _mark_incompatible() -> void:
	connected = false
	welcome_received = false
	_waiting_for_pong = false
	_set_state(ConnectionState.INCOMPATIBLE, "CORE // INCOMPATIBLE")
	if _bridge:
		_bridge.disconnect_socket()

func _request_application_page(offset: int) -> bool:
	var request_id := _take_request_id()
	_application_request_id = request_id
	_application_offset = offset
	return _send_message({
		"type": "list_applications",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
		"offset": offset,
		"limit": APPLICATION_PAGE_SIZE,
	})

func _on_applications_page(message: Dictionary) -> void:
	if state != ConnectionState.READY:
		return
	if int(message.get("request_id", 0)) != _application_request_id:
		connection_changed.emit("CORE // STALE APPLICATION PAGE")
		_emit_ux_status("registry_failed", "STALE APPLICATION DATA", "failure", 3.0)
		return

	var raw_applications = message.get("applications", null)
	if not raw_applications is Array:
		_fail_registry("CORE // INVALID APPLICATION PAGE", "INVALID APPLICATION DATA")
		return

	var total := int(message.get("total", -1))
	if total < 0 or (_application_offset > 0 and total != _application_total):
		_fail_registry("CORE // INVALID APPLICATION COUNT", "INVALID APPLICATION DATA")
		return
	_application_total = total

	for value in raw_applications:
		var application := _normalize_application(value)
		if application.is_empty():
			_fail_registry("CORE // INVALID APPLICATION", "INVALID APPLICATION DATA")
			return
		_pending_applications.append(application)

	var next_offset = message.get("next_offset", null)
	if next_offset != null:
		var next_value := int(next_offset)
		if next_value <= _application_offset or next_value > total:
			_fail_registry("CORE // INVALID APPLICATION CURSOR", "INVALID APPLICATION DATA")
			return
		if not _request_application_page(next_value):
			_fail_registry("CORE // APPLICATION REQUEST FAILED", "APPLICATION REQUEST FAILED")
		return

	if _pending_applications.size() != total:
		_fail_registry("CORE // INCOMPLETE APPLICATION REGISTRY", "INCOMPLETE APPLICATION DATA")
		return

	applications.clear()
	applications.append_array(_pending_applications)
	_pending_applications.clear()
	_application_request_id = 0
	applications_changed.emit(applications.duplicate(true))
	connection_changed.emit("CORE // %d APPLICATIONS" % applications.size())
	_emit_ux_status("ready", "READY // %d APPLICATIONS" % applications.size(), "ready", -1.0)

func _fail_registry(detail: String, concise_message: String) -> void:
	_pending_applications.clear()
	_application_request_id = 0
	_application_offset = 0
	_application_total = 0
	connection_changed.emit(detail)
	_emit_ux_status("registry_failed", concise_message, "failure", 3.0)

func _on_hyprland_capabilities(message: Dictionary) -> void:
	var capabilities = message.get("capabilities", null)
	if not capabilities is Dictionary:
		return
	var availability := String(capabilities.get("availability", "unknown"))
	if availability == session_availability:
		return
	session_availability = availability
	session_availability_changed.emit(availability)

func _on_workspace_snapshot(message: Dictionary) -> void:
	if state != ConnectionState.READY:
		return
	var request_id := int(message.get("request_id", 0))
	if _session_request_id != 0 and request_id != _session_request_id:
		connection_changed.emit("CORE // STALE SESSION SNAPSHOT")
		return
	_session_request_id = 0

	var raw_snapshot = message.get("snapshot", null)
	var snapshot := _normalize_snapshot(raw_snapshot)
	if snapshot.is_empty():
		_emit_ux_status("session_failed", "INVALID SESSION DATA", "failure", 3.0)
		return
	var sequence := int(snapshot.get("sequence", 0))
	if sequence <= int(session_snapshot.get("sequence", 0)):
		return
	session_snapshot = snapshot
	session_snapshot_changed.emit(snapshot)

func _on_workspace_snapshot_rejected(message: Dictionary) -> void:
	_session_request_id = 0
	var code := String(message.get("code", ""))
	match code:
		"hyprland_unavailable":
			_set_session_availability("unavailable")
		"hyprland_incompatible":
			_set_session_availability("incompatible")
		"snapshot_not_ready":
			pass
		_:
			pass

func _on_telemetry_snapshot(message: Dictionary) -> void:
	var request_id := int(message.get("request_id", 0))
	if request_id != _telemetry_request_id:
		return
	_telemetry_request_id = 0
	var snapshot = message.get("snapshot", null)
	if not snapshot is Dictionary or int(snapshot.get("sequence", 0)) <= int(telemetry_snapshot.get("sequence", 0)):
		return
	for key in ["cpu", "memory", "disk", "network"]:
		if not snapshot.get(key, null) is Dictionary:
			return
	telemetry_snapshot = snapshot
	_set_telemetry_availability("available")
	telemetry_snapshot_changed.emit(snapshot)

func _on_telemetry_snapshot_rejected(message: Dictionary) -> void:
	if int(message.get("request_id", 0)) != _telemetry_request_id:
		return
	_telemetry_request_id = 0
	_set_telemetry_availability("waiting")

func _set_telemetry_availability(availability: String) -> void:
	if telemetry_availability == availability:
		return
	telemetry_availability = availability
	telemetry_availability_changed.emit(availability)

func _on_media_snapshot(message: Dictionary) -> void:
	if state != ConnectionState.READY:
		return
	var request_id := int(message.get("request_id", 0))
	if _media_request_id != 0 and request_id != _media_request_id:
		connection_changed.emit("CORE // STALE MEDIA SNAPSHOT")
		return
	_media_request_id = 0
	var snapshot := _normalize_media_snapshot(message.get("snapshot", null))
	if snapshot.is_empty():
		_emit_ux_status("media_failed", "INVALID MEDIA DATA", "failure", 3.0)
		return
	var sequence := int(snapshot.get("sequence", 0))
	if sequence <= int(media_snapshot.get("sequence", 0)):
		return
	media_snapshot = snapshot
	_set_media_availability("available")
	media_snapshot_changed.emit(snapshot)

func _on_media_snapshot_rejected(message: Dictionary) -> void:
	# Rejections are strictly request-scoped, like telemetry: without a
	# pending request with a matching ID the frame is fenced so a stale or
	# unsolicited rejection can never mutate availability.
	if int(message.get("request_id", 0)) != _media_request_id:
		return
	_media_request_id = 0
	match String(message.get("code", "")):
		"media_unavailable":
			_set_media_availability("unavailable")
		"snapshot_not_ready":
			_set_media_availability("waiting")
		_:
			pass

func _on_notifications(message: Dictionary) -> void:
	if state != ConnectionState.READY:
		return
	var request_id := int(message.get("request_id", 0))
	if _notifications_request_id != 0 and request_id != _notifications_request_id:
		connection_changed.emit("CORE // STALE NOTIFICATION FEED")
		return
	_notifications_request_id = 0
	var feed := _normalize_notification_feed(message.get("feed", null))
	if feed.is_empty():
		_emit_ux_status("notifications_failed", "INVALID NOTIFICATION DATA", "failure", 3.0)
		return
	var sequence := int(feed.get("sequence", 0))
	if sequence <= int(notification_feed.get("sequence", 0)):
		return
	notification_feed = feed
	_set_notifications_availability("available")
	notification_feed_changed.emit(feed)

func _on_notifications_rejected(message: Dictionary) -> void:
	# Strict request correlation, like telemetry: a stale or unsolicited
	# rejection never mutates notifications availability.
	if int(message.get("request_id", 0)) != _notifications_request_id:
		return
	_notifications_request_id = 0
	match String(message.get("code", "")):
		"notifications_unavailable":
			_set_notifications_availability("unavailable")
		"monitor_restricted":
			_set_notifications_availability("restricted")
		"feed_not_ready":
			_set_notifications_availability("waiting")
		_:
			pass

func _set_media_availability(availability: String) -> void:
	if media_availability == availability:
		return
	media_availability = availability
	media_availability_changed.emit(availability)

func _set_notifications_availability(availability: String) -> void:
	if notifications_availability == availability:
		return
	notifications_availability = availability
	notifications_availability_changed.emit(availability)

func _set_session_availability(availability: String) -> void:
	if availability == session_availability:
		return
	session_availability = availability
	session_availability_changed.emit(availability)

func _normalize_snapshot(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var raw_workspaces = value.get("workspaces", null)
	var raw_windows = value.get("windows", null)
	if not raw_workspaces is Array or not raw_windows is Array:
		return {}
	if raw_workspaces.size() > MAX_SESSION_WORKSPACES or raw_windows.size() > MAX_SESSION_WINDOWS:
		return {}

	var workspaces: Array[Dictionary] = []
	var workspace_handles := {}
	for raw_workspace in raw_workspaces:
		var workspace := _normalize_workspace(raw_workspace)
		if workspace.is_empty() or workspace_handles.has(workspace.get("handle")):
			return {}
		workspace_handles[workspace.get("handle")] = true
		workspaces.append(workspace)

	var windows: Array[Dictionary] = []
	var window_handles := {}
	var active_window_handle := ""
	for raw_window in raw_windows:
		var window := _normalize_window(raw_window)
		if window.is_empty() or window_handles.has(window.get("handle")):
			return {}
		if not workspace_handles.has(window.get("workspace_handle")):
			return {}
		window_handles[window.get("handle")] = true
		windows.append(window)

	var active_workspace_value = value.get("active_workspace_handle", null)
	if active_workspace_value != null:
		if not active_workspace_value is String or not workspace_handles.has(active_workspace_value):
			return {}
	var active_window_value = value.get("active_window_handle", null)
	if active_window_value != null:
		if not active_window_value is String or not window_handles.has(active_window_value):
			return {}
		active_window_handle = String(active_window_value)

	var sequence_value = value.get("sequence", null)
	if not sequence_value is float and not sequence_value is int:
		return {}
	var sequence := int(sequence_value)
	if sequence < 0:
		return {}

	return {
		"sequence": sequence,
		"workspaces": workspaces,
		"windows": windows,
		"active_workspace_handle": "" if active_workspace_value == null else String(active_workspace_value),
		"active_window_handle": active_window_handle,
	}

func _normalize_workspace(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var handle_value = value.get("handle", null)
	var name_value = value.get("name", null)
	var index_value = value.get("index", null)
	var monitor_value = value.get("monitor", null)
	var window_count_value = value.get("window_count", null)
	var is_active_value = value.get("is_active", null)
	var is_special_value = value.get("is_special", null)
	var is_urgent_value = value.get("is_urgent", null)
	if not handle_value is String or String(handle_value).is_empty():
		return {}
	if not name_value is String or String(name_value).is_empty():
		return {}
	if not index_value is int and not index_value is float:
		return {}
	if monitor_value != null and not monitor_value is String:
		return {}
	if not window_count_value is int and not window_count_value is float:
		return {}
	if int(window_count_value) < 0:
		return {}
	if not is_active_value is bool or not is_special_value is bool or not is_urgent_value is bool:
		return {}
	return {
		"handle": String(handle_value),
		"name": String(name_value),
		"index": int(index_value),
		"monitor": "" if monitor_value == null else String(monitor_value),
		"window_count": int(window_count_value),
		"is_active": is_active_value,
		"is_special": is_special_value,
		"is_urgent": is_urgent_value,
	}

func _normalize_window(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var handle_value = value.get("handle", null)
	var workspace_handle_value = value.get("workspace_handle", null)
	var title_value = value.get("title", null)
	var class_value = value.get("class", null)
	var is_active_value = value.get("is_active", null)
	var is_floating_value = value.get("is_floating", null)
	var is_fullscreen_value = value.get("is_fullscreen", null)
	if not handle_value is String or String(handle_value).is_empty():
		return {}
	if not workspace_handle_value is String or String(workspace_handle_value).is_empty():
		return {}
	if not title_value is String or not class_value is String:
		return {}
	if not is_active_value is bool or not is_floating_value is bool or not is_fullscreen_value is bool:
		return {}
	return {
		"handle": String(handle_value),
		"workspace_handle": String(workspace_handle_value),
		"title": String(title_value),
		"class": String(class_value),
		"is_active": is_active_value,
		"is_floating": is_floating_value,
		"is_fullscreen": is_fullscreen_value,
	}

func _normalize_media_snapshot(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var sequence_value = value.get("sequence", null)
	if not sequence_value is float and not sequence_value is int:
		return {}
	if sequence_value < 0:
		return {}
	var raw_players = value.get("players", null)
	if not raw_players is Array:
		return {}
	if raw_players.size() > MAX_MEDIA_PLAYERS:
		return {}

	var players: Array[Dictionary] = []
	var player_handles := {}
	for raw_player in raw_players:
		var player := _normalize_media_player(raw_player)
		if player.is_empty() or player_handles.has(player.get("handle")):
			return {}
		player_handles[player.get("handle")] = true
		players.append(player)

	var active_handle := ""
	var active_value = value.get("active_player_handle", null)
	if active_value != null:
		if not active_value is String or not player_handles.has(active_value):
			return {}
		active_handle = String(active_value)

	return {
		"sequence": int(sequence_value),
		"players": players,
		"active_player_handle": active_handle,
	}

func _normalize_media_player(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var handle_value = value.get("handle", null)
	if not handle_value is String or String(handle_value).is_empty():
		return {}
	var identity_value = value.get("identity", null)
	if not identity_value is String:
		return {}
	var status := String(value.get("status", ""))
	if not PLAYBACK_STATUSES.has(status):
		return {}
	var title_value = value.get("title", null)
	var artist_value = value.get("artist", null)
	var album_value = value.get("album", null)
	for optional_string in [title_value, artist_value, album_value]:
		if optional_string != null and not optional_string is String:
			return {}
	var length_value = value.get("length_micros", null)
	if length_value != null and not length_value is float and not length_value is int:
		return {}
	if length_value != null and length_value < 0:
		return {}
	var position_value = value.get("position_micros", null)
	if not position_value is float and not position_value is int:
		return {}
	if position_value < 0:
		return {}
	for capability in [
		"can_play", "can_pause", "can_go_next", "can_go_previous", "can_seek", "can_control"
	]:
		if not value.get(capability, null) is bool:
			return {}
	if _string_exceeds_budget(identity_value, MAX_STRING_BYTES):
		return {}
	for bounded_string in [title_value, artist_value, album_value]:
		if bounded_string != null and _string_exceeds_budget(bounded_string, MAX_STRING_BYTES):
			return {}
	# Optional metadata is flattened with sentinels: absent strings become ""
	# and an unknown track length becomes -1, matching the session snapshot
	# convention of never carrying null across the normalized boundary.
	return {
		"handle": String(handle_value),
		"identity": String(identity_value),
		"status": status,
		"title": "" if title_value == null else String(title_value),
		"artist": "" if artist_value == null else String(artist_value),
		"album": "" if album_value == null else String(album_value),
		"length_micros": -1 if length_value == null else int(length_value),
		"position_micros": int(position_value),
		"can_play": value.get("can_play"),
		"can_pause": value.get("can_pause"),
		"can_go_next": value.get("can_go_next"),
		"can_go_previous": value.get("can_go_previous"),
		"can_seek": value.get("can_seek"),
		"can_control": value.get("can_control"),
	}

func _normalize_notification_feed(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var sequence_value = value.get("sequence", null)
	if not sequence_value is float and not sequence_value is int:
		return {}
	if sequence_value < 0:
		return {}
	var raw_notifications = value.get("notifications", null)
	if not raw_notifications is Array:
		return {}
	if raw_notifications.size() > MAX_NOTIFICATIONS:
		return {}

	var notifications: Array[Dictionary] = []
	var notification_handles := {}
	for raw_notification in raw_notifications:
		var notification := _normalize_notification(raw_notification)
		if notification.is_empty() or notification_handles.has(notification.get("handle")):
			return {}
		notification_handles[notification.get("handle")] = true
		notifications.append(notification)

	return {
		"sequence": int(sequence_value),
		"notifications": notifications,
	}

func _normalize_notification(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}
	var handle_value = value.get("handle", null)
	if not handle_value is String or String(handle_value).is_empty():
		return {}
	var app_name_value = value.get("app_name", null)
	var summary_value = value.get("summary", null)
	var body_value = value.get("body", null)
	for required_string in [app_name_value, summary_value, body_value]:
		if not required_string is String:
			return {}
	var urgency := String(value.get("urgency", ""))
	if not NOTIFICATION_URGENCIES.has(urgency):
		return {}
	var timestamp_value = value.get("timestamp_unix_ms", null)
	if not timestamp_value is float and not timestamp_value is int:
		return {}
	if timestamp_value < 0:
		return {}
	for bounded_string in [app_name_value, summary_value, body_value]:
		if _string_exceeds_budget(bounded_string, MAX_STRING_BYTES):
			return {}
	return {
		"handle": String(handle_value),
		"app_name": String(app_name_value),
		"summary": String(summary_value),
		"body": String(body_value),
		"urgency": urgency,
		"timestamp_unix_ms": int(timestamp_value),
	}

func _string_exceeds_budget(value: String, budget: int) -> bool:
	# The protocol bounds UTF-8 bytes, not code points, so measure bytes the
	# same way Core does.
	return value.to_utf8_buffer().size() > budget

func _on_launch_rejected(message: Dictionary) -> void:
	var request_id := int(message.get("request_id", 0))
	if request_id != _launch_request_id:
		connection_changed.emit("CORE // STALE LAUNCH REJECTION")
		return
	var desktop_id := String(message.get("desktop_id", ""))
	if desktop_id != _launch_desktop_id:
		_fail_pending_launch("invalid_launch_response", true)
		return
	var code := String(message.get("code", "launch_failed"))
	var retryable := bool(message.get("retryable", false))
	_clear_launch_request()
	_emit_launch_failure(desktop_id, code, _friendly_error(code), retryable)

func _emit_launch_failure(
	desktop_id: String,
	code: String,
	message: String,
	retryable: bool
) -> void:
	launch_rejected.emit(desktop_id, code, message, retryable)
	launch_status_changed.emit(desktop_id, "launch_failed", message, retryable)
	_emit_ux_status("launch_failed", message, "failure", 3.0)

func _fail_pending_launch(code: String, retryable: bool) -> void:
	if _launch_request_id == 0:
		return
	var desktop_id := _launch_desktop_id
	_clear_launch_request()
	_emit_launch_failure(desktop_id, code, _friendly_error(code), retryable)

func _clear_launch_request() -> void:
	_launch_request_id = 0
	_launch_desktop_id = ""
	_launch_elapsed = 0.0

func _friendly_error(code: String) -> String:
	match code:
		"unknown_application":
			return "APPLICATION NOT FOUND"
		"terminal_required":
			return "TERMINAL POLICY REQUIRED"
		"malformed_desktop_entry":
			return "INVALID APPLICATION ENTRY"
		"unsupported_exec_field":
			return "FILE OR URL LAUNCH NOT SUPPORTED"
		"shell_wrapper_rejected":
			return "BLOCKED BY SAFETY POLICY"
		"executable_unavailable":
			return "EXECUTABLE UNAVAILABLE"
		"launch_rate_limited":
			return "PLEASE WAIT AND RETRY"
		"launch_process_limit":
			return "TOO MANY APPLICATIONS"
		"connection_lost":
			return "CONNECTION LOST // RETRY"
		"core_offline":
			return "CORE OFFLINE"
		"send_failed":
			return "REQUEST FAILED // RETRY"
		"launch_timeout":
			return "LAUNCH TIMED OUT // RETRY"
		"launch_busy":
			return "LAUNCH ALREADY IN PROGRESS"
		"invalid_launch_response":
			return "INVALID LAUNCH RESPONSE"
		_:
			return "LAUNCH FAILED"

func _application_label(desktop_id: String) -> String:
	for application in applications:
		if String(application.get("id", "")) == desktop_id:
			return String(application.get("name", desktop_id)).to_upper()
	return desktop_id.trim_suffix(".desktop").to_upper()

func _normalize_application(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {}

	var desktop_id_value = value.get("id", null)
	var display_name_value = value.get("name", null)
	var exec_value = value.get("exec", null)
	var raw_categories = value.get("categories", null)
	var icon_value = value.get("icon", null)
	var terminal_value = value.get("terminal", null)
	if not desktop_id_value is String or not display_name_value is String or not exec_value is String:
		return {}
	if not terminal_value is bool:
		return {}

	var desktop_id: String = desktop_id_value
	var display_name: String = display_name_value
	var exec: String = exec_value
	if desktop_id.is_empty() or display_name.is_empty() or exec.is_empty():
		return {}
	if not raw_categories is Array:
		return {}
	if icon_value != null and not icon_value is String:
		return {}

	var categories: Array[String] = []
	for category in raw_categories:
		if not category is String:
			return {}
		categories.append(category)
	var icon := "" if icon_value == null else String(icon_value)

	return {
		"id": desktop_id,
		"name": display_name,
		"exec": exec,
		"icon": icon,
		"categories": categories,
		"terminal": terminal_value,
	}

func _take_request_id() -> int:
	var request_id := _next_request_id
	_next_request_id += 1
	return request_id

func _send_message(message: Dictionary) -> bool:
	return _bridge != null and _bridge.send_line(JSON.stringify(message))

func _set_state(next_state: ConnectionState, message: String) -> void:
	state = next_state
	state_changed.emit(state)
	connection_changed.emit(message)
	match state:
		ConnectionState.DISCONNECTED:
			_emit_ux_status("core_offline", "CORE OFFLINE", "failure", -1.0)
		ConnectionState.CONNECTING, ConnectionState.HANDSHAKING:
			_emit_ux_status("connecting", "CONNECTING", "waiting", -1.0)
		ConnectionState.READY:
			_emit_ux_status("connected", "CONNECTED", "ready", -1.0)
		ConnectionState.RECONNECTING:
			_emit_ux_status("reconnecting", "RECONNECTING", "waiting", -1.0)
		ConnectionState.INCOMPATIBLE:
			_emit_ux_status("protocol_incompatible", "PROTOCOL INCOMPATIBLE", "failure", -1.0)

func _emit_ux_status(
	stage: String,
	message: String,
	tone: String,
	transient_seconds: float
) -> void:
	ux_status_changed.emit(stage, message, tone, transient_seconds)
