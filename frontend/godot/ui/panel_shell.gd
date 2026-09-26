extends RefCounted
## Composed fixed-canvas frame; no backend or domain behavior belongs here.

const Tokens = preload("res://ui/design_tokens.gd")

var panel: PanelContainer
var box: VBoxContainer
var title: Label
var counter: Label
var hint: Label

func _init(parent: CanvasLayer, position: Vector2 = Tokens.PANEL_POSITION,
		minimum: Vector2 = Vector2(Tokens.PANEL_WIDTH, 0), vertical_margin: int = 5,
		with_counter: bool = true) -> void:
	var shade := ColorRect.new()
	shade.name = "Shade"
	shade.color = Tokens.SHADE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	parent.add_child(shade)
	panel = PanelContainer.new()
	panel.position = position
	panel.custom_minimum_size = minimum
	parent.add_child(panel)
	var margin := MarginContainer.new()
	for edge in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + edge, Tokens.SPACE * 2)
	for edge in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, vertical_margin)
	panel.add_child(margin)
	box = VBoxContainer.new()
	box.add_theme_constant_override("separation", Tokens.SPACE)
	margin.add_child(box)
	title = label("", Tokens.FONT_TITLE, Tokens.WAITING)
	if with_counter:
		var header := HBoxContainer.new()
		box.add_child(header)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(title)
		counter = label("0/0", Tokens.FONT_TITLE)
		header.add_child(counter)
	else:
		box.add_child(title)

func finish(hint_text: String) -> Label:
	hint = label(hint_text)
	box.add_child(hint)
	return hint

static func label(text: String = "", font_size: int = Tokens.FONT_BODY,
		color: Color = Tokens.MUTED) -> Label:
	var result := Label.new()
	result.text = text
	result.add_theme_font_size_override("font_size", font_size)
	result.add_theme_color_override("font_color", color)
	result.clip_text = true
	result.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return result

static func row(parent: Container) -> Dictionary:
	var panel_row := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Tokens.SURFACE
	style.content_margin_left = Tokens.SPACE
	style.content_margin_right = Tokens.SPACE
	style.content_margin_top = Tokens.SPACE / 2
	style.content_margin_bottom = Tokens.SPACE / 2
	panel_row.add_theme_stylebox_override("panel", style)
	parent.add_child(panel_row)
	var lines := VBoxContainer.new()
	lines.add_theme_constant_override("separation", 0)
	panel_row.add_child(lines)
	var summary := label("", Tokens.FONT_BODY, Tokens.TEXT)
	var detail := label()
	lines.add_child(summary)
	lines.add_child(detail)
	return {"panel": panel_row, "style": style, "summary": summary, "detail": detail}
