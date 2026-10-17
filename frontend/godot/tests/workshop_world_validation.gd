extends SceneTree
## Public production scene and texture seams. No live backend or preferences.
const MainScene = preload("res://scenes/main.tscn")
const Art = preload("res://scripts/pixel_art.gd")
const W = preload("res://ui/design_tokens.gd").Workshop
const EXPECTED_POSITIONS := {
	"Workstation": Vector2(160, 48), "BrowserStation": Vector2(96, 48), "TerminalStation": Vector2(224, 48),
	"MapObject": Vector2(64, 104), "MediaObject": Vector2(112, 104),
	"NotificationsObject": Vector2(208, 104), "ObservatoryObject": Vector2(256, 104),
}
var failed := false

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var main := MainScene.instantiate()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	main.backend.set_process(false)
	main.ui_audio.enabled = false
	main.player.set_process_unhandled_input(false)
	main.player.set_physics_process(false)
	await physics_frame
	var world: Node2D = main.world if "world" in main else main.get_node("World")
	var ground: TileMapLayer = world.get_node("Ground")
	var source: TileSetAtlasSource = ground.tile_set.get_source(ground.tile_set.get_meta("velora_source_id"))
	check(source.texture.get_image().get_pixel(0, 0) == W.FLOOR, "Production room uses the approved warm environment palette")
	check(world.scale == Vector2.ONE and main.player.position == Vector2(160, 136), "Native presentation preserves world transform and deterministic spawn")
	check(main.player.walk_speed == 48.0 and main.player.sprint_speed == 72.0, "Density does not change movement speed")
	check(ground.get_used_cells().size() == 240 and world.get_node("Walls").get_used_cells().size() == 60, "The closed room retains 20x12 tiles")
	for tile in [0, 2, 3]:
		check(source.get_tile_data(Vector2i(tile, 0), 0).get_collision_polygons_count(0) == 0, "Floor and decorative runner tiles never block movement")
	check(source.get_tile_data(Vector2i(1, 0), 0).get_collision_polygon_points(0, 0) == PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]), "Visible solid wall occupies its complete 16px physics tile")
	for station in get_nodes_in_group("application_stations"):
		station.bind_application({"id": station.desktop_id, "name": "SYNTHETIC APPLICATION"})
		check(station.sprite.texture == Art.workshop_object_texture(station.station_kind, "ready"), "Production application uses approved workshop family: " + station.station_kind)
		station.apply_launch_feedback("launching_application", "", false)
		check(station.sprite.texture == Art.workshop_object_texture(station.station_kind, "waiting"), "Pending launch has a waiting badge")
		station.apply_launch_feedback("launch_failed", "SYNTHETIC REJECTION", true)
		check(station.status == "ready" and station.is_application_available() and station.retry_available, "Failure presentation does not change safe retry availability")
		check(station.sprite.texture == Art.workshop_object_texture(station.station_kind, "failure"), "Recoverable rejection retains a distinct failure badge")
		check(station.has_method("set_selection"), "Station exposes presentation-only selection and keyboard focus")
		if station.has_method("set_selection"):
			station.set_selection(true)
			var selected_image: Image = station.sprite.texture.get_image()
			check(selected_image.get_pixel(0, 0) == W.FOCUS, "Selection uses visible corner brackets")
			check(selected_image.get_pixel(27, 25) == W.FAILURE, "Selection cannot hide a failure badge")
			station.set_selection(true, true)
			check(station.sprite.texture.get_image().get_pixel(16, 0) == W.FOCUS, "Keyboard focus has a continuous rail distinct from selection")
			station.set_selection(false)
		station.bind_application({"id": station.desktop_id, "name": "SYNTHETIC APPLICATION"})
		check(station.sprite.texture == Art.workshop_object_texture(station.station_kind, "ready"), "Fresh accepted binding clears old launch presentation")
	for object in get_nodes_in_group("hub_objects"):
		check(object.get_node("Sprite2D").texture == Art.workshop_object_texture(object.object_kind), "Production capability uses approved workshop family: " + object.object_kind)
	var catalog: Array[Dictionary] = [
		{"id": "code.desktop", "name": "SYNTHETIC EDITOR"},
		{"id": "firefox.desktop", "name": "SYNTHETIC BROWSER"},
		{"id": "kitty.desktop", "name": "SYNTHETIC TERMINAL"},
	]
	for index in range(500):
		catalog.append({"id": "synthetic-%03d.desktop" % index, "name": "SYNTHETIC APPLICATION"})
	main.backend.applications_changed.emit(catalog)
	for station in get_nodes_in_group("application_stations"):
		check(station.application.get("id", "") == station.desktop_id, "Station identity resolves only from its accepted registry mapping")
	var targets := get_nodes_in_group("application_stations") + get_nodes_in_group("hub_objects")
	check(targets.size() == 7, "Registry refresh cannot populate the world with additional stations")
	var rectangles: Array[Rect2] = []
	for target in targets:
		check(target.position == EXPECTED_POSITIONS.get(String(target.name)), "Object retains its deterministic approach lane: " + target.name)
		var collision: CollisionShape2D = target.get_node("CollisionShape2D")
		check(collision.shape.size == Vector2(32, 18) and collision.position == Vector2(0, 5), "Solid body dimensions are unchanged")
		var bounds := Rect2(target.position + collision.position - collision.shape.size / 2, collision.shape.size)
		check(not bounds.intersects(Rect2(144, 64, 32, 112)), "Central corridor stays free of physical objects")
		for other in rectangles:
			check(not bounds.intersects(other), "Object collision footprints never overlap")
		rectangles.append(bounds)
		var area: Area2D = target.get_node("InteractionArea")
		check(area.get_child(0).shape.size == Vector2(42, 32) and area.collision_layer == 4, "Facing-aware interaction distances are unchanged")
		var footprint: Sprite2D = target.get_node_or_null("Footprint")
		check(footprint != null, "Solid object footprint is visibly marked: " + target.name)
		if footprint != null:
			check(footprint.position == collision.position and Vector2(footprint.texture.get_size()) == collision.shape.size, "Visible plinth matches actual collision geometry: " + target.name)
	main.player.set_physics_process(true)
	for target in targets:
		await drive(main.player, Vector2(160, 136))
		if target.is_in_group("application_stations"):
			await drive(main.player, Vector2(160, 82))
			await drive(main.player, Vector2(target.position.x, 82))
		else:
			await drive(main.player, Vector2(target.position.x, 136))
		await face("move_up")
		main.player.refresh_interaction()
		check(main.player.active_interactable == target, "Keyboard walk and facing reach the exact object: " + target.name)
		check(not target.interaction_prompt().is_empty(), "Reachable object has keyboard guidance")
		await face("move_down")
		main.player.refresh_interaction()
		check(main.player.active_interactable != target, "Facing away cannot keep the old interaction target")
		await drive(main.player, Vector2(160, main.player.position.y))
	check(main.backend.last_requested_desktop_id.is_empty(), "Geometry validation never requests a real application launch")
	check(not main.backend.auto_connect and not main.backend.is_processing() and not main.load_preferences, "Geometry validation cannot touch live transport or preferences")
	main.backend.applications_changed.emit([])
	for station in get_nodes_in_group("application_stations"):
		station.set_selection(false)
		check(not station.is_application_available() and station.sprite.texture == Art.workshop_object_texture(station.station_kind, "offline"), "Missing mapped applications stay visible but unavailable")
	main.queue_free()
	await process_frame
	if not failed:
		print("R6.03 production workshop presentation and geometry validation passed")
	quit(1 if failed else 0)

func face(action: String) -> void:
	Input.action_press(action)
	await physics_frame
	await process_frame
	Input.action_release(action)
	await physics_frame
	await physics_frame

func drive(player: CharacterBody2D, destination: Vector2) -> void:
	# Input drives real physics along the clear lanes; no target teleportation.
	for axis in [1, 0]:
		var ticks := 0
		while absf(player.position[axis] - destination[axis]) > 1.0 and ticks < 200:
			var positive := destination[axis] > player.position[axis]
			var action := ("move_down" if positive else "move_up") if axis == 1 else ("move_right" if positive else "move_left")
			Input.action_press(action)
			await physics_frame
			Input.action_release(action)
			ticks += 1
		check(ticks < 200, "Approach lane has no invisible blocker: " + str(destination))
