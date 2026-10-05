extends CanvasLayer
## Keyboard-owned pages, composed from the same bounded shell as live panels.
const Shell = preload("res://ui/panel_shell.gd")
const Cursor = preload("res://ui/list_cursor.gd")
const Tokens = preload("res://ui/design_tokens.gd")
const Actions = preload("res://scripts/input_actions.gd")
signal resume_requested
signal replay_requested
signal dismiss_requested
var page := "home"
var backend_status: Label
var _backend: Node
var _shell: RefCounted
var _cursor := Cursor.new(5)
var _rows: Array[Label] = []
var _items: Array[String] = []
var _detail: Label

func _ready() -> void:
	visible = false
	_shell = Shell.new(self)
	for _index in range(5):
		var row := Shell.label("", Tokens.FONT_BODY, Tokens.TEXT)
		row.custom_minimum_size.y = 12
		_shell.box.add_child(row)
		_rows.append(row)
	_detail = Shell.label()
	_shell.box.add_child(_detail)
	backend_status = Shell.label("CORE OFFLINE", Tokens.FONT_BODY, Tokens.FAILURE)
	_shell.box.add_child(backend_status)
	_shell.finish("")

func configure(backend: Node) -> void:
	_backend = backend
	show_page("home")

func open() -> void:
	visible = true
	show_page("home")

func back() -> bool:
	if page == "home": return false
	show_page("home")
	return true

func show_page(next: String) -> void:
	if next not in ["home", "help", "diagnostics", "controls"]: return
	page = next
	_cursor.select(0, 1)
	refresh()

func refresh() -> void:
	if _backend == null: return
	_shell.title.text = "VELORA // " + ("PAUSED" if page == "home" else page.to_upper())
	_detail.text = ""
	match page:
		"home":
			_items.assign(["RESUME", "HELP / CONTROLS", "CAPABILITY DIAGNOSTICS", "REPLAY FIRST-RUN HINTS", "SKIP FIRST-RUN HINTS"])
		"help":
			_items.assign(["%s/%s/%s/%s MOVE" % [Actions.binding_label("move_up", 1), Actions.binding_label("move_left", 1), Actions.binding_label("move_down", 1), Actions.binding_label("move_right", 1)],
				"%s SPRINT // %s INTERACT" % [Actions.binding_label("sprint"), Actions.binding_label("interact")],
				"%s PAUSE // %s MAP" % [Actions.binding_label("menu"), Actions.binding_label("workspace_map")],
				"%s FEED // %s MEDIA" % [Actions.binding_label("notification_feed"), Actions.binding_label("media_console")], "ALL INPUT ACTIONS"])
			_detail.text = "CORE OFFLINE? START ./scripts/velora.sh dev"
		"controls":
			_items.clear()
			for action in Actions.DEFAULTS:
				_items.append("%s // %s" % [action.replace("_", " ").to_upper(), Actions.binding_label(action)])
			_detail.text = "READ-ONLY // REMAPPING IS D6.11"
		"diagnostics":
			var feed: String = "DISABLED" if _backend.notifications_policy_disabled else _backend.notifications_availability.to_upper()
			if feed == "AVAILABLE": feed = "ENABLED / OPT-IN"
			if _backend.state != BackendClient.ConnectionState.READY: feed = "CORE OFFLINE / POLICY UNKNOWN"
			_items.assign(["CORE // " + BackendClient.ConnectionState.keys()[_backend.state],
				"HYPRLAND // " + _backend.session_availability.to_upper(),
				"TELEMETRY // " + _backend.telemetry_availability.to_upper(),
				"MEDIA // " + _backend.media_availability.to_upper(), "NOTIFICATIONS // " + feed])
			_detail.text = "STATUS ONLY // NO CONTENT OR LOG HISTORY"
	_cursor.select(_cursor.selected, _items.size())
	for index in range(_rows.size()):
		var item := _cursor.offset + index
		_rows[index].text = ("> " if item == _cursor.selected else "  ") + _items[item] if item < _items.size() else ""
		_rows[index].add_theme_color_override("font_color", Tokens.READY if item == _cursor.selected else Tokens.TEXT)
	_shell.counter.text = "%d/%d" % [_cursor.selected + 1, _items.size()]
	_shell.hint.text = "%s/%s SELECT  %s OK  %s BACK" % [Actions.binding_label("nav_up", 1), Actions.binding_label("nav_down", 1), Actions.binding_label("confirm", 1), Actions.binding_label("back", 1)]

func _unhandled_input(event: InputEvent) -> void:
	if not visible: return
	if Actions.pressed(event, "nav_up") or Actions.pressed(event, "nav_down"):
		_cursor.move(-1 if Actions.pressed(event, "nav_up") else 1, _items.size())
		refresh()
	elif Actions.pressed(event, "confirm"):
		activate_selection()
	else: return
	get_viewport().set_input_as_handled()

func activate_selection() -> void:
	match page:
		"home":
			match _cursor.selected:
				0: resume_requested.emit()
				1: show_page("help")
				2: show_page("diagnostics")
				3: replay_requested.emit()
				4: dismiss_requested.emit()
		"help":
			if _cursor.selected == 4: show_page("controls")
