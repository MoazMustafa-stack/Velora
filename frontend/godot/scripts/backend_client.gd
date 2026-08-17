class_name BackendClient
extends Node

signal connection_changed(message: String)
signal application_state_changed(desktop_id: String, running: bool)

const PROTOCOL_VERSION := 1
var socket := StreamPeerUnix.new()
var connected := false
var receive_buffer := ""

func _ready() -> void:
	connect_to_core()

func _process(_delta: float) -> void:
	if not connected:
		return
	var available := socket.get_available_bytes()
	if available <= 0:
		return
	var result := socket.get_data(available)
	if result[0] != OK:
		_disconnect("CORE: DISCONNECTED")
		return
	receive_buffer += result[1].get_string_from_utf8()
	var lines := receive_buffer.split("\n", false)
	receive_buffer = "" if receive_buffer.ends_with("\n") else lines.pop_back()
	for line in lines:
		_handle_response(line)

func connect_to_core() -> void:
	var runtime_dir := OS.get_environment("XDG_RUNTIME_DIR")
	var path := runtime_dir.path_join("velora.sock") if not runtime_dir.is_empty() else "/tmp/velora-%s.sock" % OS.get_environment("UID")
	if socket.connect_to_socket(path) != OK:
		connection_changed.emit("CORE: OFFLINE — START ./scripts/run-core.sh")
		return
	connected = true
	connection_changed.emit("CORE: CONNECTED")
	_send({"protocol_version": PROTOCOL_VERSION, "type": "ping"})

func launch_app(desktop_id: String) -> bool:
	if not connected:
		return false
	return _send({"protocol_version": PROTOCOL_VERSION, "type": "launch_app", "desktop_id": desktop_id})

func _send(message: Dictionary) -> bool:
	var payload := JSON.stringify(message) + "\n"
	if socket.put_data(payload.to_utf8_buffer()) != OK:
		_disconnect("CORE: DISCONNECTED")
		return false
	return true

func _handle_response(line: String) -> void:
	var decoded = JSON.parse_string(line)
	if typeof(decoded) != TYPE_DICTIONARY:
		connection_changed.emit("CORE: INVALID RESPONSE")
		return
	if decoded.get("type") == "pong":
		connection_changed.emit("CORE: CONNECTED // PONG")
	elif decoded.get("type") == "application_state":
		application_state_changed.emit(decoded.get("desktop_id", ""), decoded.get("running", false))
	elif decoded.get("type") == "error":
		connection_changed.emit("CORE: %s" % decoded.get("message", "ERROR"))

func _disconnect(message: String) -> void:
	connected = false
	socket = StreamPeerUnix.new()
	connection_changed.emit(message)
