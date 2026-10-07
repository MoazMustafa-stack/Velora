extends SceneTree
const Actions = preload("res://scripts/input_actions.gd")
const Overlay = preload("res://ui/overlay_coordinator.gd")
var failed := false
const DEVICE := 42 # Synthetic process-local input, not an OS controller.
func check(value: bool, message: String) -> void:
	if not value: failed = true; push_error(message)
func _initialize() -> void: call_deferred("run")
func tap(button: int) -> void:
	var event := InputEventJoypadButton.new()
	event.device = DEVICE
	event.button_index = button
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame
func axis(axis_index: int, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = DEVICE
	event.axis = axis_index
	event.axis_value = value
	Input.parse_input_event(event)
	await process_frame
func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	for action in Actions.DEFAULTS:
		check(InputMap.action_get_events(action).any(func(event): return event is InputEventJoypadButton or event is InputEventJoypadMotion), "Controller fallback exists for " + action)
	await tap(JOY_BUTTON_START)
	check(main.menu_open and Actions.controller_labels, "Controller Start opens pause and uses generic pad labels")
	await tap(JOY_BUTTON_DPAD_DOWN)
	await tap(JOY_BUTTON_A)
	check(main.pause_panel.page == "help", "Controller-only navigation reaches help")
	check(main.pause_panel._items[1].contains("Pad A"), "Help reflects current controller bindings")
	await tap(JOY_BUTTON_B)
	await tap(JOY_BUTTON_B)
	check(main.player.input_enabled and not main.menu_open, "Controller Back restores world input")
	for pair in [[JOY_BUTTON_Y, Overlay.Mode.WORKSPACES], [JOY_BUTTON_LEFT_SHOULDER, Overlay.Mode.NOTIFICATIONS], [JOY_BUTTON_RIGHT_SHOULDER, Overlay.Mode.MEDIA]]:
		await tap(pair[0])
		check(main.overlays.current == pair[1], "Controller opens each top-level panel")
		await tap(JOY_BUTTON_B)
	await tap(JOY_BUTTON_START)
	await axis(JOY_AXIS_LEFT_Y, 0.2)
	check(main.pause_panel._cursor.selected == 0, "Stick drift below deadzone cannot move selection")
	await axis(JOY_AXIS_LEFT_Y, 0.8)
	check(main.pause_panel._cursor.selected == 1, "Stick crossing threshold navigates once")
	await axis(JOY_AXIS_LEFT_Y, 0.9)
	check(main.pause_panel._cursor.selected == 1, "Repeated same-direction samples do not repeat or queue navigation")
	await axis(JOY_AXIS_LEFT_Y, 0.0)
	await axis(JOY_AXIS_LEFT_Y, 0.8)
	check(main.pause_panel._cursor.selected == 2, "Returning to center re-arms stick navigation")
	main._on_joy_connection_changed(DEVICE, false)
	check(main.menu_open and not main.player.input_enabled and not Actions.controller_labels, "Disconnect preserves modal ownership and returns keyboard labels")
	var event := InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	check(not main.menu_open and main.player.input_enabled, "Keyboard recovery works after disconnect")
	event = event.duplicate(); event.pressed = false; Input.parse_input_event(event)
	main.player.position = Vector2(160, 136)
	var held := InputEventKey.new()
	held.physical_keycode = KEY_W
	held.pressed = true
	Input.parse_input_event(held)
	await axis(JOY_AXIS_LEFT_X, 0.8)
	var start: Vector2 = main.player.position
	await physics_frame
	await physics_frame
	check(main.player.position.x > start.x, "Analog controller movement remains functional")
	main._on_joy_connection_changed(DEVICE, false)
	await physics_frame
	check(not Input.is_action_pressed("move_right"), "Disconnect releases only stale controller motion")
	check(Input.is_action_pressed("move_up"), "Disconnect preserves held keyboard fallback")
	held = held.duplicate(); held.pressed = false; Input.parse_input_event(held)
	check(Actions._axis_transitions.size() <= 128, "Axis history is explicitly bounded")
	main.queue_free()
	await process_frame
	print("Physical controllers detected (manual acceptance still required): ", Input.get_connected_joypads().size())
	if not failed: print("D6.11 controller focus, deadzone, labels and hot-plug validation passed")
	quit(1 if failed else 0)
