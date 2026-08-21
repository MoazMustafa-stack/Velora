extends StaticBody2D

const PixelArt = preload("res://scripts/pixel_art.gd")

signal status_changed(message: String)

@export var desktop_id := "code.desktop"
@export var display_name := "VS CODE"
@export_enum("code", "browser", "terminal") var station_kind := "code"
@export var accent := Color("41d6c3")

@onready var sprite: Sprite2D = $Sprite2D

var status := "offline"
var application: Dictionary = {}
var registry_checked := false

func _ready() -> void:
	_refresh_sprite()

func interaction_prompt() -> String:
	if registry_checked and application.is_empty():
		return "[E] MISSING  " + display_name.to_upper()
	return "[E] USE  " + application_label().to_upper()

func interact() -> void:
	status = "attention"
	_refresh_sprite()
	if not registry_checked:
		status_changed.emit(display_name + " // CORE OFFLINE // REGISTRY UNAVAILABLE")
	elif application.is_empty():
		status_changed.emit(display_name + " // APPLICATION NOT FOUND")
	else:
		status_changed.emit(application_label() + " // LAUNCH REQUESTED")

func bind_application(value: Dictionary) -> void:
	registry_checked = true
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

func _refresh_sprite() -> void:
	sprite.texture = PixelArt.create_workstation_texture(status, accent, station_kind)
