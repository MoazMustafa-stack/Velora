extends StaticBody2D

const PixelArt = preload("res://scripts/pixel_art.gd")

signal status_changed(message: String)

@export var desktop_id := "code.desktop"
@export var display_name := "VS CODE"
@export_enum("code", "browser", "terminal") var station_kind := "code"
@export var accent := Color("41d6c3")

@onready var sprite: Sprite2D = $Sprite2D

var status := "offline"

func _ready() -> void:
	_refresh_sprite()

func interaction_prompt() -> String:
	return "[E] USE  " + display_name

func interact() -> void:
	status = "attention"
	_refresh_sprite()
	status_changed.emit(display_name + " // CORE OFFLINE // PHASE 2")

func _refresh_sprite() -> void:
	sprite.texture = PixelArt.create_workstation_texture(status, accent, station_kind)
