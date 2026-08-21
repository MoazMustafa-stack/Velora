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

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	HANDSHAKING,
	READY,
	RECONNECTING,
	INCOMPATIBLE,
}

const PROTOCOL_VERSION := 2
const CLIENT_NAME := "velora-godot"
const CLIENT_VERSION := "0.2.0"
const PING_INTERVAL_SECONDS := 5.0
const PONG_TIMEOUT_SECONDS := 3.0
const APPLICATION_PAGE_SIZE := 32
const LAUNCH_TIMEOUT_SECONDS := 5.0
const RECONNECT_DELAYS := [0.25, 0.5, 1.0, 2.0, 4.0]

@export var auto_connect := true

var connected := false
var state := ConnectionState.DISCONNECTED
var last_requested_desktop_id := ""
var last_pong_request_id := 0
var welcome_received := false
var applications: Array[Dictionary] = []

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

func _ready() -> void:
	_bridge = ClassDB.instantiate("VeloraSocketBridge") as Node
	if _bridge == null:
		_set_state(ConnectionState.DISCONNECTED, "CORE // BRIDGE NOT BUILT")
		return
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
	return _request_application_page(0)

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
		"pong":
			var request_id := int(message.get("request_id", 0))
			if _waiting_for_pong and request_id > 0:
				_waiting_for_pong = false
				last_pong_request_id = request_id
				latency_changed.emit(Time.get_ticks_msec() - _ping_started_msec)
		"applications":
			_on_applications_page(message)
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
		return

	var raw_applications = message.get("applications", null)
	if not raw_applications is Array:
		connection_changed.emit("CORE // INVALID APPLICATION PAGE")
		return

	var total := int(message.get("total", -1))
	if total < 0 or (_application_offset > 0 and total != _application_total):
		connection_changed.emit("CORE // INVALID APPLICATION COUNT")
		return
	_application_total = total

	for value in raw_applications:
		var application := _normalize_application(value)
		if application.is_empty():
			connection_changed.emit("CORE // INVALID APPLICATION")
			return
		_pending_applications.append(application)

	var next_offset = message.get("next_offset", null)
	if next_offset != null:
		var next_value := int(next_offset)
		if next_value <= _application_offset or next_value > total:
			connection_changed.emit("CORE // INVALID APPLICATION CURSOR")
			return
		_request_application_page(next_value)
		return

	if _pending_applications.size() != total:
		connection_changed.emit("CORE // INCOMPLETE APPLICATION REGISTRY")
		return

	applications.clear()
	applications.append_array(_pending_applications)
	_pending_applications.clear()
	_application_request_id = 0
	applications_changed.emit(applications.duplicate(true))
	connection_changed.emit("CORE // %d APPLICATIONS" % applications.size())
	_emit_ux_status("ready", "READY // %d APPLICATIONS" % applications.size(), "ready", -1.0)

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
