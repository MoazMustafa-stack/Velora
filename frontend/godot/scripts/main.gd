extends Node2D

@onready var player: CharacterBody2D = $World/Player
@onready var workstation: StaticBody2D = $World/Objects/Workstation
@onready var backend: Node = $BackendClient
@onready var hud: CanvasLayer = $HUD

func _ready() -> void:
	player.interaction_changed.connect(hud.set_interaction_prompt)
	player.interaction_requested.connect(_on_interaction_requested)
	player.menu_requested.connect(hud.show_menu_hint)
	workstation.status_changed.connect(hud.set_status)
	backend.connection_changed.connect(hud.set_backend_status)
	hud.set_status("VELORA // POCKET TERMINAL")

func _on_interaction_requested(target: Node) -> void:
	if target.has_method("interact"):
		target.interact()
