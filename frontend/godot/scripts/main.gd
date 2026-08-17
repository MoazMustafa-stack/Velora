extends Node3D

@onready var player: CharacterBody3D = $Player
@onready var hud: CanvasLayer = $HUD
@onready var terminal: StaticBody3D = $VSCodeTerminal
@onready var backend: BackendClient = $BackendClient

func _ready() -> void:
	hud.set_player(player)
	terminal.set_backend(backend)
	backend.connection_changed.connect(hud.set_backend_status)
