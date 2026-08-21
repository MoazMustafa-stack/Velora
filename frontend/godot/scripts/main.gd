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
		station.status_changed.connect(_on_station_status_changed)
	backend.ux_status_changed.connect(_on_backend_ux_status)
	backend.launch_status_changed.connect(_on_launch_status_changed)
	backend.applications_changed.connect(_on_applications_changed)
	if not backend.applications.is_empty():
		_on_applications_changed(backend.applications)
	hud.set_status("VELORA // POCKET TERMINAL")

func _on_station_status_changed(message: String, tone: String) -> void:
	hud.show_transient(message, tone, 3.0)

func _on_backend_ux_status(
	stage: String,
	message: String,
	tone: String,
	transient_seconds: float
) -> void:
	match stage:
		"core_offline":
			hud.set_connection_status("CORE OFFLINE", "failure")
		"connecting":
			hud.set_connection_status("CONNECTING", "waiting")
		"connected", "loading_applications", "ready":
			hud.set_connection_status("CONNECTED", "ready")
		"reconnecting":
			hud.set_connection_status("RECONNECTING", "waiting")
		"protocol_incompatible":
			hud.set_connection_status("INCOMPATIBLE", "failure")

	var hud_message := "VELORA // " + message
	if transient_seconds < 0.0:
		hud.set_status(hud_message, tone)
	else:
		hud.show_transient(hud_message, tone, transient_seconds)

func _on_launch_status_changed(
	desktop_id: String,
	stage: String,
	message: String,
	retryable: bool
) -> void:
	for station in get_tree().get_nodes_in_group("application_stations"):
		if "desktop_id" in station and station.desktop_id == desktop_id:
			station.apply_launch_feedback(stage, message, retryable)
			return

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
