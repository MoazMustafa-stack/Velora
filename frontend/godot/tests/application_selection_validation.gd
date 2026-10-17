extends SceneTree

const Selection = preload("res://scripts/application_selection.gd")

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func _run() -> void:
	var selection := Selection.new()
	var state: Dictionary = selection.view()
	_check(
		state.get("nearby_id") == "" and state.get("selected_id") == ""
		and state.get("available") == false and state.get("registry_known") == false,
		"R6.04 initial selection has no nearby or selected application"
	)
	var editor := {"id": "code.desktop", "name": "Code", "categories": ["Development"]}
	selection.observe_nearby("code.desktop", editor)
	state = selection.view()
	_check(
		state.get("nearby_id") == "code.desktop" and state.get("selected_id") == "code.desktop"
		and state.get("name") == "Code" and state.get("available") == true,
		"R6.04 approaching an application selects its accepted identity for inspection"
	)
	selection.observe_nearby("")
	state = selection.view()
	_check(
		state.get("nearby_id") == "" and state.get("selected_id") == "code.desktop"
		and state.get("name") == "Code",
		"R6.04 walking away clears nearby identity but keeps useful inspection selection"
	)
	selection.observe_nearby("web.desktop", {"id": "web.desktop", "name": "Web", "categories": ["Network"]})
	state = selection.view()
	_check(
		state.get("nearby_id") == "web.desktop" and state.get("selected_id") == "web.desktop"
		and state.get("name") == "Web" and state.get("categories") == ["Network"],
		"R6.04 approaching B replaces A's identity without retaining A's category"
	)
	selection.update_registry([editor, {"id": "web.desktop", "name": "Web Updated", "categories": ["Network"]}])
	selection.update_registry([{"id": "web.desktop", "name": "Web Updated", "categories": ["Network"]}, editor])
	state = selection.view()
	_check(
		state.get("selected_id") == "web.desktop" and state.get("name") == "Web Updated"
		and state.get("available") == true and state.get("registry_known") == true,
		"R6.04 accepted registry reorder retains the selected desktop ID and refreshes its label"
	)
	selection.update_registry([editor])
	state = selection.view()
	_check(
		state.get("selected_id") == "web.desktop" and state.get("name") == "Web Updated"
		and state.get("available") == false,
		"R6.04 registry removal makes selection unavailable without erasing its last useful identity"
	)
	var empty := Selection.new()
	empty.update_registry([])
	_check(empty.view().get("registry_known") == true and empty.view().get("selected_id") == "",
		"R6.04 the first empty registry is a known empty state, not an initial wait")
	selection.observe_nearby("missing.desktop", editor)
	state = selection.view()
	_check(
		state.get("selected_id") == "missing.desktop" and state.get("name") == "missing.desktop"
		and state.get("available") == false and state.get("categories") == [],
		"R6.04 a missing valid ID stays inspectable and cannot inherit mismatched metadata"
	)
	for invalid_id in ["/usr/bin/code", "../code.desktop", "app.desktop --flag", "bad\n.desktop", ""]:
		selection.observe_nearby(invalid_id, editor)
		state = selection.view()
		_check(state.get("nearby_id") == "" and state.get("selected_id") == "missing.desktop",
			"R6.04 malformed or absent nearby ID clears proximity, not useful selection: " + invalid_id.c_escape())
	selection.observe_nearby("unicode.desktop", {
		"id": "unicode.desktop", "name": "编辑器 🦀\nRow\tColumn\r\u001b\u007f\u0085\u2028\u2029\u202eEnd",
		"categories": ["开发\nTools"], "exec": "must not be retained", "icon": "/private/path.svg",
	})
	state = selection.view()
	_check(
		state.get("name") == "编辑器 🦀 Row Column       End"
		and state.get("categories") == ["开发 Tools"]
		and not state.has("exec") and not state.has("icon"),
		"R6.04 presentation labels preserve Unicode but remove line/control formatting and command metadata"
	)
	var categories: Array = []
	for index in range(100):
		categories.append("Category".repeat(100))
	selection.observe_nearby("long.desktop", {
		"id": "long.desktop", "name": "界".repeat(10000), "categories": categories,
	})
	state = selection.view()
	_check(
		state.get("name") == "界".repeat(128) and state.get("categories").size() == 8
		and state.get("categories")[0].length() == 48,
		"R6.04 retained display metadata is bounded without stripping non-ASCII text"
	)
	selection.observe_nearby("malformed.desktop", {
		"id": "malformed.desktop", "name": 42, "categories": [],
	})
	_check(selection.view().get("available") == false and selection.view().get("name") == "malformed.desktop",
		"R6.04 malformed metadata cannot become available or replace useful display identity")
	var caller_app := {"id": "isolated.desktop", "name": "Original", "categories": ["Office"]}
	selection.observe_nearby("isolated.desktop", caller_app)
	caller_app["name"] = "Caller changed"
	caller_app["categories"][0] = "Caller category"
	state = selection.view()
	state["name"] = "View changed"
	state["categories"][0] = "View category"
	_check(selection.view().get("name") == "Original" and selection.view().get("categories") == ["Office"],
		"R6.04 caller metadata and returned views cannot mutate retained selection")
	var catalog: Array = []
	for index in range(600):
		catalog.append({"id": "fixture-%d.desktop" % index, "name": "Fixture %d" % index})
	selection.observe_nearby("fixture-599.desktop")
	selection.update_registry(catalog)
	catalog[599]["name"] = "Caller changed catalog"
	catalog.clear()
	state = selection.view()
	_check(state.get("name") == "Fixture 599" and state.get("available") == true,
		"R6.04 selection reconciliation is independent of the chooser's 512-row cap and caller catalog mutations")
	selection.observe_nearby("")
	selection.update_registry([])
	_check(selection.view().get("nearby_id") == "" and selection.view().get("name") == "Fixture 599"
		and selection.view().get("available") == false,
		"R6.04 a later empty registry does not invent proximity or erase useful identity")
	selection.observe_nearby("fixture-599.desktop", {"id": "fixture-599.desktop", "name": "Restored"})
	_check(selection.view().get("name") == "Restored" and selection.view().get("available") == true,
		"R6.04 an application that returns can refresh the same selected identity")

	if failures.is_empty():
		print("R6.04 application selection validation passed.")
		quit(0)
	else:
		push_error("R6.04 application selection validation failed: %s" % [failures])
		quit(1)
