extends Control
## Native synthetic art review only: no Main, sockets, settings, audio or actions.
const Tokens = preload("res://ui/design_tokens.gd")
const W = Tokens.Workshop
const Art = preload("res://scripts/pixel_art.gd")
const KINDS := ["code", "browser", "terminal", "map", "media", "notifications", "observatory", "unknown"]
const LABELS := ["EDITOR", "BROWSER", "TERMINAL", "MAP", "MEDIA", "FEED", "OBSERVE", "UNKNOWN"]
const STATES := ["ready", "waiting", "failure", "offline", "disabled", "selected", "focused"]

func _ready() -> void:
	size = Vector2(W.CANVAS)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	block(Rect2(0, 0, 640, 360), W.BACKGROUND)
	text("VELORA / THE WALKABLE WORKSHOP", Rect2(16, 8, 400, 20), W.TEXT, W.FONT_TITLE)
	text("R6.02  /  ART PROPOSAL", Rect2(420, 9, 204, 18), W.ACCENT)
	text("WARM PIXELS. CLEAR OBJECTS. ONE KEYBOARD OWNER.", Rect2(16, 31, 608, 18), W.MUTED)
	for i in range(KINDS.size()):
		var x := 16 + i * 76
		block(Rect2(x, 57, 72, 104), W.PANEL)
		texture(Art.workshop_object_texture(KINDS[i]), Rect2(x + 4, 66, 64, 64))
		text(LABELS[i], Rect2(x + 2, 138, 68, 18), W.TEXT, W.FONT_BODY, HORIZONTAL_ALIGNMENT_CENTER)
	text("INSPECTOR ICONS", Rect2(16, 175, 150, 18), W.MUTED)
	for i in range(KINDS.size()):
		texture(Art.workshop_icon_texture(KINDS[i]), Rect2(176 + i * 56, 168, 32, 32))
	for i in range(STATES.size()):
		var x := 16 + i * 88
		block(Rect2(x, 211, 80, 59), W.PANEL)
		texture(Art.workshop_object_texture("code", STATES[i]), Rect2(x + 24, 214, 32, 32))
		text(STATES[i].to_upper(), Rect2(x + 2, 248, 76, 18), W.TEXT, W.FONT_BODY, HORIZONTAL_ALIGNMENT_CENTER)
	# A bounded typography specimen, not the R6.05 inspector implementation.
	block(Rect2(0, 280, 640, 80), W.PANEL)
	block(Rect2(0, 280, 640, 1), W.OUTLINE)
	texture(Art.workshop_icon_texture("code"), Rect2(16, 296, 48, 48))
	text("Éditeur • 日本語 — A very long application label that must be clipped safely", Rect2(80, 289, 390, 22), W.TEXT, W.FONT_TITLE)
	text("✓ AVAILABLE     RUNNING: UNKNOWN", Rect2(80, 314, 390, 18), W.READY)
	text("! Launch failed — recoverable error text stays inside its own region", Rect2(80, 336, 390, 18), W.FAILURE)
	text("SELECTED ≠ FOCUSED", Rect2(486, 291, 138, 18), W.ACCENT)
	text("Static / reduced motion", Rect2(486, 314, 138, 18), W.MUTED)
	text("Preview • no actions", Rect2(486, 336, 138, 18), W.MUTED)

func block(rect: Rect2, color: Color) -> void:
	var fill := ColorRect.new()
	fill.position = rect.position
	fill.size = rect.size
	fill.color = color
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fill)

func text(value: String, rect: Rect2, color: Color, font_size := W.FONT_BODY, alignment := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var label := Label.new()
	label.text = value
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	# Set bounds after entering the tree and resolving theme minimum sizes.
	label.position = rect.position
	label.size = rect.size

func texture(value: Texture2D, rect: Rect2) -> void:
	var sprite := TextureRect.new()
	sprite.texture = value
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.position = rect.position
	sprite.size = rect.size
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(sprite)
