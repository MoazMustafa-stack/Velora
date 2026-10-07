extends SceneTree
var failed := false
var cues: Array[String] = []
func check(value: bool, message: String) -> void:
	if not value: failed = true; push_error(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var path := "/tmp/velora-audio-settings-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	var main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	main.ui_audio.output_available = true
	main.ui_audio.cue_played.connect(func(kind): cues.append(kind))
	main.backend.media_snapshot_changed.emit({"players": []})
	main.backend.notification_feed_changed.emit({"notifications": []})
	main.backend.telemetry_snapshot_changed.emit({})
	check(cues.is_empty(), "Background data updates never produce audio")
	main._toggle_menu()
	main.pause_panel.show_page("audio")
	main.pause_panel.activate_selection()
	check(main.settings.audio_muted() and main.ui_audio.muted, "Audio settings immediately mute service")
	check(not main.ui_audio.play_cue("interact"), "Muted interaction stays silent")
	main.queue_free()
	await process_frame
	await create_timer(0.12).timeout
	main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	check(main.ui_audio.muted and main.settings.audio_muted(), "Mute survives restart independently of media players")
	main.reset_preferences()
	check(not main.ui_audio.muted and not FileAccess.file_exists(path), "Safe reset restores local audio defaults")
	main.queue_free()
	await process_frame
	await create_timer(0.12).timeout
	if not failed: print("D6.10 user-action audio wiring and persistence passed")
	quit(1 if failed else 0)
