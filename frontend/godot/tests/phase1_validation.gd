extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func _physics_frames(count: int) -> void:
	for _frame in range(count):
		await physics_frame

func _move_player(player: CharacterBody3D, position: Vector3, action: StringName) -> void:
	player.rotation = Vector3.ZERO
	player.global_position = position
	player.velocity = Vector3.ZERO
	await _physics_frames(2)
	Input.action_press(action)
	await _physics_frames(30)
	Input.action_release(action)

func _run() -> void:
	var scene := load("res://scenes/main.tscn") as PackedScene
	_check(scene != null, "main scene resource loads")
	if scene == null:
		quit(1)
		return

	var main := scene.instantiate()
	root.add_child(main)
	await process_frame
	await _physics_frames(5)

	var player := main.get_node_or_null("Player") as CharacterBody3D
	var camera := main.get_node_or_null("Player/Camera3D") as Camera3D
	var ray := main.get_node_or_null("Player/Camera3D/InteractRay") as RayCast3D
	var terminal := main.get_node_or_null("VSCodeTerminal") as StaticBody3D
	var player_collision := main.get_node_or_null("Player/Collision") as CollisionShape3D

	_check(player != null, "main scene contains a CharacterBody3D player")
	_check(camera != null and camera.current, "player camera is active")
	_check(ray != null and ray.enabled, "interaction ray is enabled")
	_check(terminal != null, "main scene contains the VS Code terminal")
	_check(player_collision != null and player_collision.shape is CapsuleShape3D, "player uses a capsule collider")
	_check(get_nodes_in_group("room_boundary").size() == 4, "hub has four physical boundaries")

	for action in ["move_forward", "move_back", "move_left", "move_right", "sprint", "interact", "release_mouse"]:
		_check(InputMap.has_action(action), "InputMap contains %s" % action)

	if player == null or camera == null:
		quit(1)
		return

	var settled_y := player.global_position.y
	await _physics_frames(10)
	_check(player.global_position.y > 0.9 and absf(player.global_position.y - settled_y) < 0.05, "gravity settles the player on the floor")

	player.global_position = Vector3(4, 1, 7)
	player.rotation = Vector3.ZERO
	player.velocity = Vector3.ZERO
	await _physics_frames(2)
	var walk_start := player.global_position.z
	Input.action_press("move_forward")
	await _physics_frames(10)
	Input.action_release("move_forward")
	var walk_distance := walk_start - player.global_position.z
	_check(walk_distance > 0.2, "W moves the player forward")

	player.global_position = Vector3(4, 1, 7)
	player.velocity = Vector3.ZERO
	await _physics_frames(2)
	var sprint_start := player.global_position.z
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await _physics_frames(10)
	Input.action_release("sprint")
	Input.action_release("move_forward")
	var sprint_distance := sprint_start - player.global_position.z
	_check(sprint_distance > walk_distance * 1.4, "Shift sprint is faster than walking")

	var starting_yaw := player.rotation.y
	var starting_pitch := camera.rotation.x
	var mouse_motion := InputEventMouseMotion.new()
	mouse_motion.relative = Vector2(24, -12)
	player._unhandled_input(mouse_motion)
	_check(player.rotation.y < starting_yaw, "horizontal mouse motion changes yaw")
	_check(camera.rotation.x > starting_pitch, "vertical mouse motion changes pitch")

	var escape := InputEventAction.new()
	escape.action = "release_mouse"
	escape.pressed = true
	player._unhandled_input(escape)
	_check(not player.mouse_captured, "Escape releases the mouse")
	player._unhandled_input(escape)
	_check(player.mouse_captured, "Escape recaptures the mouse")

	await _move_player(player, Vector3(11.2, 1, 5), "move_right")
	_check(player.global_position.x <= 11.38, "east wall prevents leaving the hub")

	await _move_player(player, Vector3(-11.2, 1, 5), "move_left")
	_check(player.global_position.x >= -11.38, "west wall prevents leaving the hub")

	await _move_player(player, Vector3(5, 1, -11.2), "move_forward")
	_check(player.global_position.z >= -11.38, "north wall prevents leaving the hub")

	await _move_player(player, Vector3(5, 1, 11.2), "move_back")
	_check(player.global_position.z <= 11.38, "south wall prevents leaving the hub")

	await _move_player(player, Vector3(0, 1, 0), "move_forward")
	_check(player.global_position.z > -0.8, "terminal collision prevents walking through it")

	main.queue_free()
	await process_frame
	if failures.is_empty():
		print("Phase 1 scene, controller, and collision validation passed.")
		quit(0)
	else:
		push_error("Phase 1 validation failed with %d issue(s)." % failures.size())
		quit(1)
