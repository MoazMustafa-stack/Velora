extends SceneTree
## Native production composition with synthetic snapshots only. No desktop or
## window capture, live transport, preferences, launch requests or private data.
const W = preload("res://ui/design_tokens.gd").Workshop
const Overlay = preload("res://ui/overlay_coordinator.gd")
var canvas: SubViewport
var main: Node
var output := ""
var problems: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: problems.append(message); push_error(message)
func run() -> void:
	output = OS.get_environment("VELORA_WORKSHOP_PRODUCTION_DIR")
	if output.is_empty() or DisplayServer.get_name() == "headless":
		push_error("Production workshop capture needs a real display and VELORA_WORKSHOP_PRODUCTION_DIR")
		quit(2)
		return
	canvas = SubViewport.new()
	canvas.size = W.CANVAS
	canvas.disable_3d = true
	canvas.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(canvas)
	main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	canvas.add_child(main)
	main.backend.set_process(false)
	main.ui_audio.enabled = false
	main.set_process_input(false)
	main.set_process_unhandled_input(false)
	main.player.set_process_unhandled_input(false)
	for panel in main.overlays._panels.values(): panel.set_process_unhandled_input(false)
	root.content_scale_size = W.CANVAS
	var preview := TextureRect.new()
	preview.texture = canvas.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(preview)
	await capture("offline-no-selection")
	main.backend.state = BackendClient.ConnectionState.READY
	main.backend.state_changed.emit(main.backend.state)
	main.backend.applications_changed.emit([])
	main.backend.ux_status_changed.emit("ready", "NO APPLICATIONS", "waiting", -1.0)
	await capture("first-empty-registry")
	var apps := [{"id": "code.desktop", "name": "Workshop Editor", "exec": "fixture-editor", "categories": ["Development"]},
		{"id": "firefox.desktop", "name": "Workshop Browser", "exec": "fixture-web", "categories": ["WebBrowser"]},
		{"id": "kitty.desktop", "name": "Workshop Terminal", "exec": "fixture-terminal", "categories": ["TerminalEmulator"]}]
	main.backend.applications.assign(apps)
	main.backend.applications_changed.emit(apps)
	main.backend.session_availability = "available"
	main.backend.session_snapshot = {"sequence": 1, "windows": [], "workspaces": []}
	main.backend.session_snapshot_changed.emit(main.backend.session_snapshot)
	main.backend.ux_status_changed.emit("ready", "WORKSHOP READY", "ready", -1.0)
	main.player.set_reduced_motion(true)
	var targets := get_nodes_in_group("application_stations") + get_nodes_in_group("hub_objects")
	check(targets.size() == 7, "Exactly three mapped applications and four capability objects")
	for target in targets:
		await drive(Vector2(160, 136))
		if target.is_in_group("application_stations"):
			await drive(Vector2(160, 82))
			await drive(Vector2(target.position.x, 82))
		else:
			await drive(Vector2(target.position.x, 136))
		Input.action_press("move_up")
		await physics_frame
		Input.action_release("move_up")
		await physics_frame
		await physics_frame
		main.player.refresh_interaction()
		check(main.player.active_interactable == target, "Physical keyboard approach: " + target.name)
		for sprite in [main.player.sprite, target.get_node("Sprite2D"), target.get_node("Footprint")]:
			var bounds: Rect2 = sprite.get_global_transform_with_canvas() * sprite.get_rect()
			check(Rect2(Vector2.ZERO, Vector2(W.WORLD_VIEW)).encloses(bounds), "Full player/object/plinth visible at " + target.name + " " + str(bounds))
		await capture("approach-" + target.name.to_lower())
		await drive(Vector2(160, main.player.position.y))
	await drive(Vector2(160, 82))
	main.player.facing = Vector2.UP
	main.player._update_detector_position()
	await physics_frame
	await physics_frame
	main.player.refresh_interaction()
	apps[0].name = "Éditeur 日本語 🦀 / a deliberately long application name ".repeat(8)
	main.backend.applications_changed.emit(apps)
	main.backend.launch_status_changed.emit("code.desktop", "launch_failed", "Synthetic recoverable failure — no real application was launched ".repeat(8), true)
	await capture("unicode-failure")
	main.overlays.open(Overlay.Mode.INSPECTOR)
	await capture("inspector-focused")
	for mode in main.overlays._panels:
		main.overlays.open(mode)
		await process_frame
		main.workshop.fit_panels()
		await capture("modal-" + str(mode))
		for child in main.overlays._panels[mode].get_children():
			if child is PanelContainer:
				var bounds: Rect2 = main.overlays._panels[mode].transform * child.get_rect()
				check(Rect2(W.WORLD).encloses(bounds), "Modal cannot obscure persistent inspector: " + str(bounds))
	main.overlays.open(Overlay.Mode.NONE)
	main.backend.state = BackendClient.ConnectionState.RECONNECTING
	main.backend.state_changed.emit(main.backend.state)
	main.backend.ux_status_changed.emit("reconnecting", "RECONNECTING", "waiting", -1.0)
	await capture("reconnecting")
	check(main.backend.last_requested_desktop_id.is_empty(), "No launch request during captures")
	var report := {"cards": "R6.03-R6.05", "passed": problems.is_empty(), "native_size": [640, 360],
		"world_viewport": [320, 128], "objects_physically_reached": targets.size(), "source": "synthetic only",
		"owner_world_input_review": "pending", "motion": "reduced-motion routes; separate behavior regression covers animation",
		"window_size": [root.size.x, root.size.y], "export_sizes": [[1280, 720], [1920, 1080]], "problems": problems}
	var file := FileAccess.open(output.path_join("production-layout.json"), FileAccess.WRITE)
	check(file != null, "Save production native evidence")
	if file != null: file.store_string(JSON.stringify(report, "\t") + "\n"); file.close()
	main.queue_free()
	preview.queue_free()
	canvas.queue_free()
	await process_frame
	print("R6.03-R6.05 native production report: ", JSON.stringify(report))
	quit(0 if problems.is_empty() else 1)
func drive(destination: Vector2) -> void:
	for axis in [1, 0]:
		var ticks := 0
		while absf(main.player.position[axis] - destination[axis]) > 1.0 and ticks < 200:
			var positive: bool = destination[axis] > main.player.position[axis]
			var action := ("move_down" if positive else "move_up") if axis == 1 else ("move_right" if positive else "move_left")
			Input.action_press(action)
			await physics_frame
			Input.action_release(action)
			ticks += 1
		check(ticks < 200, "Clear physical approach lane")
	await physics_frame
func capture(label: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	check(main.inspector.get_global_rect() == Rect2(W.INSPECTOR), "Persistent inspector stays in its reserved native region")
	for child in main.inspector.get_children():
		if child is Control: check(Rect2(Vector2.ZERO, Vector2(W.INSPECTOR.size)).encloses(child.get_rect()), "Inspector child remains bounded")
	var frame := canvas.get_texture().get_image()
	check(frame.get_size() == W.CANVAS, "True 640-native production render target")
	check(frame.save_png(output.path_join(label + ".png")) == OK, "Save native " + label)
	for size in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		var scaled := frame.duplicate() as Image
		scaled.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
		check(scaled.save_png(output.path_join("%s-%dx%d.png" % [label, size.x, size.y])) == OK, "Save integer export")
	for y in range(frame.get_height()):
		for x in range(frame.get_width()):
			var pixel := frame.get_pixel(x, y)
			var gray := pixel.get_luminance()
			frame.set_pixel(x, y, Color(gray, gray, gray, pixel.a))
	check(frame.save_png(output.path_join(label + "-gray.png")) == OK, "Save grayscale")
