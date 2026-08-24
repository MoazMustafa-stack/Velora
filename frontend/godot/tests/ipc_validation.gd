extends SceneTree

var failures: Array[String] = []
var rejected_desktop_id := ""
var rejection_code := ""
var rejection_retryable := true

func _on_launch_rejected(desktop_id: String, code: String, _message: String, retryable: bool) -> void:
	rejected_desktop_id = desktop_id
	rejection_code = code
	rejection_retryable = retryable

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)

func _wait_until(predicate: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false

func _write_marker(name: String) -> void:
	var test_dir := OS.get_environment("VELORA_IPC_TEST_DIR")
	if test_dir.is_empty():
		failures.append("VELORA_IPC_TEST_DIR is required")
		return
	var marker := FileAccess.open(test_dir.path_join(name), FileAccess.WRITE)
	if marker == null:
		failures.append("cannot write integration marker: " + name)
		return
	marker.store_line("ready")
	marker.close()

func _run() -> void:
	_check(ClassDB.class_exists("VeloraSocketBridge"), "P2.03 native bridge is registered")
	var backend := BackendClient.new()
	root.add_child(backend)
	backend.launch_rejected.connect(_on_launch_rejected)
	var ready := await _wait_until(func(): return backend.state == BackendClient.ConnectionState.READY, 5.0)
	_check(ready, "P2.04 client completes hello/welcome handshake")
	_check(backend.connected and backend.welcome_received, "P2.04 ready state reflects a validated welcome")
	var registry_ready := await _wait_until(func(): return backend.applications.size() == 35, 3.0)
	_check(registry_ready, "P2.07 frontend assembles the paginated application registry")
	if registry_ready:
		var application: Dictionary = {}
		for candidate in backend.applications:
			if candidate.get("id") == "velora-test.desktop":
				application = candidate
				break
		_check(not application.is_empty(), "P2.07 registry contains the requested desktop ID")
		_check(application.get("id") == "velora-test.desktop", "P2.07 preserves the desktop ID")
		_check(application.get("name") == "Velora Test Application", "P2.07 preserves the display name")
		_check(
			application.get("exec") == "/usr/bin/velora-test-never-launch %F",
			"P2.07 keeps Exec opaque"
		)
		_check(application.get("categories") == ["Utility", "Test"], "P2.07 preserves categories")
		_check(backend.launch_app("missing.desktop"), "P2.09 sends a launch request for rejection feedback")
		var rejection_ready := await _wait_until(func(): return not rejection_code.is_empty(), 3.0)
		_check(rejection_ready, "P2.09 Core returns a correlated launch rejection")
		_check(rejected_desktop_id == "missing.desktop", "P2.09 rejection preserves the desktop ID")
		_check(rejection_code == "unknown_application", "P2.09 rejection preserves the policy code")
		_check(not rejection_retryable, "P2.09 permanent policy failures are not marked retryable")
	_check(backend.request_ping(), "P2.04 client sends a typed ping")
	var pong := await _wait_until(func(): return backend.last_pong_request_id > 0, 3.0)
	_check(pong, "P2.04 core returns the matching pong")

	# The shell harness stops Core only after this marker appears. From here on,
	# every transition is produced by the real native socket worker.
	_write_marker("frontend-ready")
	var reconnecting := await _wait_until(
		func(): return backend.state == BackendClient.ConnectionState.RECONNECTING,
		5.0
	)
	_check(reconnecting, "P2.10 stopping Core enters reconnect backoff")
	_write_marker("frontend-reconnecting")
	var reconnected := await _wait_until(
		func(): return backend.state == BackendClient.ConnectionState.READY,
		10.0
	)
	_check(reconnected, "P2.10 client reconnects after Core restarts")
	_check(backend.connected and backend.welcome_received, "P2.10 restarted handshake is ready")
	var registry_reloaded := await _wait_until(func(): return backend.applications.size() == 35, 3.0)
	_check(registry_reloaded, "P2.10 registry reloads after a real Core restart")

	backend.disconnect_from_core()
	await process_frame
	_check(backend.state == BackendClient.ConnectionState.DISCONNECTED, "P2.04 explicit disconnect is clean")

	if failures.is_empty():
		print("P2.10 live restart and IPC validation passed.")
		quit(0)
	else:
		push_error("PR 4 IPC validation failed: %s" % [failures])
		quit(1)
