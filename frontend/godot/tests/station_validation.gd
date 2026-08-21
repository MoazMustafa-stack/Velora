extends SceneTree

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func _process_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame

func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	_check(packed != null, "P2.08 main scene loads for station binding")
	if packed == null:
		quit(1)
		return

	var main := packed.instantiate()
	var backend := main.get_node("BackendClient") as BackendClient
	backend.auto_connect = false
	root.add_child(main)
	await _process_frames(2)

	var workstation := main.get_node("World/Objects/Workstation")
	var terminal_station := main.get_node("World/Objects/TerminalStation")
	var hud := main.get_node("HUD")
	backend.applications_changed.emit([
		{
			"id": "code.desktop",
			"name": "Visual Studio Code",
			"exec": "/usr/bin/code %F",
			"icon": "visual-studio-code",
			"categories": ["Development", "IDE"],
			"terminal": false,
		},
	])
	await process_frame

	_check(workstation.registry_checked, "P2.08 station receives the completed application registry")
	_check(workstation.is_application_available(), "P2.08 station resolves its desktop ID")
	_check(
		workstation.application.get("name") == "Visual Studio Code",
		"P2.08 station stores real application metadata"
	)
	_check(
		workstation.interaction_prompt() == "[E] USE  VISUAL STUDIO CODE",
		"P2.08 interaction prompt uses the real application name"
	)
	_check(workstation.status == "ready", "P2.08 resolved station enters the ready state")

	_check(
		terminal_station.registry_checked and not terminal_station.is_application_available(),
		"P2.08 missing desktop IDs remain unavailable"
	)
	_check(
		terminal_station.interaction_prompt() == "[E] MISSING  TERMINAL",
		"P2.08 unavailable stations expose a clear prompt"
	)

	main._on_interaction_requested(workstation)
	await process_frame
	_check(
		backend.last_requested_desktop_id == "code.desktop",
		"P2.08 resolved station reaches the typed launch boundary"
	)
	_check(workstation.status == "ready", "P2.09 failed offline launch leaves station usable")
	_check(
		workstation.interaction_prompt() == "[E] RETRY  VISUAL STUDIO CODE",
		"P2.09 recoverable launch failure provides a keyboard retry"
	)
	_check(
		hud.status.text.contains("CORE OFFLINE"),
		"P2.09 reports the actual offline launch failure"
	)

	main._on_interaction_requested(terminal_station)
	await process_frame
	_check(
		backend.last_requested_desktop_id == "code.desktop",
		"P2.08 unavailable station does not request a launch"
	)
	_check(
		hud.status.text.contains("APPLICATION NOT FOUND"),
		"P2.08 unavailable interaction reports the missing application"
	)

	main.queue_free()
	await process_frame
	if failures.is_empty():
		print("P2.08 station application binding validation passed.")
		quit(0)
	else:
		push_error("P2.08 station validation failed: %s" % [failures])
		quit(1)
