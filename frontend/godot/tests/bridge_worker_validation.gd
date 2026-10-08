extends SceneTree
## Public GDExtension lifecycle against an isolated peer that never reads.
var failures: Array[String] = []
var connected := false
func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: failures.append(message); push_error(message)
func run() -> void:
	var directory := OS.get_environment("VELORA_BRIDGE_TEST_DIR")
	if directory.is_empty():
		push_error("VELORA_BRIDGE_TEST_DIR must identify the isolated fixture")
		quit(1)
		return
	var bridge: Node = ClassDB.instantiate("VeloraSocketBridge")
	root.add_child(bridge)
	bridge.socket_connected.connect(func(): connected = true)
	bridge.connect_socket(directory.path_join("peer.sock"))
	if OS.get_environment("VELORA_BRIDGE_TEST_MODE") == "backlog":
		await create_timer(0.2).timeout
		var started := Time.get_ticks_msec()
		bridge.disconnect_socket()
		check(Time.get_ticks_msec() - started < 1000, "Disconnect is bounded while the peer's listen backlog is full")
		bridge.queue_free()
		await process_frame
		if failures.is_empty(): print("Native bridge bounded connect shutdown validation passed")
		quit(0 if failures.is_empty() else 1)
		return
	var deadline := Time.get_ticks_msec() + 2000
	while not connected and Time.get_ticks_msec() < deadline: await process_frame
	check(connected, "Fixture socket connects")
	if connected:
		var payload := "x".repeat(65536)
		for _index in range(100): check(bridge.send_line(payload), "Bounded transport accepts valid-size frames")
		await create_timer(0.2).timeout
		var started := Time.get_ticks_msec()
		bridge.disconnect_socket()
		var elapsed := Time.get_ticks_msec() - started
		check(elapsed < 1000, "Disconnect completes within one second under write backpressure")
		check(not bridge.is_socket_connected(), "Disconnect clears connected state")
		print("Bridge backpressure disconnect elapsed ms: ", elapsed)
	bridge.queue_free()
	await process_frame
	if failures.is_empty(): print("Native bridge bounded shutdown validation passed")
	quit(0 if failures.is_empty() else 1)
