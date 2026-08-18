extends CanvasLayer

@onready var status: Label = $StatusPanel/Margin/Status
@onready var prompt_panel: PanelContainer = $PromptPanel
@onready var prompt: Label = $PromptPanel/Margin/Prompt

func _ready() -> void:
	prompt_panel.visible = false

func set_interaction_prompt(message: String) -> void:
	prompt.text = message
	prompt_panel.visible = not message.is_empty()

func set_status(message: String) -> void:
	status.text = message

func set_backend_status(message: String) -> void:
	status.text = "VELORA // " + message

func show_menu_hint() -> void:
	status.text = "VELORA // ESC MENU ARRIVES IN P1.06"
