extends CanvasLayer
## Keyboard-owned pages, composed from the same bounded shell as live panels.
const Shell = preload("res://ui/panel_shell.gd")
const Cursor = preload("res://ui/list_cursor.gd")
const Tokens = preload("res://ui/design_tokens.gd")
const Actions = preload("res://scripts/input_actions.gd")
const Bindings = preload("res://scripts/key_bindings.gd")
signal resume_requested
signal replay_requested
signal dismiss_requested
signal preferences_changed
signal reset_requested
signal ui_cue_requested(kind: String)
signal binding_requested(action: String, keys: Array)
signal bindings_reset_requested
var page := "home"
var backend_status: Label
var _backend: Node
var _settings: RefCounted
var _feedback := ""
var _shell: RefCounted
var _cursor := Cursor.new(5)
var _rows: Array[Label] = []
var _items: Array[String] = []
var _detail: Label
var capturing_key := false
var _capture_action := ""

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

func configure(backend: Node, settings: RefCounted) -> void:
	_backend = backend
	_settings = settings
	show_page("home")

func open() -> void:
	visible = true
	show_page("home")

func back() -> bool:
	if capturing_key:
		cancel_capture()
		return true
	if page == "home": return false
	show_page("settings" if page in ["accessibility", "audio", "reset"] else "home")
	return true

func show_page(next: String) -> void:
	if next not in ["home", "help", "diagnostics", "controls", "settings", "accessibility", "audio", "reset"]: return
	page = next
	capturing_key = false
	_feedback = ""
	_cursor.select(0, 1)
	refresh()

func refresh() -> void:
	if _backend == null: return
	_shell.title.text = "VELORA // " + ("PAUSED" if page == "home" else page.to_upper())
	_detail.text = ""
	match page:
		"home":
			_items.assign(["RESUME", "HELP / CONTROLS", "CAPABILITY DIAGNOSTICS", "SETTINGS", "REPLAY FIRST-RUN HINTS"])
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
			_items.append("RESET ALL KEY BINDINGS")
			_detail.text = "PRESS A NEW KEY // ESC CANCEL" if capturing_key else "ENTER REMAP // ESC REMAINS RECOVERY"
		"diagnostics":
			var feed: String = "DISABLED" if _backend.notifications_policy_disabled else _backend.notifications_availability.to_upper()
			if feed == "AVAILABLE": feed = "ENABLED / OPT-IN"
			if _backend.state != BackendClient.ConnectionState.READY: feed = "CORE OFFLINE / POLICY UNKNOWN"
			_items.assign(["CORE // " + BackendClient.ConnectionState.keys()[_backend.state],
				"HYPRLAND // " + _backend.session_availability.to_upper(),
				"TELEMETRY // " + _backend.telemetry_availability.to_upper(),
				"MEDIA // " + _backend.media_availability.to_upper(), "NOTIFICATIONS // " + feed])
			_detail.text = "STATUS ONLY // NO CONTENT OR LOG HISTORY"
		"settings":
			_items.assign(["ACCESSIBILITY", "LOCAL AUDIO PREFERENCES", "CONTROLS / CURRENT BINDINGS", "SKIP FIRST-RUN HINTS", "RESET UI PREFERENCES"])
			_detail.text = "UI ONLY // NO LIVE DATA IS SAVED"
		"accessibility":
			_items.assign(["REDUCED MOTION // " + ("ON" if _settings.reduced_motion() else "OFF"), "BACK TO SETTINGS"])
			_detail.text = "NO FLASHING // LABELS DO NOT RELY ON COLOR"
		"audio":
			_items.assign(["LOCAL MUTE // " + ("ON" if _settings.audio_muted() else "OFF"), "VOLUME // %d%%" % roundi(_settings.audio_volume() * 100), "BACK TO SETTINGS"])
			_detail.text = "VELORA UI ONLY // SYSTEM MIXER UNCHANGED"
		"reset":
			_items.assign(["CANCEL", "CONFIRM RESET // UI PREFERENCES ONLY"])
			_detail.text = "NO CORE DATA OR SYSTEM CONFIG IS TOUCHED"
	if not _feedback.is_empty(): _detail.text = _feedback
	_cursor.select(_cursor.selected, _items.size())
	for index in range(_rows.size()):
		var item := _cursor.offset + index
		_rows[index].text = ("> " if item == _cursor.selected else "  ") + _items[item] if item < _items.size() else ""
		_rows[index].add_theme_color_override("font_color", Tokens.READY if item == _cursor.selected else Tokens.TEXT)
	_shell.counter.text = "%d/%d" % [_cursor.selected + 1, _items.size()]
	_shell.hint.text = "%s/%s SELECT  %s OK  %s BACK" % [Actions.binding_label("nav_up", 1), Actions.binding_label("nav_down", 1), Actions.binding_label("confirm", 1), Actions.binding_label("back", 1)]

func _unhandled_input(event: InputEvent) -> void:
	if not visible: return
	if capturing_key: return
	if Actions.pressed(event, "nav_up") or Actions.pressed(event, "nav_down"):
		_cursor.move(-1 if Actions.pressed(event, "nav_up") else 1, _items.size())
		refresh()
		ui_cue_requested.emit("navigate")
	elif Actions.pressed(event, "confirm"):
		activate_selection()
	elif page == "audio" and _cursor.selected == 1 and (Actions.pressed(event, "nav_left") or Actions.pressed(event, "nav_right")):
		_settings.set_audio_volume(_settings.audio_volume() + (-0.1 if Actions.pressed(event, "nav_left") else 0.1))
		preferences_changed.emit()
		refresh()
	else: return
	get_viewport().set_input_as_handled()

func activate_selection() -> void:
	if page in ["home", "help", "settings", "reset"] and (page != "help" or _cursor.selected == 4):
		ui_cue_requested.emit("confirm")
	match page:
		"home":
			match _cursor.selected:
				0: resume_requested.emit()
				1: show_page("help")
				2: show_page("diagnostics")
				3: show_page("settings")
				4: replay_requested.emit()
		"help":
			if _cursor.selected == 4: show_page("controls")
		"settings":
			match _cursor.selected:
				0: show_page("accessibility")
				1: show_page("audio")
				2: show_page("controls")
				3: dismiss_requested.emit()
				4: show_page("reset")
		"accessibility":
			if _cursor.selected == 0:
				_settings.set_reduced_motion(not _settings.reduced_motion())
				preferences_changed.emit()
				refresh()
			else: show_page("settings")
		"audio":
			match _cursor.selected:
				0:
					_settings.set_audio_muted(not _settings.audio_muted())
					preferences_changed.emit()
					refresh()
				1:
					_settings.set_audio_volume(float((roundi(_settings.audio_volume() * 10) + 1) % 11) / 10.0)
					preferences_changed.emit()
					refresh()
				2: show_page("settings")
		"reset":
			if _cursor.selected == 1: reset_requested.emit()
			else: show_page("settings")
		"controls":
			if _cursor.selected == Actions.DEFAULTS.size():
				bindings_reset_requested.emit()
			else:
				_capture_action = String(Actions.DEFAULTS.keys()[_cursor.selected])
				capturing_key = true
				_feedback = ""
				refresh()

func capture_key(event: InputEventKey) -> void:
	if not capturing_key or not event.pressed or event.echo: return
	var key := int(event.physical_keycode if event.physical_keycode != 0 else event.keycode)
	if key == KEY_ESCAPE:
		cancel_capture()
		return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		set_feedback("MODIFIED CHORDS ARE NOT SUPPORTED")
		ui_cue_requested.emit("reject")
		return
	var problem := Bindings.remap_reason(_settings, _capture_action, [key])
	if not problem.is_empty():
		set_feedback(problem)
		ui_cue_requested.emit("reject")
		return
	capturing_key = false
	binding_requested.emit(_capture_action, [key])

func cancel_capture() -> void:
	capturing_key = false
	set_feedback("CANCELLED // BINDINGS UNCHANGED")

func set_feedback(message: String) -> void:
	_feedback = message
	refresh()
