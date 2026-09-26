extends SceneTree

const Overlay = preload("res://ui/overlay_coordinator.gd")
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
	root.add_child(main)
	await process_frame
	var coordinator: RefCounted = main.overlays
	for _cycle in range(30):
		for mode in [Overlay.Mode.PAUSE, Overlay.Mode.WORKSPACES, Overlay.Mode.NOTIFICATIONS, Overlay.Mode.MEDIA]:
			coordinator.open(mode)
			var count := int(main.hud.menu_overlay.visible) + int(main.workspace_map.visible) + int(main.notification_feed.visible) + int(main.media_console.visible)
			check(count == 1 and not main.player.input_enabled, "Exactly one modal owns input")
			main.backend.ux_status_changed.emit("reconnecting", "RECONNECTING", "waiting", -1.0)
			coordinator.close(Overlay.Mode.NONE)
			check(coordinator.current == mode and not main.player.input_enabled, "Stale close cannot unlock a newer modal")
		coordinator.back()
		check(main.player.input_enabled, "Back always restores movement")
	main._toggle_menu()
	main.backend.ux_status_changed.emit("ready", "READY", "ready", -1.0)
	check(main.hud.menu_connection.text == "CONNECTED", "Backend state updates while paused")
	main._toggle_menu()
	check(main.hud.status.text == "VELORA // READY", "Pause preserves useful status")
	main.player.global_position = Vector2(160, 82)
	main.player.facing = Vector2.UP
	main.player._update_detector_position()
	await physics_frame
	await physics_frame
	main.player.refresh_interaction()
	var prompt: String = main.hud.prompt.text
	check(not prompt.is_empty(), "Prompt recovery fixture has an actual station target")
	main._toggle_menu()
	check(not main.hud.prompt_panel.visible, "Modal hides world prompt")
	main._toggle_menu()
	check(main.hud.prompt.text == prompt, "Close restores the current world prompt")
	main.queue_free()
	await process_frame
	if failures.is_empty():
		print("D6.04 overlay coordination validation passed.")
	quit(0 if failures.is_empty() else 1)
