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
var _telemetry: Label

func _ready() -> void:
	prompt_panel.visible = false
	_telemetry = Label.new()
	_telemetry.position = Vector2(8, 146)
	_telemetry.size = Vector2(304, 12)
	_telemetry.add_theme_font_size_override("font_size", 7)
	_telemetry.clip_text = true
	add_child(_telemetry)
	set_telemetry_availability("waiting")
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

func set_telemetry_availability(availability: String) -> void:
	_telemetry.text = "SYS // " + ("WAITING FOR SAMPLE" if availability == "waiting" else "CORE OFFLINE")
	_telemetry.add_theme_color_override("font_color", _tone_color("waiting" if availability == "waiting" else "failure"))

func set_telemetry_snapshot(snapshot: Dictionary) -> void:
	var cpu: Dictionary = snapshot.get("cpu", {})
	var memory: Dictionary = snapshot.get("memory", {})
	var disk: Dictionary = snapshot.get("disk", {})
	var network: Dictionary = snapshot.get("network", {})
	var cpu_percent := float(int(cpu.get("utilization_basis_points", 0))) / 100.0
	var memory_percent := 0.0
	if int(memory.get("total_bytes", 0)) > 0:
		memory_percent = 100.0 * float(int(memory.get("used_bytes", 0))) / float(int(memory.get("total_bytes", 1)))
	_telemetry.text = "SYS // CPU %.0f%%  MEM %.0f%%  D %s/%s  N %s/%s" % [cpu_percent, memory_percent, _rate(int(disk.get("read_bytes_per_second", 0))), _rate(int(disk.get("write_bytes_per_second", 0))), _rate(int(network.get("receive_bytes_per_second", 0))), _rate(int(network.get("transmit_bytes_per_second", 0)))]
	_telemetry.add_theme_color_override("font_color", _tone_color("ready"))

func _rate(bytes_per_second: int) -> String:
	if bytes_per_second >= 1_048_576:
		return "%dM" % (bytes_per_second / 1_048_576)
	if bytes_per_second >= 1024:
		return "%dK" % (bytes_per_second / 1024)
	return "%dB" % bytes_per_second

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
