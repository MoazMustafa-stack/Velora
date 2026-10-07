extends SceneTree
const Bindings = preload("res://scripts/key_bindings.gd")
const Store = preload("res://scripts/settings_store.gd")
const Actions = preload("res://scripts/input_actions.gd")
var failed := false
func check(value: bool, message: String) -> void:
	if not value: failed = true; push_error(message)
func _initialize() -> void: call_deferred("run")
func tap(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame
func run() -> void:
	var path := "/tmp/velora-remapping-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	var store := Store.new(path)
	check(Bindings.reason(Bindings.effective(store)).is_empty(), "Existing defaults are context-safe")
	check(not Bindings.remap_reason(store, "move_up", [KEY_S]).is_empty(), "Same-context collision is rejected")
	check(not Bindings.remap_reason(store, "confirm", [KEY_ESCAPE]).is_empty(), "Escape is reserved for recovery")
	check(Bindings.remap_reason(store, "media_next", [KEY_W]).is_empty() == false, "Media navigation conflict is rejected")
	check(Bindings.remap_reason(store, "workspace_map", [KEY_G]).is_empty(), "Nonconflicting custom key accepted")
	store.set_action_keys("move_up", [KEY_S])
	check(not Bindings.apply(store) and Actions.binding_label("move_up").contains("W"), "Invalid persisted conflicts fall back to defaults")
	var main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	main._toggle_menu()
	main.pause_panel.show_page("controls")
	var index: int = Actions.DEFAULTS.keys().find("workspace_map")
	main.pause_panel._cursor.select(index, Actions.DEFAULTS.size() + 1)
	main.pause_panel.refresh()
	main.pause_panel.activate_selection()
	check(main.pause_panel.capturing_key, "Keyboard action enters remap capture")
	await tap(KEY_ESCAPE)
	check(not main.pause_panel.capturing_key and main.menu_open and not FileAccess.file_exists(path), "Escape cancels without writing or leaving overlay")
	main.pause_panel.activate_selection()
	await tap(KEY_W)
	check(main.pause_panel.capturing_key and main.pause_panel._detail.text.contains("CONFLICT"), "Rejected conflict preserves old controls and capture")
	await tap(KEY_G)
	check(not main.pause_panel.capturing_key and Actions.binding_label("workspace_map") == "G", "Accepted remap applies to InputMap")
	main._toggle_menu()
	main._toggle_menu()
	await tap(KEY_M)
	check(not main.map_open, "Old default no longer opens map")
	await tap(KEY_G)
	check(main.map_open, "Remapped key opens its panel")
	await tap(KEY_ESCAPE)
	check(main.player.input_enabled, "Protected Back remains reachable")
	main.queue_free()
	await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	check(Actions.binding_label("workspace_map") == "G", "Remap persists across restart")
	main._toggle_menu()
	main.pause_panel.show_page("controls")
	main._reset_bindings()
	check(Actions.binding_label("workspace_map").contains("Tab"), "Reset restores current defaults")
	main.reset_preferences()
	main.queue_free()
	await process_frame
	if not failed: print("D6.11 keyboard remapping, conflicts, cancellation and persistence passed")
	quit(1 if failed else 0)
