class_name BackendClient
extends Node

signal connection_changed(message: String)
signal state_changed(state: ConnectionState)
signal latency_changed(milliseconds: int)
signal applications_changed(applications: Array)
signal application_state_changed(desktop_id: String, running: bool)

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
	return _request_application_page(0)

func launch_app(desktop_id: String) -> bool:
	last_requested_desktop_id = desktop_id
	if state != ConnectionState.READY:
		connection_changed.emit("CORE // OFFLINE // IPC NOT READY")
	else:
		connection_changed.emit("CORE // LAUNCH DISABLED // P2.08")
	return false

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
	if state != ConnectionState.INCOMPATIBLE and state != ConnectionState.DISCONNECTED:
		_schedule_reconnect()

func _on_transport_error(code: String, _message: String) -> void:
	connection_changed.emit("CORE // TRANSPORT ERROR // " + code.to_upper())

func _on_line_received(payload: String) -> void:
	var message = JSON.parse_string(payload)
	if not message is Dictionary:
		connection_changed.emit("CORE // INVALID RESPONSE")
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
		"error":
			if String(message.get("code", "")) == "protocol_mismatch":
				_mark_incompatible()
			else:
				connection_changed.emit("CORE // " + String(message.get("code", "ERROR")).to_upper())
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
