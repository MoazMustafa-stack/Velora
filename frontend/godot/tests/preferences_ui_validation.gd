extends SceneTree
const Store = preload("res://scripts/settings_store.gd")
var failed := false

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var path := "/tmp/velora-ui-preferences-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	var main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	main._toggle_menu()
	var panel = main.pause_panel
	panel.show_page("settings")
	panel.activate_selection()
	check(panel.page == "accessibility", "Accessibility is reachable from settings")
	panel.activate_selection()
	var restored = Store.new(path)
	check(restored.load_settings() == OK and restored.reduced_motion(), "Reduced motion preference is saved through UI")
	panel.back()
	check(panel.page == "settings" and not main.player.input_enabled, "Subpage Back preserves modal lock")
	panel.show_page("audio")
	panel.activate_selection()
	panel._cursor.select(1, 3)
	panel.activate_selection()
	check(main.settings.audio_muted() and is_equal_approx(main.settings.audio_volume(), 0.6), "Local audio preferences are independently editable")
	check(panel._detail.text.contains("SAVED"), "Successful persistence gives feedback")
	panel.show_page("reset")
	panel.activate_selection()
	check(FileAccess.file_exists(path), "Reset defaults to Cancel")
	panel.show_page("reset")
	panel._cursor.select(1, 2)
	panel.activate_selection()
	check(not FileAccess.file_exists(path), "Confirmed reset removes only injected settings file")
	check(not main.settings.reduced_motion() and not main.settings.audio_muted() and main.onboarding.active, "Reset restores defaults and onboarding")
	check(panel.page == "settings" and not main.player.input_enabled, "Reset retains settings overlay ownership")
	# A nonexistent parent forces a save failure without chmod or production files.
	main.preferences_path = path + "/missing.json"
	main.settings = Store.new(main.preferences_path)
	panel.configure(main.backend, main.settings)
	panel.show_page("accessibility")
	panel.activate_selection()
	check(main.preferences_error != OK and panel._detail.text.contains("NOT SAVED"), "IO failure is visible inside modal")
	main.queue_free()
	await process_frame
	if not failed: print("D6.08 preferences UI validation passed")
	quit(1 if failed else 0)
