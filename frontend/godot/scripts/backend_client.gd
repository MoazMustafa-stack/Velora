class_name BackendClient
extends Node

## Phase 1 frontend boundary.
##
## Godot 4.7 does not expose Unix-domain sockets to GDScript. Phase 1 keeps
## this typed, signal-based boundary offline-safe; Phase 2 will provide the
## native Unix-socket transport without leaking Linux commands into the UI.

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
		connection_changed.emit("CORE: OFFLINE — PHASE 2 IPC NOT CONNECTED")
		return false
	return false

func _announce_offline() -> void:
	connection_changed.emit("CORE: OFFLINE — SPATIAL PROTOTYPE MODE")
