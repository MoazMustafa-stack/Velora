extends CanvasLayer

const Tokens = preload("res://ui/design_tokens.gd")
const Layout = preload("res://ui/hud_layout.gd")
const MetricStatus = preload("res://ui/telemetry_status.gd")

const TONE_COLORS := Tokens.TONES

@onready var status: Label = $StatusPanel/Margin/Status
@onready var connection: Label = $ConnectionPanel/Margin/Connection
@onready var prompt_panel: PanelContainer = $PromptPanel
@onready var prompt: Label = $PromptPanel/Margin/Prompt
var menu_overlay: CanvasLayer
var menu_connection: Label

var _world_status := "VELORA // POCKET TERMINAL"
var _world_tone := "ready"
var _transient_status := ""
var _transient_tone := "ready"
var _transient_remaining := 0.0
var _transient_active := false
var _telemetry: Label
var _modal_active := false
var _connection_tone := "failure"
var _workshop_presentation := false
@onready var help: Label = $Help

func _ready() -> void:
	prompt_panel.visible = false
	_telemetry = Label.new()
	Layout.fit(_telemetry, Layout.FOOTER)
	_telemetry.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_telemetry.clip_text = true
	_telemetry.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_telemetry)
	Layout.fit($StatusPanel, Layout.STATUS)
	Layout.fit($ConnectionPanel, Layout.CONNECTION)
	Layout.fit(help, Layout.HELP)
	for label in [status, connection, prompt, help]:
		label.clip_text = true
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	for edge in ["top", "bottom"]:
		$PromptPanel/Margin.add_theme_constant_override("margin_" + edge, 2)
	# The default theme adds enough vertical padding to force a 23px minimum,
	# overriding size and overlapping HELP. Own footer padding explicitly.
	var footer_style := prompt_panel.get_theme_stylebox("panel").duplicate() as StyleBox
	footer_style.set_content_margin(SIDE_TOP, 0)
	footer_style.set_content_margin(SIDE_BOTTOM, 0)
	prompt_panel.add_theme_stylebox_override("panel", footer_style)
	Layout.fit(prompt_panel, Layout.FOOTER)
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

func configure_workshop() -> void:
	_workshop_presentation = true
	var w = Tokens.Workshop
	for pair in [[$StatusPanel, Rect2(8, 0, 430, 24)], [$ConnectionPanel, Rect2(454, 0, 178, 24)]]:
		var panel: PanelContainer = pair[0]
		var style := StyleBoxFlat.new()
		style.bg_color = w.PANEL
		style.set_content_margin_all(0)
		panel.add_theme_stylebox_override("panel", style)
		var margin: MarginContainer = panel.get_child(0)
		for edge in ["top", "bottom"]: margin.add_theme_constant_override("margin_" + edge, 0)
		Layout.fit(panel, pair[1])
	for label in [status, connection]: label.add_theme_font_size_override("font_size", w.FONT_BODY)
	_refresh_visibility()

func set_interaction_prompt(message: String) -> void:
	prompt.text = message
	_refresh_visibility()

func set_status(message: String, tone := "ready") -> void:
	_world_status = message
	_world_tone = tone
	_render_status()

func set_backend_status(message: String) -> void:
	set_status("VELORA // " + message)

func set_connection_status(message: String, tone: String) -> void:
	_connection_tone = tone
	connection.text = message
	connection.add_theme_color_override("font_color", _tone_color(tone))
	if menu_connection != null:
		menu_connection.text = message
		menu_connection.add_theme_color_override("font_color", _tone_color(tone))
	_refresh_visibility()

func set_telemetry_availability(availability: String) -> void:
	_telemetry.text = "SYS // " + ("WAITING FOR SAMPLE" if availability == "waiting" else "CORE OFFLINE")
	_telemetry.add_theme_color_override("font_color", _tone_color("waiting" if availability == "waiting" else "failure"))

func set_telemetry_snapshot(snapshot: Dictionary) -> void:
	var cpu: Dictionary = snapshot.get("cpu", {})
	var memory: Dictionary = snapshot.get("memory", {})
	var disk: Dictionary = snapshot.get("disk", {})
	var network: Dictionary = snapshot.get("network", {})
	var cpu_text := MetricStatus.label(cpu, "utilization_basis_points")
	var memory_text := MetricStatus.label(memory)
	var disk_text := MetricStatus.label(disk)
	var network_text := MetricStatus.label(network)
	var fully_available := cpu_text.is_empty() and memory_text.is_empty() and disk_text.is_empty() and network_text.is_empty()
	if cpu_text.is_empty(): cpu_text = "%.0f%%" % (float(cpu.utilization_basis_points) / 100.0)
	var memory_percent := 0.0
	if int(memory.get("total_bytes", 0)) > 0:
		memory_percent = 100.0 * float(int(memory.get("used_bytes", 0))) / float(int(memory.get("total_bytes", 1)))
	if memory_text.is_empty(): memory_text = "%.0f%%" % memory_percent
	if disk_text.is_empty(): disk_text = "%s/%s" % [_rate(int(disk.get("read_bytes_per_second", 0))), _rate(int(disk.get("write_bytes_per_second", 0)))]
	if network_text.is_empty(): network_text = "%s/%s" % [_rate(int(network.get("receive_bytes_per_second", 0))), _rate(int(network.get("transmit_bytes_per_second", 0)))]
	_telemetry.text = "SYS // CPU %s  MEM %s  D %s  N %s" % [cpu_text, memory_text, disk_text, network_text]
	_telemetry.add_theme_color_override("font_color", _tone_color("ready" if fully_available else "waiting"))

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
		status.text = "VELORA // PAUSED"
		status.add_theme_color_override("font_color", _tone_color("waiting"))
	else:
		_render_status()
	_refresh_visibility()

func attach_pause(panel: CanvasLayer) -> void:
	menu_overlay = panel
	menu_connection = panel.backend_status
	set_connection_status(connection.text, _connection_tone)

func set_modal_active(active: bool) -> void:
	_modal_active = active
	_refresh_visibility()

func set_help(message: String) -> void:
	help.text = message

func _refresh_visibility() -> void:
	if _workshop_presentation:
		# The persistent inspector now owns contextual guidance. Retain the old
		# prompt/help/telemetry values for state recovery and fixture comparison.
		$StatusPanel.show()
		$ConnectionPanel.show()
		help.hide()
		prompt_panel.hide()
		_telemetry.hide()
		return
	var tone := _transient_tone if _transient_active else _world_tone
	var shown := Layout.visibility(_modal_active or (menu_overlay != null and menu_overlay.visible),
		tone == "failure" or _connection_tone == "failure", not prompt.text.is_empty())
	$StatusPanel.visible = shown.world
	$ConnectionPanel.visible = shown.world
	help.visible = shown.world
	prompt_panel.visible = shown.prompt
	_telemetry.visible = shown.telemetry

func _render_status() -> void:
	_refresh_visibility()
	if menu_overlay != null and menu_overlay.visible:
		return
	if _transient_active:
		status.text = _transient_status
		status.add_theme_color_override("font_color", _tone_color(_transient_tone))
	else:
		status.text = _world_status
		status.add_theme_color_override("font_color", _tone_color(_world_tone))

func _tone_color(tone: String) -> Color:
	if _workshop_presentation:
		return {"ready": Tokens.Workshop.READY, "waiting": Tokens.Workshop.WAITING, "failure": Tokens.Workshop.FAILURE}.get(tone, Tokens.Workshop.TEXT)
	return TONE_COLORS.get(tone, TONE_COLORS["ready"])
