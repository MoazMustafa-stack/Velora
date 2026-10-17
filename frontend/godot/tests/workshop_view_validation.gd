extends SceneTree
const W = preload("res://ui/design_tokens.gd").Workshop
var problems: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: problems.append(message); push_error(message)
func run() -> void:
	check(ProjectSettings.get_setting("display/window/size/viewport_width") == 640, "Approved production native width")
	check(ProjectSettings.get_setting("display/window/size/viewport_height") == 360, "Approved production native height")
	var main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	main.backend.set_process(false)
	main.ui_audio.enabled = false
	if not "workshop" in main or not "world" in main:
		check(false, "Main exposes production composition and unscaled world")
		main.queue_free()
		await process_frame
		quit(1)
		return
	await physics_frame
	await physics_frame
	check(main.world.get_parent() == main.workshop.world_viewport, "Only world rendering uses the smaller viewport")
	check(main.workshop.world_viewport.size == W.WORLD_VIEW, "Exactly 320x128 physical view")
	check(main.workshop.stage.get_rect() == Rect2(W.WORLD), "World displays at integer 2x below header")
	check(main.world.scale == Vector2.ONE and main.player.scale == Vector2.ONE, "Canvas change never scales physics")
	check(main.world.get_node("Walls").collision_visibility_mode == 0, "Production walls never force the collision-debug overlay")
	check(main.player.position == Vector2(160, 136) and main.player.walk_speed == 48.0 and main.player.sprint_speed == 72.0, "Spawn and movement units preserved")
	for mode in main.overlays._panels:
		main.overlays.open(mode)
		await process_frame
		await process_frame
		main.workshop.fit_panels()
		await process_frame
		var panel: CanvasLayer = main.overlays._panels[mode]
		for child in panel.get_children():
			if child is PanelContainer:
				var native_rect: Rect2 = panel.transform * child.get_rect()
				check(Rect2(W.WORLD).encloses(native_rect), "Existing modal stays above persistent inspector: " + panel.name + " " + str(native_rect))
	main.overlays.back()
	main.queue_free()
	await process_frame
	if problems.is_empty(): print("R6.03 production composition validation passed")
	quit(0 if problems.is_empty() else 1)
