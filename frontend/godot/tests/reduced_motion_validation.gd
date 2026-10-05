extends SceneTree
var failed := false

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var path := "/tmp/velora-motion-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	var main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	var player = main.player
	player.set_physics_process(false)
	player._update_animation(player.animation_interval, true)
	check(player._animation_step == 1, "Baseline walk cycle animates")
	main._toggle_menu()
	main.pause_panel.show_page("accessibility")
	main.pause_panel.activate_selection()
	check(player.reduced_motion and player._animation_step == 0, "Settings immediately stop decorative motion while paused")
	player._update_animation(5.0, true)
	check(player._animation_step == 0 and player._animation_time == 0.0, "Reduced motion suppresses walk cycle")
	main._toggle_menu()
	main._toggle_menu()
	main._toggle_menu()
	check(not main.menu_open and player.input_enabled, "Three nested Back steps return to the world")
	player.position = Vector2(160, 110)
	Input.action_press("move_right")
	var before: Vector2 = player.position
	player._physics_process(1.0 / 60.0)
	Input.action_release("move_right")
	check(player.position.x > before.x and player.velocity.x == player.walk_speed, "Reduced motion preserves locomotion and speed")
	check(player.facing == Vector2.RIGHT and player._animation_step == 0, "Facing information remains without animation")
	main.queue_free()
	await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	check(main.player.reduced_motion and main.settings.reduced_motion(), "Reduced motion survives restart")
	main._toggle_menu()
	main.pause_panel.show_page("accessibility")
	main.pause_panel.activate_selection()
	check(not main.player.reduced_motion, "Motion can be re-enabled immediately")
	main.player._update_animation(main.player.animation_interval, true)
	check(main.player._animation_step == 1, "Normal animation resumes")
	main.reset_preferences()
	check(not FileAccess.file_exists(path) and not main.player.reduced_motion, "Reset removes fixture preference and applies defaults")
	main.queue_free()
	await process_frame
	if not failed: print("D6.09 reduced motion validation passed")
	quit(1 if failed else 0)
