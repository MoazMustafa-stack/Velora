extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	main.player.set_physics_process(false)
	main.hud.set_status("VELORA // POCKET TERMINAL")
	await _capture("hub")
	main.notification_feed.update_feed({"notifications": [
		{"handle": "fixture-1", "app_name": "Demo", "summary": "Build complete", "body": "Synthetic notification", "urgency": "normal", "timestamp_unix_ms": 1},
		{"handle": "fixture-2", "app_name": "Demo", "summary": "A very long synthetic message that must remain inside the panel", "body": "No live data is read by this fixture", "urgency": "critical", "timestamp_unix_ms": 2}
	]})
	main.notification_feed.set_availability("available")
	main.notification_feed.open()
	await _capture("notifications")
	main.notification_feed.close()
	main.media_console.set_availability("unavailable")
	main.media_console.open()
	await _capture("media-empty")
	main.media_console.update_media({"active_player_handle": "fixture-player", "players": [
		{"handle": "fixture-player", "identity": "Synthetic Player", "status": "playing", "title": "An intentionally long synthetic title to verify clipping in the console", "artist": "Demo Artist", "can_control": true, "can_play": true, "can_pause": true, "can_go_next": true, "can_go_previous": true}
	]})
	main.media_console.set_availability("available")
	await _capture("media-populated")
	main.media_console.set_availability("unavailable")
	await _capture("media-stale")
	main.media_console.close()
	main.workspace_map.update_session({"workspaces": [
		{"handle": "workspace-1", "index": 1, "name": "1", "window_count": 2, "is_active": true},
		{"handle": "workspace-2", "index": 2, "name": "2", "window_count": 0}
	]})
	main.workspace_map.open()
	await _capture("workspaces")
	var crowded: Array = []
	for index in range(20):
		crowded.append({"handle": "w-%d" % index, "index": index, "name": "Workspace with a long name", "monitor": "Synthetic monitor", "window_count": 99, "is_urgent": index == 2, "is_special": index == 3, "is_active": index == 0})
	main.workspace_map.update_session({"workspaces": crowded})
	await _capture("workspaces-full")
	if main.workspace_map._panel.position.y + main.workspace_map._panel.size.y > 180:
		push_error("Workspace panel exceeds canvas: " + str(main.workspace_map._panel.get_rect()))
		quit(1)
		return
	main.workspace_map.close()
	main._toggle_menu()
	await _capture("pause")
	main._toggle_menu()
	main.notification_feed.update_feed({"notifications": []})
	for state in ["waiting", "unavailable", "restricted", "available"]:
		main.notification_feed.set_availability(state)
		main.notification_feed.open()
		await _capture("notifications-" + state)
		main.notification_feed.close()
	main.queue_free()
	await process_frame
	quit()

func _capture(label: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var frame := root.get_texture().get_image()
	var output := OS.get_environment("VELORA_VISUAL_DIR")
	assert(not output.is_empty(), "Set VELORA_VISUAL_DIR to a private evidence directory")
	assert(frame.save_png(output.path_join(label + "-scaled.png")) == OK)
	frame.resize(320, 180, Image.INTERPOLATE_NEAREST)
	assert(frame.save_png(output.path_join(label + ".png")) == OK)
