extends SceneTree
const Composition = preload("res://tests/workshop_composition.gd")
var failed := false

func check(value: bool, message: String) -> void:
	if not value: failed = true; push_error(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	for size in Composition.NATIVE_SIZES:
		var boxes := Composition.regions(size)
		var bounds := Rect2(Vector2.ZERO, Vector2(size))
		for rect in boxes.values(): check(bounds.encloses(rect), "Composition stays in native bounds")
		check(not boxes.world.intersects(boxes.inspector), "Inspector never overlays the world")
		check(not boxes.header.intersects(boxes.world), "Header never overlays the world")
		check(boxes.world.size.y > size.y * 0.7, "World retains over 70% of the canvas height")
		for output in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
			check(output.x % size.x == 0 and output.y % size.y == 0, "720p and 1080p use integer scaling")
		var fixture := Composition.new(size)
		root.add_child(fixture)
		await physics_frame
		await process_frame
		check(fixture.world.size == Vector2i(320, 128), "Both densities preserve identical world viewport/FOV")
		check(fixture.main.get_node("World").scale == Vector2.ONE, "World physics root is not scaled")
		check(fixture.main.player.walk_speed == 48.0 and fixture.main.player.sprint_speed == 72.0, "Movement speeds stay unchanged")
		check(not fixture.main.backend.auto_connect and not fixture.main.backend.is_processing(), "No transport or reconnect timers")
		check(not fixture.main.load_preferences and not fixture.main.ui_audio.enabled, "No preference IO or audio")
		check(not fixture.main.player.is_processing_unhandled_input(), "Fixture cannot launch via real keyboard input")
		for sample in ["ready", "long-text", "offline", "waiting", "empty", "paused"]:
			fixture.set_sample(sample)
			await process_frame
			check(fixture.modal.visible == (sample == "paused"), "Modal sample is explicit")
			check_labels(fixture.ui)
		check(fixture.main.backend.last_requested_desktop_id.is_empty(), "Synthetic states never send a launch")
		fixture.queue_free()
		await process_frame
	if not failed: print("R6.01 isolated composition geometry and safety validation passed")
	quit(1 if failed else 0)

func check_labels(parent: Node) -> void:
	for child in parent.get_children():
		if child is Label:
			check(child.clip_text and Rect2(Vector2.ZERO, child.get_parent().size).encloses(child.get_rect()), "Clipped label fits its panel: " + child.text.left(24) + " rect=" + str(child.get_rect()) + " parent=" + str(child.get_parent().size))
		check_labels(child)
