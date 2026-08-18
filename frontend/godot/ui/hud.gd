extends CanvasLayer

@onready var status: Label = $StatusPanel/Margin/Status
@onready var prompt_panel: PanelContainer = $PromptPanel
@onready var prompt: Label = $PromptPanel/Margin/Prompt
@onready var menu_overlay: Control = $MenuOverlay

var _world_status := "VELORA // POCKET TERMINAL"

func _ready() -> void:
	prompt_panel.visible = false

func set_interaction_prompt(message: String) -> void:
	prompt.text = message
	prompt_panel.visible = not message.is_empty()

func set_status(message: String) -> void:
	_world_status = message
	if not menu_overlay.visible:
		status.text = _world_status

func set_backend_status(message: String) -> void:
	_world_status = "VELORA // " + message
	if not menu_overlay.visible:
		status.text = _world_status

func set_menu_visible(visible: bool) -> void:
	menu_overlay.visible = visible
	if visible:
		prompt_panel.visible = false
		status.text = "VELORA // PAUSED"
	else:
		status.text = _world_status
