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
	backend.applications_changed.connect(_on_applications_changed)
	if not backend.applications.is_empty():
		_on_applications_changed(backend.applications)
	hud.set_status("VELORA // POCKET TERMINAL")

func _on_interaction_requested(target: Node) -> void:
	if target.has_method("interact"):
		if "desktop_id" in target:
			var registry_rejected: bool = (
				"registry_checked" in target
				and target.registry_checked
				and target.has_method("is_application_available")
				and not target.is_application_available()
			)
			if not registry_rejected:
				backend.launch_app(target.desktop_id)
		target.interact()

func _on_applications_changed(applications: Array) -> void:
	var applications_by_id: Dictionary = {}
	for application in applications:
		if application is Dictionary:
			var desktop_id := String(application.get("id", ""))
			if not desktop_id.is_empty():
				applications_by_id[desktop_id] = application

	for station in get_tree().get_nodes_in_group("application_stations"):
		if "desktop_id" in station and station.has_method("bind_application"):
			station.bind_application(applications_by_id.get(station.desktop_id, {}))

func _toggle_menu() -> void:
	menu_open = not menu_open
	player.set_input_enabled(not menu_open)
	hud.set_menu_visible(menu_open)
