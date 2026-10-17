extends Node2D

const Actions = preload("res://scripts/input_actions.gd")
const Overlay = preload("res://ui/overlay_coordinator.gd")
const SessionBinding = preload("res://scripts/session_binding.gd")
const Store = preload("res://scripts/settings_store.gd")
const Onboarding = preload("res://ui/onboarding.gd")
const UiAudio = preload("res://scripts/ui_audio.gd")
const Bindings = preload("res://scripts/key_bindings.gd")
const Mappings = preload("res://scripts/station_mappings.gd")
const WorkshopView = preload("res://ui/workshop_view.gd")
const Selection = preload("res://scripts/application_selection.gd")
const Inspector = preload("res://ui/application_inspector.gd")

# Tests and performance fixtures disable all preference IO, or inject a temp path.
@export var load_preferences := true
@export var preferences_path := Store.DEFAULT_PATH
# Fixture injection only: historical density proofs bypass production composition.
@export var compose_workshop := true
var workshop: Node
var inspector: Control
var selection := Selection.new()
var settings: RefCounted
var onboarding: RefCounted
var preferences_error: Error = OK
var _last_player_position := Vector2.ZERO
var ui_audio: Node

@onready var player: CharacterBody2D = $World/Player
@onready var world: Node2D = $World
@onready var backend: Node = $BackendClient
@onready var hud: CanvasLayer = $HUD
@onready var workspace_map: CanvasLayer = $WorkspaceMap
@onready var notification_feed: CanvasLayer = $NotificationFeed
@onready var media_console: CanvasLayer = $MediaConsole
@onready var pause_panel: CanvasLayer = $PausePanel
@onready var observatory: CanvasLayer = $Observatory

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
var _applications_by_id: Dictionary = {}
var _registry_received := false

func _ready() -> void:
	if compose_workshop:
		workshop = WorkshopView.new()
		add_child(workshop)
		workshop.configure(world, hud, [pause_panel, workspace_map, notification_feed, media_console, observatory])
		var inspector_layer := CanvasLayer.new()
		inspector_layer.layer = 7
		add_child(inspector_layer)
		inspector = Inspector.new()
		inspector_layer.add_child(inspector)
		inspector.back_requested.connect(func(): overlays.close(Overlay.Mode.INSPECTOR))
	Actions.ensure_registered()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	settings = Store.new(preferences_path)
	if load_preferences:
		preferences_error = settings.load_settings()
	ui_audio = UiAudio.new()
	add_child(ui_audio)
	_apply_preferences()
	onboarding = Onboarding.new(settings.onboarding_completed())
	onboarding.changed.connect(_refresh_help)
	onboarding.completed.connect(_complete_onboarding)
	_last_player_position = player.position
	_refresh_help()
	pause_panel.configure(backend, settings)
	hud.attach_pause(pause_panel)
	pause_panel.resume_requested.connect(func(): overlays.close(Overlay.Mode.PAUSE))
	pause_panel.replay_requested.connect(func(): replay_onboarding(); overlays.close(Overlay.Mode.PAUSE))
	pause_panel.dismiss_requested.connect(func(): onboarding.dismiss(); overlays.close(Overlay.Mode.PAUSE))
	pause_panel.preferences_changed.connect(_on_preferences_changed)
	pause_panel.reset_requested.connect(reset_preferences)
	pause_panel.binding_requested.connect(_on_binding_requested)
	pause_panel.bindings_reset_requested.connect(_reset_bindings)
	pause_panel.station_mapping_requested.connect(_on_station_mapping_requested)
	pause_panel.station_mappings_reset_requested.connect(_reset_station_mappings)
	for panel in [pause_panel, workspace_map, notification_feed, media_console]:
		panel.ui_cue_requested.connect(ui_audio.play_cue)
	overlays = Overlay.new(player, hud, {
		Overlay.Mode.PAUSE: pause_panel,
		Overlay.Mode.WORKSPACES: workspace_map,
		Overlay.Mode.NOTIFICATIONS: notification_feed,
		Overlay.Mode.MEDIA: media_console,
		Overlay.Mode.OBSERVATORY: observatory,
	}, inspector)
	overlays.changed.connect(_on_context_changed)
	player.interaction_changed.connect(hud.set_interaction_prompt)
	player.target_changed.connect(_on_nearby_target_changed)
	player.interaction_changed.connect(func(_prompt): _refresh_inspector())
	player.interaction_requested.connect(_on_interaction_requested)
	player.menu_requested.connect(_toggle_menu)
	for object in get_tree().get_nodes_in_group("hub_objects"):
		object.activated.connect(_on_hub_object_activated)
	observatory.observatory_closed.connect(func(): overlays.close(Overlay.Mode.OBSERVATORY))
	for station in get_tree().get_nodes_in_group("application_stations"):
		_stations.append(station)
		station.status_changed.connect(_on_station_status_changed)
	_apply_station_mappings()
	backend.ux_status_changed.connect(_on_backend_ux_status)
	backend.launch_status_changed.connect(_on_launch_status_changed)
	backend.applications_changed.connect(_on_applications_changed)
	backend.session_snapshot_changed.connect(_on_session_snapshot_changed)
	backend.session_availability_changed.connect(_on_session_availability_changed)
	backend.telemetry_snapshot_changed.connect(hud.set_telemetry_snapshot)
	backend.telemetry_availability_changed.connect(hud.set_telemetry_availability)
	backend.telemetry_snapshot_changed.connect(observatory.update_snapshot)
	backend.telemetry_availability_changed.connect(observatory.set_availability)
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
	backend.media_control_rejected.connect(func(_handle, _verb, _code, _message, _retryable): ui_audio.play_cue("reject"))
	media_console.control_requested.connect(backend.send_media_control)
	media_console.control_requested.connect(func(_handle, _verb): ui_audio.play_cue("media"))
	media_console.console_closed.connect(_on_media_console_closed)
	media_console.set_availability(backend.media_availability)
	if not backend.media_snapshot.is_empty():
		media_console.update_media(backend.media_snapshot)
	workspace_map.map_closed.connect(_on_map_closed)
	workspace_map.switch_requested.connect(backend.request_switch_workspace)
	workspace_map.switch_requested.connect(func(_handle): ui_audio.play_cue("confirm"))
	if backend.session_availability != "unknown":
		_on_session_availability_changed(backend.session_availability)
	if not backend.applications.is_empty():
		_on_applications_changed(backend.applications)
	hud.set_status("VELORA // POCKET TERMINAL")
	_on_core_state_changed(backend.state)
	if preferences_error != OK:
		hud.show_transient("SETTINGS INVALID // USING DEFAULTS", "waiting", 4.0)
	_refresh_inspector()

func _process(_delta: float) -> void:
	if onboarding.active and overlays.current == Overlay.Mode.NONE and player.position != _last_player_position:
		onboarding.observe("move")
	_last_player_position = player.position

func _refresh_help() -> void:
	hud.set_help(onboarding.hint())
	_refresh_inspector()

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

func _on_preferences_changed(success_message := "SAVED // UI PREFERENCES ONLY") -> Error:
	_apply_preferences()
	var error := _save_preferences()
	if error != OK:
		ui_audio.play_cue("reject")
		pause_panel.set_feedback("APPLIED // NOT SAVED // CHECK FILE ACCESS")
	else:
		ui_audio.play_cue("confirm")
		pause_panel.set_feedback(success_message)
	return error

func _apply_preferences() -> void:
	player.set_reduced_motion(settings.reduced_motion())
	if ui_audio != null: ui_audio.configure(settings.audio_muted(), settings.audio_volume())
	if not Bindings.apply(settings):
		# Malformed/conflicting keyboard configuration fails to reachable defaults.
		settings.clear_bindings()
		hud.show_transient("CONTROLS INVALID // DEFAULTS RESTORED", "waiting", 4.0)
	if onboarding != null: _refresh_help()
	_apply_station_mappings()
	if not settings.invalid_station_slots().is_empty():
		hud.show_transient("STATION ID INVALID // DEFAULT USED", "waiting", 4.0)

func _apply_station_mappings() -> void:
	var changed := false
	for station in _stations:
		var slot: String = station.station_slot
		var target_id: String = Mappings.desktop_id(settings, slot)
		var checked: bool = _registry_received or not settings.station_desktop_id(slot).is_empty()
		var application: Dictionary = _applications_by_id.get(target_id, {}) if checked else {}
		if station.desktop_id == target_id and station.registry_checked == checked and station.application == application:
			continue
		station.desktop_id = target_id
		changed = true
		# A saved but unknown ID is unavailable even before the first catalog.
		if checked:
			station.bind_application(application)
		else:
			station.registry_checked = false
			station.application.clear()
			station.status = "offline"
			station.retry_available = false
			station._refresh_sprite()
	if player.input_enabled: player.refresh_interaction()
	if changed: _refresh_station_running_states(backend.session_snapshot)
	_on_nearby_target_changed(player.active_interactable)

func _on_station_mapping_requested(slot: String, id: String) -> void:
	var problem := "INVALID SLOT" if not Mappings.DEFAULTS.has(slot) else ""
	if problem.is_empty() and not id.is_empty():
		problem = "CORE OFFLINE // RECONNECT FIRST" if backend.state != BackendClient.ConnectionState.READY else Mappings.choose_reason(slot, id, _applications_by_id)
	if not problem.is_empty():
		pause_panel.set_feedback(problem)
		ui_audio.play_cue("reject")
		return
	if id.is_empty(): settings.clear_station_mapping(slot)
	else: settings.set_station_desktop_id(slot, id)
	pause_panel.show_page("stations")
	_on_preferences_changed("STATION MAPPED // CORE STILL VALIDATES LAUNCH")

func _reset_station_mappings() -> void:
	settings.clear_station_mappings()
	_on_preferences_changed("DEFAULT STATIONS RESTORED")

func _on_binding_requested(action: String, keys: Array) -> void:
	var problem := Bindings.remap_reason(settings, action, keys)
	if not problem.is_empty():
		pause_panel.set_feedback(problem)
		ui_audio.play_cue("reject")
		return
	settings.set_action_keys(action, keys)
	_on_preferences_changed()
	pause_panel.refresh()

func _reset_bindings() -> void:
	settings.clear_bindings()
	_on_preferences_changed("DEFAULT KEYS RESTORED // CONTROLLER UNCHANGED")

func reset_preferences() -> void:
	# Disabled IO means reset is in-memory too, never delete the production file.
	preferences_error = settings.reset() if load_preferences else OK
	if preferences_error != OK:
		pause_panel.set_feedback("RESET FAILED // ORIGINAL SETTINGS KEPT")
		return
	settings = Store.new(preferences_path)
	_apply_preferences()
	pause_panel.configure(backend, settings)
	onboarding.replay()
	pause_panel.show_page("settings")
	pause_panel.set_feedback("RESET COMPLETE // HINTS RESTART ON RESUME")

func _on_core_state_changed(state: int) -> void:
	var online := state == BackendClient.ConnectionState.READY
	for panel in [workspace_map, notification_feed, media_console, observatory]:
		panel.set_core_online(online)
	pause_panel.refresh()

func _on_hub_object_activated(kind: String) -> void:
	match kind:
		"map": _toggle_workspace_map()
		"media": _toggle_media_console()
		"notifications": _toggle_notification_feed()
		"observatory":
			backend.request_telemetry_snapshot()
			overlays.open(Overlay.Mode.OBSERVATORY)

func _input(event: InputEvent) -> void:
	if Actions.observe_input(event): _refresh_input_labels()
	if pause_panel.capturing_key and not event is InputEventKey:
		if Actions.pressed(event, "back") or Actions.pressed(event, "menu"):
			pause_panel.cancel_capture()
		get_viewport().set_input_as_handled()
		return
	if pause_panel.capturing_key and event is InputEventKey:
		get_viewport().set_input_as_handled()
		pause_panel.capture_key(event)
		return
	if Actions.pressed(event, "back") or Actions.pressed(event, "menu"):
		get_viewport().set_input_as_handled()
		_toggle_menu()
		return
	if inspector != null and Actions.pressed(event, "focus_inspector") and overlays.current in [Overlay.Mode.NONE, Overlay.Mode.INSPECTOR]:
		get_viewport().set_input_as_handled()
		overlays.toggle(Overlay.Mode.INSPECTOR)
		return
	if overlays.current == Overlay.Mode.INSPECTOR:
		# Own this context before native GUI ui_accept can bypass remapped
		# confirm, or the same Enter can fall through into world activation.
		get_viewport().set_input_as_handled()
		if Actions.pressed(event, "confirm"): overlays.close(Overlay.Mode.INSPECTOR)
		elif Actions.pressed(event, "workspace_map"): _toggle_workspace_map()
		elif Actions.pressed(event, "notification_feed"): _toggle_notification_feed()
		elif Actions.pressed(event, "media_console"): _toggle_media_console()

func _refresh_input_labels() -> void:
	_refresh_help()
	player.refresh_interaction()
	pause_panel.refresh()
	for panel in [workspace_map, notification_feed, media_console]: panel._refresh_hint()
	observatory.refresh()
	_refresh_inspector()

func _on_nearby_target_changed(target: Node) -> void:
	if is_instance_valid(target) and target.is_in_group("application_stations"):
		selection.observe_nearby(target.desktop_id, target.application)
	else:
		selection.observe_nearby("")
	_refresh_inspector()

func _on_context_changed(_mode: int) -> void:
	if workshop != null: workshop.call_deferred("fit_panels")
	_refresh_inspector()

func _refresh_inspector() -> void:
	if inspector == null or backend == null: return
	var view := selection.view()
	var focused: bool = overlays != null and overlays.current == Overlay.Mode.INSPECTOR
	for station in _stations:
		station.set_selection(station.desktop_id == view.selected_id, focused)
	var core_state: String = {
		BackendClient.ConnectionState.DISCONNECTED: "offline",
		BackendClient.ConnectionState.CONNECTING: "connecting",
		BackendClient.ConnectionState.HANDSHAKING: "connected",
		BackendClient.ConnectionState.READY: "ready",
		BackendClient.ConnectionState.RECONNECTING: "reconnecting",
		BackendClient.ConnectionState.INCOMPATIBLE: "protocol_incompatible",
	}.get(backend.state, "offline")
	inspector.update_view(view, {
		"core_state": core_state,
		"registry_empty": _registry_received and _applications_by_id.is_empty(),
		"nearby_prompt": hud.prompt.text,
		"focus_hint": "[%s] INSPECT" % Actions.binding_label("focus_inspector", 1),
	})

func _on_joy_connection_changed(device: int, connected: bool) -> void:
	if connected: return
	var was_active := Actions.active_device == device
	Actions.release_controller(device)
	if was_active:
		player.velocity = Vector2.ZERO
		_refresh_input_labels()
		hud.show_transient("CONTROLLER LOST // KEYBOARD READY", "waiting", 3.0)

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
	elif workshop != null and workshop.forward_world_input(event):
		get_viewport().set_input_as_handled()

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
	if tone == "failure": ui_audio.play_cue("reject")
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
	if stage in ["launch_successful", "launch_failed"]:
		ui_audio.play_cue("confirm" if stage == "launch_successful" else "reject")
	for station in _stations:
		if "desktop_id" in station and station.desktop_id == desktop_id:
			station.apply_launch_feedback(stage, message, retryable)
			return

func _on_interaction_requested(target: Node) -> void:
	# Inspection can outlive proximity, but it can never grant world authority.
	if not player.input_enabled or overlays.current != Overlay.Mode.NONE or not is_instance_valid(target) or target != player.active_interactable:
		return
	if target.has_method("interact"):
		ui_audio.play_cue("interact")
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
	selection.update_registry(applications)
	_applications_by_id.clear()
	_registry_received = true
	for application in applications:
		if application is Dictionary:
			var desktop_id := String(application.get("id", ""))
			if Store._valid_desktop_id(desktop_id):
				_applications_by_id[desktop_id] = application
	_apply_station_mappings()
	pause_panel.set_registry(_applications_by_id)

func _toggle_menu() -> void:
	ui_audio.play_cue("confirm")
	if overlays.current != Overlay.Mode.NONE:
		if menu_open and pause_panel.back(): return
		overlays.back()
	else:
		onboarding.observe("pause")
		overlays.open(Overlay.Mode.PAUSE)
