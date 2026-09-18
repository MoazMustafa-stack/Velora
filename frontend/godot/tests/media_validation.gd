extends SceneTree

# P5.08 media console scene and UI validation. Client-side BackendClient
# media coverage (normalization, bounds, fencing, retention, availability,
# and control results) lives in media_client_validation.gd; this file
# exercises the console and its main-scene wiring only, including the
# Core-aligned capability gates and keyboard reachability of all six
# allowlisted verbs.

const MediaConsoleScript = preload("res://ui/media_console.gd")

class FakeBridge:
	extends Node

	signal socket_connected
	signal socket_disconnected(reason: String)
	signal line_received(payload: String)
	signal transport_error(code: String, message: String)

	var sent_lines: Array[String] = []
	var connected_path := ""
	var disconnected := false

	func default_socket_path() -> String:
		return "/tmp/velora-fake.sock"

	func connect_socket(path: String) -> bool:
		connected_path = path
		return true

	func disconnect_socket() -> void:
		disconnected = true

	func send_line(payload: String) -> bool:
		sent_lines.append(payload)
		return true

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func _key_event(keycode: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event

func _welcome() -> Dictionary:
	return {
		"type": "welcome",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"server_name": "velora-core-test",
		"server_version": "0.2.0",
	}

func _player(
	handle: String,
	identity := "Velora Test Player",
	status := "playing",
	title := "Velora Theme",
	artist := "Velora",
	album: Variant = null,
	length_micros: Variant = null,
	position_micros := 12500000,
	can_play := true,
	can_pause := true,
	can_go_next := true,
	can_go_previous := true,
	can_seek := false,
	can_control := true
) -> Dictionary:
	return {
		"handle": handle,
		"identity": identity,
		"status": status,
		"title": title,
		"artist": artist,
		"album": album,
		"length_micros": length_micros,
		"position_micros": position_micros,
		"can_play": can_play,
		"can_pause": can_pause,
		"can_go_next": can_go_next,
		"can_go_previous": can_go_previous,
		"can_seek": can_seek,
		"can_control": can_control,
	}

func _snapshot(sequence: int, players: Array, active: Variant = null) -> Dictionary:
	return {"sequence": sequence, "players": players, "active_player_handle": active}

func _emit_media(bridge: FakeBridge, request_id: Variant, snapshot: Variant) -> void:
	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": request_id,
		"snapshot": snapshot,
	}))

func _emit_media_rejected(
	bridge: FakeBridge,
	request_id: Variant,
	code: String,
	retryable: bool
) -> void:
	bridge.line_received.emit(JSON.stringify({
		"type": "media_snapshot_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": request_id,
		"code": code,
		"retryable": retryable,
	}))

func _emit_control_accepted(bridge: FakeBridge, request_id: Variant, player_handle: String) -> void:
	bridge.line_received.emit(JSON.stringify({
		"type": "media_control_accepted",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": request_id,
		"player_handle": player_handle,
	}))

func _emit_control_rejected(
	bridge: FakeBridge,
	request_id: Variant,
	player_handle: String,
	code: String
) -> void:
	bridge.line_received.emit(JSON.stringify({
		"type": "media_control_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": request_id,
		"player_handle": player_handle,
		"code": code,
	}))

func _message_at(bridge: FakeBridge, index: int) -> Dictionary:
	if index < 0 or index >= bridge.sent_lines.size():
		return {}
	var value = JSON.parse_string(bridge.sent_lines[index])
	return value if value is Dictionary else {}

func _last_request_of_type(bridge: FakeBridge, request_type: String) -> Dictionary:
	for index in range(bridge.sent_lines.size() - 1, -1, -1):
		var candidate := _message_at(bridge, index)
		if candidate.get("type") == request_type:
			return candidate
	return {}

func _run() -> void:
	await _run_scene_wiring()
	await _run_console()
	if failures.is_empty():
		print("P5.08 media console validation passed.")
		quit(0)
	else:
		push_error("P5.08 media console validation failed: %s" % [failures])
		quit(1)

func _run_scene_wiring() -> void:
	# --- main-scene wiring: typed client signals reach the console ---
	var bridge := FakeBridge.new()
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	var main: Node = main_scene.instantiate()
	var scene_backend: BackendClient = main.get_node("BackendClient")
	scene_backend.auto_connect = false
	scene_backend.bridge_override = bridge
	root.add_child(main)
	await process_frame
	var console: CanvasLayer = main.get_node("MediaConsole")
	_check(not console.visible, "P5.08 the media console starts hidden in the scene")

	scene_backend.connect_to_core()
	bridge.socket_connected.emit()
	bridge.line_received.emit(JSON.stringify(_welcome()))
	var scene_media_request := _last_request_of_type(bridge, "get_media_snapshot")
	_emit_media(bridge, scene_media_request.get("request_id"), _snapshot(21, [
		_player("player:music-1", "Spotify", "playing", "Velora Theme", "Velora", "Night Album", 250000000),
		_player("player:music-2", "Firefox", "paused", "Quiet Track", "", "", null, 5000000, true, true, false, false, false, true),
	], "player:music-1"))
	_check(
		console.players.size() == 2 and console.selected_index == 0,
		"P5.08 typed client signals reach the scene console with the active player selected"
	)
	_check(
		console._title.text == "MEDIA // PLAYERS",
		"P5.08 the scene console labels availability from typed client state"
	)
	_check(
		String(console._rows[0]["summary"].text) == ">+@ SPOTIFY",
		"P5.08 the scene console renders status and active markers without color"
	)

	main._toggle_media_console()
	_check(
		main.media_open and console.visible and not main.player.input_enabled,
		"P5.08 opening the console locks world input"
	)
	var refresh_request := _last_request_of_type(bridge, "get_media_snapshot")
	_check(
		int(refresh_request.get("request_id", 0)) > int(scene_media_request.get("request_id", 0)),
		"P5.08 opening the console triggers a scene-driven snapshot refresh"
	)

	console._unhandled_input(_key_event(KEY_SPACE))
	var control_message := _last_request_of_type(bridge, "send_media_control")
	_check(
		control_message.get("player_handle") == "player:music-1"
		and control_message.get("verb") == "play_pause"
		and control_message.keys().size() == 5,
		"P5.08 console verb keypresses travel the typed request path"
	)
	_emit_control_accepted(bridge, control_message.get("request_id"), "player:music-1")
	_check(
		String(console._feedback.text) == "PLAY/PAUSE OK",
		"P5.08 correlated control acceptance surfaces in the console feedback line"
	)

	console._unhandled_input(_key_event(KEY_N))
	var next_message := _last_request_of_type(bridge, "send_media_control")
	_emit_control_rejected(bridge, next_message.get("request_id"), "player:music-1", "stale_handle")
	_check(
		String(console._feedback.text) == "PLAYER STALE // REFRESH LIST",
		"P5.08 typed control rejections surface in the console feedback line"
	)

	console._unhandled_input(_key_event(KEY_DOWN))
	var lines_before_gate := bridge.sent_lines.size()
	console._unhandled_input(_key_event(KEY_N))
	_check(
		bridge.sent_lines.size() == lines_before_gate
		and String(console._feedback.text) == "CONTROL NOT AVAILABLE",
		"P5.08 capability gates block unsupported verbs before the wire"
	)

	console._unhandled_input(_key_event(KEY_ESCAPE))
	_check(
		not main.media_open and not console.visible and main.player.input_enabled,
		"P5.08 closing the console restores world input"
	)
	main._unhandled_input(_key_event(KEY_P))
	_check(main.media_open and console.visible, "P5.08 P toggles the console from the world view")
	console._unhandled_input(_key_event(KEY_ESCAPE))
	main.queue_free()
	await process_frame

func _run_console() -> void:
	# --- standalone console behaviours (offline, no core) ---
	var user_files_before := DirAccess.get_files_at(OS.get_user_data_dir())
	var user_dirs_before := DirAccess.get_directories_at(OS.get_user_data_dir())

	var console: CanvasLayer = CanvasLayer.new()
	console.set_script(MediaConsoleScript)
	root.add_child(console)
	await process_frame

	# --- conservative start state
	_check(not console.visible, "P5.08 the console starts hidden")
	_check(console._title.text.contains("WAITING"), "P5.08 the console starts in a typed waiting state")
	_check(console._counter.text == "0/0", "P5.08 the position counter starts at zero")
	_check(console._feedback.text == "", "P5.08 the feedback line starts empty")

	# --- explicit availability states
	console.set_availability("unavailable")
	_check(console._title.text.contains("NO SERVICE"), "P5.08 a missing media service is labelled explicitly")
	console.set_availability("available")
	_check(
		console._title.text.contains("PLAYERS") and not console._title.text.contains("NO SERVICE"),
		"P5.08 an available media service is labelled explicitly"
	)
	console.set_availability("unknown")
	_check(console._title.text.contains("WAITING"), "P5.08 unknown availability falls back to waiting")

	# --- empty snapshots are explicit, never guessed
	console.update_media(_snapshot(1, [], null))
	console.open()
	_check(
		String(console._rows[0]["summary"].text) == "NO PLAYERS",
		"P5.08 an empty player list states it explicitly rather than guessing"
	)
	_check(
		console.selected_index == -1 and console.scroll_offset == 0,
		"P5.08 an empty player list has no selection"
	)
	console._unhandled_input(_key_event(KEY_SPACE))
	_check(
		String(console._feedback.text) == "NO PLAYERS",
		"P5.08 control keypresses with no players are labelled explicitly"
	)
	console.close()

	# --- status and active markers never rely on color alone
	var music_player := _player("player:music-1", "Spotify", "playing", "Velora Theme", "Velora", "Night Album", 250000000, 12500000)
	var paused_player := _player("player:music-2", "Firefox", "paused", "Quiet Track", "", "", null, 5000000)
	var stopped_player := _player("player:music-3", "Vlc", "stopped", "", "Someone", "", null, 0)
	console.update_media(_snapshot(2, [music_player, paused_player, stopped_player], "player:music-1"))
	console.open()
	_check(console._counter.text == "1/3", "P5.08 the counter reports the selected position and total")
	_check(
		String(console._rows[0]["summary"].text) == ">+@ SPOTIFY",
		"P5.08 a selected playing active player carries cursor, status, and active markers"
	)
	_check(
		String(console._rows[0]["detail"].text) == "PLAY // ACTIVE // Velora Theme // Velora // Night Album // 0:12 / 4:10",
		"P5.08 the active player spells status, metadata, and position"
	)
	_check(
		String(console._rows[1]["summary"].text) == " =  FIREFOX"
		and String(console._rows[1]["detail"].text).begins_with("PAUSE // Quiet Track // 0:05 / --:--"),
		"P5.08 paused players carry the equals marker and an unknown length sentinel"
	)
	_check(
		String(console._rows[2]["summary"].text) == " .  VLC"
		and String(console._rows[2]["detail"].text).begins_with("STOP // UNTITLED // Someone // 0:00 / --:--"),
		"P5.08 stopped players carry the dot marker and spell UNTITLED"
	)
	_check(
		console._hint.text == "SPACE PLAY/PAUSE  X STOP  N NEXT  B PREV  P CLOSE",
		"P5.08 the hint line lists exactly the capability-allowed verbs"
	)

	# --- keyboard-only selection and scrolling across more players
	var scroll_players: Array = []
	var statuses := ["playing", "paused", "stopped"]
	for index in range(6):
		scroll_players.append(_player(
			"player:scroll-%d" % index,
			"Scroll %d" % index,
			statuses[index % 3]
		))
	console.update_media(_snapshot(3, scroll_players, null))
	console.open()
	_check(
		console.selected_index == 0 and console._counter.text == "1/6",
		"P5.08 reopening resets selection to the first player"
	)
	console._unhandled_input(_key_event(KEY_END))
	_check(
		console.selected_index == 5 and console.scroll_offset == 3 and console._counter.text == "6/6",
		"P5.08 End jumps to the last player and scrolls the window"
	)
	_check(
		String(console._rows[0]["summary"].text).begins_with(" +  SCROLL 3")
		and String(console._rows[2]["summary"].text).begins_with(">.  SCROLL 5"),
		"P5.08 the visible window follows the selection"
	)
	console._unhandled_input(_key_event(KEY_DOWN))
	_check(console.selected_index == 0, "P5.08 selection wraps forward past the end")
	console._unhandled_input(_key_event(KEY_UP))
	_check(console.selected_index == 5, "P5.08 selection wraps backward past the start")
	console._unhandled_input(_key_event(KEY_HOME))
	_check(
		console.selected_index == 0 and console.scroll_offset == 0,
		"P5.08 Home jumps to the first player"
	)
	console._unhandled_input(_key_event(KEY_PAGEDOWN))
	_check(console.selected_index == 3, "P5.08 Page Down scrolls a full window")
	console._unhandled_input(_key_event(KEY_PAGEUP))
	_check(console.selected_index == 0, "P5.08 Page Up scrolls a full window back")
	console._unhandled_input(_key_event(KEY_S))
	_check(console.selected_index == 1, "P5.08 W and S mirror the arrow keys")

	# --- verb keypresses emit only allowlisted verbs for opaque handles
	console.update_media(_snapshot(4, [music_player], "player:music-1"))
	console.open()
	var emitted: Array = []
	console.control_requested.connect(func(player_handle: String, verb: String) -> void:
		emitted.append([player_handle, verb])
	)
	# All six allowlisted verbs are keyboard reachable: the toggle keys
	# resolve the combined verb for players advertising both capabilities,
	# and the numpad play/pause glyphs carry the standalone verbs.
	var verb_keys := {
		KEY_SPACE: "play_pause",
		KEY_E: "play_pause",
		KEY_ENTER: "play_pause",
		KEY_N: "next",
		KEY_RIGHT: "next",
		KEY_D: "next",
		KEY_B: "previous",
		KEY_LEFT: "previous",
		KEY_A: "previous",
		KEY_X: "stop",
		KEY_KP_0: "play",
		KEY_KP_2: "pause",
	}
	for verb_key in verb_keys:
		console._unhandled_input(_key_event(verb_key))
	_check(
		emitted.size() == verb_keys.size()
		and String(emitted[0][0]) == "player:music-1",
		"P5.08 each control key emits exactly one typed verb for the opaque handle"
	)
	var emitted_verbs := {}
	for pair in emitted:
		emitted_verbs[pair[1]] = true
	_check(
		emitted_verbs.keys().size() == 6
		and emitted_verbs.has("play")
		and emitted_verbs.has("pause")
		and emitted_verbs.has("play_pause")
		and emitted_verbs.has("stop")
		and emitted_verbs.has("next")
		and emitted_verbs.has("previous"),
		"P5.08 every one of the six allowlisted verbs is keyboard reachable"
	)

	# --- capability gates fail closed before the wire
	var locked_player := _player("player:locked-1", "Locked", "playing", "T", "A", null, null, 0, true, true, true, true, false, false)
	console.update_media(_snapshot(5, [locked_player], "player:locked-1"))
	var emitted_before_gate := emitted.size()
	console._unhandled_input(_key_event(KEY_SPACE))
	console._unhandled_input(_key_event(KEY_N))
	console._unhandled_input(_key_event(KEY_X))
	_check(
		emitted.size() == emitted_before_gate
		and String(console._feedback.text) == "CONTROL NOT AVAILABLE"
		and console._hint.text == "NO CONTROLS  P CLOSE",
		"P5.08 players without control capability fail closed with an explicit label"
	)
	var no_next_player := _player("player:nonext-1", "No Next", "paused", "T", "A", null, null, 0, true, true, false)
	console.update_media(_snapshot(6, [no_next_player], "player:nonext-1"))
	console._unhandled_input(_key_event(KEY_N))
	_check(
		emitted.size() == emitted_before_gate
		and String(console._feedback.text) == "CONTROL NOT AVAILABLE",
		"P5.08 unsupported next controls are gated before the wire"
	)
	var listen_only := _player("player:listen-1", "Listen Only", "playing", "T", "A", null, null, 0, false, false, false, false)
	console.update_media(_snapshot(7, [listen_only], "player:listen-1"))
	console._unhandled_input(_key_event(KEY_SPACE))
	_check(
		emitted.size() == emitted_before_gate,
		"P5.08 players without play or pause capability gate the toggle verb"
	)

	# --- Core-aligned PlayPause gate: both capabilities are required
	# media_store::verb_supported gates PlayPause on can_play AND can_pause,
	# so the combined verb must never leave the console for a half-capable
	# player; the toggle key degrades to the exact advertised verb instead.
	var play_only := _player("player:playonly-1", "Play Only", "paused", "T", "A", null, null, 0, true, false, false, false)
	console.update_media(_snapshot(14, [play_only], "player:playonly-1"))
	console._unhandled_input(_key_event(KEY_SPACE))
	_check(
		emitted.size() == emitted_before_gate + 1
		and String(emitted[emitted.size() - 1][1]) == "play",
		"P5.08 a play-only player toggles with the standalone play verb"
	)
	_check(
		console._hint.text == "SPACE PLAY  X STOP  P CLOSE",
		"P5.08 the hint names the exact verb the toggle key will fire"
	)
	console._unhandled_input(_key_event(KEY_KP_0))
	console._unhandled_input(_key_event(KEY_KP_2))
	_check(
		emitted.size() == emitted_before_gate + 2
		and String(emitted[emitted.size() - 1][0]) == "player:playonly-1"
		and String(emitted[emitted.size() - 1][1]) == "play",
		"P5.08 the standalone play key still fires for a play-only player"
	)
	var pause_only := _player("player:pauseonly-1", "Pause Only", "playing", "T", "A", null, null, 0, false, true, false, false)
	console.update_media(_snapshot(15, [pause_only], "player:pauseonly-1"))
	console._unhandled_input(_key_event(KEY_SPACE))
	_check(
		emitted.size() == emitted_before_gate + 3
		and String(emitted[emitted.size() - 1][1]) == "pause",
		"P5.08 a pause-only player toggles with the standalone pause verb"
	)
	_check(
		console._hint.text == "SPACE PAUSE  X STOP  P CLOSE",
		"P5.08 the pause-only hint names the pause verb"
	)
	var half_toggle := _player("player:half-1", "Half", "playing", "T", "A", null, null, 0, true, false, false, false)
	console.update_media(_snapshot(16, [half_toggle], "player:half-1"))
	console._request_verb("play_pause")
	_check(
		emitted.size() == emitted_before_gate + 3
		and String(console._feedback.text) == "CONTROL NOT AVAILABLE",
		"P5.08 the combined toggle verb requires both play and pause capability like Core"
	)

	# --- the toggle degrades conservatively as capabilities change
	var degrading := _player("player:degrade-1", "Degrade", "playing", "T", "A", null, null, 0, true, true, false, false)
	console.update_media(_snapshot(17, [degrading], "player:degrade-1"))
	console._unhandled_input(_key_event(KEY_SPACE))
	degrading["can_pause"] = false
	console.update_media(_snapshot(18, [degrading], "player:degrade-1"))
	console._unhandled_input(_key_event(KEY_SPACE))
	_check(
		emitted.size() == emitted_before_gate + 5
		and String(emitted[emitted.size() - 2][1]) == "play_pause"
		and String(emitted[emitted.size() - 1][1]) == "play",
		"P5.08 the toggle degrades from combined to standalone as capabilities drop"
	)

	# --- correlated control outcomes in the feedback line
	console.update_media(_snapshot(8, [music_player], "player:music-1"))
	console.open()
	console.apply_control_accepted("player:music-1", "next")
	_check(
		console._feedback.text == "NEXT OK"
		and console._feedback.get_theme_color("font_color") == MediaConsoleScript.TONE_COLORS["ready"],
		"P5.08 accepted controls render a ready-tone outcome"
	)
	console.apply_control_rejected("player:music-1", "next", "unknown_player", "PLAYER NO LONGER EXISTS", false)
	_check(
		console._feedback.text == "PLAYER NO LONGER EXISTS"
		and console._feedback.get_theme_color("font_color") == MediaConsoleScript.TONE_COLORS["failure"],
		"P5.08 non-retryable rejections render the typed failure tone"
	)
	console.apply_control_rejected("player:music-1", "next", "connection_lost", "CONNECTION LOST // RETRY", true)
	_check(
		console._feedback.text == "CONNECTION LOST // RETRY"
		and console._feedback.get_theme_color("font_color") == MediaConsoleScript.TONE_COLORS["waiting"],
		"P5.08 retryable rejections render the typed waiting tone"
	)
	console.close()
	console.open()
	_check(
		console._feedback.text == "",
		"P5.08 reopening resets the feedback line for a fresh inspection"
	)

	# --- selection follows player handles across updates
	console.update_media(_snapshot(9, [music_player, paused_player, stopped_player], "player:music-1"))
	console.open()
	console._unhandled_input(_key_event(KEY_DOWN))
	_check(console.selected_index == 1, "P5.08 the second player can be selected")
	console.update_media(_snapshot(10, [music_player, stopped_player, paused_player], "player:music-1"))
	_check(
		console.selected_index == 2
		and String(console.players[console.selected_index].get("handle", "")) == "player:music-2",
		"P5.08 selection follows the player handle across snapshot reordering"
	)
	console.update_media(_snapshot(11, [music_player, stopped_player], "player:music-1"))
	_check(
		console.selected_index == 0
		and console._counter.text == "1/2",
		"P5.08 a vanished selection falls back to the active player"
	)

	# --- malformed console frames never replace last-good state
	console.update_media({"sequence": 12, "players": "not-an-array"})
	_check(
		console.players.size() == 2
		and String(console.players[0].get("handle", "")) == "player:music-1",
		"P5.08 malformed console frames never replace last-good state"
	)
	console.update_media(_snapshot(12, [
		{"handle": "", "identity": "X", "status": "playing"},
		stopped_player,
	], null))
	_check(
		console.players.size() == 1
		and String(console.players[0].get("handle", "")) == "player:music-3",
		"P5.08 entries without handles are dropped while valid frames replace state"
	)
	console.update_media(_snapshot(12, [stopped_player, stopped_player], null))
	_check(
		console.players.size() == 1,
		"P5.08 duplicate player handles are dropped defensively"
	)
	var oversized: Array = []
	for index in range(MediaConsoleScript.MAX_TRACKED_PLAYERS + 1):
		oversized.append(_player("player:flood-%d" % index, "Flood %d" % index))
	console.update_media(_snapshot(13, oversized, null))
	_check(
		console.players.size() == 1,
		"P5.08 oversized player lists never replace last-good console state"
	)

	# --- stale-but-labelled availability keeps last-good players
	console.set_availability("unavailable")
	_check(
		console._title.text.contains("NO SERVICE") and console.players.size() == 1,
		"P5.08 unavailability labels stale players instead of clearing them"
	)
	console.set_availability("available")
	_check(
		console._title.text.contains("PLAYERS") and console.players.size() == 1,
		"P5.08 restored availability keeps the tracked players"
	)

	# --- rapid snapshot bursts never reflow the layout
	console.update_media(_snapshot(20, [music_player, paused_player, stopped_player], "player:music-1"))
	console.open()
	await process_frame
	var panel_rect: Rect2 = console._panel.get_rect()
	var row_height: float = console._rows[0]["panel"].get_rect().size.y
	_check(
		panel_rect.position == Vector2(40, 24)
		and panel_rect.end.x <= 320.0
		and panel_rect.end.y <= 180.0,
		"P5.08 the fixed panel always fits the 320 x 180 canvas"
	)
	for burst in range(60):
		var flood: Array = []
		for index in range(burst % 18):
			flood.append(_player(
				"player:burst-%d-%d" % [burst, index],
				"Burst %d %s" % [index, "x".repeat(index * 8)],
				statuses[index % 3],
				"Title %d %s" % [index, "y".repeat(index * 8)],
				"Artist %d" % index
			))
		console.update_media(_snapshot(100 + burst, flood, null))
	await process_frame
	_check(
		console._panel.get_rect() == panel_rect,
		"P5.08 rapid snapshot bursts never reflow the panel geometry"
	)
	_check(
		console._rows_box.get_child_count() == MediaConsoleScript.MAX_VISIBLE_PLAYERS,
		"P5.08 the row structure stays fixed under bursts"
	)
	_check(
		console._rows[0]["panel"].get_rect().size.y == row_height,
		"P5.08 row heights stay fixed under bursts"
	)

	# --- maximum-length content is clipped, never overflowing
	var max_identity := "s".repeat(256)
	var max_title := "t".repeat(256)
	console.update_media(_snapshot(200, [
		_player("player:long-1", max_identity, "playing", max_title, "Velora", "", null, 0),
	], "player:long-1"))
	await process_frame
	var long_row: Dictionary = console._rows[0]
	_check(
		bool(long_row["summary"].clip_text) and int(long_row["summary"].text_overrun_behavior) == 3,
		"P5.08 long identities clip with word ellipsis"
	)
	_check(
		bool(long_row["detail"].clip_text) and int(long_row["detail"].text_overrun_behavior) == 3,
		"P5.08 long titles clip with word ellipsis"
	)
	_check(
		long_row["panel"].get_rect().size.y == row_height
		and console._panel.get_rect() == panel_rect,
		"P5.08 maximum-length entries never change the panel geometry"
	)

	# --- reduced motion: every state change is instant, never animated
	console.update_media(_snapshot(300, [music_player, paused_player], "player:music-1"))
	console.open()
	console._unhandled_input(_key_event(KEY_DOWN))
	_check(
		console._rows[1]["style"].bg_color == MediaConsoleScript.ROW_BG_SELECTED,
		"P5.08 selection applies in the same frame with no animated transition"
	)
	console._unhandled_input(_key_event(KEY_UP))
	_check(
		console._rows[0]["style"].bg_color == MediaConsoleScript.ROW_BG_SELECTED
		and console._rows[1]["style"].bg_color == MediaConsoleScript.ROW_BG,
		"P5.08 deselection is equally instant"
	)

	# --- closing
	var close_count := [0]
	console.console_closed.connect(func() -> void:
		close_count[0] += 1
	)
	console._unhandled_input(_key_event(KEY_ESCAPE))
	_check(
		not console.visible and close_count[0] == 1,
		"P5.08 Escape closes the console"
	)
	console.open()
	console._unhandled_input(_key_event(KEY_P))
	_check(
		not console.visible and close_count[0] == 2,
		"P5.08 P closes the console"
	)

	# --- the console never persists, shells out, or logs
	var console_source := FileAccess.get_file_as_string("res://ui/media_console.gd")
	for banned in [
		"FileAccess",
		"ConfigFile",
		"ResourceSaver",
		"user://",
		"store_",
		"save_",
		"Tween",
		"create_tween",
		"AnimationPlayer",
		"print(",
		"hyprctl",
		"OS." + "execute",
	]:
		_check(not console_source.contains(banned), "P5.08 the console never uses %s" % banned)
	var user_files_after := DirAccess.get_files_at(OS.get_user_data_dir())
	var user_dirs_after := DirAccess.get_directories_at(OS.get_user_data_dir())
	_check(
		user_files_before == user_files_after and user_dirs_before == user_dirs_after,
		"P5.08 a full console inspection cycle writes nothing to user data"
	)

	# --- nothing survives a restart
	var restarted: CanvasLayer = CanvasLayer.new()
	restarted.set_script(MediaConsoleScript)
	root.add_child(restarted)
	await process_frame
	_check(
		restarted.players.is_empty()
		and restarted.selected_index == -1
		and restarted._title.text.contains("WAITING"),
		"P5.08 a fresh console starts empty: nothing survives a restart"
	)
	restarted.queue_free()
	await process_frame

	console.queue_free()
	await process_frame
