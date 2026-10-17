extends SceneTree
## Drive real keyboard paths, with an injected temporary settings destination.
const Actions = preload("res://scripts/input_actions.gd")
var failed := false

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func text_of(node: Node) -> String:
	var result: String = node.text + "\n" if node is Label else ""
	for child in node.get_children(): result += text_of(child)
	return result

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

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var path := "/tmp/velora-save-feedback-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	for writable in [false, true]:
		var main = load("res://scenes/main.tscn").instantiate()
		# Missing parent fails deterministically, without chmod or live preferences.
		main.preferences_path = path if writable else path + "/missing.json"
		main.get_node("BackendClient").auto_connect = false
		root.add_child(main)
		await process_frame
		main.backend.set_process(false)
		main.backend.state = BackendClient.ConnectionState.READY
		main.backend.state_changed.emit(main.backend.state)
		main.backend.applications_changed.emit([{"id": "fixture.desktop", "name": "Fixture"}])
		await tap(KEY_ESCAPE)
		for index in range(3): await tap(KEY_DOWN)
		await tap(KEY_ENTER)
		check(main.pause_panel.page == "settings", "Settings reachable from keyboard pause")
		for index in range(3): await tap(KEY_DOWN)
		await tap(KEY_ENTER)
		await tap(KEY_ENTER)
		await tap(KEY_END)
		await tap(KEY_ENTER)
		check(main.world.get_node("Objects/Workstation").desktop_id == "fixture.desktop", "Valid mapping remains usable in memory even when disk save fails")
		check_feedback(main, writable, "STATION MAPPED", "Mapping")
		await tap(KEY_END)
		await tap(KEY_ENTER)
		check(main.world.get_node("Objects/Workstation").desktop_id == "code.desktop", "Station reset applies safe runtime defaults")
		check_feedback(main, writable, "DEFAULT STATIONS RESTORED", "Station reset")
		await tap(KEY_ESCAPE)
		await tap(KEY_DOWN)
		await tap(KEY_DOWN)
		await tap(KEY_ENTER)
		check(main.pause_panel.page == "controls", "Controls reachable with keyboard")
		await tap(KEY_END)
		await tap(KEY_ENTER)
		check_feedback(main, writable, "DEFAULT KEYS RESTORED", "Binding reset")
		check(Actions.binding_label("workspace_map").contains("Tab"), "Failed binding save still leaves default recovery keys usable")
		main.queue_free()
		await process_frame
	if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	check(not FileAccess.file_exists(path + ".tmp"), "Settings temporary file is cleaned up")
	if not failed: print("Keyboard preference save-failure/success feedback validation passed")
	quit(1 if failed else 0)

func check_feedback(main: Node, writable: bool, success: String, operation: String) -> void:
	var text := text_of(main.pause_panel)
	if writable:
		check(main.preferences_error == OK and text.contains(success), operation + " reports persisted success when writing succeeds")
	else:
		check(main.preferences_error != OK and text.contains("NOT SAVED") and not text.contains(success), operation + " cannot mask failed persistence with success feedback")
