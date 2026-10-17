extends SceneTree
## Previously agreed transport/UI and keyboard seams; no live services or IO.
class FixtureBridge:
	extends Node
	signal socket_connected
	signal socket_disconnected(reason: String)
	signal line_received(payload: String)
	signal transport_error(code: String, message: String)
	var requests: Array[Dictionary] = []
	func default_socket_path() -> String: return "/tmp/velora-phase-six-unused.sock"
	func connect_socket(_path: String) -> void: pass
	func disconnect_socket() -> void: pass
	func send_line(payload: String) -> bool:
		requests.append(JSON.parse_string(payload))
		return true
	func last(kind: String) -> Dictionary:
		for index in range(requests.size() - 1, -1, -1):
			if requests[index].type == kind: return requests[index]
		return {}
	func reply(frame: Dictionary) -> void:
		frame["protocol_version"] = BackendClient.PROTOCOL_VERSION
		line_received.emit(JSON.stringify(frame))

var failed := false
func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func text_of(node: Node) -> String:
	var result: String = node.text + "\n" if node is Label else ""
	for child in node.get_children(): result += text_of(child)
	return result

func tap(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	var bridge := FixtureBridge.new()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	main.get_node("BackendClient").bridge_override = bridge
	root.add_child(main)
	await process_frame
	main.backend.set_process(false)
	main.backend.connect_to_core()
	bridge.socket_connected.emit()
	bridge.reply({"type": "welcome", "server_name": "fixture", "server_version": "0.2.0"})
	await tap(KEY_N)
	bridge.reply({"type": "notifications", "request_id": bridge.last("get_notifications").get("request_id", 0), "feed": {"sequence": 0, "notifications": []}})
	check(main.feed_open and text_of(main.notification_feed).contains("NO NOTIFICATIONS"), "The first empty wire feed reaches explicit empty UI, not permanent waiting")
	bridge.socket_disconnected.emit("fixture restart")
	check(text_of(main.notification_feed).contains("CORE OFFLINE"), "Empty feed distinguishes disconnect from a healthy empty feed")
	main.backend.connect_to_core()
	bridge.socket_connected.emit()
	bridge.reply({"type": "welcome", "server_name": "fixture", "server_version": "0.2.0"})
	bridge.reply({"type": "notifications_rejected", "request_id": bridge.last("get_notifications").get("request_id", 0), "code": "notifications_unavailable", "retryable": false, "message": "disabled fixture"})
	check(text_of(main.notification_feed).contains("NOTIFICATIONS DISABLED"), "Reconnect to a default-disabled Core changes empty feed to policy-disabled UI")
	await tap(KEY_ESCAPE)
	await tap(KEY_ESCAPE)
	for index in range(3): await tap(KEY_DOWN)
	await tap(KEY_ENTER)
	for index in range(3): await tap(KEY_DOWN)
	await tap(KEY_ENTER)
	var registry: Array[Dictionary] = []
	for index in range(600): registry.append({"id": "fixture-%04d.desktop" % index, "name": "App %04d" % index})
	main.backend.applications_changed.emit(registry)
	await tap(KEY_ENTER)
	await tap(KEY_END)
	check(text_of(main.pause_panel).contains("513/513") and text_of(main.pause_panel).contains("ID // fixture-0511.desktop"), "Keyboard reaches the last bounded chooser entry with 600 registry applications")
	registry[511].name = "A renamed fixture"
	main.backend.applications_changed.emit(registry)
	check(text_of(main.pause_panel).contains("ID // fixture-0511.desktop"), "Live registry reorder preserves the selected desktop ID")
	await tap(KEY_ENTER)
	check(main.world.get_node("Objects/Workstation").desktop_id == "fixture-0511.desktop", "Keyboard confirms the same selected ID after live reorder")
	check(bridge.last("launch_application").is_empty(), "Browsing and choosing a mapping never launches an application")
	main.queue_free()
	await process_frame
	if not failed: print("D6.13 first-empty feed and crowded keyboard chooser acceptance passed")
	quit(1 if failed else 0)
