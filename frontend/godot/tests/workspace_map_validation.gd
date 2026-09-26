extends SceneTree

const WorkspaceMapScript = preload("res://ui/workspace_map.gd")

var failures: Array[String] = []

var fixture_workspaces: Array = []

func _initialize() -> void:
	for index in range(1, 11):
		fixture_workspaces.append({
			"handle": "workspace:%d" % index,
			"name": str(index),
			"index": index,
			"monitor": "eDP-1",
			"window_count": index % 3,
			"is_active": index == 2,
			"is_special": false,
			"is_urgent": false,
		})
	fixture_workspaces.append({
		"handle": "workspace:-99",
		"name": "special:notes",
		"index": -1,
		"monitor": "eDP-1",
		"window_count": 0,
		"is_active": false,
		"is_special": true,
		"is_urgent": false,
	})
	fixture_workspaces[4]["is_urgent"] = true

	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func _cell_headers(map: CanvasLayer) -> Array[String]:
	var headers: Array[String] = []
	for cell in map._grid.get_children():
		for child in cell.get_children():
			if child is VBoxContainer:
				headers.append(String(child.get_child(0).text))
	return headers

func _run() -> void:
	var map: CanvasLayer = CanvasLayer.new()
	map.set_script(WorkspaceMapScript)
	root.add_child(map)
	await process_frame

	_check(
		not map.visible and map._title.text.contains("WAITING"),
		"P3.07 map starts hidden with a typed waiting state"
	)

	map.set_availability("unavailable")
	await process_frame
	_check(
		map._title.text.contains("NO HYPRLAND") and map.visible_workspaces.is_empty(),
		"P3.07 missing Hyprland is explicit and clears stale cells"
	)

	map.update_session({"sequence": 1, "workspaces": fixture_workspaces})
	map.open()
	await process_frame
	_check(map.visible, "P3.07 open() reveals the map")
	_check(
		map._title.text.contains("HYPRLAND"),
		"P3.07 available Hyprland is titled explicitly"
	)
	_check(
		map._grid.get_child_count() == fixture_workspaces.size(),
		"P3.07 every workspace renders as its own cell"
	)
	_check(
		map.selected_index == 1,
		"P3.07 selection defaults to the active workspace"
	)

	var headers := _cell_headers(map)
	_check(headers.any(func(text: String) -> bool: return text.begins_with("!")), 
		"P3.07 urgent workspaces carry a color-independent marker")
	_check(headers.any(func(text: String) -> bool: return text.begins_with("~")),
		"P3.07 special workspaces carry a distinct marker")
	_check(headers.any(func(text: String) -> bool: return text.begins_with(">")),
		"P3.07 the active workspace carries an arrow marker")

	map._move_selection(1)
	_check(map.selected_index == 2, "P3.07 selection advances past the default")
	map._move_selection(-3)
	_check(map.selected_index == fixture_workspaces.size() - 1,
		"P3.07 selection wraps backwards across zero")

	var visited := {}
	for _step in range(fixture_workspaces.size()):
		visited[map.selected_index] = true
		map._move_selection(1)
	_check(
		visited.size() == fixture_workspaces.size(),
		"P3.07 every workspace is reachable from the keyboard"
	)

	map._select_index(0)
	var switch_handles: Array[String] = []
	map.switch_requested.connect(func(handle: String) -> void:
		switch_handles.append(handle)
	)
	map._confirm_selection()
	_check(
		switch_handles == ["workspace:1"],
		"P3.07 confirming emits only the snapshot-issued workspace handle"
	)

	map.update_session({"sequence": 2, "workspaces": fixture_workspaces.slice(0, 10)})
	_check(
		map._grid.get_child_count() == 10 and map.selected_index == 0,
		"D6.02 refreshed sessions preserve the selected workspace handle"
	)
	map.update_session({"workspaces": fixture_workspaces.slice(1, 10)})
	_check(map.selected_index == 0, "D6.02 removed selection falls back to the active workspace")
	await process_frame
	await process_frame
	_check(map._panel.position.x + map._panel.size.x <= 320, "D6.02 grid stays within the canvas")
	_check(map._cells[0].panel.size.x >= 40, "D6.02 clipped cells retain readable width")

	map.close()
	_check(not map.visible, "P3.07 close() hides the map again")

	map.queue_free()
	await process_frame
	if failures.is_empty():
		print("P3.07 workspace map validation passed.")
		quit(0)
	else:
		push_error("P3.07 workspace map validation failed: %s" % [failures])
		quit(1)
