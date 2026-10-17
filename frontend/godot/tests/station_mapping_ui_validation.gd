extends SceneTree
const Store = preload("res://scripts/settings_store.gd")
const Overlay = preload("res://ui/overlay_coordinator.gd")
class FakeBridge:
	extends Node
	var lines: Array[String] = []
	func send_line(payload: String) -> bool:
		lines.append(payload)
		return true
	func disconnect_socket() -> void: pass
var failed := false
func check(value: bool, message: String) -> void:
	if not value: failed = true; push_error(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var path := "/tmp/velora-station-ui-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	var store := Store.new(path)
	store.set_station_desktop_id("editor", "missing.desktop")
	check(store.save_settings() == OK, "Fixture stores a syntactically valid missing desktop ID")
	var main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	main.backend.set_process(false)
	var station = main.world.get_node("Objects/Workstation")
	check(station.desktop_id == "missing.desktop" and station.registry_checked and not station.is_application_available(), "Missing saved mapping is unavailable before the first catalog")
	await approach(main)
	check(main.player.active_interactable == station, "Mapping fixture interacts only with a physically nearby station")
	main._on_interaction_requested(station)
	check(main.backend.last_requested_desktop_id.is_empty(), "Unknown saved mapping never creates a launch request")
	var fixture := [{"id": "safe.desktop", "name": "Safe\nApp", "startup_wm_class": "SafeApp", "exec": "/usr/bin/safeapp"}, {"id": "code.desktop", "name": "Editor"}]
	main.backend.session_availability = "available"
	main.backend.session_snapshot = {"sequence": 1, "workspaces": [{"handle": "workspace:1", "name": "7"}], "windows": [{"handle": "window:1", "class": "safeapp", "workspace_handle": "workspace:1"}]}
	main.backend.applications.assign(fixture)
	main.backend.applications_changed.emit(fixture)
	main._toggle_menu()
	main.pause_panel.show_page("stations")
	main.pause_panel.activate_selection()
	check(main.pause_panel.page == "station_choice", "Fixed editor slot opens a registry chooser")
	var choice: int = main.pause_panel._choices.find({"id": "safe.desktop", "name": "Safe App"})
	check(choice >= 0, "Chooser renders Core registry names as a single line")
	main.pause_panel._cursor.select(choice + 1, main.pause_panel._choices.size() + 1)
	main.pause_panel.activate_selection()
	check(station.desktop_id == "missing.desktop" and main.pause_panel._detail.text.contains("OFFLINE"), "Offline chooser rejects stale registry choices")
	main.backend.state = BackendClient.ConnectionState.READY
	main.backend.state_changed.emit(main.backend.state)
	main.pause_panel.activate_selection()
	check(station.desktop_id == "safe.desktop" and station.is_application_available(), "Known live registry choice maps the fixed slot")
	check(station.application_label() == "Safe App", "Application name cannot introduce multiline prompt overflow")
	check(station.application.startup_wm_class == "SafeApp", "Running-state matching metadata remains intact")
	check(station.running_state == "running" and station.running_location == "7", "Mapping immediately uses the last useful session snapshot")
	station.apply_launch_feedback("launching_application", "", false)
	main.settings.set_audio_volume(0.7)
	main._on_preferences_changed()
	check(station.status == "attention", "Unrelated preferences cannot erase pending launch feedback")
	var restored := Store.new(path)
	check(restored.load_settings() == OK and restored.station_desktop_id("editor") == "safe.desktop", "Only desktop ID is persisted")
	var saved := FileAccess.get_file_as_string(path)
	check(not saved.contains("SafeApp") and not saved.contains("Safe App") and not saved.contains("startup_wm_class"), "Runtime registry data is not persisted")
	main._on_station_mapping_requested("editor", "sh -c arbitrary")
	check(station.desktop_id == "safe.desktop", "Arbitrary command mapping is rejected without mutation")
	main._on_station_mapping_requested("editor", "unknown.desktop")
	check(station.desktop_id == "safe.desktop", "Unknown ID mapping is rejected without mutation")
	var bridge := FakeBridge.new()
	main.backend.add_child(bridge)
	main.backend._bridge = bridge
	main.overlays.back()
	await approach(main)
	main._on_interaction_requested(station)
	check(bridge.lines.size() == 1, "Known mapping sends exactly one fake launch request")
	var request: Dictionary = JSON.parse_string(bridge.lines[0])
	check(request.type == "launch_application" and request.desktop_id == "safe.desktop" and not request.has("exec"), "Wire request contains an ID, never a command")
	main.backend._clear_launch_request()
	main.backend.applications_changed.emit([])
	main._on_interaction_requested(station)
	check(bridge.lines.size() == 1 and station.interaction_prompt().contains("MISSING"), "Registry removal blocks launch while preserving explicit missing feedback")
	main.backend.applications_changed.emit(fixture)
	main._reset_station_mappings()
	check(station.desktop_id == "code.desktop" and main.settings.station_desktop_id("editor").is_empty(), "Station reset restores safe defaults")
	main.reset_preferences()
	check(not FileAccess.file_exists(path), "Fixture settings are removed")
	main.queue_free()
	await process_frame
	var corrupt := FileAccess.open(path, FileAccess.WRITE)
	corrupt.store_string('{"version":1,"stations":{"editor":"sh -c arbitrary"}}')
	corrupt.close()
	main = load("res://scenes/main.tscn").instantiate()
	main.preferences_path = path
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	main._toggle_menu()
	main.pause_panel.show_page("stations")
	check(main.world.get_node("Objects/Workstation").desktop_id == "code.desktop" and main.pause_panel._detail.text.contains("INVALID SAVED ID"), "Malformed persisted mapping falls back visibly, without command execution")
	main.reset_preferences()
	main.queue_free()
	await process_frame
	if not failed: print("D6.12 registry station chooser, safe launch path and persistence passed")
	quit(1 if failed else 0)

func approach(main: Node) -> void:
	main.player.position = Vector2(160, 82)
	main.player.facing = Vector2.UP
	main.player._update_detector_position()
	await physics_frame
	await physics_frame
	main.player.refresh_interaction()
