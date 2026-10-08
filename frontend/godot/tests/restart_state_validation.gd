extends SceneTree
## Exercise client lifecycle through its transport boundary, never private handlers.
class FakeBridge:
	extends Node
	signal socket_connected
	signal socket_disconnected(reason: String)
	signal line_received(payload: String)
	signal transport_error(code: String, message: String)
	var requests: Array[Dictionary] = []
	func default_socket_path() -> String: return "/tmp/velora-restart-fixture-unused.sock"
	func connect_socket(_path: String) -> void: pass
	func disconnect_socket() -> void: pass
	func send_line(payload: String) -> bool:
		requests.append(JSON.parse_string(payload))
		return true
	func last(kind: String) -> Dictionary:
		for index in range(requests.size() - 1, -1, -1):
			if requests[index].type == kind: return requests[index]
		return {}
	func reply(message: Dictionary) -> void:
		message["protocol_version"] = BackendClient.PROTOCOL_VERSION
		line_received.emit(JSON.stringify(message))

var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)
func _initialize() -> void: call_deferred("run")
func welcome(backend: Node, bridge: Node) -> void:
	backend.connect_to_core()
	bridge.socket_connected.emit()
	bridge.reply({"type":"welcome","server_name":"fixture","server_version":"0.2.0"})

func snapshots(bridge: Node, sequence: int) -> void:
	bridge.reply({"type":"workspace_snapshot","request_id":bridge.last("get_workspace_snapshot").get("request_id",0),"snapshot":{"sequence":sequence,"workspaces":[],"windows":[]}})
	bridge.reply({"type":"media_snapshot","request_id":bridge.last("get_media_snapshot").get("request_id",0),"snapshot":{"sequence":sequence,"players":[]}})
	bridge.reply({"type":"notifications","request_id":bridge.last("get_notifications").get("request_id",0),"feed":{"sequence":sequence,"notifications":[]}})
	bridge.reply({"type":"telemetry_snapshot","request_id":bridge.last("get_telemetry_snapshot").get("request_id",0),"snapshot":{"sequence":sequence,"sampled_at_unix_ms":1,"sample_interval_ms":1000,
		"cpu":{"availability":"available","utilization_basis_points":100,"logical_cpu_count":1,"load_1m_milli":0,"load_5m_milli":0,"load_15m_milli":0},
		"memory":{"availability":"available","total_bytes":1024,"available_bytes":512,"used_bytes":512,"cached_bytes":0,"swap_total_bytes":0,"swap_used_bytes":0},
		"disk":{"availability":"available","read_bytes_per_second":0,"write_bytes_per_second":0,"device_count":0},
		"network":{"availability":"available","receive_bytes_per_second":0,"transmit_bytes_per_second":0,"interface_count":0}}})

func run() -> void:
	var bridge := FakeBridge.new()
	var backend := BackendClient.new()
	backend.auto_connect = false
	backend.bridge_override = bridge
	root.add_child(backend)
	backend.set_process(false)
	welcome(backend, bridge)
	snapshots(bridge, 10)
	check(backend.session_snapshot.get("sequence") == 10, "First connection accepts workspace state")
	bridge.socket_disconnected.emit("fixture Core restarted")
	check(backend.session_snapshot.get("sequence") == 10, "Last useful workspace state remains cached offline")
	bridge.requests.clear()
	welcome(backend, bridge)
	check(not bridge.last("get_workspace_snapshot").is_empty(), "Every connection requests workspace state to restore its push subscription")
	snapshots(bridge, 1)
	for pair in [[backend.session_snapshot,"workspace"], [backend.media_snapshot,"media"], [backend.notification_feed,"notifications"], [backend.telemetry_snapshot,"telemetry"]]:
		check(pair[0].get("sequence") == 1, "Restarted Core's fresh lower sequence replaces cached " + pair[1])
	bridge.reply({"type":"workspace_snapshot","request_id":0,"snapshot":{"sequence":2,"workspaces":[],"windows":[]}})
	bridge.reply({"type":"media_snapshot","request_id":0,"snapshot":{"sequence":2,"players":[]}})
	bridge.reply({"type":"notifications","request_id":0,"feed":{"sequence":2,"notifications":[]}})
	for kind in ["workspace_snapshot", "media_snapshot", "notifications"]:
		var body := {"sequence":1,"workspaces":[],"windows":[]} if kind == "workspace_snapshot" else {"sequence":1,"players":[]} if kind == "media_snapshot" else {"sequence":1,"notifications":[]}
		var frame := {"type":kind,"request_id":0}
		frame["feed" if kind == "notifications" else "snapshot"] = body
		bridge.reply(frame)
	check(backend.session_snapshot.sequence == 2 and backend.media_snapshot.sequence == 2 and backend.notification_feed.sequence == 2, "Older pushes inside one connection are still fenced out")
	backend.request_telemetry_snapshot()
	var pending: int = bridge.last("get_telemetry_snapshot").request_id
	bridge.socket_disconnected.emit("fixture disconnect with telemetry pending")
	bridge.requests.clear()
	welcome(backend, bridge)
	check(int(bridge.last("get_telemetry_snapshot").get("request_id",0)) > pending, "Reconnect replaces an in-flight telemetry request instead of stranding it")
	backend.queue_free()
	await process_frame
	if failures.is_empty(): print("Restart state lifecycle validation passed")
	quit(0 if failures.is_empty() else 1)
