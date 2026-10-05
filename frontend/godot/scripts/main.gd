extends Node2D

const Actions = preload("res://scripts/input_actions.gd")
const Overlay = preload("res://ui/overlay_coordinator.gd")
const SessionBinding = preload("res://scripts/session_binding.gd")
const Store = preload("res://scripts/settings_store.gd")
const Onboarding = preload("res://ui/onboarding.gd")

# Tests and performance fixtures disable all preference IO, or inject a temp path.
@export var load_preferences := true
@export var preferences_path := Store.DEFAULT_PATH
var settings: RefCounted
var onboarding: RefCounted
var preferences_error: Error = OK
var _last_player_position := Vector2.ZERO

@onready var player: CharacterBody2D = $World/Player
@onready var backend: Node = $BackendClient
@onready var hud: CanvasLayer = $HUD
@onready var workspace_map: CanvasLayer = $WorkspaceMap
@onready var notification_feed: CanvasLayer = $NotificationFeed
@onready var media_console: CanvasLayer = $MediaConsole
@onready var pause_panel: CanvasLayer = $PausePanel

var overlays: RefCounted
# Read-only compatibility views; the coordinator is the only state owner.
var menu_open: bool:
	get: return overlays.current == Overlay.Mode.PAUSE
var map_open: bool:
	get: return overlays.current == Overlay.Mode.WORKSPACES
var feed_open: bool:
	get: return overlays.current == Overlay.Mode.NOTIFICATIONS
var media_open: bool:
	get: return overlays.current == Overlay.Mode.MEDIA
var _stations: Array[Node] = []

func _ready() -> void:
	Actions.ensure_registered()
	settings = Store.new(preferences_path)
	if load_preferences:
		preferences_error = settings.load_settings()
	onboarding = Onboarding.new(settings.onboarding_completed())
	onboarding.changed.connect(_refresh_help)
	onboarding.completed.connect(_complete_onboarding)
	_last_player_position = player.position
	_refresh_help()
	pause_panel.configure(backend)
	hud.attach_pause(pause_panel)
	pause_panel.resume_requested.connect(func(): overlays.close(Overlay.Mode.PAUSE))
	pause_panel.replay_requested.connect(func(): replay_onboarding(); overlays.close(Overlay.Mode.PAUSE))
	pause_panel.dismiss_requested.connect(func(): onboarding.dismiss(); overlays.close(Overlay.Mode.PAUSE))
	overlays = Overlay.new(player, hud, {
		Overlay.Mode.PAUSE: pause_panel,
		Overlay.Mode.WORKSPACES: workspace_map,
		Overlay.Mode.NOTIFICATIONS: notification_feed,
		Overlay.Mode.MEDIA: media_console,
	})
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
	backend.notifications_policy_changed.connect(notification_feed.set_policy_disabled)
	backend.state_changed.connect(_on_core_state_changed)
	for signal_name in ["session_availability_changed", "telemetry_availability_changed", "notifications_availability_changed", "notifications_policy_changed", "media_availability_changed"]:
		backend.connect(signal_name, func(_value): pause_panel.refresh())
	notification_feed.feed_closed.connect(_on_feed_closed)
	notification_feed.set_availability(backend.notifications_availability)
	notification_feed.set_policy_disabled(backend.notifications_policy_disabled)
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
	_on_core_state_changed(backend.state)
	if preferences_error != OK:
		hud.show_transient("SETTINGS INVALID // USING DEFAULTS", "waiting", 4.0)

func _process(_delta: float) -> void:
	if onboarding.active and overlays.current == Overlay.Mode.NONE and player.position != _last_player_position:
		onboarding.observe("move")
	_last_player_position = player.position

func _refresh_help() -> void:
	hud.set_help(onboarding.hint())

func _complete_onboarding() -> void:
	settings.set_onboarding_completed(true)
	_save_preferences()

func replay_onboarding() -> void:
	settings.set_onboarding_completed(false)
	onboarding.replay()
	_save_preferences()

func _save_preferences() -> Error:
	preferences_error = settings.save_settings() if load_preferences else OK
	if preferences_error != OK:
		hud.show_transient("SETTINGS NOT SAVED // CHECK ACCESS", "failure", 4.0)
	return preferences_error

func _on_core_state_changed(state: int) -> void:
	var online := state == BackendClient.ConnectionState.READY
	for panel in [workspace_map, notification_feed, media_console]:
		panel.set_core_online(online)
	pause_panel.refresh()

func _input(event: InputEvent) -> void:
	if Actions.pressed(event, "back") or Actions.pressed(event, "menu"):
		get_viewport().set_input_as_handled()
		_toggle_menu()

func _unhandled_input(event: InputEvent) -> void:
	if overlays.current != Overlay.Mode.NONE:
		return
	if Actions.pressed(event, "workspace_map"):
		get_viewport().set_input_as_handled()
		_toggle_workspace_map()
	elif Actions.pressed(event, "notification_feed"):
		get_viewport().set_input_as_handled()
		_toggle_notification_feed()
	elif Actions.pressed(event, "media_console"):
		get_viewport().set_input_as_handled()
		_toggle_media_console()

func _toggle_workspace_map() -> void:
	onboarding.observe("map")
	overlays.toggle(Overlay.Mode.WORKSPACES)

func _on_map_closed() -> void:
	overlays.close(Overlay.Mode.WORKSPACES)

func _toggle_notification_feed() -> void:
	onboarding.observe("feed")
	if not feed_open:
		backend.request_notifications()
	overlays.toggle(Overlay.Mode.NOTIFICATIONS)

func _on_feed_closed() -> void:
	overlays.close(Overlay.Mode.NOTIFICATIONS)

func _toggle_media_console() -> void:
	onboarding.observe("media")
	if not media_open:
		backend.request_media_snapshot()
	overlays.toggle(Overlay.Mode.MEDIA)

func _on_media_console_closed() -> void:
	overlays.close(Overlay.Mode.MEDIA)

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
	pause_panel.refresh()

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
		onboarding.observe("interact")
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
	if overlays.current != Overlay.Mode.NONE:
		if menu_open and pause_panel.back(): return
		overlays.back()
	else:
		onboarding.observe("pause")
		overlays.open(Overlay.Mode.PAUSE)
