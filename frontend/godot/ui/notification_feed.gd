extends CanvasLayer

const Tokens = preload("res://ui/design_tokens.gd")

signal feed_closed

# P5.10 notification feed panel.
#
# Renders the most recent BackendClient notification feed entries in a
# fixed panel: keyboard-only scrolling, color-independent urgency cues, and
# strict clipping so long summaries and bodies can never overflow the
# 320 x 180 canvas. All state is memory-only and every state change is
# applied instantly with no animated transitions, so the panel writes
# nothing to disk and the reduced-motion guarantee holds by construction.

const TONE_COLORS := Tokens.TONES
const DIM_COLOR := Tokens.MUTED
const ROW_BG := Tokens.SURFACE
const ROW_BG_SELECTED := Tokens.SELECTED
# Urgency never relies on color alone: every level renders a distinct marker
# glyph plus its spelled name, and color is only a secondary channel.
const URGENCY_MARKERS := {
	"critical": "!!",
	"normal": "!",
	"low": ".",
}
const URGENCY_LABELS := {
	"critical": "CRIT",
	"normal": "NORM",
	"low": "LOW",
}
const URGENCY_COLORS := {
	"critical": Tokens.FAILURE,
	"normal": Tokens.TEXT,
	"low": Tokens.MUTED,
}
const FALLBACK_URGENCY := "normal"
const MAX_VISIBLE_ENTRIES := 4
# Mirrors the protocol feed ceiling (BackendClient.MAX_NOTIFICATIONS) so a
# mis-wired source can never grow the tracked set beyond the v5 bound.
const MAX_TRACKED_ENTRIES := 32

var entries: Array[Dictionary] = []
var selected_index := -1
var scroll_offset := 0
var availability := "waiting"

var _panel: PanelContainer
var _title: Label
var _counter: Label
var _rows_box: VBoxContainer
var _hint: Label
var _rows: Array[Dictionary] = []

func _ready() -> void:
	visible = false
	_build_ui()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE, KEY_N:
				get_viewport().set_input_as_handled()
				close()
			KEY_UP, KEY_W:
				get_viewport().set_input_as_handled()
				_move_selection(-1)
			KEY_DOWN, KEY_S:
				get_viewport().set_input_as_handled()
				_move_selection(1)
			KEY_LEFT, KEY_A, KEY_PAGEUP:
				get_viewport().set_input_as_handled()
				_move_selection(-MAX_VISIBLE_ENTRIES)
			KEY_RIGHT, KEY_D, KEY_PAGEDOWN:
				get_viewport().set_input_as_handled()
				_move_selection(MAX_VISIBLE_ENTRIES)
			KEY_HOME:
				get_viewport().set_input_as_handled()
				_select_index(0)
			KEY_END:
				get_viewport().set_input_as_handled()
				_select_index(entries.size() - 1)

func open() -> void:
	visible = true
	_select_index(_default_selection())

func close() -> void:
	visible = false
	feed_closed.emit()

func toggle() -> void:
	if visible:
		close()
	else:
		open()

func set_availability(next_availability: String) -> void:
	availability = next_availability
	_refresh_title()

func update_feed(feed: Dictionary) -> void:
	var raw_entries = feed.get("notifications", null)
	if not raw_entries is Array:
		return
	var selected_handle := _selected_handle()
	entries.clear()
	# Keep only the newest slice when a source exceeds the feed ceiling.
	var start_index := maxi(0, raw_entries.size() - MAX_TRACKED_ENTRIES)
	for raw_index in range(start_index, raw_entries.size()):
		var raw_entry = raw_entries[raw_index]
		if not raw_entry is Dictionary:
			continue
		var handle := String(raw_entry.get("handle", ""))
		if handle.is_empty():
			continue
		entries.append({
			"handle": handle,
			"app_name": String(raw_entry.get("app_name", "")),
			"summary": String(raw_entry.get("summary", "")),
			"body": String(raw_entry.get("body", "")),
			"urgency": String(raw_entry.get("urgency", "")),
			"timestamp_unix_ms": int(raw_entry.get("timestamp_unix_ms", 0)),
		})
	entries.sort_custom(_newest_first)
	_preserve_selection(selected_handle)

func _default_selection() -> int:
	return 0 if not entries.is_empty() else -1

func _selected_handle() -> String:
	if selected_index >= 0 and selected_index < entries.size():
		return String(entries[selected_index].get("handle", ""))
	return ""

func _preserve_selection(handle: String) -> void:
	if not handle.is_empty():
		for index in range(entries.size()):
			if String(entries[index].get("handle", "")) == handle:
				_select_index(index)
				return
	_select_index(selected_index)

func _newest_first(a: Dictionary, b: Dictionary) -> bool:
	var a_time := int(a.get("timestamp_unix_ms", 0))
	var b_time := int(b.get("timestamp_unix_ms", 0))
	if a_time != b_time:
		return a_time > b_time
	# Deterministic order for equal timestamps: sort by the opaque handle.
	return String(a.get("handle", "")) < String(b.get("handle", ""))

func _move_selection(step: int) -> void:
	if entries.is_empty():
		return
	if selected_index < 0:
		_select_index(0)
		return
	var count := entries.size()
	var next_index := selected_index + step
	while next_index < 0:
		next_index += count
	_select_index(next_index % count)

func _select_index(index: int) -> void:
	if entries.is_empty():
		selected_index = -1
		scroll_offset = 0
		_refresh_rows()
		return
	selected_index = clampi(index, 0, entries.size() - 1)
	if selected_index < scroll_offset:
		scroll_offset = selected_index
	elif selected_index >= scroll_offset + MAX_VISIBLE_ENTRIES:
		scroll_offset = selected_index - MAX_VISIBLE_ENTRIES + 1
	scroll_offset = clampi(scroll_offset, 0, maxi(0, entries.size() - MAX_VISIBLE_ENTRIES))
	_refresh_rows()

func _refresh_title() -> void:
	match availability:
		"available":
			_title.text = "NOTIFICATIONS // FEED"
			_title.add_theme_color_override("font_color", TONE_COLORS["ready"])
		"unavailable":
			_title.text = "NOTIFICATIONS // NO FEED"
			_title.add_theme_color_override("font_color", TONE_COLORS["failure"])
		"restricted":
			_title.text = "NOTIFICATIONS // MONITOR RESTRICTED"
			_title.add_theme_color_override("font_color", TONE_COLORS["failure"])
		_:
			_title.text = "NOTIFICATIONS // WAITING"
			_title.add_theme_color_override("font_color", TONE_COLORS["waiting"])

func _refresh_rows() -> void:
	if entries.is_empty():
		for row_index in range(_rows.size()):
			_apply_row(
				_rows[row_index],
				"NO NOTIFICATIONS" if row_index == 0 else "",
				"",
				DIM_COLOR,
				false
			)
		_refresh_counter()
		return
	for row_index in range(_rows.size()):
		var row := _rows[row_index]
		var entry_index := scroll_offset + row_index
		if entry_index >= entries.size():
			_apply_row(row, "", "", DIM_COLOR, false)
			continue
		var entry := entries[entry_index]
		var urgency := String(entry.get("urgency", ""))
		if not URGENCY_MARKERS.has(urgency):
			urgency = FALLBACK_URGENCY
		var summary := String(entry.get("summary", ""))
		if summary.is_empty():
			summary = "UNTITLED"
		var app_name := String(entry.get("app_name", "")).to_upper()
		if app_name.is_empty():
			app_name = "UNKNOWN APP"
		var detail := "%s // %s" % [URGENCY_LABELS[urgency], app_name]
		var body := String(entry.get("body", ""))
		if not body.is_empty():
			detail += " // " + body
		var is_selected := entry_index == selected_index
		_apply_row(
			row,
			"%s%s %s" % [">" if is_selected else " ", URGENCY_MARKERS[urgency], summary],
			detail,
			URGENCY_COLORS[urgency],
			is_selected
		)
	_refresh_counter()

func _apply_row(
	row: Dictionary,
	summary_text: String,
	detail_text: String,
	summary_color: Color,
	is_selected: bool
) -> void:
	row["style"].bg_color = ROW_BG_SELECTED if is_selected else ROW_BG
	row["summary"].text = summary_text
	row["summary"].add_theme_color_override("font_color", summary_color)
	row["detail"].text = detail_text

func _refresh_counter() -> void:
	if selected_index < 0 or entries.is_empty():
		_counter.text = "0/0"
	else:
		_counter.text = "%d/%d" % [selected_index + 1, entries.size()]

func _build_ui() -> void:
	var shade := ColorRect.new()
	shade.name = "Shade"
	shade.color = Tokens.SHADE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)

	_panel = PanelContainer.new()
	_panel.position = Tokens.PANEL_POSITION
	_panel.custom_minimum_size = Vector2(Tokens.PANEL_WIDTH, 0)
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 5)
	_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)

	_title = Label.new()
	_title.text = "NOTIFICATIONS // WAITING"
	_title.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	_title.add_theme_color_override("font_color", TONE_COLORS["waiting"])
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.clip_text = true
	_title.text_overrun_behavior = 3
	header.add_child(_title)

	_counter = Label.new()
	_counter.text = "0/0"
	_counter.add_theme_font_size_override("font_size", Tokens.FONT_TITLE)
	_counter.add_theme_color_override("font_color", DIM_COLOR)
	header.add_child(_counter)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 2)
	box.add_child(_rows_box)

	# The row structure is fixed and every row keeps the same two clipped
	# lines regardless of content, so feed bursts can never reflow the panel.
	for _row_index in range(MAX_VISIBLE_ENTRIES):
		_rows.append(_build_row())

	_hint = Label.new()
	_hint.text = "ARROWS SCROLL  N CLOSE"
	_hint.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	_hint.add_theme_color_override("font_color", DIM_COLOR)
	box.add_child(_hint)

func _build_row() -> Dictionary:
	var row := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = ROW_BG
	style.content_margin_left = 4
	style.content_margin_right = 4
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	row.add_theme_stylebox_override("panel", style)
	_rows_box.add_child(row)

	var lines := VBoxContainer.new()
	lines.add_theme_constant_override("separation", 0)
	row.add_child(lines)

	var summary := Label.new()
	summary.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	summary.clip_text = true
	summary.text_overrun_behavior = 3
	lines.add_child(summary)

	var detail := Label.new()
	detail.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	detail.add_theme_color_override("font_color", DIM_COLOR)
	detail.clip_text = true
	detail.text_overrun_behavior = 3
	lines.add_child(detail)

	return {"panel": row, "style": style, "summary": summary, "detail": detail}
