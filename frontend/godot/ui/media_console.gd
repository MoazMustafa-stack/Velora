extends CanvasLayer

const Actions = preload("res://scripts/input_actions.gd")
const Shell = preload("res://ui/panel_shell.gd")
const Cursor = preload("res://ui/list_cursor.gd")
const Tokens = preload("res://ui/design_tokens.gd")

signal control_requested(player_handle: String, verb: String)
signal console_closed

# P5.08 media console panel.
#
# Renders the BackendClient media snapshot in a fixed panel: keyboard-only
# player selection, color-independent status and active-player cues, and
# strict clipping so long identities and titles can never overflow the
# 320 x 180 canvas. Controls travel only as opaque snapshot-issued player
# handles plus the six allowlisted verbs; bus names, method names, raw
# arguments, and shell commands never appear on this side of the boundary.
# All state is memory-only and every state change is applied instantly with
# no animated transitions, so the panel writes nothing to disk and the
# reduced-motion guarantee holds by construction.

const TONE_COLORS := Tokens.TONES
const TEXT_COLOR := Tokens.TEXT
const DIM_COLOR := Tokens.MUTED
const ROW_BG := Tokens.SURFACE
const ROW_BG_SELECTED := Tokens.SELECTED
# Status never relies on color alone: every level renders a distinct marker
# glyph plus its spelled name, and color is only a secondary channel. An
# unrecognized status is labelled UNKNOWN instead of being guessed.
const STATUS_MARKERS := {
	"playing": "+",
	"paused": "=",
	"stopped": ".",
}
const STATUS_LABELS := {
	"playing": "PLAY",
	"paused": "PAUSE",
	"stopped": "STOP",
}
const STATUS_COLORS := {
	"playing": Tokens.READY,
	"paused": Tokens.WAITING,
	"stopped": Tokens.MUTED,
}
const VERB_LABELS := {
	"play": "PLAY",
	"pause": "PAUSE",
	"play_pause": "PLAY/PAUSE",
	"stop": "STOP",
	"next": "NEXT",
	"previous": "PREVIOUS",
}
# How many play/pause capabilities a player advertises. The single toggle key
# resolves to exactly one of the three play/pause verbs using this ratio, so
# the console never emits a verb the player cannot honour and Core will never
# have to reject. Core applies the identical table (media_store::verb_supported).
const TOGGLE_BOTH := 2
const TOGGLE_PLAY_ONLY := 1
const TOGGLE_PAUSE_ONLY := -1
const TOGGLE_NONE := 0
const MAX_VISIBLE_PLAYERS := 3
# Mirrors the protocol player ceiling (BackendClient.MAX_MEDIA_PLAYERS) so a
# mis-wired source can never grow the tracked set beyond the v5 bound.
const MAX_TRACKED_PLAYERS := 16

var players: Array[Dictionary] = []
var _cursor := Cursor.new(MAX_VISIBLE_PLAYERS)
var selected_index: int:
	get: return _cursor.selected
var scroll_offset: int:
	get: return _cursor.offset
var _shell: RefCounted
var availability := "waiting"
var active_handle := ""

var _panel: PanelContainer
var _title: Label
var _counter: Label
var _rows_box: VBoxContainer
var _feedback: Label
var _hint: Label
var _rows: Array[Dictionary] = []

func _ready() -> void:
	Actions.ensure_registered()
	visible = false
	_build_ui()

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if Actions.pressed(event, "back") or Actions.pressed(event, "media_console"):
		get_viewport().set_input_as_handled()
		close()
	elif Actions.pressed(event, "nav_up"):
		get_viewport().set_input_as_handled()
		_move_selection(-1)
	elif Actions.pressed(event, "nav_down"):
		get_viewport().set_input_as_handled()
		_move_selection(1)
	elif Actions.pressed(event, "page_up"):
		get_viewport().set_input_as_handled()
		_move_selection(-MAX_VISIBLE_PLAYERS)
	elif Actions.pressed(event, "page_down"):
		get_viewport().set_input_as_handled()
		_move_selection(MAX_VISIBLE_PLAYERS)
	elif Actions.pressed(event, "first"):
		get_viewport().set_input_as_handled()
		_select_index(0)
	elif Actions.pressed(event, "last"):
		get_viewport().set_input_as_handled()
		_select_index(players.size() - 1)
	elif Actions.pressed(event, "media_toggle"):
		get_viewport().set_input_as_handled()
		_request_toggle()
	elif Actions.pressed(event, "media_next"):
		get_viewport().set_input_as_handled()
		_request_verb("next")
	elif Actions.pressed(event, "media_previous"):
		get_viewport().set_input_as_handled()
		_request_verb("previous")
	elif Actions.pressed(event, "media_stop"):
		get_viewport().set_input_as_handled()
		_request_verb("stop")
	elif Actions.pressed(event, "media_play"):
		get_viewport().set_input_as_handled()
		_request_verb("play")
	elif Actions.pressed(event, "media_pause"):
		get_viewport().set_input_as_handled()
		_request_verb("pause")

func open() -> void:
	visible = true
	_set_feedback("", "ready")
	_select_index(_default_selection())

func close() -> void:
	visible = false
	console_closed.emit()

func set_availability(next_availability: String) -> void:
	availability = next_availability
	_refresh_title()

# Consumes a client-normalized media snapshot. Last-good players are kept
# across malformed frames and stale availability so the console keeps
# showing stale-but-labelled state instead of going blank; the client's
# sequence fencing guarantees this method only runs for newer frames.
func update_media(snapshot: Dictionary) -> void:
	var raw_players = snapshot.get("players", null)
	if not raw_players is Array:
		return
	if raw_players.size() > MAX_TRACKED_PLAYERS:
		return
	var selected_handle := _selected_handle()
	players.clear()
	var seen_handles := {}
	for raw_player in raw_players:
		if not raw_player is Dictionary:
			continue
		var handle := String(raw_player.get("handle", ""))
		if handle.is_empty() or seen_handles.has(handle):
			continue
		seen_handles[handle] = true
		players.append({
			"handle": handle,
			"identity": _as_text(raw_player.get("identity", null), ""),
			"status": _as_text(raw_player.get("status", null), ""),
			"title": _as_text(raw_player.get("title", null), ""),
			"artist": _as_text(raw_player.get("artist", null), ""),
			"album": _as_text(raw_player.get("album", null), ""),
			"length_micros": _as_micros(raw_player.get("length_micros", null), -1),
			"position_micros": _as_micros(raw_player.get("position_micros", null), 0),
			"can_play": bool(raw_player.get("can_play", false)),
			"can_pause": bool(raw_player.get("can_pause", false)),
			"can_go_next": bool(raw_player.get("can_go_next", false)),
			"can_go_previous": bool(raw_player.get("can_go_previous", false)),
			"can_seek": bool(raw_player.get("can_seek", false)),
			"can_control": bool(raw_player.get("can_control", false)),
		})
	active_handle = _as_text(snapshot.get("active_player_handle", null), "")
	_preserve_selection(selected_handle)

# Correlated control outcomes arrive through the client's typed signals.
func apply_control_accepted(_player_handle: String, verb: String) -> void:
	_set_feedback("%s OK" % VERB_LABELS.get(verb, verb.to_upper()), "ready")

func apply_control_rejected(
	_player_handle: String,
	_verb: String,
	_code: String,
	message: String,
	retryable: bool
) -> void:
	_set_feedback(message, "waiting" if retryable else "failure")

func _default_selection() -> int:
	if not active_handle.is_empty():
		for index in range(players.size()):
			if String(players[index].get("handle", "")) == active_handle:
				return index
	return 0 if not players.is_empty() else -1

func _selected_handle() -> String:
	if selected_index >= 0 and selected_index < players.size():
		return String(players[selected_index].get("handle", ""))
	return ""

func _selected_player() -> Dictionary:
	if selected_index >= 0 and selected_index < players.size():
		return players[selected_index]
	return {}

func _preserve_selection(handle: String) -> void:
	_cursor.preserve(players.map(func(player: Dictionary): return player["handle"]), handle, _default_selection())
	_refresh_rows()

func _move_selection(step: int) -> void:
	_cursor.move(step, players.size())
	_refresh_rows()

func _select_index(index: int) -> void:
	_cursor.select(index, players.size())
	_refresh_rows()

func _refresh_title() -> void:
	match availability:
		"available":
			_title.text = "MEDIA // PLAYERS"
			_title.add_theme_color_override("font_color", TONE_COLORS["ready"])
		"unavailable":
			_title.text = "MEDIA // NO SERVICE"
			_title.add_theme_color_override("font_color", TONE_COLORS["failure"])
		_:
			_title.text = "MEDIA // WAITING"
			_title.add_theme_color_override("font_color", TONE_COLORS["waiting"])

# Emits one allowlisted verb for the selected player's opaque handle. The
# verb is gated on the snapshot's capability flags so unsupported controls
# fail closed here instead of crossing IPC to be rejected by Core.
func _request_verb(verb: String) -> void:
	if players.is_empty():
		_set_feedback("NO PLAYERS", "failure")
		return
	var player := _selected_player()
	if player.is_empty():
		_set_feedback("NO PLAYERS", "failure")
		return
	if not _verb_allowed(player, verb):
		_set_feedback("CONTROL NOT AVAILABLE", "failure")
		return
	_set_feedback("%s SENT" % VERB_LABELS.get(verb, verb.to_upper()), "waiting")
	control_requested.emit(String(player.get("handle", "")), verb)

# The toggle key resolves to the exact play/pause verb the player advertises
# rather than always forcing the combined verb, so every one of the six
# allowlisted verbs is keyboard reachable and no keypress ever emits a verb
# Core would reject.
func _request_toggle() -> void:
	if players.is_empty():
		_set_feedback("NO PLAYERS", "failure")
		return
	var player := _selected_player()
	if player.is_empty():
		_set_feedback("NO PLAYERS", "failure")
		return
	_request_verb(_toggle_verb(player))

func _toggle_verb(player: Dictionary) -> String:
	match _toggle_ratio(player):
		TOGGLE_BOTH:
			return "play_pause"
		TOGGLE_PLAY_ONLY:
			return "play"
		TOGGLE_PAUSE_ONLY:
			return "pause"
	return ""

func _toggle_ratio(player: Dictionary) -> int:
	var can_play := bool(player.get("can_play", false))
	var can_pause := bool(player.get("can_pause", false))
	if can_play and can_pause:
		return TOGGLE_BOTH
	if can_play:
		return TOGGLE_PLAY_ONLY
	if can_pause:
		return TOGGLE_PAUSE_ONLY
	return TOGGLE_NONE

# Core re-maps each verb onto its MPRIS method, and media_store::verb_supported
# gates PlayPause on both can_play AND can_pause. This table mirrors Core
# exactly, so the console and the Core dispatcher can never disagree; a
# player that can only play is started with the standalone play verb instead
# of a combined toggle Core would reject. MPRIS has no CanStop flag, so Stop
# is gated by the master CanControl alone, again identically to Core.
func _verb_allowed(player: Dictionary, verb: String) -> bool:
	if not VERB_LABELS.has(verb):
		return false
	if not bool(player.get("can_control", false)):
		return false
	match verb:
		"play":
			return bool(player.get("can_play", false))
		"pause":
			return bool(player.get("can_pause", false))
		"play_pause":
			return bool(player.get("can_play", false)) and bool(player.get("can_pause", false))
		"next":
			return bool(player.get("can_go_next", false))
		"previous":
			return bool(player.get("can_go_previous", false))
		"stop":
			return true
	return false

func _set_feedback(message: String, tone: String) -> void:
	_feedback.text = message
	_feedback.add_theme_color_override("font_color", TONE_COLORS.get(tone, TONE_COLORS["ready"]))

func _refresh_rows() -> void:
	if players.is_empty():
		for row_index in range(_rows.size()):
			_apply_row(
				_rows[row_index],
				"NO PLAYERS" if row_index == 0 else "",
				"",
				DIM_COLOR,
				false
			)
		_refresh_counter()
		_refresh_hint()
		return
	for row_index in range(_rows.size()):
		var row := _rows[row_index]
		var player_index := scroll_offset + row_index
		if player_index >= players.size():
			_apply_row(row, "", "", DIM_COLOR, false)
			continue
		var player := players[player_index]
		_apply_row(
			row,
			_build_summary(player_index, player),
			_build_detail(player),
			_status_color(String(player.get("status", ""))),
			player_index == selected_index
		)
	_refresh_counter()
	_refresh_hint()

func _build_summary(player_index: int, player: Dictionary) -> String:
	var status := String(player.get("status", ""))
	var marker: String = STATUS_MARKERS.get(status, "?")
	var is_selected := player_index == selected_index
	var is_active := String(player.get("handle", "")) == active_handle
	var identity := String(player.get("identity", "")).to_upper()
	if identity.is_empty():
		identity = "UNKNOWN PLAYER"
	return "%s%s%s %s" % [
		">" if is_selected else " ",
		marker,
		"@" if is_active else " ",
		identity,
	]

func _build_detail(player: Dictionary) -> String:
	var status := String(player.get("status", ""))
	var parts: Array[String] = [String(STATUS_LABELS.get(status, "UNKNOWN"))]
	if String(player.get("handle", "")) == active_handle:
		parts.append("ACTIVE")
	var title := String(player.get("title", ""))
	parts.append("UNTITLED" if title.is_empty() else title)
	for metadata in ["artist", "album"]:
		var value := String(player.get(metadata, ""))
		if not value.is_empty():
			parts.append(value)
	var position_micros := int(player.get("position_micros", 0))
	var length_micros := int(player.get("length_micros", -1))
	var time_text := "%s / %s" % [
		_format_time(position_micros),
		_format_time(length_micros) if length_micros >= 0 else "--:--",
	]
	parts.append(time_text)
	return " // ".join(parts)

func _format_time(micros: int) -> String:
	var total_seconds := micros / 1000000
	return "%d:%02d" % [total_seconds / 60, total_seconds % 60]

func _status_color(status: String) -> Color:
	return STATUS_COLORS.get(status, TEXT_COLOR)

func _refresh_hint() -> void:
	var parts: Array[String] = []
	if not players.is_empty():
		var player := _selected_player()
		if not player.is_empty():
			# The toggle hint names the exact verb the key will fire for this
			# player, so the label and the wire request can never disagree.
			var toggle_verb := _toggle_verb(player)
			if not toggle_verb.is_empty() and _verb_allowed(player, toggle_verb):
				parts.append("SPACE %s" % VERB_LABELS[toggle_verb])
			if _verb_allowed(player, "stop"):
				parts.append("X STOP")
			if _verb_allowed(player, "next"):
				parts.append("N NEXT")
			if _verb_allowed(player, "previous"):
				parts.append("B PREV")
		if parts.is_empty():
			parts.append("NO CONTROLS")
	parts.append("P CLOSE")
	_hint.text = "  ".join(parts)

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
	if selected_index < 0 or players.is_empty():
		_counter.text = "0/0"
	else:
		_counter.text = "%d/%d" % [selected_index + 1, players.size()]

func _as_micros(value: Variant, fallback: int) -> int:
	if value is float or value is int:
		return int(value)
	return fallback

# Strings are coerced defensively: the client normalizes snapshots before they
# reach the console, but a non-string field degrades to its default instead
# of crashing or guessing.
func _as_text(value: Variant, fallback: String) -> String:
	if value is String:
		return value
	return fallback

func _build_ui() -> void:
	_shell = Shell.new(self)
	_panel = _shell.panel
	_title = _shell.title
	_title.text = "MEDIA // WAITING"
	_counter = _shell.counter
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", Tokens.SPACE / 2)
	_shell.box.add_child(_rows_box)
	for _row_index in range(MAX_VISIBLE_PLAYERS):
		_rows.append(Shell.row(_rows_box))
	_feedback = Shell.label()
	_shell.box.add_child(_feedback)
	_hint = _shell.finish("P CLOSE")
