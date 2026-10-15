extends SceneTree
## Real rendered native viewports and physics; exports only synthetic content.
const Composition = preload("res://tests/workshop_composition.gd")
var fixture: Node
var output := ""
var problems: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value: problems.append(message); push_error(message)

func run() -> void:
	output = OS.get_environment("VELORA_WORKSHOP_REPORT_DIR")
	var width := int(OS.get_environment("VELORA_WORKSHOP_WIDTH"))
	if DisplayServer.get_name() == "headless" or output.is_empty() or width not in [320, 640]:
		push_error("Need real display, VELORA_WORKSHOP_REPORT_DIR and VELORA_WORKSHOP_WIDTH=320|640")
		quit(2)
		return
	fixture = Composition.new(Vector2i(width, width * 9 / 16))
	root.add_child(fixture)
	fixture.present(root)
	await physics_frame
	await physics_frame
	for sample in ["ready", "long-text", "offline", "waiting", "empty", "paused"]:
		fixture.set_sample(sample)
		await capture(sample)
	fixture.set_sample("ready")
	fixture.main.player.set_reduced_motion(true)
	await capture("reduced-motion")
	var targets := get_nodes_in_group("application_stations") + get_nodes_in_group("hub_objects")
	check(targets.size() == 7, "All seven original objects are present")
	for target in targets:
		print("R6.01 approach: ", target.name)
		await drive(Vector2(160, 136))
		if "desktop_id" in target:
			await drive(Vector2(160, 82))
			await drive(Vector2(target.position.x, 82))
		else:
			await drive(Vector2(target.position.x, 136))
		Input.action_press("move_up")
		await physics_frame
		await process_frame
		Input.action_release("move_up")
		await physics_frame
		await physics_frame
		fixture.main.player.refresh_interaction()
		check(fixture.main.player.active_interactable == target, "Physical approach selects " + target.name)
		await process_frame
		check_visible(target.get_node("Sprite2D"), target.name)
		check_visible(fixture.main.player.sprite, "player at " + target.name)
		await capture("approach-" + target.name.to_lower())
		await drive(Vector2(160, fixture.main.player.position.y))
	check(fixture.main.backend.last_requested_desktop_id.is_empty(), "No launches requested")
	var report := {"card": "R6.01", "passed": problems.is_empty(), "native_size": [width, width * 9 / 16],
		"world_viewport": [320, 128], "physics_root_scale": [1, 1], "objects_physically_reached": targets.size(),
		"exports": ["native", "native grayscale", "1280x720 integer export", "1920x1080 integer export"],
		"scope": "viewport-only mock inspector/layout; production input/selection/art not implemented", "problems": problems}
	var file := FileAccess.open(output.path_join("layout-%d.json" % width), FileAccess.WRITE)
	check(file != null, "Can save native layout report")
	if file != null: file.store_string(JSON.stringify(report, "\t") + "\n"); file.close()
	print("R6.01 rendered layout report: ", JSON.stringify(report))
	fixture.queue_free()
	await process_frame
	quit(0 if problems.is_empty() else 1)

func drive(destination: Vector2) -> void:
	var player: CharacterBody2D = fixture.main.player
	for axis in [1, 0]:
		var ticks := 0
		while absf(player.position[axis] - destination[axis]) > 1.0 and ticks < 200:
			var positive := destination[axis] > player.position[axis]
			var action := ("move_down" if positive else "move_up") if axis == 1 else ("move_right" if positive else "move_left")
			Input.action_press(action)
			await physics_frame
			Input.action_release(action)
			ticks += 1
		check(ticks < 200, "Approach lane clear: " + str(destination))
	# Always yield, including a zero-distance leg; callers await this coroutine.
	await physics_frame

func check_visible(sprite: Sprite2D, context: String) -> void:
	var rect := sprite.get_global_transform_with_canvas() * sprite.get_rect()
	check(Rect2(Vector2.ZERO, Vector2(Composition.WORLD_VIEW)).encloses(rect), "Full sprite visible at approach: " + context + " " + str(rect))

func capture(label: String) -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var frame: Image = fixture.canvas.get_texture().get_image()
	check(frame.get_size() == fixture.native_size, "Real native render target, not downsampled window")
	check(frame.save_png(output.path_join(label + ".png")) == OK, "Save native " + label)
	for size in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		var scaled := frame.duplicate() as Image
		scaled.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
		check(scaled.save_png(output.path_join("%s-%dx%d.png" % [label, size.x, size.y])) == OK, "Save integer export")
	for y in range(frame.get_height()):
		for x in range(frame.get_width()):
			var pixel := frame.get_pixel(x, y)
			var luma := pixel.get_luminance()
			frame.set_pixel(x, y, Color(luma, luma, luma, pixel.a))
	check(frame.save_png(output.path_join(label + "-gray.png")) == OK, "Save native grayscale")
