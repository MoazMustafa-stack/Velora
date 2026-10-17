extends StaticBody2D

const PixelArt = preload("res://scripts/pixel_art.gd")
const Actions = preload("res://scripts/input_actions.gd")

signal status_changed(message: String, tone: String)

@export var desktop_id := "code.desktop"
@export var display_name := "VS CODE"
@export_enum("editor", "browser", "terminal") var station_slot := "editor"
@export_enum("code", "browser", "terminal") var station_kind := "code"

@onready var sprite: Sprite2D = $Sprite2D

var status := "offline"
var application: Dictionary = {}
var registry_checked := false
var retry_available := false
# One of SessionBinding.STATE_*: unknown, not_running, running.
var running_state := "unknown"
var running_location := ""
var running_window_count := 0
var _default_id := ""
# Presentation only: launch eligibility still comes from the bound registry.
var _launch_badge := ""
var _selected := false
var _inspector_focused := false

func _ready() -> void:
	_default_id = desktop_id
	var footprint := Sprite2D.new()
	footprint.name = "Footprint"
	footprint.position = $CollisionShape2D.position
	footprint.z_index = -1
	footprint.texture = PixelArt.workshop_footprint_texture()
	add_child(footprint)
	_refresh_sprite()

func interaction_prompt() -> String:
	var key := "[%s] " % Actions.binding_label("interact", 1).to_upper()
	if registry_checked and application.is_empty():
		return key + "MISSING  " + application_label().to_upper()
	var running_suffix := ""
	match running_state:
		"running":
			running_suffix = " // RUNNING"
			if not running_location.is_empty():
				running_suffix += " WS" + running_location
			if running_window_count > 1:
				running_suffix += " x%d" % running_window_count
		"not_running":
			running_suffix = " // IDLE"
	if retry_available:
		return key + "RETRY  " + application_label().to_upper() + running_suffix
	return key + "USE  " + application_label().to_upper() + running_suffix

func apply_running_state(state: String, location := "", window_count := 0) -> void:
	running_state = state
	running_location = location
	running_window_count = window_count

func interact() -> void:
	if not registry_checked:
		status = "offline"
		_refresh_sprite()
		status_changed.emit(
			"VELORA // CORE OFFLINE // REGISTRY UNAVAILABLE",
			"failure"
		)
	elif application.is_empty():
		status = "offline"
		_refresh_sprite()
		status_changed.emit("VELORA // APPLICATION NOT FOUND", "failure")

func bind_application(value: Dictionary) -> void:
	registry_checked = true
	retry_available = false
	_launch_badge = ""
	if String(value.get("id", "")) != desktop_id:
		application.clear()
		status = "offline"
	else:
		application = value.duplicate(true)
		status = "ready"
	_refresh_sprite()

func is_application_available() -> bool:
	return not application.is_empty()

func set_selection(selected: bool, focused := false) -> void:
	_selected = selected
	_inspector_focused = selected and focused
	_refresh_sprite()

func application_label() -> String:
	var label := (display_name if desktop_id == _default_id else desktop_id) if application.is_empty() else String(application.get("name", display_name))
	return label.replace("\n", " ").replace("\r", " ").replace("\t", " ").left(128)

func apply_launch_feedback(stage: String, _message: String, retryable: bool) -> void:
	match stage:
		"launching_application":
			status = "attention"
			_launch_badge = "waiting"
			retry_available = false
		"launch_successful":
			status = "ready"
			_launch_badge = ""
			retry_available = false
		"launch_failed":
			status = "ready" if not application.is_empty() else "offline"
			_launch_badge = "failure"
			retry_available = retryable and not application.is_empty()
	_refresh_sprite()

func _refresh_sprite() -> void:
	var marker := "waiting" if status == "attention" else status
	if not _launch_badge.is_empty() and not application.is_empty():
		marker = _launch_badge
	sprite.texture = PixelArt.workshop_object_texture(station_kind, marker, _selected, _inspector_focused)
