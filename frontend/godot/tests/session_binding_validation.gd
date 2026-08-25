extends SceneTree

const SessionBinding = preload("res://scripts/session_binding.gd")

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
	var code_app := {
		"id": "code.desktop",
		"name": "Visual Studio Code",
		"exec": "/usr/bin/code %F",
		"icon": "code",
		"categories": ["Development"],
		"terminal": false,
	}
	var foot_app := {
		"id": "foot.desktop",
		"name": "Foot",
		"exec": "foot",
		"icon": "",
		"categories": [],
		"terminal": true,
	}

	_check(
		SessionBinding.exec_basename("/usr/bin/code %F") == "code",
		"P3.08 exec basename extraction strips paths and placeholders"
	)
	_check(
		SessionBinding.exec_basename("  foot  ") == "foot",
		"P3.08 exec basename tolerates whitespace"
	)

	var windows := [
		{
			"handle": "window:one", "workspace_handle": "workspace:1",
			"title": "Editor", "class": "Code", "is_active": false,
			"is_floating": false, "is_fullscreen": false,
		},
		{
			"handle": "window:two", "workspace_handle": "workspace:2",
			"title": "Terminal", "class": "code", "is_active": true,
			"is_floating": false, "is_fullscreen": false,
		},
	]
	var matches := SessionBinding.running_applications([code_app], windows)
	_check(
		matches.has("code.desktop") and int(matches["code.desktop"]["window_count"]) == 2,
		"P3.08 class matching is case-insensitive and counts multiple windows"
	)
	_check(
		String(matches["code.desktop"]["workspace_handle"]) == "workspace:2",
		"P3.08 the active window decides the reported workspace"
	)

	var ambiguous_apps := [
		code_app,
		{"id": "code-fork.desktop", "name": "Code Fork", "exec": "/opt/fork/code"},
	]
	var ambiguous := SessionBinding.running_applications(ambiguous_apps, windows)
	_check(
		ambiguous.is_empty(),
		"P3.08 a shared executable name is never claimed by either application"
	)

	var unrelated := [
		{"handle": "window:x", "workspace_handle": "workspace:1", "title": "",
			"class": "somethingelse", "is_active": true, "is_floating": false,
			"is_fullscreen": false},
	]
	_check(
		SessionBinding.running_applications([code_app], unrelated).is_empty(),
		"P3.08 unmatched window classes bind nothing"
	)

	var snapshot := {
		"sequence": 1,
		"workspaces": [
			{"handle": "workspace:1", "name": "1", "index": 1, "monitor": "eDP-1",
				"window_count": 1, "is_active": false, "is_special": false, "is_urgent": false},
			{"handle": "workspace:2", "name": "2", "index": 2, "monitor": "DP-1",
				"window_count": 1, "is_active": true, "is_special": false, "is_urgent": false},
		],
		"windows": windows,
	}
	var running_state := SessionBinding.station_running_state(
		"code.desktop", snapshot, "available", code_app
	)
	_check(
		running_state["state"] == SessionBinding.STATE_RUNNING
		and running_state["location"] == "2"
		and int(running_state["windows"]) == 2,
		"P3.08 running stations report workspace name and window count"
	)

	var idle_state := SessionBinding.station_running_state(
		"foot.desktop", snapshot, "available", foot_app
	)
	_check(
		idle_state["state"] == SessionBinding.STATE_NOT_RUNNING,
		"P3.08 registered applications with no windows are idle, not unknown"
	)

	var unavailable_state := SessionBinding.station_running_state(
		"code.desktop", {}, "unavailable", code_app
	)
	_check(
		unavailable_state["state"] == SessionBinding.STATE_UNKNOWN,
		"P3.08 missing Hyprland keeps every station Unknown instead of guessing"
	)

	var empty_registry_state := SessionBinding.station_running_state(
		"code.desktop", snapshot, "available", {}
	)
	_check(
		empty_registry_state["state"] == SessionBinding.STATE_UNKNOWN,
		"P3.08 unbound stations stay Unknown even with live session data"
	)

	if failures.is_empty():
		print("P3.08 session binding validation passed.")
		quit(0)
	else:
		push_error("P3.08 session binding validation failed: %s" % [failures])
		quit(1)
