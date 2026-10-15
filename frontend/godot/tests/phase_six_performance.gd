extends SceneTree
## Bounded synthetic UI workload: no live transport, content, preferences or audio.
const Overlay = preload("res://ui/overlay_coordinator.gd")
const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 600
const MIN_FPS := 55.0
const MAX_P95_MS := 25.0
var main: Node
var notes: Array[Dictionary] = []
var players: Array[Dictionary] = []
var session := {"sequence": 1, "workspaces": [], "windows": []}
var registry: Array[Dictionary] = []
var telemetry := {"sequence": 1, "sampled_at_unix_ms": 1, "sample_interval_ms": 1000,
	"cpu": {"availability": "warming_up", "utilization_basis_points": null},
	"memory": {"availability": "available", "used_bytes": 1048576000, "total_bytes": 2097152000},
	"disk": {"availability": "available", "read_bytes_per_second": 999999999999, "write_bytes_per_second": 999999999999},
	"network": {"availability": "available", "receive_bytes_per_second": 999999999999, "transmit_bytes_per_second": 999999999999}}

func _initialize() -> void: call_deferred("run")

func run() -> void:
	if DisplayServer.get_name() == "headless" or RenderingServer.get_video_adapter_name().is_empty():
		push_error("D6.13 performance requires a real rendered session")
		quit(1)
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.load_preferences = false
	main.get_node("BackendClient").auto_connect = false
	root.add_child(main)
	await process_frame
	main.backend.set_process(false)
	main.ui_audio.enabled = false
	main.backend.state = BackendClient.ConnectionState.READY
	main.backend.state_changed.emit(main.backend.state)
	main.backend.ux_status_changed.emit("ready", "SYNTHETIC BENCHMARK", "ready", -1.0)
	for signal_name in ["session_availability_changed", "telemetry_availability_changed", "media_availability_changed", "notifications_availability_changed"]:
		main.backend.emit_signal(signal_name, "available")
	for index in range(32):
		notes.append({"handle": "n-%d" % index, "app_name": "Fixture", "summary": "Synthetic summary ".repeat(8), "body": "Synthetic body ".repeat(8), "urgency": "critical", "timestamp_unix_ms": index})
	for index in range(16):
		players.append({"handle": "p-%d" % index, "identity": "Fixture player ".repeat(8), "title": "Synthetic title ".repeat(12), "artist": "Fixture artist", "status": "playing", "can_control": true})
	for index in range(20):
		session.workspaces.append({"handle": "w-%d" % index, "index": index, "name": "Synthetic workspace ".repeat(8), "monitor": "Fixture", "window_count": 99, "is_active": index == 0})
	for index in range(600):
		registry.append({"id": "fixture-%04d.desktop" % index, "name": "Synthetic application ".repeat(8)})
	main.backend.applications_changed.emit(registry)
	update_snapshots(0)
	for frame in range(WARMUP_FRAMES):
		apply_workload(frame)
		await process_frame
	var timings: Array[float] = []
	var previous := Time.get_ticks_usec()
	for frame in range(SAMPLE_FRAMES):
		apply_workload(frame)
		await process_frame
		var now := Time.get_ticks_usec()
		timings.append(float(now - previous) / 1000.0)
		previous = now
	release_movement()
	main.overlays.back()
	var sorted := timings.duplicate()
	sorted.sort()
	var total := 0.0
	for timing in timings: total += timing
	var fps := 1000.0 * timings.size() / total
	var p95: float = sorted[int(ceil(sorted.size() * 0.95)) - 1]
	var report := {"card": "D6.13", "passed": fps >= MIN_FPS and p95 <= MAX_P95_MS,
		"adapter": RenderingServer.get_video_adapter_name(), "renderer": RenderingServer.get_current_rendering_method(), "display_driver": DisplayServer.get_name(),
		"sample_frames": SAMPLE_FRAMES, "average_fps": snappedf(fps, 0.01), "p95_frame_ms": snappedf(p95, 0.01), "maximum_frame_ms": snappedf(sorted[-1], 0.01),
		"minimum_average_fps": MIN_FPS, "maximum_p95_frame_ms": MAX_P95_MS,
		"workload": "movement; feed32; media16; map20; chooser600 capped512; nullable telemetry; snapshots every6 frames; registry every30 frames",
		"scope": "UI-bound synthetic stress, not live transport or wire-budget validation; preferences/backend/audio disabled"}
	var path := OS.get_environment("VELORA_PHASE_SIX_PERF_REPORT")
	if path.is_empty(): path = "/tmp/velora-phase-six-performance.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot save D6.13 performance report")
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print("D6.13 crowded UI report: ", JSON.stringify(report))
	main.queue_free()
	await process_frame
	quit(0 if report.passed else 1)

func update_snapshots(frame: int) -> void:
	telemetry.cpu.availability = "warming_up" if frame % 12 == 0 else "available"
	telemetry.cpu.utilization_basis_points = null if frame % 12 == 0 else 5023
	main.backend.telemetry_snapshot_changed.emit(telemetry)
	main.backend.notification_feed_changed.emit({"sequence": frame, "notifications": notes})
	main.backend.media_snapshot_changed.emit({"sequence": frame, "players": players, "active_player_handle": "p-0"})
	main.backend.session_snapshot_changed.emit(session)

func apply_workload(frame: int) -> void:
	release_movement()
	if frame % 6 == 0: update_snapshots(frame)
	if frame % 30 == 0: main.backend.applications_changed.emit(registry)
	# Include opening/closing and chooser rebuild costs inside the measured window.
	if frame % 100 == 0:
		match frame / 100:
			0: main.overlays.back()
			1: main.overlays.open(Overlay.Mode.NOTIFICATIONS)
			2: main.overlays.open(Overlay.Mode.MEDIA)
			3: main.overlays.open(Overlay.Mode.WORKSPACES)
			4:
				main.overlays.open(Overlay.Mode.PAUSE)
				main.pause_panel.show_page("station_choice")
			5: main.overlays.open(Overlay.Mode.OBSERVATORY)
	if frame < 100:
		Input.action_press("move_right" if frame % 60 < 30 else "move_left")
		Input.action_press("sprint")

func release_movement() -> void:
	for action in ["move_up", "move_down", "move_left", "move_right", "sprint"]: Input.action_release(action)
