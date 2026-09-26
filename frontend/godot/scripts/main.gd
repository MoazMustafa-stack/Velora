extends Node2D

const SessionBinding = preload("res://scripts/session_binding.gd")

@onready var player: CharacterBody2D = $World/Player
@onready var backend: Node = $BackendClient
@onready var hud: CanvasLayer = $HUD
@onready var workspace_map: CanvasLayer = $WorkspaceMap
@onready var notification_feed: CanvasLayer = $NotificationFeed
@onready var media_console: CanvasLayer = $MediaConsole

var menu_open := false
var map_open := false
var feed_open := false
var media_open := false
var _stations: Array[Node] = []

func _ready() -> void:
	player.interaction_changed.connect(hud.set_interaction_prompt)
	player.interaction_requested.connect(_on_interaction_requested)
	player.menu_requested.connect(_toggle_menu)
	for station in get_tree().get_nodes_in_group("application_stations"):
		_stations.append(station)
		station.status_changed.connect(_on_station_status_changed)
	backend.ux_status_changed.connect(_on_backend_ux_status)
	backend.launch_status_changed.connect(_on_launch_status_changed)
	backend.applications_changed.connect(_on_applications_changed)
	backend.session_snapshot_changed.connect(_on_session_snapshot_changed)
	backend.session_availability_changed.connect(_on_session_availability_changed)
	backend.telemetry_snapshot_changed.connect(hud.set_telemetry_snapshot)
	backend.telemetry_availability_changed.connect(hud.set_telemetry_availability)
	backend.notification_feed_changed.connect(notification_feed.update_feed)
	backend.notifications_availability_changed.connect(notification_feed.set_availability)
	notification_feed.feed_closed.connect(_on_feed_closed)
	notification_feed.set_availability(backend.notifications_availability)
	if not backend.notification_feed.is_empty():
		notification_feed.update_feed(backend.notification_feed)
	backend.media_snapshot_changed.connect(media_console.update_media)
	backend.media_availability_changed.connect(media_console.set_availability)
	backend.media_control_accepted.connect(media_console.apply_control_accepted)
	backend.media_control_rejected.connect(media_console.apply_control_rejected)
	media_console.control_requested.connect(backend.send_media_control)
	media_console.console_closed.connect(_on_media_console_closed)
	media_console.set_availability(backend.media_availability)
	if not backend.media_snapshot.is_empty():
		media_console.update_media(backend.media_snapshot)
	workspace_map.map_closed.connect(_on_map_closed)
	workspace_map.switch_requested.connect(backend.request_switch_workspace)
	if backend.session_availability != "unknown":
		_on_session_availability_changed(backend.session_availability)
	if not backend.applications.is_empty():
		_on_applications_changed(backend.applications)
	hud.set_status("VELORA // POCKET TERMINAL")

func _unhandled_input(event: InputEvent) -> void:
	if menu_open or map_open or feed_open or media_open or not event is InputEventKey:
		return
	if not event.pressed or event.echo:
		return
	if event.keycode in [KEY_TAB, KEY_M]:
		get_viewport().set_input_as_handled()
		_toggle_workspace_map()
	elif event.keycode == KEY_N:
		get_viewport().set_input_as_handled()
		_toggle_notification_feed()
	elif event.keycode == KEY_P:
		get_viewport().set_input_as_handled()
		_toggle_media_console()

func _toggle_workspace_map() -> void:
	map_open = true
	player.set_input_enabled(false)
	workspace_map.open()

func _on_map_closed() -> void:
	map_open = false
	player.set_input_enabled(true)

func _toggle_notification_feed() -> void:
	feed_open = true
	player.set_input_enabled(false)
	# Scene-driven refresh: the client fetches once per connection, so the
	# panel asks for a fresh single-flight feed whenever it is inspected.
	backend.request_notifications()
	notification_feed.open()

func _on_feed_closed() -> void:
	feed_open = false
	player.set_input_enabled(true)

func _toggle_media_console() -> void:
	media_open = true
	player.set_input_enabled(false)
	# Scene-driven refresh: the client fetches once per connection, so the
	# console asks for a fresh single-flight snapshot whenever it is opened.
	backend.request_media_snapshot()
	media_console.open()

func _on_media_console_closed() -> void:
	media_open = false
	player.set_input_enabled(true)

func _on_session_snapshot_changed(snapshot: Dictionary) -> void:
	workspace_map.update_session(snapshot)
	_refresh_station_running_states(snapshot)

func _on_session_availability_changed(availability: String) -> void:
	workspace_map.set_availability(availability)
	if availability != "available":
		_refresh_station_running_states({})

func _refresh_station_running_states(snapshot: Dictionary) -> void:
	var availability: String = backend.session_availability if not snapshot.is_empty() else "unavailable"
	var station_applications: Array = []
	for station in _stations:
		if station.application is Dictionary and not station.application.is_empty():
			station_applications.append(station.application)
	var running := SessionBinding.running_applications(
		station_applications,
		snapshot.get("windows", [])
	)
	for station in _stations:
		if not station.has_method("apply_running_state"):
			continue
		var state: Dictionary = SessionBinding.station_running_state_from_matches(
			station.desktop_id,
			snapshot,
			availability,
			station.application,
			running
		)
		station.apply_running_state(
			String(state["state"]),
			String(state["location"]),
			int(state["windows"])
		)

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
	for station in _stations:
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

	for station in _stations:
		if "desktop_id" in station and station.has_method("bind_application"):
			station.bind_application(applications_by_id.get(station.desktop_id, {}))

func _toggle_menu() -> void:
	menu_open = not menu_open
	player.set_input_enabled(not menu_open)
	hud.set_menu_visible(menu_open)
