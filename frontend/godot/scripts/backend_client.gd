class_name BackendClient
extends Node

signal connection_changed(message: String)
signal state_changed(state: ConnectionState)
signal latency_changed(milliseconds: int)
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
const RECONNECT_DELAYS := [0.25, 0.5, 1.0, 2.0, 4.0]

@export var auto_connect := true

var connected := false
var state := ConnectionState.DISCONNECTED
var last_requested_desktop_id := ""
var last_pong_request_id := 0
var welcome_received := false

var _bridge: Node
var _socket_path := ""
var _reconnect_index := 0
var _reconnect_remaining := 0.0
var _heartbeat_elapsed := 0.0
var _pong_elapsed := 0.0
var _waiting_for_pong := false
var _next_request_id := 1
var _ping_started_msec := 0

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
	_set_state(ConnectionState.DISCONNECTED, "CORE // DISCONNECTED")

func request_ping() -> bool:
	if state != ConnectionState.READY:
		return false
	var request_id := _next_request_id
	_next_request_id += 1
	_ping_started_msec = Time.get_ticks_msec()
	_waiting_for_pong = true
	_pong_elapsed = 0.0
	return _send_message({
		"type": "ping",
		"protocol_version": PROTOCOL_VERSION,
		"request_id": request_id,
	})

func launch_app(desktop_id: String) -> bool:
	last_requested_desktop_id = desktop_id
	if state != ConnectionState.READY:
		connection_changed.emit("CORE // OFFLINE // IPC NOT READY")
	else:
		connection_changed.emit("CORE // APP REGISTRY ARRIVES IN PR 4")
	return false

func _attempt_connect() -> void:
	if not _bridge or _socket_path.is_empty():
		return
	connected = false
	welcome_received = false
	_waiting_for_pong = false
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
		"pong":
			var request_id := int(message.get("request_id", 0))
			if _waiting_for_pong and request_id > 0:
				_waiting_for_pong = false
				last_pong_request_id = request_id
				latency_changed.emit(Time.get_ticks_msec() - _ping_started_msec)
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

func _send_message(message: Dictionary) -> bool:
	return _bridge != null and _bridge.send_line(JSON.stringify(message))

func _set_state(next_state: ConnectionState, message: String) -> void:
	state = next_state
	state_changed.emit(state)
	connection_changed.emit(message)

