extends SceneTree
## Agreed seam: native keys/proximity + accepted snapshots -> one input owner
## and zero/one mocked launch call. No socket, real application or settings IO.
const Overlay = preload("res://ui/overlay_coordinator.gd")
const Bindings = preload("res://scripts/key_bindings.gd")
class MockBackend extends BackendClient:
	var launches: Array[String] = []
	func launch_app(id: String) -> bool:
		launches.append(id)
		return true
var problems: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: problems.append(message); push_error(message)
func tap(code: int) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame
func approach(main: Node, position: Vector2) -> void:
	main.player.position = position
	main.player.facing = Vector2.UP
	main.player._update_detector_position()
	await physics_frame
	await physics_frame
	main.player.refresh_interaction()
func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	var original: Node = main.get_node("BackendClient")
	main.remove_child(original)
	original.free()
	var backend := MockBackend.new()
	backend.name = "BackendClient"
	backend.auto_connect = false
	main.add_child(backend)
	root.add_child(main)
	backend.set_process(false)
	main.ui_audio.enabled = false
	if not "selection" in main or not "inspector" in main:
		check(false, "Production scene wires separate inspection selection and focus")
		main.queue_free()
		await process_frame
		quit(1)
		return
	backend.state = BackendClient.ConnectionState.READY
	var a := {"id": "code.desktop", "name": "Fixture A", "exec": "fixture-editor", "categories": ["Development"]}
	var b := {"id": "firefox.desktop", "name": "Fixture B", "exec": "fixture-web", "categories": ["WebBrowser"]}
	backend.applications_changed.emit([a, b])
	await approach(main, Vector2(160, 82))
	check(main.selection.view().selected_id == "code.desktop", "Approaching A selects accepted identity")
	await approach(main, Vector2(160, 136))
	await tap(KEY_E)
	check(main.selection.view().selected_id == "code.desktop" and main.selection.view().nearby_id.is_empty() and backend.launches.is_empty(), "Retained A cannot launch after walking away")
	await approach(main, Vector2(96, 82))
	check(main.selection.view().selected_id == "firefox.desktop", "A to B selects B, not a row index")
	await tap(KEY_E)
	check(backend.launches == ["firefox.desktop"], "World activation crosses the mock launch boundary exactly once")
	backend.applications_changed.emit([b, a])
	check(main.selection.view().selected_id == "firefox.desktop", "Registry reorder preserves selection")
	backend.applications_changed.emit([a])
	check(not main.selection.view().available and main.selection.view().name == "Fixture B", "Removal retains useful identity but never availability")
	for _cycle in range(5):
		await tap(KEY_F)
		check(main.overlays.current == Overlay.Mode.INSPECTOR and not main.player.input_enabled and main.inspector.focus_anchor().has_focus(), "Explicit focus locks world, not inspector visibility")
		main.overlays.open(Overlay.Mode.WORKSPACES)
		main.overlays.open(Overlay.Mode.MEDIA)
		main.overlays.close(Overlay.Mode.WORKSPACES)
		check(main.overlays.current == Overlay.Mode.MEDIA and not main.player.input_enabled, "Late close cannot unlock a newer modal")
		backend.ux_status_changed.emit("reconnecting", "RECONNECTING", "waiting", -1.0)
		check(main.overlays.current == Overlay.Mode.MEDIA and main.inspector.visible, "Reconnect updates never steal modal ownership or erase inspection")
		main.overlays.back()
		check(main.overlays.current == Overlay.Mode.INSPECTOR and main.inspector.focus_anchor().has_focus(), "Modal Back restores prior explicit inspector focus")
		await tap(KEY_ESCAPE)
		check(main.overlays.current == Overlay.Mode.NONE and main.player.input_enabled, "Inspector Back always restores world")
	main.settings.set_action_keys("focus_inspector", [KEY_G])
	main.settings.set_action_keys("confirm", [KEY_H])
	check(Bindings.apply(main.settings), "New action and confirm remap are context-safe")
	await tap(KEY_F)
	check(main.overlays.current == Overlay.Mode.NONE, "Old inspector key is inactive after remapping")
	await tap(KEY_G)
	check(main.overlays.current == Overlay.Mode.INSPECTOR, "Remapped inspector key acquires focus")
	await tap(KEY_ENTER)
	check(main.overlays.current == Overlay.Mode.INSPECTOR and backend.launches.size() == 1, "Old GUI confirm cannot dismiss or double-launch behind the inspector")
	await tap(KEY_H)
	check(main.overlays.current == Overlay.Mode.NONE and main.player.input_enabled, "Named remapped confirm returns to world exactly once")
	check(not backend.auto_connect and not backend.is_processing() and not main.load_preferences, "Test uses no live transport or preferences")
	main.queue_free()
	await process_frame
	if problems.is_empty(): print("R6.04 integrated keyboard/selection ownership validation passed")
	quit(0 if problems.is_empty() else 1)
