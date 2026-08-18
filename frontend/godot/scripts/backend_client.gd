class_name BackendClient
extends Node

## Offline-safe frontend boundary for the future native core transport.
##
## Godot does not expose Unix-domain sockets directly to GDScript. Phase 1
## therefore keeps the Linux integration behind signals and semantic methods;
## Phase 2 can replace the transport without coupling UI nodes to shell calls.

signal connection_changed(message: String)
signal application_state_changed(desktop_id: String, running: bool)

var connected := false

func _ready() -> void:
	call_deferred("_announce_offline")

func connect_to_core() -> void:
	connected = false
	_announce_offline()

func launch_app(_desktop_id: String) -> bool:
	if not connected:
		connection_changed.emit("CORE: OFFLINE // PHASE 2 IPC")
		return false
	return false

func _announce_offline() -> void:
	connection_changed.emit("CORE: OFFLINE // PIXEL HUB MODE")
