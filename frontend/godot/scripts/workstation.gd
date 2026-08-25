extends StaticBody2D

const PixelArt = preload("res://scripts/pixel_art.gd")

signal status_changed(message: String, tone: String)

@export var desktop_id := "code.desktop"
@export var display_name := "VS CODE"
@export_enum("code", "browser", "terminal") var station_kind := "code"
@export var accent := Color("41d6c3")

@onready var sprite: Sprite2D = $Sprite2D

var status := "offline"
var application: Dictionary = {}
var registry_checked := false
var retry_available := false
# One of SessionBinding.STATE_*: unknown, not_running, running.
var running_state := "unknown"
var running_location := ""
var running_window_count := 0

func _ready() -> void:
	_refresh_sprite()

func interaction_prompt() -> String:
	if registry_checked and application.is_empty():
		return "[E] MISSING  " + display_name.to_upper()
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
		return "[E] RETRY  " + application_label().to_upper() + running_suffix
	return "[E] USE  " + application_label().to_upper() + running_suffix

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
	if String(value.get("id", "")) != desktop_id:
		application.clear()
		status = "offline"
	else:
		application = value.duplicate(true)
		status = "ready"
	_refresh_sprite()

func is_application_available() -> bool:
	return not application.is_empty()

func application_label() -> String:
	return display_name if application.is_empty() else String(application.get("name", display_name))

func apply_launch_feedback(stage: String, _message: String, retryable: bool) -> void:
	match stage:
		"launching_application":
			status = "attention"
			retry_available = false
		"launch_successful":
			status = "ready"
			retry_available = false
		"launch_failed":
			status = "ready" if not application.is_empty() else "offline"
			retry_available = retryable and not application.is_empty()
	_refresh_sprite()

func _refresh_sprite() -> void:
	sprite.texture = PixelArt.create_workstation_texture(status, accent, station_kind)
