extends SceneTree
const Guide = preload("res://ui/onboarding.gd")
const Store = preload("res://scripts/settings_store.gd")
const Actions = preload("res://scripts/input_actions.gd")
var failed := false

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	Actions.ensure_registered()
	var guide = Guide.new()
	check(guide.hint().contains("MOVE"), "Fresh guide starts with movement")
	guide.observe("map")
	guide.observe("move")
	check(guide.hint().contains("STATION"), "Progress is contextual, not a blocking sequence")
	guide.observe("interact")
	guide.observe("pause")
	check(guide.hint().contains("OPT-IN"), "Previously visited map is skipped")
	guide.observe("feed")
	guide.observe("media")
	check(not guide.active, "All useful actions complete onboarding")
	guide.replay()
	check(guide.active and guide.hint().contains("MOVE"), "Replay resets progress")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_H
	var old_events := InputMap.action_get_events("menu")
	InputMap.action_erase_events("menu")
	InputMap.action_add_event("menu", key)
	guide.observe("move")
	guide.observe("interact")
	check(guide.hint().begins_with("H PAUSE"), "Guide uses live bindings")
	InputMap.action_erase_events("menu")
	for event in old_events:
		InputMap.action_add_event("menu", event)
	var path := OS.get_environment("TMPDIR")
	if path.is_empty(): path = "/tmp"
	path += "/velora-onboarding-%d.json" % OS.get_process_id()
	check(not FileAccess.file_exists(path), "Test starts with its own fresh settings file")
	var main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	check(main.onboarding.active and not FileAccess.file_exists(path), "Startup explains first action without writing")
	main.onboarding.dismiss()
	check(FileAccess.file_exists(path), "Explicit dismissal saves completion")
	main.queue_free()
	await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	check(not main.onboarding.active, "Dismissal survives restart")
	main.replay_onboarding()
	var restored = Store.new(path)
	check(restored.load_settings() == OK and not restored.onboarding_completed(), "Replay persists its reset")
	check(main.onboarding.active, "Replay resumes contextual hints")
	main.queue_free()
	await process_frame
	check(DirAccess.remove_absolute(path) == OK, "Temporary settings cleaned up")
	if not failed: print("D6.07 onboarding validation passed")
	quit(1 if failed else 0)
