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

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	HANDSHAKING,
	READY,
	RECONNECTING,
	INCOMPATIBLE,
}

const PROTOCOL_VERSION := 3
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
	if _switch_request_id != 0:
		var pending_handle := _switch_handle
		_clear_switch_request()
		_emit_switch_rejection(pending_handle, "connection_lost", "CONNECTION LOST // RETRY", true)
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
	if _switch_request_id != 0:
		var pending_handle := _switch_handle
		_clear_switch_request()
		_emit_switch_rejection(pending_handle, "connection_lost", "CONNECTION LOST // RETRY", true)
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
	if _launch_request_id == 0:
		return
	_launch_elapsed += delta
	if _launch_elapsed >= LAUNCH_TIMEOUT_SECONDS:
		_fail_pending_launch("launch_timeout", true)
	if _switch_request_id != 0:
		_switch_elapsed += delta
		if _switch_elapsed >= SWITCH_TIMEOUT_SECONDS:
			var handle := _switch_handle
			_clear_switch_request()
			_emit_switch_rejection(handle, "switch_timeout", "SWITCH TIMED OUT // RETRY", true)

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

func _emit_switch_rejection(
	workspace_handle: String,
	code: String,
	message: String,
	retryable: bool
) -> void:
	switch_rejected.emit(workspace_handle, code, message, retryable)
	_emit_ux_status("switch_failed", message, "failure", 3.0 if retryable else -1.0)

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
