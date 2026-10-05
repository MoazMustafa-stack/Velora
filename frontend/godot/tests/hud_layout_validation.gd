extends SceneTree
const Layout = preload("res://ui/hud_layout.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	main.get_node("BackendClient").auto_connect = false
	main.load_preferences = false
	root.add_child(main)
	await process_frame
	var hud = main.hud
	hud.set_connection_status("CONNECTED", "ready")
	hud.set_status("A long application title ".repeat(30), "ready")
	hud.set_interaction_prompt("A long station prompt ".repeat(40))
	await process_frame
	await process_frame
	check(hud.prompt_panel.visible and not hud._telemetry.visible, "Prompt takes the shared footer from telemetry")
	for region in [Layout.STATUS, Layout.CONNECTION, Layout.FOOTER, Layout.HELP]:
		check(Rect2(0, 0, 320, 180).encloses(region), "Every HUD region fits the canvas")
	check(not Layout.STATUS.intersects(Layout.CONNECTION), "Status and connection never overlap")
	check(not Layout.FOOTER.intersects(Layout.HELP), "Footer and controls never overlap")
	for label in [hud.status, hud.connection, hud.prompt, hud.help, hud._telemetry]:
		check(label.clip_text and label.text_overrun_behavior != 0, "Every fixed HUD label clips")
	hud.show_transient("FAILURE", "failure", 0.1)
	check(not hud.prompt_panel.visible and not hud._telemetry.visible, "Failure takes priority over prompt and telemetry")
	hud._process(0.2)
	check(hud.status.text.begins_with("A long") and hud.prompt_panel.visible, "Transient expiry restores useful status and prompt")
	for open_method in ["_toggle_menu", "_toggle_workspace_map", "_toggle_notification_feed", "_toggle_media_console"]:
		main.call(open_method)
		check(not hud.help.visible and not hud._telemetry.visible and not hud.prompt_panel.visible and not hud.get_node("StatusPanel").visible, "Every modal hides the world HUD")
		main.overlays.back()
		check(hud.help.visible and main.player.input_enabled, "Closing modal restores HUD and input")
	main.queue_free()
	await process_frame
	if failures.is_empty():
		print("D6.06 HUD layout validation passed.")
	quit(0 if failures.is_empty() else 1)
