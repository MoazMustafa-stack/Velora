extends SceneTree
## Bridge-signal boundary -> accepted BackendClient snapshots -> native inspector.
## Reuse the deterministic restart peer; no socket or real launch is performed.
const RestartFixture = preload("res://tests/restart_state_validation.gd")
const Overlay = preload("res://ui/overlay_coordinator.gd")
var problems: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: problems.append(message); push_error(message)
func connect_peer(backend: Node, peer: Node) -> void:
	backend.connect_to_core()
	peer.socket_connected.emit()
	peer.reply({"type": "welcome", "server_name": "synthetic", "server_version": "0.2.0"})
	peer.reply({"type": "hyprland_capabilities", "capabilities": {"availability": "available"}})
func catalog(peer: Node, include_editor := true) -> void:
	var apps := [{"id": "firefox.desktop", "name": "Fixture Browser", "exec": "fixture-web", "icon": null, "categories": ["WebBrowser"], "terminal": false}]
	if include_editor:
		apps.append({"id": "code.desktop", "name": "Éditeur 日本語 🦀", "exec": "fixture-editor", "icon": null, "categories": ["Development"], "terminal": false})
	peer.reply({"type": "applications", "request_id": peer.last("list_applications").request_id, "applications": apps, "total": apps.size(), "next_offset": null})
func session(peer: Node, sequence: int, running: bool) -> void:
	var windows: Array = []
	if running:
		windows.append({"handle": "window:fixture", "workspace_handle": "workspace:fixture", "title": "Synthetic editor", "class": "fixture-editor", "is_active": true, "is_floating": false, "is_fullscreen": false})
	peer.reply({"type": "workspace_snapshot", "request_id": peer.last("get_workspace_snapshot").get("request_id", 0) if sequence == 1 else 0, "snapshot": {"sequence": sequence, "workspaces": [{"handle": "workspace:fixture", "index": 1, "name": "Workshop", "monitor": "fixture", "window_count": windows.size(), "is_active": true, "is_special": false, "is_urgent": false}], "windows": windows}})
func approach(main: Node, x: float) -> void:
	main.player.position = Vector2(x, 82)
	main.player.facing = Vector2.UP
	main.player._update_detector_position()
	await physics_frame
	await physics_frame
	main.player.refresh_interaction()
func tap(code: int) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame
func run() -> void:
	var peer := RestartFixture.FakeBridge.new()
	var main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	var backend: Node = main.get_node("BackendClient")
	backend.auto_connect = false
	backend.bridge_override = peer
	root.add_child(main)
	backend.set_process(false)
	main.ui_audio.enabled = false
	check(main.inspector.get_node("Availability").text == "CORE OFFLINE", "Inspector starts truthfully offline")
	connect_peer(backend, peer)
	check(main.inspector.get_node("Availability").text == "LOADING APPLICATIONS", "Handshake and pending registry have distinct visible feedback")
	catalog(peer)
	session(peer, 1, false)
	await approach(main, 160)
	check(main.inspector.get_node("Identity").text == "Éditeur 日本語 🦀" and main.inspector.get_node("Availability").text == "AVAILABLE", "Accepted registry identity reaches persistent inspection")
	check(main.inspector.get_node("Running").text == "NOT RUNNING", "Observed empty session does not invent running state")
	await tap(KEY_E)
	var launch: Dictionary = peer.last("launch_application")
	check(launch.get("desktop_id") == "code.desktop" and main.inspector.get_node("Feedback").text == "LAUNCHING APPLICATION", "Existing correlated launch status reaches the selected inspector")
	await approach(main, 96)
	peer.reply({"type": "launch_accepted", "request_id": launch.request_id, "desktop_id": "code.desktop", "process_id": 123})
	check(main.inspector.get_node("Identity").text == "Fixture Browser" and not main.inspector.get_node("Feedback").text.contains("ACCEPTED"), "Result A never becomes selected B's result")
	await approach(main, 160)
	check(main.inspector.get_node("Feedback").text.begins_with("LAUNCH ACCEPTED") and main.inspector.get_node("Running").text == "NOT RUNNING", "Returning to A retains useful acceptance without claiming a ready window")
	session(peer, 2, true)
	check(main.inspector.get_node("Running").text.begins_with("RUNNING x1"), "SessionBinding observation, not launch acceptance, establishes running")
	main.overlays.open(Overlay.Mode.PAUSE)
	peer.socket_disconnected.emit("synthetic Core restart")
	check(main.overlays.current == Overlay.Mode.PAUSE and main.inspector.visible and main.inspector.get_node("Identity").text == "Éditeur 日本語 🦀", "Core restart while paused retains useful identity and input owner")
	check(main.inspector.get_node("Running").text.begins_with("STALE") and main.inspector.get_node("Availability").text == "RECONNECTING", "Cached observations are visibly stale during reconnect")
	peer.requests.clear()
	connect_peer(backend, peer)
	catalog(peer)
	session(peer, 1, false)
	check(main.inspector.get_node("Running").text == "NOT RUNNING" and main.overlays.current == Overlay.Mode.PAUSE, "Fresh lower-sequence restart snapshot replaces stale running without stealing focus")
	main.overlays.back()
	backend.request_applications()
	peer.reply({"type": "applications", "request_id": peer.last("list_applications").request_id, "applications": "malformed", "total": 1})
	check(main.inspector.get_node("Availability").text == "REGISTRY STALE" and main.inspector.get_node("Identity").text == "Éditeur 日本語 🦀", "Recoverable malformed refresh preserves useful identity and labels stale registry")
	backend.request_applications()
	catalog(peer, false)
	check(main.inspector.get_node("Availability").text == "APP UNAVAILABLE" and main.inspector.get_node("Identity").text == "Éditeur 日本語 🦀", "Accepted removal does not erase identity or invent availability")
	check(not backend.auto_connect and not backend.is_processing() and not main.load_preferences, "Integration uses only the fake peer and session-only UI")
	main.queue_free()
	await process_frame
	if problems.is_empty(): print("R6.05 accepted snapshot/feedback/restart integration passed")
	quit(0 if problems.is_empty() else 1)
