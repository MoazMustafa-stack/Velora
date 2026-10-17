extends Panel
## Persistent presentation only. Core/selection/focus ownership lives outside.
## update_view consumes accepted selected identity and precomputed context. It
## retains no registry, window snapshot, feedback dictionary or request state.
## focus_hint is the caller's complete remapped hint; context.focused is ignored
## deliberately. Only set_inspector_focused may change actual keyboard focus.
## registry_empty requires explicit accepted-catalog evidence; running_stale can
## mark retained session observations stale independently of Core connectivity.

signal back_requested

const Tokens = preload("res://ui/design_tokens.gd")
const W = Tokens.Workshop
const Art = preload("res://scripts/pixel_art.gd")
const MAX_NAME_CHARACTERS := 128
const MAX_FEEDBACK_CHARACTERS := 160

var _identity: Label
var _details: Label
var _availability: Label
var _running: Label
var _feedback: Label
var _guidance: Label
var _icon: TextureRect
var _label_bounds: Dictionary = {}
var _return: Button
var _style: StyleBoxFlat
var _focused := false
var _selected := false
var _world_guidance := "APPROACH AN APPLICATION STATION"
var _focused_guidance := "RETURN TO WORLD"

func _init() -> void:
	name = "ApplicationInspector"
	position = Vector2(W.INSPECTOR.position)
	size = Vector2(W.INSPECTOR.size)
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style = StyleBoxFlat.new()
	_style.bg_color = W.PANEL
	_style.border_color = W.OUTLINE
	_style.set_border_width_all(W.OUTLINE_WIDTH)
	add_theme_stylebox_override("panel", _style)
	_icon = TextureRect.new()
	_icon.name = "Icon"
	_icon.position = Vector2(16, 8)
	_icon.size = Vector2(48, 48)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_icon)
	_identity = _label("Identity", Rect2(80, 4, 350, 22), W.FONT_TITLE, W.TEXT)
	_details = _label("Details", Rect2(80, 26, 350, 18), W.FONT_BODY, W.MUTED)
	_availability = _label("Availability", Rect2(444, 6, 180, 18), W.FONT_BODY, W.MUTED)
	_running = _label("Running", Rect2(444, 24, 180, 18), W.FONT_BODY, W.MUTED)
	_feedback = _label("Feedback", Rect2(80, 44, 544, 18), W.FONT_BODY, W.MUTED)
	_guidance = _label("Guidance", Rect2(80, 62, 432, 17), W.FONT_BODY, W.MUTED)
	_return = Button.new()
	_return.name = "ReturnToWorld"
	_return.text = "RETURN"
	_return.position = Vector2(528, 62)
	_return.size = Vector2(96, 17)
	_return.focus_mode = Control.FOCUS_NONE
	_return.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_return.clip_text = true
	_return.add_theme_font_size_override("font_size", W.FONT_BODY)
	_return.add_theme_color_override("font_color", W.TEXT)
	var button_style := StyleBoxFlat.new()
	button_style.bg_color = W.SURFACE
	button_style.content_margin_left = 4
	button_style.content_margin_right = 4
	button_style.content_margin_top = 0
	button_style.content_margin_bottom = 0
	for state in ["normal", "hover", "pressed", "disabled"]:
		_return.add_theme_stylebox_override(state, button_style)
	var focus_style := StyleBoxFlat.new()
	focus_style.draw_center = false
	focus_style.border_color = W.FOCUS
	focus_style.set_border_width_all(W.FOCUS_WIDTH)
	_return.add_theme_stylebox_override("focus", focus_style)
	_return.pressed.connect(_on_return_pressed)
	add_child(_return)

func _ready() -> void:
	_refit_labels()
	_return.size = Vector2(96, 17)
	_update_focus_appearance()

## This explicit coordinator request is the only path that can acquire focus.
func set_inspector_focused(value: bool) -> void:
	_focused = value
	_return.focus_mode = Control.FOCUS_ALL if value else Control.FOCUS_NONE
	if value and is_inside_tree() and is_visible_in_tree():
		_return.grab_focus()
	elif not value and _return.has_focus():
		_return.release_focus()
	_update_focus_appearance()

func focus_anchor() -> Control:
	return _return

func _on_return_pressed() -> void:
	if _focused:
		back_requested.emit()

func _update_focus_appearance() -> void:
	_style.border_color = W.FOCUS if _focused else W.ACCENT if _selected else W.OUTLINE
	_style.set_border_width_all(W.FOCUS_WIDTH if _focused else W.OUTLINE_WIDTH)
	_guidance.text = _focused_guidance if _focused else _world_guidance

func _label(node_name: String, bounds: Rect2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = node_name
	label.position = bounds.position
	label.size = bounds.size
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	_label_bounds[label] = bounds
	return label

func _refit_labels() -> void:
	if not is_inside_tree():
		return
	# Pre-tree Controls initially use the 16px fallback theme. Refit only after
	# their explicit native font overrides resolve, not by clipping taller text.
	for label: Label in _label_bounds:
		var bounds: Rect2 = _label_bounds[label]
		label.position = bounds.position
		label.size = bounds.size

func update_view(selection: Dictionary, context: Dictionary) -> void:
	var desktop_id := _display_text(selection.get("selected_id", ""), 255)
	_selected = not desktop_id.is_empty()
	var core_state := _display_text(context.get("core_state", "offline"), 32)
	var registry_known := bool(selection.get("registry_known", false))
	var registry_empty := registry_known and bool(context.get("registry_empty", false)) and core_state == "ready"
	var label := _display_text(selection.get("name", desktop_id), MAX_NAME_CHARACTERS)
	_identity.text = (label if not label.is_empty() else desktop_id.left(MAX_NAME_CHARACTERS)) if not desktop_id.is_empty() \
		else "NO APPLICATIONS" if registry_empty else "NO APPLICATION SELECTED"
	var availability_color := W.WAITING
	match core_state:
		"offline":
			_availability.text = "CORE OFFLINE"
			availability_color = W.MUTED
		"connecting":
			_availability.text = "CONNECTING"
		"connected":
			_availability.text = "CONNECTED // WAITING"
		"loading_applications":
			_availability.text = "LOADING APPLICATIONS"
		"registry_stale":
			_availability.text = "REGISTRY STALE"
		"reconnecting":
			_availability.text = "RECONNECTING"
		"protocol_incompatible":
			_availability.text = "PROTOCOL INCOMPATIBLE"
			availability_color = W.FAILURE
		"ready":
			if not registry_known:
				_availability.text = "WAITING FOR REGISTRY"
			elif not desktop_id.is_empty():
				var available := bool(selection.get("available", false))
				_availability.text = "AVAILABLE" if available else "APP UNAVAILABLE"
				availability_color = W.READY if available else W.DISABLED
			else:
				_availability.text = "REGISTRY EMPTY" if registry_empty else "REGISTRY READY"
				availability_color = W.DISABLED if registry_empty else W.READY
		_:
			_availability.text = "CORE STATE UNKNOWN"
	_availability.add_theme_color_override("font_color", availability_color)
	var raw_categories = selection.get("categories", [])
	var categories: Array = raw_categories.slice(0, 8) if raw_categories is Array else []
	var category := _display_text(categories[0], 48) if not categories.is_empty() else "Application"
	if category.is_empty():
		category = "Application"
	_details.text = (category + " // " + desktop_id).left(192) if not desktop_id.is_empty() else "Select an application to inspect"
	var running_state := _display_text(context.get("running_state", "unknown"), 24)
	match running_state:
		"running":
			var window_value = context.get("running_windows", 0)
			var windows := clampi(window_value, 0, 9999) if window_value is int else 0
			_running.text = "RUNNING x%d" % windows if windows > 0 else "RUNNING"
			var location := _display_text(context.get("running_location", ""), 24)
			if not location.is_empty():
				_running.text += " // " + location
		"not_running":
			_running.text = "NOT RUNNING"
		_:
			_running.text = "RUNNING UNKNOWN"
	if desktop_id.is_empty():
		_running.text = "NO APP SELECTED"
	elif core_state != "ready" or context.get("running_stale", false) == true:
		_running.text = "STALE // " + _running.text
	_icon.texture = Art.workshop_icon_texture(_icon_kind(desktop_id, categories))
	var focus_hint := _display_text(context.get("focus_hint", ""), 48)
	var nearby_prompt := _display_text(context.get("nearby_prompt", ""), 80)
	var world_hint := "WORLD: " + nearby_prompt if not nearby_prompt.is_empty() else "APPROACH AN APPLICATION STATION"
	if bool(context.get("world_locked", false)): world_hint = "WORLD INPUT LOCKED // PANEL ACTIVE"
	_focused_guidance = _display_text(context.get("back_hint", "RETURN TO WORLD"), 96)
	_world_guidance = (((focus_hint + " // ") if not focus_hint.is_empty() else "") + world_hint).left(128)
	_update_focus_appearance()
	_update_feedback(desktop_id, core_state, context.get("feedback", {}))
	_refit_labels()

func _update_feedback(desktop_id: String, core_state: String, value: Variant) -> void:
	_feedback.text = "Actions: nearby object only"
	var color := W.MUTED
	if not desktop_id.is_empty() and value is Dictionary and value.get("desktop_id", "") == desktop_id:
		match value.get("stage", ""):
			"launching_application":
				_feedback.text = "LAUNCHING APPLICATION"
				color = W.WAITING
			"launch_successful", "launch_accepted":
				_feedback.text = "LAUNCH ACCEPTED // Window state is observed separately"
				color = W.READY
			"launch_failed":
				var message := _display_text(value.get("message", "Launch request rejected"), 112)
				_feedback.text = "LAUNCH FAILED // " + (message if not message.is_empty() else "Launch request rejected")
				if bool(value.get("retryable", false)):
					_feedback.text += " // RETRY AT STATION"
				color = W.FAILURE
		if color != W.MUTED and core_state != "ready":
			_feedback.text = "LAST: " + _feedback.text
	_feedback.text = _feedback.text.left(MAX_FEEDBACK_CHARACTERS)
	_feedback.add_theme_color_override("font_color", color)

static func _display_text(value: Variant, maximum: int) -> String:
	if not value is String:
		return ""
	var result := ""
	for index in range(mini(value.length(), maximum)):
		var codepoint: int = value.unicode_at(index)
		if codepoint < 32 or (codepoint >= 127 and codepoint <= 159) \
			or codepoint in [0x2028, 0x2029] or (codepoint >= 0x202a and codepoint <= 0x202e) \
			or (codepoint >= 0x2066 and codepoint <= 0x2069):
			result += " "
		else:
			result += value[index]
	return result.strip_edges()

static func _icon_kind(desktop_id: String, categories: Array) -> String:
	if desktop_id == "code.desktop" or "Development" in categories:
		return "code"
	if desktop_id == "firefox.desktop" or "WebBrowser" in categories:
		return "browser"
	if desktop_id == "kitty.desktop" or "TerminalEmulator" in categories:
		return "terminal"
	return "unknown"
