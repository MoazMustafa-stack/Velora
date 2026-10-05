extends SceneTree
const Art = preload("res://scripts/pixel_art.gd")
const Empty = preload("res://ui/empty_states.gd")
var failed := false

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var patterns: Array[String] = []
	for state in ["ready", "attention", "offline"]:
		var image := Art.create_workstation_texture(state).get_image()
		var pattern := ""
		for y in range(21, 26):
			for x in range(24, 29):
				pattern += "#" if image.get_pixel(x, y).get_luminance() > 0.7 else "."
		check(pattern not in patterns and pattern.contains("#"), "Station status has a unique grayscale shape: " + state)
		patterns.append(pattern)
	var map = load("res://ui/workspace_map.gd").new()
	root.add_child(map)
	map.update_session({"workspaces": [{"handle": "a", "index": 1, "name": "1", "is_active": true, "is_urgent": true}, {"handle": "b", "index": 2, "name": "2", "is_special": true}]})
	check(map._cells[0].header.text.begins_with(">!*"), "Active, urgent and selected markers coexist")
	map._move_selection(1)
	check(not map._cells[0].header.text.contains("*") and map._cells[1].header.text.begins_with("~*"), "Cursor selection moves independently of status color")
	var labels: Array[String] = []
	for state in ["waiting", "available", "disabled", "unavailable", "restricted", "offline"]:
		var label: String = Empty.describe("notifications", state).title
		check(label not in labels, "Empty/failure/waiting/privacy states have distinct text")
		labels.append(label)
	map.queue_free()
	await process_frame
	if not failed: print("D6.09 grayscale marker validation passed")
	quit(1 if failed else 0)
