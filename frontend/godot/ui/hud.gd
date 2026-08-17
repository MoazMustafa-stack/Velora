extends CanvasLayer

@onready var status: Label = $Panel/Margin/Status

func set_player(player: CharacterBody3D) -> void:
	player.interaction_changed.connect(_on_interaction_changed)
	status.text = "VELORA // CORE: START ./scripts/run-core.sh"

func _on_interaction_changed(prompt: String) -> void:
	status.text = prompt if not prompt.is_empty() else "VELORA // WASD MOVE · E INTERACT · ESC RELEASE MOUSE"

func set_backend_status(message: String) -> void:
	status.text = "VELORA // " + message
