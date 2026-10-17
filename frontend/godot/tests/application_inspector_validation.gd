extends SceneTree

const Inspector = preload("res://ui/application_inspector.gd")
const Art = preload("res://scripts/pixel_art.gd")

var failures: Array[String] = []
var back_count := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func _text(inspector: Control, child_name: String) -> String:
	var child := inspector.get_node_or_null(child_name)
	return child.text if child is Label else ""

func _run() -> void:
	root.size = Vector2i(640, 360)
	var inspector := Inspector.new()
	root.add_child(inspector)
	inspector.update_view({}, {"core_state": "ready"})
	await process_frame
	_check(
		inspector.position == Vector2(0, 280) and inspector.size == Vector2(640, 80)
		and inspector.get_node("Identity").text == "NO APPLICATION SELECTED"
		and root.gui_get_focus_owner() == null,
		"R6.05 persistent inspector uses approved lower region without taking focus"
	)
	inspector.update_view({"registry_known": true}, {"core_state": "ready", "registry_empty": false})
	_check(_text(inspector, "Identity") == "NO APPLICATION SELECTED"
		and _text(inspector, "Availability") == "REGISTRY READY"
		and _text(inspector, "Guidance").contains("APPROACH"),
		"R6.05 a populated-but-unselected registry invites approach rather than claiming empty")
	inspector.update_view({"registry_known": true}, {"core_state": "ready", "registry_empty": true})
	_check(_text(inspector, "Identity") == "NO APPLICATIONS"
		and _text(inspector, "Availability") == "REGISTRY EMPTY",
		"R6.05 first accepted empty registry has an explicit truthful empty state")
	inspector.update_view({"registry_known": false}, {"core_state": "loading_applications", "registry_empty": true})
	_check(_text(inspector, "Identity") == "NO APPLICATION SELECTED"
		and _text(inspector, "Availability") == "LOADING APPLICATIONS",
		"R6.05 initial loading cannot falsely become an empty registry")
	var editor := {
		"nearby_id": "code.desktop", "selected_id": "code.desktop", "name": "Code",
		"categories": ["Development"], "available": true, "registry_known": true,
	}
	inspector.update_view(editor, {"core_state": "ready", "running_state": "running", "running_location": "2", "running_windows": 2})
	_check(_text(inspector, "Identity") == "Code" and _text(inspector, "Availability").contains("AVAILABLE")
		and _text(inspector, "Details").contains("Development") and _text(inspector, "Details").contains("code.desktop")
		and _text(inspector, "Running").contains("RUNNING x2") and _text(inspector, "Running").contains("2"),
		"R6.05 selected application shows identity, category, ID, availability and observed running location")
	var missing := editor.duplicate(true)
	missing["nearby_id"] = ""
	missing["available"] = false
	inspector.update_view(missing, {"core_state": "ready", "running_state": "unknown", "registry_empty": true})
	_check(_text(inspector, "Identity") == "Code" and _text(inspector, "Availability") == "APP UNAVAILABLE"
		and _text(inspector, "Running") == "RUNNING UNKNOWN",
		"R6.05 registry removal retains useful selected identity without guessing running state")
	var core_states := {
		"offline": "CORE OFFLINE", "connecting": "CONNECTING", "connected": "CONNECTED // WAITING",
		"loading_applications": "LOADING APPLICATIONS", "reconnecting": "RECONNECTING",
		"protocol_incompatible": "PROTOCOL INCOMPATIBLE",
	}
	for state in core_states:
		inspector.update_view(editor, {"core_state": state, "running_state": "running", "running_windows": 2})
		_check(_text(inspector, "Identity") == "Code" and _text(inspector, "Availability") == core_states[state]
			and _text(inspector, "Running").begins_with("STALE //"),
			"R6.05 retained identity distinguishes backend state and stale observations: " + state)
	inspector.update_view(editor, {"core_state": "ready", "running_state": "not_running"})
	_check(_text(inspector, "Availability") == "AVAILABLE" and _text(inspector, "Running") == "NOT RUNNING",
		"R6.05 fresh ready data clears stale presentation without requiring a restart")
	inspector.update_view(editor, {"core_state": "ready", "running_state": "running", "running_windows": 1, "running_stale": true})
	_check(_text(inspector, "Availability") == "AVAILABLE" and _text(inspector, "Running") == "STALE // RUNNING x1",
		"R6.05 ready Core cannot make an unavailable/waiting session's retained observations look fresh")
	inspector.update_view(editor, {"core_state": "ready", "feedback": {
		"desktop_id": "web.desktop", "stage": "launch_failed", "message": "Other application's failure", "retryable": true,
	}})
	_check(_text(inspector, "Feedback") == "Actions: nearby object only",
		"R6.05 another application's launch feedback cannot be relabelled as the selected app's result")
	inspector.update_view(editor, {"core_state": "ready", "feedback": {
		"desktop_id": "code.desktop", "stage": "launch_successful", "message": "WINDOW READY AND FOCUSED",
	}})
	_check(_text(inspector, "Feedback").begins_with("LAUNCH ACCEPTED")
		and not _text(inspector, "Feedback").contains("WINDOW READY"),
		"R6.05 spawn acceptance never claims that an application window is ready or focused")
	inspector.update_view(editor, {"core_state": "ready", "feedback": {
		"desktop_id": "code.desktop", "stage": "launching_application", "message": "Launching Code",
	}})
	_check(_text(inspector, "Feedback") == "LAUNCHING APPLICATION",
		"R6.05 correlated pending launch has visible feedback without adding an action")
	inspector.update_view(editor, {"core_state": "ready", "feedback": {
		"desktop_id": "code.desktop", "stage": "launch_failed", "message": "Temporarily unavailable", "retryable": true,
	}})
	_check(_text(inspector, "Feedback").contains("LAUNCH FAILED // Temporarily unavailable")
		and _text(inspector, "Feedback").contains("RETRY AT STATION"),
		"R6.05 retryable failure remains truthful about the existing station-only action")
	inspector.update_view(editor, {"core_state": "offline", "feedback": {
		"desktop_id": "code.desktop", "stage": "launch_successful",
	}})
	_check(_text(inspector, "Feedback").begins_with("LAST: LAUNCH ACCEPTED"),
		"R6.05 retained launch history is marked last-known while Core is offline")
	var browser := {"selected_id": "web.desktop", "name": "Web", "available": true, "registry_known": true}
	inspector.update_view(browser, {"core_state": "ready", "feedback": {
		"desktop_id": "code.desktop", "stage": "launch_failed", "message": "Code failed",
	}})
	_check(_text(inspector, "Identity") == "Web" and _text(inspector, "Feedback") == "Actions: nearby object only",
		"R6.05 selecting B clears A's prior visible result instead of attaching it to B")
	_check(inspector.get_node("Icon").texture == Art.workshop_icon_texture("unknown"),
		"R6.05 an unclassified application uses the approved unknown icon rather than guessing identity")
	inspector.update_view({
		"selected_id": "unknown.desktop", "nearby_id": "", "name": "编辑器 🦀\n" + "界".repeat(1000),
		"categories": ["未知\nCategory".repeat(100)], "available": true, "registry_known": true,
	}, {"core_state": "ready", "running_state": "running", "running_windows": 999999,
		"running_location": "Room\n".repeat(100), "focus_hint": "[Q] INSPECT", "nearby_prompt": "Open map\n".repeat(100),
		"feedback": {"desktop_id": "unknown.desktop", "stage": "launch_failed", "message": "失败\r\n\u001b".repeat(1000)},
	})
	await process_frame
	_check(_text(inspector, "Identity").begins_with("编辑器 🦀 ")
		and _text(inspector, "Identity").length() <= 128 and _text(inspector, "Feedback").length() <= 160
		and _text(inspector, "Guidance").begins_with("[Q] INSPECT")
		and not _text(inspector, "Feedback").contains("\n") and not _text(inspector, "Feedback").contains("\u001b"),
		"R6.05 unusual Unicode and long/control text remain bounded, single-line and remapped-key friendly")
	for child in inspector.get_children():
		if child is Label:
			_check(child.clip_text and child.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS
				and child.position.x >= 0 and child.position.y >= 0
				and child.position.x + child.size.x <= inspector.size.x
				and child.position.y + child.size.y <= inspector.size.y,
				"R6.05 native label stays clipped inside the inspector: %s %s" % [child.name, child.get_rect()])
	var labels: Array = inspector.get_children().filter(func(child): return child is Label)
	var labels_overlap := false
	for index in range(labels.size()):
		for other in range(index + 1, labels.size()):
			if labels[index].get_rect().intersects(labels[other].get_rect()):
				labels_overlap = true
	_check(not labels_overlap, "R6.05 native Unicode line heights do not overlap neighbouring inspector labels")
	var sentinel := Button.new()
	sentinel.text = "Synthetic modal focus"
	root.add_child(sentinel)
	sentinel.grab_focus()
	inspector.update_view(editor, {"core_state": "ready", "focus_hint": "[Q] INSPECT", "focused": true})
	_check(root.gui_get_focus_owner() == sentinel,
		"R6.05 backend/context updates cannot steal focus even when given a presentation focus flag")
	inspector.back_requested.connect(func(): back_count += 1)
	inspector.set_inspector_focused(true)
	_check(root.gui_get_focus_owner() == inspector.focus_anchor()
		and inspector.focus_anchor() is Button and inspector.focus_anchor().text == "RETURN",
		"R6.05 explicit inspector focus reaches only a clearly labelled Return control")
	inspector.update_view(editor, {"core_state": "reconnecting"})
	_check(root.gui_get_focus_owner() == inspector.focus_anchor(),
		"R6.05 live updates preserve explicitly owned inspector focus")
	var anchor := inspector.focus_anchor()
	_check(anchor.position.x + anchor.size.x <= inspector.size.x
		and anchor.position.y + anchor.size.y <= inspector.size.y
		and not anchor.get_rect().intersects(inspector.get_node("Guidance").get_rect()),
		"R6.05 the Return control remains bounded and separate from keyboard guidance")
	var confirm := InputEventAction.new()
	confirm.action = "ui_accept"
	confirm.pressed = true
	root.push_input(confirm)
	await process_frame
	confirm = InputEventAction.new()
	confirm.action = "ui_accept"
	confirm.pressed = false
	root.push_input(confirm)
	await process_frame
	_check(back_count == 1, "R6.05 keyboard Return activation emits one back intent and no launch intent")
	inspector.set_inspector_focused(false)
	_check(root.gui_get_focus_owner() != inspector.focus_anchor()
		and inspector.focus_anchor().focus_mode == Control.FOCUS_NONE,
		"R6.05 leaving inspector focus releases its control for coordinator restoration")
	var children_before: Array = inspector.get_children().map(func(child): return child.get_instance_id())
	for index in range(100):
		inspector.update_view(editor, {"core_state": "ready", "running_state": "unknown"})
	_check(inspector.get_children().map(func(child): return child.get_instance_id()) == children_before,
		"R6.05 repeated accepted state updates reuse the existing bounded view tree")
	sentinel.queue_free()
	inspector.queue_free()
	await process_frame
	if failures.is_empty():
		print("R6.05 application inspector validation passed.")
		quit(0)
	else:
		push_error("R6.05 application inspector validation failed: %s" % [failures])
		quit(1)
