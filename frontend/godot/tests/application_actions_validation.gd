extends SceneTree
## Agreed seam: explicit launch intent -> fake transport adapter. Never launches.
class Peer extends Node:
	signal state_changed(state: int)
	signal launch_status_changed(id: String, stage: String, message: String, retryable: bool)
	var state := BackendClient.ConnectionState.DISCONNECTED
	var sent: Array[String] = []
	var pending := ""
	func pending_launch_id() -> String: return pending
	func launch_app(id: String) -> bool:
		sent.append(id)
		pending = id
		launch_status_changed.emit(id, "launching_application", "LAUNCHING", false)
		return true
	func finish(id: String, stage: String, retryable := false) -> void:
		pending = ""
		launch_status_changed.emit(id, stage, "Synthetic result", retryable)
var problems: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value: problems.append(message); push_error(message)
func run() -> void:
	var script = load("res://scripts/application_actions.gd")
	if script == null:
		check(false, "Explicit launch intent has a shared dispatcher")
		quit(1)
		return
	var peer := Peer.new()
	var actions = script.new(peer)
	actions.set_registry({"a.desktop": {"id": "a.desktop"}})
	check(actions.request_launch("a.desktop") == "rejected" and peer.sent.is_empty(), "Offline intent sends zero requests")
	peer.state = BackendClient.ConnectionState.READY
	peer.state_changed.emit(peer.state)
	actions.set_registry({"a.desktop": {"id": "a.desktop"}})
	check(actions.request_launch("unknown.desktop") == "rejected" and peer.sent.is_empty(), "Unknown identity sends zero requests")
	check(actions.request_launch("a.desktop") == "pending" and peer.sent == ["a.desktop"], "Eligible identity starts exactly one transport request")
	check(actions.request_launch("a.desktop") == "pending" and peer.sent.size() == 1, "Repeated pending confirmation cannot enqueue duplicates")
	peer.finish("a.desktop", "launch_failed", false)
	check(not actions.describe("a.desktop").enabled and actions.feedback_for("b.desktop").is_empty(), "Permanent rejection is not offered as retry or attributed to B")
	actions.set_registry({"a.desktop": {"id": "a.desktop"}})
	check(actions.describe("a.desktop").enabled, "Fresh accepted registry permits a new explicit launch after policy repair")
	actions.request_launch("a.desktop")
	peer.finish("a.desktop", "launch_failed", true)
	check(actions.describe("a.desktop").label == "RETRY" and peer.sent.size() == 2, "Retryable failure offers explicit retry without automatic replay")
	actions.request_launch("a.desktop")
	peer.finish("a.desktop", "launch_successful")
	check(actions.feedback_for("a.desktop").stage == "launch_successful" and peer.sent.size() == 3, "Accepted spawn is feedback, never an inferred running window")
	actions.request_launch("a.desktop")
	peer.finish("a.desktop", "launch_failed", true)
	peer.state = BackendClient.ConnectionState.RECONNECTING
	peer.state_changed.emit(peer.state)
	peer.state = BackendClient.ConnectionState.READY
	peer.state_changed.emit(peer.state)
	check(not actions.describe("a.desktop").enabled and peer.sent.size() == 4, "Reconnect invalidates registry authority and never replays a launch")
	actions.set_registry({})
	check(not actions.describe("a.desktop").enabled, "Accepted removal revokes launch eligibility")
	peer.free()
	if problems.is_empty(): print("R6.06 application actions validation passed")
	quit(0 if problems.is_empty() else 1)
