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

func _wait_until(predicate: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false

func _run() -> void:
	_check(ClassDB.class_exists("VeloraSocketBridge"), "P2.03 native bridge is registered")
	var backend := BackendClient.new()
	root.add_child(backend)
	var ready := await _wait_until(func(): return backend.state == BackendClient.ConnectionState.READY, 5.0)
	_check(ready, "P2.04 client completes hello/welcome handshake")
	_check(backend.connected and backend.welcome_received, "P2.04 ready state reflects a validated welcome")
	_check(backend.request_ping(), "P2.04 client sends a typed ping")
	var pong := await _wait_until(func(): return backend.last_pong_request_id > 0, 3.0)
	_check(pong, "P2.04 core returns the matching pong")

	# Feed the client the same event the native bridge emits after a broken
	# socket. The retry must replace the old worker, reconnect, and handshake.
	backend._on_socket_disconnected("validation disconnect")
	_check(
		backend.state == BackendClient.ConnectionState.RECONNECTING,
		"P2.05 unexpected disconnect enters reconnect backoff"
	)
	var reconnected := await _wait_until(
		func(): return backend.state == BackendClient.ConnectionState.READY,
		3.0
	)
	_check(reconnected, "P2.05 client reconnects and handshakes again")
	_check(backend.connected and backend.welcome_received, "P2.05 reconnected client is ready")

	backend.disconnect_from_core()
	await process_frame
	_check(backend.state == BackendClient.ConnectionState.DISCONNECTED, "P2.04 explicit disconnect is clean")

	if failures.is_empty():
		print("PR 3 native IPC validation passed.")
		quit(0)
	else:
		push_error("PR 3 IPC validation failed: %s" % failures)
		quit(1)
