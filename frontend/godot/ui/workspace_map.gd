extends CanvasLayer

const Actions = preload("res://scripts/input_actions.gd")
const Shell = preload("res://ui/panel_shell.gd")
const Cursor = preload("res://ui/list_cursor.gd")
const Tokens = preload("res://ui/design_tokens.gd")

signal switch_requested(workspace_handle: String)
signal map_closed

const TONE_COLORS := Tokens.TONES
const TEXT_COLOR := Tokens.TEXT
const DIM_COLOR := Tokens.MUTED
const CELL_BG := Tokens.SURFACE
const CELL_BG_SELECTED := Tokens.SELECTED
const COLUMNS := 5
const MAX_VISIBLE_WORKSPACES := 20

var visible_workspaces: Array[Dictionary] = []
var _cursor := Cursor.new(MAX_VISIBLE_WORKSPACES)
var selected_index: int:
	get: return _cursor.selected
var _shell: RefCounted

var _panel: PanelContainer
var _title: Label
var _grid: GridContainer
var _hint: Label
var _cells: Array[Dictionary] = []

func _ready() -> void:
	Actions.ensure_registered()
	visible = false
	_build_ui()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if Actions.pressed(event, "back") or Actions.pressed(event, "workspace_map"):
		get_viewport().set_input_as_handled()
		close()
	elif Actions.pressed(event, "nav_left"):
		get_viewport().set_input_as_handled()
		_move_selection(-1)
	elif Actions.pressed(event, "nav_right"):
		get_viewport().set_input_as_handled()
		_move_selection(1)
	elif Actions.pressed(event, "nav_up"):
		get_viewport().set_input_as_handled()
		_move_selection(-COLUMNS)
	elif Actions.pressed(event, "nav_down"):
		get_viewport().set_input_as_handled()
		_move_selection(COLUMNS)
	elif Actions.pressed(event, "first"):
		get_viewport().set_input_as_handled()
		_select_index(0)
	elif Actions.pressed(event, "last"):
		get_viewport().set_input_as_handled()
		_select_index(visible_workspaces.size() - 1)
	elif Actions.pressed(event, "confirm"):
		get_viewport().set_input_as_handled()
		_confirm_selection()

func open() -> void:
	visible = true
	_select_index(_default_selection())

func close() -> void:
	visible = false
	map_closed.emit()

func set_availability(availability: String) -> void:
	match availability:
		"available":
			_title.text = "WORKSPACES // HYPRLAND"
			_title.add_theme_color_override("font_color", TONE_COLORS["ready"])
		"unavailable":
			_title.text = "WORKSPACES // NO HYPRLAND"
			_title.add_theme_color_override("font_color", TONE_COLORS["failure"])
			visible_workspaces.clear()
			_cursor.select(-1, 0)
			_refresh_grid()
		"incompatible":
			_title.text = "WORKSPACES // INCOMPATIBLE"
			_title.add_theme_color_override("font_color", TONE_COLORS["failure"])
			visible_workspaces.clear()
			_cursor.select(-1, 0)
			_refresh_grid()
		_:
			_title.text = "WORKSPACES // WAITING"
			_title.add_theme_color_override("font_color", TONE_COLORS["waiting"])

func update_session(snapshot: Dictionary) -> void:
	var selected_handle := ""
	if selected_index >= 0 and selected_index < visible_workspaces.size():
		selected_handle = String(visible_workspaces[selected_index]["handle"])
	var raw_workspaces = snapshot.get("workspaces", [])
	if not raw_workspaces is Array:
		return
	var workspaces: Array[Dictionary] = []
	for value in raw_workspaces:
		if value is Dictionary and not String(value.get("handle", "")).is_empty():
			workspaces.append(value)
	workspaces.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_special := bool(a.get("is_special", false))
		var b_special := bool(b.get("is_special", false))
		if a_special != b_special:
			return b_special
		return int(a.get("index", 0)) < int(b.get("index", 0))
	)
	visible_workspaces = workspaces.slice(0, MAX_VISIBLE_WORKSPACES)
	set_availability("available")
	_cursor.preserve(visible_workspaces.map(func(workspace: Dictionary): return workspace["handle"]), selected_handle, _default_selection())
	_refresh_grid()

func _default_selection() -> int:
	for index in range(visible_workspaces.size()):
		if bool(visible_workspaces[index].get("is_active", false)):
			return index
	return 0 if not visible_workspaces.is_empty() else -1

func _select_index(index: int) -> void:
	if visible_workspaces.is_empty():
		_cursor.select(-1, 0)
		return
	var previous := selected_index
	_cursor.select(index, visible_workspaces.size())
	if _cells.size() != visible_workspaces.size():
		_refresh_grid()
		return
	_set_cell_selected(previous, false)
	_set_cell_selected(selected_index, true)

func _move_selection(step: int) -> void:
	var previous := selected_index
	_cursor.move(step, visible_workspaces.size())
	_set_cell_selected(previous, false)
	_set_cell_selected(selected_index, true)

func _confirm_selection() -> void:
	if selected_index < 0 or selected_index >= visible_workspaces.size():
		return
	var handle := String(visible_workspaces[selected_index].get("handle", ""))
	if not handle.is_empty():
		switch_requested.emit(handle)

func _refresh_grid() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_cells.clear()

	if visible_workspaces.is_empty():
		var empty_label := Label.new()
		empty_label.text = "NO SESSION DATA"
		empty_label.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
		empty_label.add_theme_color_override("font_color", DIM_COLOR)
		_grid.add_child(empty_label)
		return

	for index in range(visible_workspaces.size()):
		var workspace := visible_workspaces[index]
		var cell_data := _build_cell(index, workspace)
		_cells.append(cell_data)
		_grid.add_child(cell_data["panel"])

func _set_cell_selected(index: int, is_selected: bool) -> void:
	if index < 0 or index >= _cells.size():
		return
	var style: StyleBoxFlat = _cells[index]["style"]
	style.bg_color = CELL_BG_SELECTED if is_selected else CELL_BG

func _build_cell(index: int, workspace: Dictionary) -> Dictionary:
	var is_active := bool(workspace.get("is_active", false))
	var is_urgent := bool(workspace.get("is_urgent", false))
	var is_special := bool(workspace.get("is_special", false))
	var window_count := int(workspace.get("window_count", 0))
	var display_name := String(workspace.get("name", "?"))
	var monitor := String(workspace.get("monitor", ""))

	var marker := " "
	var tone_color := DIM_COLOR if window_count == 0 else TEXT_COLOR
	if is_active:
		marker = ">"
		tone_color = TONE_COLORS["ready"]
	elif is_urgent:
		marker = "!"
		tone_color = TONE_COLORS["failure"]
	elif is_special:
		marker = "~"
		tone_color = TONE_COLORS["waiting"]

	var cell := PanelContainer.new()
	# Explicit width keeps clipped text readable rather than collapsing cells.
	cell.custom_minimum_size.x = floorf((Tokens.PANEL_WIDTH - 16 - 3 * (COLUMNS - 1)) / COLUMNS)
	var style := StyleBoxFlat.new()
	style.bg_color = CELL_BG_SELECTED if index == selected_index else CELL_BG
	style.content_margin_left = 4
	style.content_margin_right = 4
	style.content_margin_top = 1
	style.content_margin_bottom = 1
	cell.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	cell.add_child(box)

	var header := Label.new()
	header.text = "%s%s" % [marker, display_name]
	header.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	header.add_theme_color_override("font_color", tone_color)
	header.clip_text = true
	header.text_overrun_behavior = 3
	box.add_child(header)

	var detail_parts: Array[String] = ["%dw" % window_count]
	if is_special:
		detail_parts.append("special")
	if not monitor.is_empty():
		detail_parts.append(monitor)
	var detail := Label.new()
	detail.text = " ".join(detail_parts)
	detail.add_theme_font_size_override("font_size", Tokens.FONT_BODY)
	detail.add_theme_color_override("font_color", DIM_COLOR)
	detail.clip_text = true
	detail.text_overrun_behavior = 3
	box.add_child(detail)

	return {"panel": cell, "style": style}

func _build_ui() -> void:
	_shell = Shell.new(self, Tokens.MAP_POSITION, Tokens.MAP_MINIMUM, 6, false)
	_panel = _shell.panel
	_title = _shell.title
	_title.text = "WORKSPACES // WAITING"
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 3)
	_grid.add_theme_constant_override("v_separation", 3)
	_shell.box.add_child(_grid)
	_hint = _shell.finish("ARROWS SELECT  TAB CLOSE")
	_refresh_grid()
