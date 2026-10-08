extends SceneTree
## Public backend signals exercise the real HUD and observatory together.
const Overlay = preload("res://ui/overlay_coordinator.gd")
var failed := false

func check(value: bool, message: String) -> void:
	if not value:
		failed = true
		push_error(message)

func text_of(node: Node) -> String:
	var result: String = node.text + "\n" if node is Label else ""
	for child in node.get_children(): result += text_of(child)
	return result

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	main.backend.set_process(false)
	main.backend.state = BackendClient.ConnectionState.READY
	main.backend.state_changed.emit(main.backend.state)
	main.backend.telemetry_availability_changed.emit("available")
	var sample := {"sequence": 1, "sampled_at_unix_ms": 1, "sample_interval_ms": 1000,
		"cpu": {"availability": "warming_up", "utilization_basis_points": null, "logical_cpu_count": 1, "load_1m_milli": 0, "load_5m_milli": 0, "load_15m_milli": 0},
		"memory": {"availability": "available", "total_bytes": 2097152, "used_bytes": 1048576, "available_bytes": 1048576, "cached_bytes": 0, "swap_total_bytes": 0, "swap_used_bytes": 0},
		"disk": {"availability": "warming_up", "read_bytes_per_second": 0, "write_bytes_per_second": 0, "device_count": 1},
		"network": {"availability": "unavailable", "receive_bytes_per_second": 0, "transmit_bytes_per_second": 0, "interface_count": 0}}
	main.backend.telemetry_snapshot_changed.emit(sample)
	main.overlays.open(Overlay.Mode.OBSERVATORY)
	await process_frame
	var hud_text := text_of(main.hud)
	var panel_text := text_of(main.observatory)
	check(hud_text.contains("CPU WARMING") and panel_text.contains("CPU // WARMING"), "Nullable first CPU sample is visibly warming, not zero percent")
	check(hud_text.contains("D WARMING") and panel_text.contains("DISK // WARMING"), "Unsampled disk rates are not presented as measured zero")
	check(hud_text.contains("N UNAVAILABLE") and panel_text.contains("NETWORK // UNAVAILABLE"), "Unavailable network rates have explicit feedback")
	check(hud_text.contains("MEM 50%") and panel_text.contains("MEMORY // 1 / 2 MiB"), "Available memory still displays its measured value")
	if not OS.get_environment("VELORA_TELEMETRY_FRAME").is_empty():
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("VELORA_TELEMETRY_FRAME"))
	sample.cpu.availability = "available"
	sample.cpu.utilization_basis_points = 2500
	sample.disk.availability = "available"
	sample.network.availability = "available"
	main.backend.telemetry_snapshot_changed.emit(sample)
	check(text_of(main.hud).contains("CPU 25%") and text_of(main.observatory).contains("CPU // 25.0%"), "Next measured sample replaces warming feedback")
	sample.cpu.availability = "offline"
	sample.cpu.utilization_basis_points = null
	sample.memory.availability = "unavailable"
	main.backend.telemetry_snapshot_changed.emit(sample)
	check(text_of(main.hud).contains("CPU OFFLINE") and text_of(main.observatory).contains("CPU // OFFLINE"), "Offline nullable CPU is explicit")
	check(text_of(main.hud).contains("MEM UNAVAILABLE") and text_of(main.observatory).contains("MEMORY // UNAVAILABLE"), "Unavailable memory does not leak last measured values as live")
	main.backend.state = BackendClient.ConnectionState.DISCONNECTED
	main.backend.state_changed.emit(main.backend.state)
	check(text_of(main.observatory).contains("STALE //"), "Disconnect preserves stale labeling")
	main.queue_free()
	await process_frame
	if not failed: print("Telemetry HUD/observatory availability validation passed")
	quit(1 if failed else 0)
