extends SceneTree
const Actions = preload("res://scripts/input_actions.gd")
var failed := false

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func key(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame

func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	await key(KEY_ESCAPE)
	check(main.menu_open and main.pause_panel.visible and not main.player.input_enabled, "Keyboard pause owns modal input")
	await key(KEY_DOWN)
	await key(KEY_ENTER)
	check(main.pause_panel.page == "help", "Help is keyboard reachable")
	check(main.pause_panel._items[1].contains(Actions.binding_label("interact")), "Help describes actual action bindings")
	await key(KEY_ESCAPE)
	check(main.menu_open and main.pause_panel.page == "home", "Inner Back returns home without unlocking player")
	main.pause_panel.show_page("diagnostics")
	main.backend.notifications_policy_disabled = true
	main.backend.notifications_policy_changed.emit(true)
	main.backend.state = BackendClient.ConnectionState.READY
	main.backend.state_changed.emit(main.backend.state)
	check(main.pause_panel._items[4].contains("DISABLED"), "Diagnostic policy is explicit")
	main.backend.notifications_policy_disabled = false
	main.backend.notifications_availability = "available"
	main.backend.notifications_availability_changed.emit("available")
	check(main.pause_panel._items[4].contains("ENABLED / OPT-IN"), "Diagnostics update live while paused")
	check(main.pause_panel._detail.text.contains("NO CONTENT"), "Diagnostics stay status-level")
	main.pause_panel.show_page("controls")
	var keys := InputMap.action_get_events("workspace_map")
	InputMap.action_erase_events("workspace_map")
	var changed := InputEventKey.new()
	changed.physical_keycode = KEY_F
	InputMap.action_add_event("workspace_map", changed)
	main.pause_panel.refresh()
	check(main.pause_panel._items.has("WORKSPACE MAP // F"), "Rebound InputMap action is reflected immediately")
	InputMap.action_erase_events("workspace_map")
	for event in keys: InputMap.action_add_event("workspace_map", event)
	await key(KEY_ESCAPE)
	await key(KEY_ESCAPE)
	check(not main.menu_open and main.player.input_enabled, "Back returns world input")
	main._toggle_menu()
	main.pause_panel._cursor.select(4, 5)
	main.pause_panel.activate_selection()
	check(main.onboarding.active and not main.menu_open, "Replay resumes guide and exits overlay")
	main._toggle_menu()
	main.pause_panel.show_page("settings")
	main.pause_panel._cursor.select(3, 5)
	main.pause_panel.activate_selection()
	check(not main.onboarding.active and not main.menu_open, "Skip dismisses guide through keyboard menu")
	main.queue_free()
	await process_frame
	if not failed: print("D6.08 pause/help validation passed")
	quit(1 if failed else 0)
