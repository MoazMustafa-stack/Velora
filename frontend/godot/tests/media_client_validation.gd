extends SceneTree

# P5.07 media client validation: the BackendClient media surface over a fake
# bridge, covering the typed v5 fetch, normalization with bounds and types,
# strict sequence fencing, last-good reconnect retention, de-duplicated
# availability transitions, and typed control results. Scene and console
# coverage lives in media_validation.gd; this file keeps no scene or UI
# dependencies.

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
var last_ux_stage := ""
var last_ux_message := ""
var last_ux_tone := ""

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func _on_ux_status(stage: String, message: String, tone: String, _seconds: float) -> void:
	last_ux_stage = stage
	last_ux_message = message
	last_ux_tone = tone

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
	await _run_client()
	if failures.is_empty():
		print("P5.07 media client validation passed.")
		quit(0)
	else:
		push_error("P5.07 media client validation failed: %s" % [failures])
		quit(1)

func _run_client() -> void:
	# --- typed client media surface over the fake bridge ---
	var bridge := FakeBridge.new()
	var backend := BackendClient.new()
	backend.auto_connect = false
	backend.bridge_override = bridge
	backend.ux_status_changed.connect(_on_ux_status)
	var snapshot_emissions := [0]
	backend.media_snapshot_changed.connect(func(_snapshot: Dictionary) -> void:
		snapshot_emissions[0] += 1
	)
	var availability_emissions := [0]
	backend.media_availability_changed.connect(func(availability: String) -> void:
		availability_emissions[0] += 1
	)
	var control_accepts: Array = []
	var control_rejections: Array = []
	backend.media_control_accepted.connect(func(player_handle: String, verb: String) -> void:
		control_accepts.append([player_handle, verb])
	)
	backend.media_control_rejected.connect(
		func(player_handle: String, verb: String, code: String, _message: String, _retryable: bool) -> void:
			control_rejections.append([player_handle, verb, code])
	)
	root.add_child(backend)
	await process_frame

	backend.connect_to_core()
	bridge.socket_connected.emit()
	bridge.line_received.emit(JSON.stringify(_welcome()))
	var media_request := _last_request_of_type(bridge, "get_media_snapshot")
	_check(
		media_request.get("type") == "get_media_snapshot"
		and media_request.get("protocol_version") == 5,
		"P5.07 the client fetches the typed v5 media snapshot on connect"
	)

	# --- normalization: required fields stay typed, optional metadata flattens
	var normalized_player := _player("player:opaque-1")
	_emit_media(bridge, media_request.get("request_id"), _snapshot(7, [normalized_player], "player:opaque-1"))
	var stored := backend.media_snapshot
	_check(
		backend._media_request_id == 0
		and snapshot_emissions[0] == 1
		and backend.media_availability == "available"
		and availability_emissions[0] == 1,
		"P5.07 a served snapshot normalizes, stores, and signals exactly once"
	)
	_check(
		int(stored.get("sequence", 0)) == 7
		and String(stored.get("active_player_handle", "")) == "player:opaque-1",
		"P5.07 the snapshot carries its sequence and active player handle"
	)
	var stored_player: Dictionary = stored.get("players", [])[0]
	_check(
		String(stored_player.get("handle", "")) == "player:opaque-1"
		and String(stored_player.get("status", "")) == "playing"
		and bool(stored_player.get("can_seek", true)) == false
		and bool(stored_player.get("can_control", false)) == true,
		"P5.07 required player fields keep their validated types and flags"
	)
	_check(
		String(stored_player.get("album", "unset")) == ""
		and int(stored_player.get("length_micros", 0)) == -1
		and int(stored_player.get("position_micros", 0)) == 12500000,
		"P5.07 absent metadata flattens to empty and -1 sentinels"
	)

	# --- bounds and types: malformed payloads never replace last-good state
	var missing_flag := _player("player:opaque-3").duplicate(true)
	missing_flag.erase("can_seek")
	var missing_position := _player("player:opaque-11").duplicate(true)
	missing_position.erase("position_micros")
	var bad_identity := _player("player:opaque-7").duplicate(true)
	bad_identity["identity"] = 5
	var bad_length := _player("player:opaque-12", "Bad Length")
	bad_length["length_micros"] = "long"
	var too_many_players: Array = []
	for index in range(BackendClient.MAX_MEDIA_PLAYERS + 1):
		var bounded_player := _player("player:opaque-%d" % index)
		too_many_players.append(bounded_player)
	var malformed_snapshots := [
		_snapshot(8, [_player("player:opaque-2", "Bad Status", "buffering")], null),
		_snapshot(8, [missing_flag], null),
		_snapshot(8, [_player("player:opaque-4", "Long Title", "playing", "t".repeat(BackendClient.MAX_STRING_BYTES + 1))], null),
		_snapshot(8, [_player("")], null),
		_snapshot(8, [normalized_player, normalized_player], null),
		_snapshot(8, too_many_players, null),
		_snapshot(8, [_player("player:opaque-5")], "player:missing"),
		_snapshot(8, [_player("player:opaque-13")], 5),
		{"sequence": 8, "players": "not-an-array", "active_player_handle": null},
		{"sequence": "eight", "players": [normalized_player], "active_player_handle": null},
		_snapshot(-1, [normalized_player], null),
		_snapshot(8, [_player("player:opaque-6", "Negative Position", "playing", "T", "A", null, null, -5)], null),
		_snapshot(8, [_player("player:opaque-8", "Negative Length", "playing", "T", "A", null, -3)], null),
		_snapshot(8, [bad_identity], null),
		_snapshot(8, [bad_length], null),
		_snapshot(8, [missing_position], null),
	]
	for malformed_snapshot in malformed_snapshots:
		_emit_media(bridge, 0, malformed_snapshot)
	_emit_media(bridge, 0, "not-a-dictionary")
	_check(
		last_ux_stage == "media_failed" and last_ux_message == "INVALID MEDIA DATA",
		"P5.07 malformed media snapshots produce concise visible feedback"
	)
	_check(
		snapshot_emissions[0] == 1
		and int(backend.media_snapshot.get("sequence", 0)) == 7
		and backend.media_availability == "available"
		and availability_emissions[0] == 1,
		"P5.07 out-of-bounds or mistyped payloads never replace last-good media state"
	)

	# --- strict sequence fencing: single-flight requests and stale frames
	_check(backend.request_media_snapshot(), "P5.07 a fresh snapshot can be requested on demand")
	var pending_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	_check(
		not backend.request_media_snapshot(),
		"P5.07 snapshot requests stay single-flight while one is pending"
	)
	_emit_media(bridge, 888888, _snapshot(8, [_player("player:opaque-stale", "Stale Frame")], null))
	_check(
		snapshot_emissions[0] == 1
		and int(backend.media_snapshot.get("sequence", 0)) == 7
		and backend._media_request_id != 0,
		"P5.07 stale snapshot frames are fenced while a request is pending"
	)
	_emit_media(bridge, 0, _snapshot(8, [], null))
	_check(
		snapshot_emissions[0] == 2
		and int(backend.media_snapshot.get("sequence", 0)) == 8
		and backend._media_request_id != 0,
		"P5.07 a live Core push is accepted without cancelling a pending request"
	)
	_emit_media(bridge, pending_request.get("request_id"), _snapshot(8, [_player("player:opaque-equal", "Equal Seq")], null))
	_check(
		snapshot_emissions[0] == 2
		and int(backend.media_snapshot.get("sequence", 0)) == 8
		and backend._media_request_id == 0,
		"P5.07 an equal sequence clears the request without replacing state"
	)
	_emit_media(bridge, 0, _snapshot(6, [], null))
	_check(
		snapshot_emissions[0] == 2
		and int(backend.media_snapshot.get("sequence", 0)) == 8,
		"P5.07 older sequences are fenced out without emissions"
	)
	_emit_media(bridge, 0, _snapshot(8, [], null))
	_check(
		snapshot_emissions[0] == 2
		and backend.media_snapshot.get("players", []).is_empty()
		and String(backend.media_snapshot.get("active_player_handle", "")) == "",
		"P5.07 an empty player list is a valid frame, not an error"
	)
	_emit_media(bridge, 0, _snapshot(9, [
		normalized_player,
		_player("player:opaque-2", "Second Player", "paused"),
	], "player:opaque-2"))
	_check(
		snapshot_emissions[0] == 3
		and backend.media_snapshot.get("players", []).size() == 2
		and String(backend.media_snapshot.get("active_player_handle", "")) == "player:opaque-2",
		"P5.07 newer event-driven snapshots replace state without polling"
	)

	# --- availability transitions stay de-duplicated and request-scoped
	_check(backend.request_media_snapshot(), "P5.07 snapshot requests can be re-issued")
	var unavailable_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	_emit_media_rejected(bridge, 999999, "media_unavailable", false)
	_check(
		backend.media_availability == "available" and availability_emissions[0] == 1,
		"P5.07 uncorrelated rejections never mutate availability"
	)
	_emit_media_rejected(bridge, unavailable_request.get("request_id"), "media_unavailable", false)
	_check(
		backend.media_availability == "unavailable" and availability_emissions[0] == 2,
		"P5.07 a correlated media-unavailable rejection flips availability once"
	)
	_emit_media_rejected(bridge, unavailable_request.get("request_id"), "media_unavailable", false)
	_check(
		backend.media_availability == "unavailable" and availability_emissions[0] == 2,
		"P5.07 repeated media unavailability stays silent without log spam"
	)
	_check(backend.request_media_snapshot(), "P5.07 the snapshot can be requested while unavailable")
	var waiting_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	_emit_media_rejected(bridge, waiting_request.get("request_id"), "snapshot_not_ready", true)
	_check(
		backend.media_availability == "waiting" and availability_emissions[0] == 3,
		"P5.07 snapshot-not-ready maps to a typed waiting availability"
	)
	_check(
		snapshot_emissions[0] == 3
		and int(backend.media_snapshot.get("sequence", 0)) == 9,
		"P5.07 transient rejections never discard last-good media state"
	)
	_check(backend.request_media_snapshot(), "P5.07 the snapshot can be requested while waiting")
	var restore_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	_emit_media(bridge, restore_request.get("request_id"), _snapshot(10, [
		normalized_player,
		_player("player:opaque-2", "Second Player", "paused"),
	], "player:opaque-2"))
	_check(
		backend.media_availability == "available"
		and availability_emissions[0] == 4
		and snapshot_emissions[0] == 4,
		"P5.07 a served snapshot restores availability without extra emissions"
	)

	# --- reconnect retention and post-reconnect fencing
	_check(
		backend.send_media_control("player:opaque-2", "next"),
		"P5.07 a control can be pending across a disconnect"
	)
	bridge.socket_disconnected.emit("media retention test")
	_check(
		control_rejections.size() == 1
		and control_rejections[0][2] == "connection_lost",
		"P5.07 a disconnect fails pending controls as connection loss"
	)
	_check(
		int(backend.media_snapshot.get("sequence", 0)) == 10
		and not backend.media_snapshot.is_empty(),
		"P5.07 last-good media state survives the disconnect"
	)
	bridge.socket_connected.emit()
	bridge.line_received.emit(JSON.stringify(_welcome()))
	var refreshed_request := _last_request_of_type(bridge, "get_media_snapshot")
	_check(
		int(refreshed_request.get("request_id", 0)) > int(restore_request.get("request_id", 0)),
		"P5.07 reconnect re-requests the media snapshot without adding polling"
	)
	_emit_media(bridge, refreshed_request.get("request_id"), _snapshot(9, [], null))
	_check(
		snapshot_emissions[0] == 4
		and int(backend.media_snapshot.get("sequence", 0)) == 10,
		"P5.07 an older post-reconnect frame cannot regress retained state"
	)
	_emit_media(bridge, 0, _snapshot(11, [
		_player("player:opaque-9", "Fresh Player", "stopped"),
	], "player:opaque-9"))
	_check(
		snapshot_emissions[0] == 5
		and int(backend.media_snapshot.get("sequence", 0)) == 11,
		"P5.07 a newer post-reconnect snapshot refreshes the retained state"
	)

	# --- control handling: only the typed handle and verb boundary
	var sent_lines_before_control := bridge.sent_lines.size()
	_check(
		not backend.send_media_control("", "play"),
		"P5.07 empty player handles are rejected locally"
	)
	_check(
		not backend.send_media_control("player:opaque-9", "SetPosition"),
		"P5.07 raw MPRIS method names are rejected as verbs"
	)
	_check(
		not backend.send_media_control("player:opaque-9", "org.mpris.MediaPlayer2.Play"),
		"P5.07 raw D-Bus names are rejected as verbs or handles"
	)
	_check(
		bridge.sent_lines.size() == sent_lines_before_control
		and control_rejections.size() == 4,
		"P5.07 locally rejected controls never reach the wire"
	)
	_check(
		backend.send_media_control("player:opaque-9", "play_pause"),
		"P5.07 a ready client accepts an allowlisted control"
	)
	var control_request := _message_at(bridge, bridge.sent_lines.size() - 1)
	_check(
		control_request.get("type") == "send_media_control"
		and control_request.get("protocol_version") == 5
		and control_request.get("player_handle") == "player:opaque-9"
		and control_request.get("verb") == "play_pause"
		and control_request.keys().size() == 5,
		"P5.07 control requests carry only the typed handle and verb boundary"
	)
	_emit_control_accepted(bridge, 777777, "player:opaque-9")
	_check(
		backend._media_control_request_id != 0 and control_accepts.is_empty(),
		"P5.07 uncorrelated control acceptance is fenced out"
	)
	_check(
		not backend.send_media_control("player:opaque-9", "stop"),
		"P5.07 a second control is rejected while one is pending"
	)
	_emit_control_accepted(bridge, control_request.get("request_id"), "player:opaque-9")
	_check(
		control_accepts.size() == 1
		and control_accepts[0][0] == "player:opaque-9"
		and control_accepts[0][1] == "play_pause"
		and backend._media_control_request_id == 0,
		"P5.07 correlated acceptance clears pending state and echoes the verb"
	)
	_check(
		backend.send_media_control("player:opaque-9", "next"),
		"P5.07 another control can be requested"
	)
	var stale_control := _message_at(bridge, bridge.sent_lines.size() - 1)
	_emit_control_rejected(bridge, stale_control.get("request_id"), "player:opaque-9", "stale_handle")
	_check(
		control_rejections.size() == 6
		and control_rejections[5][2] == "stale_handle"
		and last_ux_message == "PLAYER STALE // REFRESH LIST",
		"P5.07 stale player handles fail with concise typed feedback"
	)
	_check(
		backend.send_media_control("player:opaque-9", "play"),
		"P5.07 a pending control can be left to time out"
	)
	backend._update_launch_timeout(BackendClient.MEDIA_CONTROL_TIMEOUT_SECONDS + 0.1)
	_check(
		backend._media_control_request_id == 0
		and control_rejections.size() == 7
		and control_rejections[6][2] == "media_control_timeout",
		"P5.07 pending controls time out with retryable typed feedback"
	)

	# --- typed control results drive availability transitions once
	_check(
		backend.send_media_control("player:opaque-9", "next"),
		"P5.07 a control result can report media unavailability"
	)
	var unavailable_control := _message_at(bridge, bridge.sent_lines.size() - 1)
	_emit_control_rejected(bridge, unavailable_control.get("request_id"), "player:opaque-9", "media_unavailable")
	_check(
		control_rejections.size() == 8
		and control_rejections[7][2] == "media_unavailable"
		and backend.media_availability == "unavailable"
		and availability_emissions[0] == 5,
		"P5.07 a media-unavailable control failure flips availability exactly once"
	)
	_emit_control_rejected(bridge, unavailable_control.get("request_id"), "player:opaque-9", "media_unavailable")
	_check(
		control_rejections.size() == 8
		and backend.media_availability == "unavailable"
		and availability_emissions[0] == 5,
		"P5.07 repeated control-driven unavailability stays silent"
	)
	_check(
		last_ux_stage == "media_control_failed"
		and last_ux_message == "MEDIA PLAYBACK UNAVAILABLE"
		and last_ux_tone == "failure",
		"P5.07 control unavailability surfaces concise typed feedback"
	)

	backend.queue_free()
	await process_frame
