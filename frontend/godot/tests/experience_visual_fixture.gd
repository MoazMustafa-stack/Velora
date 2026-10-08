extends SceneTree
## Synthetic viewport-only captures: no desktop, production settings or IPC.
const Overlay = preload("res://ui/overlay_coordinator.gd")
const Layout = preload("res://ui/hud_layout.gd")
const Actions = preload("res://scripts/input_actions.gd")
var failed := false
var output := ""
var hud: CanvasLayer

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func run() -> void:
	output = OS.get_environment("VELORA_VISUAL_DIR")
	if output.is_empty() or DisplayServer.get_name() == "headless":
		push_error("Set VELORA_VISUAL_DIR and run with a real display")
		quit(1)
		return
	var main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	# Fake READY state must never run heartbeat/reconnect timers on a real bridge.
	main.backend.set_process(false)
	hud = main.hud
	main.ui_audio.enabled = false
	main.player.set_physics_process(false)
	main.backend.state = BackendClient.ConnectionState.READY
	main._on_core_state_changed(main.backend.state)
	main.hud.set_connection_status("CONNECTED", "ready")
	main.hud.set_status("A VERY LONG SYNTHETIC APPLICATION NAME ".repeat(8))
	main.hud.set_interaction_prompt("[E] USE // SYNTHETIC LONG APPLICATION NAME ".repeat(8))
	await capture("hud-prompt")
	main.hud.show_transient("LAUNCH FAILED // SYNTHETIC FAILURE ".repeat(8), "failure", 1.0)
	await capture("hud-failure")
	main.hud._process(2.0)
	main.hud.set_interaction_prompt("")
	await capture("hud-telemetry")
	var notes: Array = []
	for index in range(32):
		notes.append({"handle": "n-%d" % index, "app_name": "Synthetic App", "summary": "Long synthetic message ".repeat(8), "body": "Synthetic body ".repeat(8), "urgency": "critical" if index % 2 == 0 else "normal", "timestamp_unix_ms": index})
	main.notification_feed.set_availability("available")
	main.notification_feed.update_feed({"notifications": notes})
	main.overlays.open(Overlay.Mode.NOTIFICATIONS)
	await capture("notifications-full", main.notification_feed._panel)
	main.notification_feed.set_core_online(false)
	await capture("notifications-stale", main.notification_feed._panel)
	main.notification_feed.set_core_online(true)
	main.notification_feed.set_policy_disabled(true)
	await capture("notifications-disabled", main.notification_feed._panel)
	main.notification_feed.set_policy_disabled(false)
	main.notification_feed.update_feed({"notifications": []})
	for state in ["available", "waiting", "unavailable", "restricted"]:
		main.notification_feed.set_availability(state)
		await capture("notifications-" + state, main.notification_feed._panel)
	var players: Array = []
	for index in range(16):
		players.append({"handle": "p-%d" % index, "identity": "Synthetic player ".repeat(8), "status": "playing", "title": "Synthetic title ".repeat(12), "artist": "Synthetic artist", "can_control": true, "can_play": true, "can_pause": true, "can_go_next": true, "can_go_previous": true})
	main.media_console.update_media({"players": players, "active_player_handle": "p-0"})
	main.media_console.set_availability("available")
	main.overlays.open(Overlay.Mode.MEDIA)
	await capture("media-full", main.media_console._panel)
	main.media_console.set_core_online(false)
	await capture("media-stale", main.media_console._panel)
	main.media_console.set_core_online(true)
	main.media_console.update_media({"players": []})
	await capture("media-empty", main.media_console._panel)
	var workspaces: Array = []
	for index in range(20):
		workspaces.append({"handle": "w-%d" % index, "index": index, "name": "Synthetic long workspace ".repeat(8), "monitor": "Synthetic monitor", "window_count": 99, "is_active": index == 0, "is_urgent": index <= 1, "is_special": index == 2})
	main.workspace_map.update_session({"workspaces": workspaces})
	main.overlays.open(Overlay.Mode.WORKSPACES)
	await capture("workspaces-full", main.workspace_map._panel)
	main.overlays.open(Overlay.Mode.PAUSE)
	for page in ["home", "help", "diagnostics", "settings", "accessibility", "audio", "controls", "reset", "stations", "station_choice"]:
		main.pause_panel.show_page(page)
		await capture("pause-" + page, main.pause_panel._shell.panel)
	main.pause_panel.show_page("controls")
	main.pause_panel.activate_selection()
	await capture("pause-remap-capture", main.pause_panel._shell.panel)
	main.pause_panel.cancel_capture()
	var apps: Array[Dictionary] = [{"id": "code.desktop", "name": "Fixture Editor"}, {"id": "firefox.desktop", "name": "Fixture Browser"}, {"id": "kitty.desktop", "name": "Fixture Terminal"}]
	for index in range(500): apps.append({"id": "fixture-%d.desktop" % index, "name": "Long synthetic registry application ".repeat(10)})
	main.backend.applications_changed.emit(apps)
	main.pause_panel.show_page("station_choice")
	main.pause_panel._cursor.select(main.pause_panel._items.size() - 1, main.pause_panel._items.size())
	main.pause_panel.refresh()
	await capture("station-chooser-500", main.pause_panel._shell.panel)
	main.pause_panel.show_page("stations")
	await capture("station-slots", main.pause_panel._shell.panel)
	Actions.controller_labels = true
	main._refresh_input_labels()
	for page in ["help", "controls", "settings", "station_choice"]:
		main.pause_panel.show_page(page)
		await capture("controller-" + page, main.pause_panel._shell.panel)
	Actions.controller_labels = false
	main._refresh_input_labels()
	main.overlays.open(Overlay.Mode.OBSERVATORY)
	main.observatory.set_availability("available")
	main.observatory.update_snapshot({"cpu": {"availability": "available", "utilization_basis_points": 5023}, "memory": {"availability": "available", "used_bytes": 1048576000, "total_bytes": 2097152000}, "disk": {"availability": "available", "read_bytes_per_second": 999999999999}, "network": {"availability": "available", "transmit_bytes_per_second": 999999999999}})
	await capture("observatory-full", main.observatory._shell.panel)
	main.observatory.set_core_online(false)
	await capture("observatory-stale", main.observatory._shell.panel)
	main.overlays.back()
	main.settings.set_reduced_motion(true)
	main._apply_preferences()
	await capture("hub-reduced-motion")
	main.queue_free()
	await process_frame
	if not failed: print("D6.06-D6.09 rendered layout validation passed: ", output)
	quit(1 if failed else 0)

func capture(label: String, panel: Control = null) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	for pair in [[hud.get_node("StatusPanel"), Layout.STATUS], [hud.get_node("ConnectionPanel"), Layout.CONNECTION], [hud.prompt_panel, Layout.FOOTER], [hud.help, Layout.HELP]]:
		check(pair[1].encloses(pair[0].get_rect()), "Actual HUD fits reserved bounds: " + label + " " + pair[0].name)
	if panel != null:
		check(Rect2(0, 0, 320, 180).encloses(panel.get_global_rect()), "Panel fits canvas: " + label + " " + str(panel.get_global_rect()))
		check_bounds(panel, panel.get_global_rect(), label)
	var frame := root.get_texture().get_image()
	check(frame.save_png(output.path_join(label + "-scaled.png")) == OK, "Save scaled frame")
	frame.resize(320, 180, Image.INTERPOLATE_NEAREST)
	check(frame.save_png(output.path_join(label + ".png")) == OK, "Save native frame")
	for y in range(frame.get_height()):
		for x in range(frame.get_width()):
			var pixel := frame.get_pixel(x, y)
			var luma := pixel.get_luminance()
			frame.set_pixel(x, y, Color(luma, luma, luma, pixel.a))
	check(frame.save_png(output.path_join(label + "-gray.png")) == OK, "Save grayscale frame")

func check_bounds(node: Node, bounds: Rect2, label: String) -> void:
	for child in node.get_children():
		if child is Label:
			check(child.clip_text and bounds.encloses(child.get_global_rect()), "Clipped label fits panel: " + label + " " + child.text)
		check_bounds(child, bounds, label)
