extends Node
## R6.01 ONLY: isolated native blockout, not a production inspector or theme.
## Physics stays in the existing room; only its viewport texture is enlarged.
const Tokens = preload("res://ui/design_tokens.gd")
const Art = preload("res://scripts/pixel_art.gd")
const WORLD_VIEW := Vector2i(320, 128)
const NATIVE_SIZES := [Vector2i(320, 180), Vector2i(640, 360)]
var native_size: Vector2i
var scale_factor: int
var canvas: SubViewport
var world: SubViewport
var main: Node
var ui: Control
var title: Label
var detail: Label
var state_label: Label
var hint: Label
var modal: Panel
var stage: TextureRect

static func regions(size: Vector2i) -> Dictionary:
	var factor := size.x / 320
	return {"header": Rect2(0, 0, size.x, 12 * factor),
		"world": Rect2(0, 12 * factor, size.x, 128 * factor),
		"inspector": Rect2(0, 140 * factor, size.x, 40 * factor)}

func _init(size := Vector2i(320, 180)) -> void:
	assert(size in NATIVE_SIZES)
	native_size = size
	scale_factor = size.x / 320
	canvas = SubViewport.new()
	canvas.size = size
	canvas.disable_3d = true
	canvas.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(canvas)
	world = SubViewport.new()
	world.size = WORLD_VIEW
	world.world_2d = World2D.new()
	world.disable_3d = true
	world.gui_disable_input = true
	world.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	canvas.add_child(world)
	main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	world.add_child(main)
	ui = Control.new()
	ui.size = Vector2(size)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(ui)
	var boxes := regions(size)
	var header := _panel(boxes.header)
	_label(header, Rect2(4, 0, size.x * 0.65, 12 * scale_factor), "VELORA / NATIVE BLOCKOUT", 7 if scale_factor == 1 else 12, Tokens.TEXT)
	_label(header, Rect2(size.x * 0.67, 0, size.x * 0.32, 12 * scale_factor), "%d x %d" % [size.x, size.y], 7 if scale_factor == 1 else 12, Tokens.READY)
	stage = TextureRect.new()
	stage.texture = world.get_texture()
	stage.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	stage.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stage.position = boxes.world.position
	stage.size = boxes.world.size
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(stage)
	var inspector := _panel(boxes.inspector)
	var icon := TextureRect.new()
	icon.texture = Art.workstation_texture("ready", Tokens.READY, "code")
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.position = Vector2(4, 4) * scale_factor
	icon.size = Vector2(32, 32) * scale_factor
	inspector.add_child(icon)
	var left := 40 * scale_factor
	var right := 198 * scale_factor
	var font := 7 if scale_factor == 1 else 12
	title = _label(inspector, Rect2(left, 2 * scale_factor, 150 * scale_factor, 12 * scale_factor), "", 8 if scale_factor == 1 else 14, Tokens.TEXT)
	detail = _label(inspector, Rect2(left, 14 * scale_factor, 150 * scale_factor, 10 * scale_factor), "EDITOR / code.desktop", font, Tokens.MUTED)
	state_label = _label(inspector, Rect2(right, 2 * scale_factor, 118 * scale_factor, 12 * scale_factor), "", font, Tokens.READY)
	hint = _label(inspector, Rect2(left, 26 * scale_factor, (size.x - left - 4 * scale_factor), 12 * scale_factor), "", font, Tokens.TEXT)
	_label(inspector, Rect2(right, 14 * scale_factor, 118 * scale_factor, 10 * scale_factor), "VIEW ONLY / MOCK STATE", font, Tokens.WAITING)
	modal = _panel(Rect2(60 * scale_factor, 38 * scale_factor, 200 * scale_factor, 80 * scale_factor))
	_label(modal, Rect2(8, 6, 184 * scale_factor, 16 * scale_factor), "PAUSED / LAYOUT SAMPLE", 8 if scale_factor == 1 else 14, Tokens.TEXT)
	_label(modal, Rect2(8, 28 * scale_factor, 184 * scale_factor, 14 * scale_factor), "Inspector remains visible below", font, Tokens.TEXT)
	_label(modal, Rect2(8, 52 * scale_factor, 184 * scale_factor, 14 * scale_factor), "No controls or real application launch", font, Tokens.WAITING)
	modal.hide()
	set_sample("ready")

func _ready() -> void:
	_fit_labels(ui)
	# Disable both transport timers and all key-driven actions before any frame.
	main.backend.set_process(false)
	main.ui_audio.enabled = false
	main.set_process_input(false)
	main.set_process_unhandled_input(false)
	main.player.set_process_unhandled_input(false)
	main.hud.hide()
	for panel in [main.pause_panel, main.workspace_map, main.notification_feed, main.media_console, main.observatory]:
		panel.set_process_unhandled_input(false)
		panel.hide()
	main.backend.state = BackendClient.ConnectionState.READY
	main.backend.applications_changed.emit([
		{"id": "code.desktop", "name": "Fixture Editor"},
		{"id": "firefox.desktop", "name": "Fixture Browser"},
		{"id": "kitty.desktop", "name": "Fixture Terminal"}])

func set_sample(sample: String) -> void:
	title.text = "Fixture Code / application inspector"
	state_label.text = "+ AVAILABLE"
	state_label.add_theme_color_override("font_color", Tokens.READY)
	hint.text = "WASD MOVE / [E] NEARBY OBJECT / INSPECTOR MOCK ONLY"
	if sample == "long-text":
		title.text = "Fixture editor / 日本語 / é / ".repeat(12)
		hint.text = "! OPEN FAILED / Synthetic error with a very long explanation ".repeat(12)
		state_label.text = "! LAUNCH FAILED"
		state_label.add_theme_color_override("font_color", Tokens.FAILURE)
	elif sample == "offline":
		state_label.text = "x CORE OFFLINE"
		state_label.add_theme_color_override("font_color", Tokens.FAILURE)
		hint.text = "LAST KNOWN APP / reconnect before any action"
	elif sample == "waiting":
		state_label.text = "... WAITING"
		state_label.add_theme_color_override("font_color", Tokens.WAITING)
		hint.text = "SYNTHETIC PENDING / no request sent"
	elif sample == "empty":
		title.text = "No application selected"
		state_label.text = "- NO REGISTRY"
		hint.text = "APPROACH AN OBJECT / empty synthetic state"
	modal.visible = sample == "paused"

func present(window: Window) -> void:
	var display := TextureRect.new()
	display.texture = canvas.get_texture()
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	window.add_child(display)

func _panel(rect: Rect2) -> Panel:
	var panel := Panel.new()
	panel.position = rect.position
	panel.size = rect.size
	panel.clip_contents = true
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Tokens.PANEL
	style.border_color = Tokens.WORLD_STEEL_LIGHT
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)
	ui.add_child(panel)
	return panel

func _label(parent: Control, rect: Rect2, text: String, font: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	label.position = rect.position
	label.size = rect.size
	label.set_meta("proof_size", rect.size)
	return label

func _fit_labels(parent: Node) -> void:
	# Labels built before entering the tree initially inherit the 16px theme.
	# Refit after their explicit native font sizes have reached the scene tree.
	for child in parent.get_children():
		if child is Label: child.size = child.get_meta("proof_size")
		_fit_labels(child)
