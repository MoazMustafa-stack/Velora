extends RefCounted
## Session-local progress; only dismissal/completion is persisted by Main.
const Actions = preload("res://scripts/input_actions.gd")
const STEPS := ["move", "interact", "pause", "map", "feed", "media"]
signal changed
signal completed
var active := true
var _seen: Dictionary = {}

func _init(already_completed: bool = false) -> void:
	active = not already_completed

func observe(step: String) -> void:
	if not active or step not in STEPS or _seen.has(step):
		return
	_seen[step] = true
	if _seen.size() == STEPS.size():
		dismiss()
	else:
		changed.emit()

func dismiss() -> void:
	if not active:
		return
	active = false
	changed.emit()
	completed.emit()

func replay() -> void:
	_seen.clear()
	active = true
	changed.emit()

func hint() -> String:
	if not active:
		return "%s HELP  %s MAP  %s FEED  %s MEDIA" % [Actions.binding_label("menu"),
			Actions.binding_label("workspace_map"), Actions.binding_label("notification_feed"), Actions.binding_label("media_console")]
	for step in STEPS:
		if _seen.has(step):
			continue
		match step:
			"move": return "FIRST STEPS // %s/%s/%s/%s MOVE" % [Actions.binding_label("move_up", 1), Actions.binding_label("move_left", 1), Actions.binding_label("move_down", 1), Actions.binding_label("move_right", 1)]
			"interact": return "WALK TO A STATION // %s INTERACT" % Actions.binding_label("interact")
			"pause": return "%s PAUSE // HELP OR SKIP HINTS" % Actions.binding_label("menu")
			"map": return "%s WORKSPACE MAP // %s BACK" % [Actions.binding_label("workspace_map"), Actions.binding_label("back")]
			"feed": return "%s FEED // MONITOR IS OPT-IN" % Actions.binding_label("notification_feed")
			"media": return "%s MEDIA // OPEN A PLAYER FIRST" % Actions.binding_label("media_console")
	return ""
