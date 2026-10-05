extends SceneTree
const Empty = preload("res://ui/empty_states.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var feed = load("res://ui/notification_feed.gd").new()
	root.add_child(feed)
	feed.set_availability("available")
	check(feed._rows[0].summary.text == "NO NOTIFICATIONS", "Available-but-empty is explicit")
	feed.set_availability("unavailable")
	check(feed._rows[0].summary.text == "FEED UNAVAILABLE", "Unavailable is not empty")
	feed.set_policy_disabled(true)
	check(feed._rows[0].summary.text == "NOTIFICATIONS DISABLED", "Disabled is not unavailable")
	feed.update_feed({"notifications": [{"handle": "fake", "summary": "PRIVATE FIXTURE", "app_name": "Fixture", "urgency": "normal"}]})
	check(not feed._rows[0].summary.text.contains("PRIVATE"), "Disabled feed never displays last-good content")
	feed.set_core_online(false)
	check(not feed._rows[0].summary.text.contains("PRIVATE"), "Disconnect cannot reveal policy-disabled content")
	check(feed._counter.text == "0/0", "Disabled policy also hides cached entry count when offline")
	feed.set_policy_disabled(false)
	check(feed._rows[0].detail.text.begins_with("STALE"), "Offline populated state is visibly stale")
	feed.set_core_online(true)
	feed.set_policy_disabled(false)
	feed.set_availability("available")
	check(not feed._rows[0].detail.text.begins_with("STALE"), "Recovery restores live presentation")
	var client := BackendClient.new()
	client._notifications_request_id = 7
	client._on_notifications_rejected({"request_id": 8, "code": "notifications_unavailable", "retryable": false})
	check(not client.notifications_policy_disabled, "Uncorrelated policy response ignored")
	client._on_notifications_rejected({"request_id": 7, "code": "notifications_unavailable", "retryable": false})
	check(client.notifications_policy_disabled, "Existing non-retryable v5 response identifies policy-off")
	client._notifications_request_id = 9
	client._on_notifications_rejected({"request_id": 9, "code": "notifications_unavailable", "retryable": true})
	check(not client.notifications_policy_disabled, "Retryable unavailable monitor is not reported disabled")
	client.free()
	for topic in ["notifications", "media", "workspaces", "registry"]:
		var state := Empty.describe(topic, "offline")
		check(not state.title.is_empty() and not state.detail.is_empty(), "Empty states give cause and next action")
	feed.queue_free()
	await process_frame
	if failures.is_empty():
		print("D6.07 empty states validation passed.")
	quit(0 if failures.is_empty() else 1)
