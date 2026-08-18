extends Node2D

@onready var player: CharacterBody2D = $World/Player
@onready var backend: Node = $BackendClient
@onready var hud: CanvasLayer = $HUD

var menu_open := false

func _ready() -> void:
	player.interaction_changed.connect(hud.set_interaction_prompt)
	player.interaction_requested.connect(_on_interaction_requested)
	player.menu_requested.connect(_toggle_menu)
	for station in get_tree().get_nodes_in_group("application_stations"):
		station.status_changed.connect(hud.set_status)
	backend.connection_changed.connect(hud.set_backend_status)
	hud.set_status("VELORA // POCKET TERMINAL")

func _on_interaction_requested(target: Node) -> void:
	if target.has_method("interact"):
		if "desktop_id" in target:
			backend.launch_app(target.desktop_id)
		target.interact()

func _toggle_menu() -> void:
	menu_open = not menu_open
	player.set_input_enabled(not menu_open)
	hud.set_menu_visible(menu_open)
