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
	_check(packed != null, "P2.09 main scene loads for launch UX validation")
	if packed == null:
		quit(1)
		return

	var main := packed.instantiate()
	var backend := main.get_node("BackendClient") as BackendClient
	backend.auto_connect = false
	root.add_child(main)
	await _process_frames(2)

	var hud = main.get_node("HUD")
	var workstation = main.get_node("World/Objects/Workstation")
	_check(hud.connection.text == "CORE OFFLINE", "P2.09 Core offline is visible")

	backend._set_state(BackendClient.ConnectionState.CONNECTING, "validation")
	_check(hud.connection.text == "CONNECTING", "P2.09 connecting is visible")
	backend._set_state(BackendClient.ConnectionState.HANDSHAKING, "validation")
	_check(hud.status.text.contains("CONNECTING"), "P2.09 handshake keeps concise connecting feedback")
	backend._set_state(BackendClient.ConnectionState.READY, "validation")
	_check(hud.connection.text == "CONNECTED", "P2.09 connected is visible")

	backend._emit_ux_status("loading_applications", "LOADING APPLICATIONS", "waiting", -1.0)
	_check(hud.status.text.contains("LOADING APPLICATIONS"), "P2.09 registry loading is visible")
	backend._emit_ux_status("ready", "READY // 1 APPLICATION", "ready", -1.0)
	_check(hud.status.text.contains("READY"), "P2.09 ready is visible")

	backend.applications = [{
		"id": "code.desktop",
		"name": "Visual Studio Code",
		"exec": "/usr/bin/code",
		"icon": "visual-studio-code",
		"categories": ["Development"],
		"terminal": false,
	}]
	backend.applications_changed.emit(backend.applications.duplicate(true))
	await process_frame
	_check(workstation.is_application_available(), "P2.09 test station is registry-backed")

	backend._launch_request_id = 41
	backend._launch_desktop_id = "code.desktop"
	backend.launch_status_changed.emit(
		"code.desktop",
		"launching_application",
		"LAUNCHING VISUAL STUDIO CODE",
		false
	)
	backend._emit_ux_status(
		"launching_application",
		"LAUNCHING // VISUAL STUDIO CODE",
		"waiting",
		0.0
	)
	_check(workstation.status == "attention", "P2.09 launching state reaches the station")
	_check(hud.status.text.contains("LAUNCHING"), "P2.09 launching application is visible")

	backend._on_line_received(JSON.stringify({
		"type": "launch_accepted",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 41,
		"desktop_id": "code.desktop",
		"process_id": 1234,
	}))
	_check(workstation.status == "ready", "P2.09 launch success restores the station")
	_check(hud.status.text.contains("LAUNCHED"), "P2.09 launch success is visible")

	backend._launch_request_id = 42
	backend._launch_desktop_id = "code.desktop"
	backend._on_line_received(JSON.stringify({
		"type": "launch_rejected",
		"protocol_version": BackendClient.PROTOCOL_VERSION,
		"request_id": 42,
		"desktop_id": "code.desktop",
		"code": "launch_rate_limited",
		"message": "a deliberately long backend detail that the HUD must not display",
		"retryable": true,
	}))
	_check(hud.status.text.contains("PLEASE WAIT AND RETRY"), "P2.09 launch failure is concise")
	_check(
		workstation.interaction_prompt() == "[E] RETRY  VISUAL STUDIO CODE",
		"P2.09 retry remains keyboard-only"
	)
	backend._launch_request_id = 43
	backend._launch_desktop_id = "code.desktop"
	backend._update_launch_timeout(BackendClient.LAUNCH_TIMEOUT_SECONDS + 0.1)
	_check(backend._launch_request_id == 0, "P2.09 launch timeout clears the pending request")
	_check(hud.status.text.contains("TIMED OUT"), "P2.09 launch timeout provides recoverable feedback")

	var connection_before_pause: String = hud.connection.text
	main._toggle_menu()
	backend._set_state(BackendClient.ConnectionState.RECONNECTING, "validation")
	_check(hud.connection.text == "RECONNECTING", "P2.09 reconnecting remains visible while paused")
	_check(
		hud.menu_connection.text == "RECONNECTING",
		"P2.09 pause menu preserves the live connection state"
	)
	backend._set_state(BackendClient.ConnectionState.READY, "validation")
	main._toggle_menu()
	_check(
		hud.connection.text == "CONNECTED" and connection_before_pause == "CONNECTED",
		"P2.09 connection state survives pause and resume"
	)

	backend._emit_ux_status("ready", "READY // 1 APPLICATION", "ready", -1.0)
	hud.show_transient("VELORA // " + "X".repeat(200), "failure", 0.1)
	_check(hud.status.clip_text, "P2.09 long status text is clipped inside the HUD")
	_check(hud.status.text_overrun_behavior != 0, "P2.09 clipped status uses an ellipsis")
	hud._process(0.2)
	_check(hud.status.text.contains("READY"), "P2.09 recoverable errors expire to the last useful state")

	backend._set_state(BackendClient.ConnectionState.INCOMPATIBLE, "validation")
	_check(hud.connection.text == "INCOMPATIBLE", "P2.09 protocol incompatibility is visible")
	backend._set_state(BackendClient.ConnectionState.RECONNECTING, "validation")
	backend._set_state(BackendClient.ConnectionState.READY, "validation")
	backend._emit_ux_status("ready", "READY // 1 APPLICATION", "ready", -1.0)
	_check(
		hud.connection.text == "CONNECTED" and hud.status.text.contains("READY"),
		"P2.09 frontend recovers without restarting Godot"
	)

	main.queue_free()
	await process_frame
	if failures.is_empty():
		print("P2.09 connection and launch UX validation passed.")
		quit(0)
	else:
		push_error("P2.09 launch UX validation failed: %s" % [failures])
		quit(1)
