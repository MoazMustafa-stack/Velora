extends CanvasLayer

const TONE_COLORS := {
	"ready": Color("9af4e7"),
	"waiting": Color("f5b943"),
	"failure": Color("e05a67"),
}

@onready var status: Label = $StatusPanel/Margin/Status
@onready var connection: Label = $ConnectionPanel/Margin/Connection
@onready var prompt_panel: PanelContainer = $PromptPanel
@onready var prompt: Label = $PromptPanel/Margin/Prompt
@onready var menu_overlay: Control = $MenuOverlay
@onready var menu_connection: Label = $MenuOverlay/MenuPanel/Margin/Content/Safety

var _world_status := "VELORA // POCKET TERMINAL"
var _world_tone := "ready"
var _transient_status := ""
var _transient_tone := "ready"
var _transient_remaining := 0.0
var _transient_active := false

func _ready() -> void:
	prompt_panel.visible = false
	set_connection_status("CORE OFFLINE", "failure")
	_render_status()

func _process(delta: float) -> void:
	if not _transient_active or _transient_remaining <= 0.0:
		return
	_transient_remaining -= delta
	if _transient_remaining <= 0.0:
		_transient_active = false
		_render_status()

func set_interaction_prompt(message: String) -> void:
	prompt.text = message
	prompt_panel.visible = not message.is_empty() and not menu_overlay.visible

func set_status(message: String, tone := "ready") -> void:
	_world_status = message
	_world_tone = tone
	_render_status()

func set_backend_status(message: String) -> void:
	set_status("VELORA // " + message)

func set_connection_status(message: String, tone: String) -> void:
	connection.text = message
	connection.add_theme_color_override("font_color", _tone_color(tone))
	menu_connection.text = message
	menu_connection.add_theme_color_override("font_color", _tone_color(tone))

func show_transient(message: String, tone: String, duration_seconds: float) -> void:
	_transient_status = message
	_transient_tone = tone
	_transient_remaining = maxf(duration_seconds, 0.0)
	_transient_active = true
	_render_status()

func set_menu_visible(visible: bool) -> void:
	menu_overlay.visible = visible
	if visible:
		prompt_panel.visible = false
		status.text = "VELORA // PAUSED"
		status.add_theme_color_override("font_color", _tone_color("waiting"))
	else:
		prompt_panel.visible = not prompt.text.is_empty()
		_render_status()

func _render_status() -> void:
	if menu_overlay.visible:
		return
	if _transient_active:
		status.text = _transient_status
		status.add_theme_color_override("font_color", _tone_color(_transient_tone))
	else:
		status.text = _world_status
		status.add_theme_color_override("font_color", _tone_color(_world_tone))

func _tone_color(tone: String) -> Color:
	return TONE_COLORS.get(tone, TONE_COLORS["ready"])
