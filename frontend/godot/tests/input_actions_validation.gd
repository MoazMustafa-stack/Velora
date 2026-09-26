extends SceneTree

const Actions = preload("res://scripts/input_actions.gd")
const Store = preload("res://scripts/settings_store.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func key(code: int, pressed: bool = true) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	return event

func tap(code: int) -> void:
	Input.parse_input_event(key(code))
	await process_frame
	Input.parse_input_event(key(code, false))
	await process_frame

func _run() -> void:
	Actions.ensure_registered()
	var store := Store.new("/tmp/velora-input-test-unused.json")
	for action in Actions.DEFAULTS:
		check(store.set_action_keys(action, Actions.DEFAULTS[action]), "Default bindings fit the settings allowlist")
		check(not InputMap.action_get_events(action).is_empty(), "Every action has defaults")
	var main = load("res://scenes/main.tscn").instantiate()
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	for code in [KEY_M, KEY_TAB, KEY_N, KEY_P]:
		await tap(code)
		check(not main.player.input_enabled, "Top-level action opens a modal")
		await tap(KEY_ESCAPE)
		check(main.player.input_enabled, "Escape closes modal without opening pause")
	await tap(KEY_ESCAPE)
	check(main.menu_open, "Escape from world opens pause")
	await tap(KEY_ESCAPE)
	check(not main.menu_open and main.player.input_enabled, "Escape resumes")
	await tap(KEY_P)
	await tap(KEY_N)
	check(main.media_open and not main.feed_open, "Media next does not open notifications")
	await tap(KEY_P)
	check(main.player.input_enabled, "Panel toggle closes its own modal")
	# A named action follows InputMap, rather than retaining a hidden raw-key path.
	InputMap.action_erase_events("workspace_map")
	InputMap.action_add_event("workspace_map", key(KEY_G))
	Actions.ensure_registered()
	await tap(KEY_M)
	check(not main.map_open, "Removed default is not silently reinstalled")
	await tap(KEY_G)
	check(main.map_open, "Top-level dispatch follows the named action")
	await tap(KEY_ESCAPE)
	main.queue_free()
	await process_frame
	if failures.is_empty():
		print("D6.04 input action validation passed.")
	quit(0 if failures.is_empty() else 1)
