extends SceneTree
const Overlay = preload("res://ui/overlay_coordinator.gd")
var failed := false

func check(value: bool, message: String) -> void:
	if not value: failed = true; push_error(message)

func _initialize() -> void:
	call_deferred("run")

func drive(player: CharacterBody2D, destination: Vector2) -> void:
	# Actual physics/input movement, not teleporting to each object.
	for axis in [1, 0]:
		var ticks := 0
		while absf(player.position[axis] - destination[axis]) > 1.0 and ticks < 200:
			var positive := destination[axis] > player.position[axis]
			var action := ("move_down" if positive else "move_up") if axis == 1 else ("move_right" if positive else "move_left")
			Input.action_press(action)
			await physics_frame
			Input.action_release(action)
			ticks += 1
		check(ticks < 200, "Keyboard lane is unobstructed: " + str(destination))

func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await physics_frame
	await physics_frame
	var targets: Array[Node] = []
	targets.assign(get_nodes_in_group("application_stations") + get_nodes_in_group("hub_objects"))
	check(targets.size() == 7, "Three application stations and four capability objects exist")
	var rectangles: Array[Rect2] = []
	for target in targets:
		var collision: CollisionShape2D = target.get_node("CollisionShape2D")
		var rect := Rect2(collision.global_position - collision.shape.size / 2, collision.shape.size)
		for other in rectangles: check(not rect.intersects(other), "Physical object collision bounds do not overlap")
		rectangles.append(rect)
	for target in targets:
		await drive(main.player, Vector2(160, 136))
		if "desktop_id" in target:
			await drive(main.player, Vector2(160, 82))
			await drive(main.player, Vector2(target.position.x, 82))
		else:
			await drive(main.player, Vector2(target.position.x, 136))
		main.player.facing = Vector2.UP
		main.player._update_detector_position()
		await physics_frame
		await physics_frame
		main.player.refresh_interaction()
		check(main.player.active_interactable == target, "Facing selects exact reachable object: " + target.name)
		main.player.refresh_interaction()
		check(main.player.active_interactable == target, "Target selection is stable")
		if not "desktop_id" in target:
			main._on_interaction_requested(target)
			check(main.overlays.current != Overlay.Mode.NONE and not main.player.input_enabled, "Object opens a functional modal: " + target.name)
			check(main.backend.last_requested_desktop_id.is_empty(), "Capability object never requests an application launch")
			main.overlays.back()
		# Return along the upper/bottom lane, not vertically through an object.
		await drive(main.player, Vector2(160, main.player.position.y))
	main.overlays.open(Overlay.Mode.OBSERVATORY)
	main.backend.telemetry_snapshot_changed.emit({"cpu": {"utilization_basis_points": 1234}, "memory": {"used_bytes": 1048576, "total_bytes": 2097152}})
	check(main.observatory._rows[0].summary.text.contains("12.3%"), "Observatory displays real normalized snapshot fields while paused")
	main.overlays.back()
	main.queue_free()
	await process_frame
	if not failed: print("D6.05 keyboard reachability and world layout validation passed")
	quit(1 if failed else 0)
