extends StaticBody2D

const PixelArt = preload("res://scripts/pixel_art.gd")

signal status_changed(message: String)

@onready var sprite: Sprite2D = $Sprite2D

var status := "offline"

func _ready() -> void:
	_refresh_sprite()

func interaction_prompt() -> String:
	return "[E] USE  VS CODE"

func interact() -> void:
	status = "attention"
	_refresh_sprite()
	status_changed.emit("VS CODE // CORE OFFLINE // PHASE 2")

func _refresh_sprite() -> void:
	sprite.texture = PixelArt.create_workstation_texture(status)
