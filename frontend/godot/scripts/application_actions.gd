extends RefCounted
## Explicit session-only intents. BackendClient owns request IDs, the single
## pending request, timeouts and reconnect; Core alone owns launch policy.
signal changed
signal feedback_changed(id: String, stage: String, message: String, retryable: bool)
const Store = preload("res://scripts/settings_store.gd")
const Text = preload("res://scripts/display_text.gd")
var _peer: Node
var _ids: Dictionary = {}
var _registry_current := false
# One latest display result, never a request queue or persisted launch history.
var _feedback: Dictionary = {}

func _init(peer: Node) -> void:
	_peer = peer
	_peer.state_changed.connect(_on_state_changed)
	_peer.launch_status_changed.connect(_on_feedback)

func set_registry(registry: Dictionary) -> void:
	_ids.clear()
	for id in registry:
		if id is String and Store._valid_desktop_id(id) and registry[id] is Dictionary and registry[id].get("id") == id:
			_ids[id] = true
	_registry_current = _peer.state == BackendClient.ConnectionState.READY
	# A complete fresh catalog is a deliberate opportunity to revalidate a
	# repaired installation. Recoverable feedback remains useful across refresh.
	if _registry_current and _feedback.get("stage") == "launch_failed" and not _feedback.get("retryable", false):
		_feedback.clear()
	changed.emit()

func describe(id: String) -> Dictionary:
	var reason := ""
	var label := "LAUNCH"
	if _peer.state != BackendClient.ConnectionState.READY:
		reason = "CORE OFFLINE // RECONNECT FIRST"
	elif not _registry_current:
		reason = "WAIT FOR FRESH REGISTRY"
	elif not Store._valid_desktop_id(id) or not _ids.has(id):
		reason = "APPLICATION UNAVAILABLE"
	elif not _peer.pending_launch_id().is_empty():
		label = "LAUNCHING" if _peer.pending_launch_id() == id else "BUSY"
		reason = "LAUNCH ALREADY IN PROGRESS"
	elif _feedback.get("desktop_id") == id and _feedback.get("stage") == "launch_failed":
		if _feedback.get("retryable", false): label = "RETRY"
		else: reason = "UNAVAILABLE // " + _feedback.get("message", "REJECTED BY CORE")
	return {"enabled": reason.is_empty(), "label": label if reason.is_empty() or label in ["BUSY", "LAUNCHING"] else "UNAVAILABLE", "reason": reason}

func request_launch(id: String) -> String:
	# Busy confirmation is consumed without asking BackendClient to reject it,
	# preserving the original pending action and its useful feedback.
	if not _peer.pending_launch_id().is_empty(): return "pending"
	var intent := describe(id)
	if not intent.enabled:
		_on_feedback(id, "launch_failed", intent.reason, _peer.state != BackendClient.ConnectionState.READY)
		return "rejected"
	var sent: bool = _peer.launch_app(id)
	return "pending" if sent else "rejected"

func feedback_for(id: String) -> Dictionary:
	return _feedback.duplicate() if _feedback.get("desktop_id", "") == id else {}

func _on_state_changed(_state: int) -> void:
	# Even READY must receive a new accepted registry; no cached intent replay.
	_registry_current = false
	changed.emit()

func _on_feedback(id: String, stage: String, message: String, retryable: bool) -> void:
	_feedback = {"desktop_id": id.left(255), "stage": stage, "message": Text.single_line(message, 160), "retryable": retryable}
	feedback_changed.emit(id, stage, _feedback.message, retryable)
	changed.emit()
