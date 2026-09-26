extends SceneTree

const NotificationFeedScript = preload("res://ui/notification_feed.gd")

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func _entry(
	handle: String,
	summary: String,
	body: String,
	urgency: String,
	timestamp: int,
	app_name := "Velora"
) -> Dictionary:
	return {
		"handle": handle,
		"app_name": app_name,
		"summary": summary,
		"body": body,
		"urgency": urgency,
		"timestamp_unix_ms": timestamp,
	}

func _feed(notifications: Array, sequence: int) -> Dictionary:
	return {"sequence": sequence, "notifications": notifications}

func _key_event(keycode: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event

func _run() -> void:
	# --- main-scene wiring: typed client signals reach the panel ---
	# The client stays offline so the wiring check is deterministic and
	# never touches a live session bus or socket.
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	var main: Node = main_scene.instantiate()
	var scene_backend: BackendClient = main.get_node("BackendClient")
	scene_backend.auto_connect = false
	root.add_child(main)
	await process_frame
	var scene_feed: CanvasLayer = main.get_node("NotificationFeed")
	scene_backend.notification_feed_changed.emit(_feed([
		_entry("notification:wired-1", "Wired summary", "Wired body", "critical", 500),
		_entry("notification:wired-2", "Wired second", "", "low", 600),
	], 10))
	scene_backend.notifications_availability_changed.emit("available")
	_check(
		scene_feed.entries.size() == 2 and scene_feed._title.text.contains("FEED"),
		"P5.10 main-scene wiring routes typed client signals into the panel"
	)
	main._toggle_notification_feed()
	_check(
		main.feed_open and scene_feed.visible and not main.player.input_enabled,
		"P5.10 opening the feed locks world input"
	)
	scene_feed._unhandled_input(_key_event(KEY_ESCAPE))
	_check(
		not main.feed_open and not scene_feed.visible and main.player.input_enabled,
		"P5.10 closing the feed restores world input"
	)
	main.queue_free()
	await process_frame

	var user_files_before := DirAccess.get_files_at(OS.get_user_data_dir())
	var user_dirs_before := DirAccess.get_directories_at(OS.get_user_data_dir())

	var panel: CanvasLayer = CanvasLayer.new()
	panel.set_script(NotificationFeedScript)
	root.add_child(panel)
	await process_frame

	# --- conservative start state ---
	_check(not panel.visible, "P5.10 the feed panel starts hidden")
	_check(panel._title.text.contains("WAITING"), "P5.10 the feed panel starts in a typed waiting state")
	_check(panel._counter.text == "0/0", "P5.10 the position counter starts at zero")

	# --- explicit availability states ---
	panel.set_availability("unavailable")
	_check(panel._title.text.contains("NO FEED"), "P5.10 a missing feed is labelled explicitly")
	panel.set_availability("restricted")
	_check(panel._title.text.contains("RESTRICTED"), "P5.10 a monitor-restricted feed is labelled explicitly")
	panel.set_availability("available")
	_check(
		panel._title.text.contains("FEED") and not panel._title.text.contains("NO FEED"),
		"P5.10 an available feed is labelled explicitly"
	)
	panel.set_availability("unknown")
	_check(panel._title.text.contains("WAITING"), "P5.10 unknown availability falls back to waiting")

	# --- empty feeds are explicit, never guessed ---
	panel.update_feed(_feed([], 1))
	_check(
		String(panel._rows[0]["summary"].text) == "NO NOTIFICATIONS",
		"P5.10 an empty feed states it explicitly rather than guessing"
	)
	_check(
		panel.selected_index == -1 and panel.scroll_offset == 0,
		"P5.10 an empty feed has no selection"
	)

	# --- entries are ordered newest first ---
	panel.update_feed(_feed([
		_entry("notification:old", "Old summary", "Old body", "normal", 1000),
		_entry("notification:urgent", "Disk space low", "Root partition 95% full", "critical", 3000, "Backup Tool"),
		_entry("notification:quiet", "Quiet summary", "", "low", 2000),
	], 2))
	_check(panel.entries.size() == 3, "P5.10 feed entries are tracked")
	_check(
		String(panel.entries[0].get("handle")) == "notification:urgent"
		and String(panel.entries[1].get("handle")) == "notification:quiet"
		and String(panel.entries[2].get("handle")) == "notification:old",
		"P5.10 entries render newest first"
	)

	# --- urgency cues that never rely on color alone ---
	panel.open()
	_check(
		panel.visible and panel.selected_index == 0,
		"P5.10 open() reveals the feed with the newest entry selected"
	)
	_check(
		String(panel._rows[0]["summary"].text).begins_with(">!! "),
		"P5.10 critical entries carry a cursor plus double-bang marker"
	)
	_check(
		String(panel._rows[0]["detail"].text).begins_with("CRIT // BACKUP TOOL // Root partition 95% full"),
		"P5.10 critical entries spell the urgency level and app name"
	)
	panel._unhandled_input(_key_event(KEY_DOWN))
	panel._unhandled_input(_key_event(KEY_DOWN))
	_check(
		String(panel._rows[0]["summary"].text).begins_with(" !! "),
		"P5.10 unselected critical entries keep the marker column"
	)
	_check(
		String(panel._rows[1]["summary"].text).begins_with(" . "),
		"P5.10 low entries carry the dot marker"
	)
	_check(
		String(panel._rows[1]["detail"].text).begins_with("LOW // VELORA"),
		"P5.10 low entries spell the urgency level and omit empty bodies"
	)
	_check(
		String(panel._rows[2]["summary"].text).begins_with(">! "),
		"P5.10 normal entries carry a single-bang marker under the cursor"
	)
	_check(
		String(panel._rows[2]["detail"].text).begins_with("NORM // VELORA // Old body"),
		"P5.10 normal entries spell the urgency level"
	)
	_check(
		panel._counter.text == "3/3",
		"P5.10 the counter reports the selected position and total"
	)

	# --- keyboard-only scrolling across a longer feed ---
	var scroll_feed: Array = []
	for index in range(12):
		scroll_feed.append(_entry(
			"notification:scroll-%d" % index,
			"Entry %d" % index,
			"Body %d" % index,
			"normal",
			2000 - index * 10
		))
	panel.update_feed(_feed(scroll_feed, 3))
	panel.open()
	_check(
		panel.selected_index == 0 and panel._counter.text == "1/12",
		"P5.10 reopening resets to the newest entry"
	)
	panel._unhandled_input(_key_event(KEY_DOWN))
	_check(
		panel.selected_index == 1 and panel.scroll_offset == 0,
		"P5.10 arrow keys scroll within the visible window"
	)
	for _step in range(4):
		panel._unhandled_input(_key_event(KEY_DOWN))
	_check(
		panel.selected_index == 5 and panel.scroll_offset == 2,
		"P5.10 the visible window follows the selection downward"
	)
	_check(
		String(panel._rows[0]["summary"].text).begins_with(" ! Entry 2"),
		"P5.10 the top row shows the scrolled window start"
	)
	_check(
		String(panel._rows[3]["summary"].text).begins_with(">! Entry 5"),
		"P5.10 the selected row shows the cursor"
	)
	panel._unhandled_input(_key_event(KEY_UP))
	_check(panel.selected_index == 4, "P5.10 arrow keys scroll back up")
	panel._unhandled_input(_key_event(KEY_END))
	_check(
		panel.selected_index == 11 and panel.scroll_offset == 8,
		"P5.10 End jumps to the oldest entry"
	)
	panel._unhandled_input(_key_event(KEY_DOWN))
	_check(panel.selected_index == 0, "P5.10 scrolling wraps forward past the end")
	panel._unhandled_input(_key_event(KEY_UP))
	_check(panel.selected_index == 11, "P5.10 scrolling wraps backward past the start")
	panel._unhandled_input(_key_event(KEY_HOME))
	_check(
		panel.selected_index == 0 and panel.scroll_offset == 0,
		"P5.10 Home jumps to the newest entry"
	)
	panel._unhandled_input(_key_event(KEY_PAGEDOWN))
	_check(panel.selected_index == 4, "P5.10 Page Down scrolls a full window")
	panel._unhandled_input(_key_event(KEY_PAGEUP))
	_check(panel.selected_index == 0, "P5.10 Page Up scrolls a full window back")
	panel._unhandled_input(_key_event(KEY_S))
	_check(panel.selected_index == 1, "P5.10 W and S mirror the arrow keys")

	# --- closing ---
	var close_count := [0]
	panel.feed_closed.connect(func() -> void:
		close_count[0] += 1
	)
	panel._unhandled_input(_key_event(KEY_ESCAPE))
	_check(
		not panel.visible and close_count[0] == 1,
		"P5.10 Escape closes the feed"
	)
	panel.open()
	panel._unhandled_input(_key_event(KEY_N))
	_check(
		not panel.visible and close_count[0] == 2,
		"P5.10 N closes the feed"
	)

	# --- spam never reflows the layout ---
	panel.update_feed(_feed(scroll_feed, 4))
	panel.open()
	await process_frame
	var panel_rect: Rect2 = panel._panel.get_rect()
	var row_height: float = panel._rows[0]["panel"].get_rect().size.y
	_check(
		panel_rect.position == Vector2(40, 24)
		and panel_rect.end.x <= 320.0
		and panel_rect.end.y <= 180.0,
		"P5.10 the fixed panel always fits the 320 x 180 canvas"
	)
	for burst in range(60):
		var count := burst % 33
		var flood: Array = []
		for index in range(count):
			flood.append(_entry(
				"notification:flood-%d-%d" % [burst, index],
				"Summary %d %s" % [index, "x".repeat(index * 8)],
				"Body %d %s" % [index, "y".repeat(index * 8)],
				["low", "normal", "critical"][index % 3],
				index * 10
			))
		panel.update_feed(_feed(flood, 100 + burst))
	await process_frame
	_check(
		panel._panel.get_rect() == panel_rect,
		"P5.10 rapid feed bursts never reflow the panel geometry"
	)
	_check(
		panel._rows_box.get_child_count() == NotificationFeedScript.MAX_VISIBLE_ENTRIES,
		"P5.10 the row structure stays fixed under spam"
	)
	_check(
		panel._rows[0]["panel"].get_rect().size.y == row_height,
		"P5.10 row heights stay fixed under spam"
	)

	# --- maximum-length content is clipped, never overflowing ---
	var max_summary := "s".repeat(256)
	var max_body := "b".repeat(256)
	panel.update_feed(_feed([
		_entry("notification:long", max_summary, max_body, "critical", 9000),
	], 200))
	await process_frame
	var long_row: Dictionary = panel._rows[0]
	_check(
		bool(long_row["summary"].clip_text) and int(long_row["summary"].text_overrun_behavior) == 3,
		"P5.10 long summaries clip with word ellipsis"
	)
	_check(
		bool(long_row["detail"].clip_text) and int(long_row["detail"].text_overrun_behavior) == 3,
		"P5.10 long bodies clip with word ellipsis"
	)
	_check(
		long_row["panel"].get_rect().size.y == row_height,
		"P5.10 maximum-length entries never grow a row"
	)
	_check(
		panel._panel.get_rect() == panel_rect,
		"P5.10 maximum-length entries never change the panel geometry"
	)
	var all_clipped := true
	for row in panel._rows:
		all_clipped = all_clipped and bool(row["summary"].clip_text) and bool(row["detail"].clip_text)
	_check(all_clipped, "P5.10 every feed label clips by construction")

	# --- selection follows entries across updates ---
	panel.update_feed(_feed([
		_entry("notification:older", "Older entry", "Older body", "normal", 100),
		_entry("notification:newer", "Newer entry", "", "low", 200),
	], 300))
	panel.open()
	panel._unhandled_input(_key_event(KEY_DOWN))
	_check(panel.selected_index == 1, "P5.10 the second newest entry can be selected")
	panel.update_feed(_feed([
		_entry("notification:latest", "Latest entry", "", "critical", 300),
		_entry("notification:newer", "Newer entry updated", "", "low", 201),
		_entry("notification:older", "Older entry", "Older body", "normal", 100),
	], 301))
	_check(
		panel.selected_index == 2
		and String(panel.entries[panel.selected_index].get("handle")) == "notification:older",
		"P5.10 selection follows the entry handle across feed updates"
	)
	panel.update_feed(_feed([
		_entry("notification:fresh", "Fresh entry", "", "normal", 400),
	], 302))
	_check(
		panel.selected_index == 0 and panel._counter.text == "1/1",
		"P5.10 a vanished selection clamps to a valid entry"
	)

	# --- stale-but-labelled and malformed feeds ---
	panel.set_availability("restricted")
	_check(
		panel._title.text.contains("RESTRICTED") and panel.entries.size() == 1,
		"P5.10 restricted monitoring keeps last-good entries labelled as stale"
	)
	panel.update_feed({"sequence": 500, "notifications": "not-an-array"})
	_check(panel.entries.size() == 1, "P5.10 malformed feeds never replace last-good state")
	panel.update_feed(_feed([
		{"handle": "", "app_name": "X", "summary": "Y", "body": "", "urgency": "low", "timestamp_unix_ms": 1},
		_entry("notification:valid", "Valid entry", "", "low", 900),
	], 501))
	_check(
		panel.entries.size() == 1 and String(panel.entries[0].get("handle")) == "notification:valid",
		"P5.10 entries without handles are dropped while valid frames replace state"
	)
	panel.set_availability("unavailable")
	_check(
		panel._title.text.contains("NO FEED") and panel.entries.size() == 1,
		"P5.10 unavailability labels stale entries instead of clearing them"
	)

	# --- reduced motion: every state change is instant, never animated ---
	panel.set_availability("available")
	panel.update_feed(_feed([
		_entry("notification:motion-a", "Motion A", "", "normal", 600),
		_entry("notification:motion-b", "Motion B", "", "normal", 700),
	], 600))
	panel.open()
	panel._unhandled_input(_key_event(KEY_DOWN))
	_check(
		panel._rows[1]["style"].bg_color == NotificationFeedScript.ROW_BG_SELECTED,
		"P5.10 selection applies in the same frame with no animated transition"
	)
	panel._unhandled_input(_key_event(KEY_UP))
	_check(
		panel._rows[0]["style"].bg_color == NotificationFeedScript.ROW_BG_SELECTED
		and panel._rows[1]["style"].bg_color == NotificationFeedScript.ROW_BG,
		"P5.10 deselection is equally instant"
	)

	# --- nothing persists across restarts ---
	var panel_source := FileAccess.get_file_as_string("res://ui/notification_feed.gd")
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
	]:
		_check(not panel_source.contains(banned), "P5.10 the panel never uses %s" % banned)
	var user_files_after := DirAccess.get_files_at(OS.get_user_data_dir())
	var user_dirs_after := DirAccess.get_directories_at(OS.get_user_data_dir())
	_check(
		user_files_before == user_files_after and user_dirs_before == user_dirs_after,
		"P5.10 a full inspection cycle writes nothing to user data"
	)
	var restarted: CanvasLayer = CanvasLayer.new()
	restarted.set_script(NotificationFeedScript)
	root.add_child(restarted)
	await process_frame
	_check(
		restarted.entries.is_empty()
		and restarted.selected_index == -1
		and restarted._title.text.contains("WAITING"),
		"P5.10 a fresh instance starts empty: nothing survives a restart"
	)
	restarted.queue_free()
	await process_frame

	panel.queue_free()
	await process_frame
	if failures.is_empty():
		print("P5.10 notification feed validation passed.")
		quit(0)
	else:
		push_error("P5.10 notification feed validation failed: %s" % [failures])
		quit(1)
