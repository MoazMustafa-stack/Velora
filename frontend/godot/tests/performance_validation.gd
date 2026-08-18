extends SceneTree

const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 600
const MIN_AVERAGE_FPS := 55.0
const MAX_P95_FRAME_MS := 25.0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		push_error("P1.10 could not load the main scene")
		quit(1)
		return

	var main := packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	var adapter := RenderingServer.get_video_adapter_name()
	var renderer := RenderingServer.get_current_rendering_method()
	var display_driver := DisplayServer.get_name()
	if adapter.is_empty() or adapter.to_lower().contains("dummy"):
		push_error("P1.10 requires a real graphics adapter, got: " + adapter)
		quit(1)
		return

	for _frame in range(WARMUP_FRAMES):
		await process_frame

	var frame_times: Array[float] = []
	var previous_usec := Time.get_ticks_usec()
	for frame in range(SAMPLE_FRAMES):
		_apply_workload(frame)
		await process_frame
		var now_usec := Time.get_ticks_usec()
		frame_times.append(float(now_usec - previous_usec) / 1000.0)
		previous_usec = now_usec
	_release_movement()

	var total_ms := 0.0
	for frame_ms in frame_times:
		total_ms += frame_ms
	var average_ms := total_ms / frame_times.size()
	var average_fps := 1000.0 / average_ms
	var sorted_times := frame_times.duplicate()
	sorted_times.sort()
	var p95_index := clampi(int(ceil(sorted_times.size() * 0.95)) - 1, 0, sorted_times.size() - 1)
	var p95_ms: float = sorted_times[p95_index]
	var maximum_ms: float = sorted_times[-1]
	var passed := average_fps >= MIN_AVERAGE_FPS and p95_ms <= MAX_P95_FRAME_MS

	var report := {
		"card": "P1.10",
		"passed": passed,
		"adapter": adapter,
		"renderer": renderer,
		"display_driver": display_driver,
		"resolution": "320x180 internal / 960x540 window",
		"sample_frames": SAMPLE_FRAMES,
		"average_fps": snappedf(average_fps, 0.01),
		"average_frame_ms": snappedf(average_ms, 0.01),
		"p95_frame_ms": snappedf(p95_ms, 0.01),
		"maximum_frame_ms": snappedf(maximum_ms, 0.01),
		"minimum_average_fps": MIN_AVERAGE_FPS,
		"maximum_p95_frame_ms": MAX_P95_FRAME_MS,
	}
	var report_path := OS.get_environment("VELORA_PERF_REPORT")
	if report_path.is_empty():
		report_path = "/tmp/velora-performance.json"
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file:
		report_file.store_string(JSON.stringify(report, "\t") + "\n")

	print("P1.10 integrated graphics report: ", JSON.stringify(report))
	if passed:
		print("P1.10 performance validation passed.")
		quit(0)
	else:
		push_error("P1.10 performance validation failed")
		quit(1)

func _apply_workload(frame: int) -> void:
	_release_movement()
	Input.action_press("sprint")
	match (frame / 150) % 4:
		0:
			Input.action_press("move_right")
		1:
			Input.action_press("move_down")
		2:
			Input.action_press("move_left")
		3:
			Input.action_press("move_up")

func _release_movement() -> void:
	for action in ["move_up", "move_down", "move_left", "move_right", "sprint"]:
		Input.action_release(action)
