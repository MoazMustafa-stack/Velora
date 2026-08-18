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

func _hold(action: StringName, frames: int) -> void:
	Input.action_press(action)
	await _physics_frames(frames)
	Input.action_release(action)
	await _physics_frames(2)

func _run() -> void:
	_check(ProjectSettings.get_setting("display/window/size/viewport_width") == 320, "P1.01 uses a 320 px internal width")
	_check(ProjectSettings.get_setting("display/window/size/viewport_height") == 180, "P1.01 uses a 180 px internal height")
	_check(ProjectSettings.get_setting("rendering/textures/canvas_textures/default_texture_filter") == 0, "P1.01 uses nearest-neighbour texture filtering")

	var packed := load("res://scenes/main.tscn") as PackedScene
	_check(packed != null, "P1.02 main scene loads")
	if packed == null:
		quit(1)
		return
	var main := packed.instantiate()
	root.add_child(main)
	await _physics_frames(3)

	var ground := main.get_node("World/Ground") as TileMapLayer
	var walls := main.get_node("World/Walls") as TileMapLayer
	var details := main.get_node("World/Details") as TileMapLayer
	var player := main.get_node("World/Player") as CharacterBody2D
	var workstation := main.get_node("World/Objects/Workstation") as StaticBody2D
	var detector := player.get_node("InteractionDetector") as Area2D
	var backend := main.get_node("BackendClient")
	var hud := main.get_node("HUD")

	_check(ground != null and not ground.get_used_cells().is_empty(), "P1.02 builds the hub ground with TileMapLayer")
	_check(walls != null and walls.get_used_cells().size() == 60, "P1.02 builds a closed 20 x 12 room boundary")
	_check(details != null and not details.get_used_cells().is_empty(), "P1.02 builds a readable navigation path")
	_check(ground.tile_set != null and ground.tile_set.tile_size == Vector2i(16, 16), "P1.02 uses a 16 px tile grammar")

	player.position = Vector2(80, 130)
	var start_y := player.position.y
	await _hold("move_up", 8)
	_check(player.position.y < start_y - 3.0, "P1.03 moves with keyboard input")
	_check(player.facing == Vector2.UP, "P1.03 tracks four-direction facing")

	player.position = Vector2(80, 130)
	await _hold("move_right", 10)
	var walked := player.position.x - 80.0
	player.position = Vector2(80, 130)
	Input.action_press("sprint")
	await _hold("move_right", 10)
	Input.action_release("sprint")
	var sprinted := player.position.x - 80.0
	_check(sprinted > walked * 1.25, "P1.03 Shift sprint is measurably faster")

	player.position = Vector2(292, 100)
	await _hold("move_right", 30)
	_check(player.position.x <= 299.2, "P1.04 blocks the right room edge")
	player.position = Vector2(28, 100)
	await _hold("move_left", 30)
	_check(player.position.x >= 20.8, "P1.04 blocks the left room edge")
	player.position = Vector2(80, 28)
	await _hold("move_up", 30)
	_check(player.position.y >= 19.8, "P1.04 blocks the top room edge")
	player.position = Vector2(80, 164)
	await _hold("move_down", 30)
	_check(player.position.y <= 172.2, "P1.04 blocks the bottom room edge")
	player.position = Vector2(160, 82)
	await _hold("move_up", 30)
	_check(player.position.y >= 65.8, "P1.04 workstation collision prevents overlap")

	player.position = Vector2(160, 82)
	player.facing = Vector2.UP
	player._update_detector_position()
	await _physics_frames(3)
	player._update_interaction()
	_check(detector.has_overlapping_areas(), "P1.05 detects an interactable in front of the player")
	_check(player.active_interactable == workstation, "P1.05 selects the workstation")
	_check(workstation.interaction_prompt() == "[E] USE  VS CODE", "P1.05 exposes a clear interaction prompt")
	player._unhandled_input(_action_event("interact"))
	await process_frame
	_check(workstation.status == "attention", "P1.05 E/Enter interaction reaches the target")

	player.position = Vector2(80, 130)
	player._unhandled_input(_action_event("menu"))
	await process_frame
	_check(main.menu_open, "P1.06 Escape opens the pause/help menu")
	_check(hud.get_node("MenuOverlay").visible, "P1.06 menu presents controls and safety state")
	_check(not player.input_enabled, "P1.06 menu locks player input")
	var paused_position := player.position
	await _hold("move_right", 8)
	_check(player.position.is_equal_approx(paused_position), "P1.06 player cannot move behind the menu")
	player._unhandled_input(_action_event("menu"))
	await process_frame
	_check(not main.menu_open and player.input_enabled, "P1.06 Escape resumes the hub")

	var stations := get_nodes_in_group("application_stations")
	var station_ids: Array[String] = []
	for station in stations:
		station_ids.append(station.desktop_id)
	_check(stations.size() == 3, "P1.07 hub exposes three reusable application stations")
	_check(station_ids.has("code.desktop") and station_ids.has("firefox.desktop") and station_ids.has("kitty.desktop"), "P1.07 stations carry semantic desktop IDs")
	_check(main.get_node("World/Objects/BrowserStation").interaction_prompt() == "[E] USE  FIREFOX", "P1.07 station prompts are configured per application")

	_check(backend.last_requested_desktop_id == "code.desktop", "P1.08 interaction reaches the typed backend boundary")
	_check(not backend.connected, "P1.08 Phase 1 remains offline-safe")
	_check(hud.status.text.contains("CORE OFFLINE"), "P1.08 HUD reports the safe offline result")

	if failures.is_empty():
		print("Phase 1.01-1.08 validation passed.")
		quit(0)
	else:
		push_error("Phase 1 validation failed: %s" % failures)
		quit(1)

func _action_event(action: StringName) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	return event
