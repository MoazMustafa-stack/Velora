extends RefCounted
## Shared defaults. Existing bindings are never overwritten by registration.
## Context decides which actions are active (N is next only inside media).

const DEFAULTS := {
	"move_up": [KEY_W, KEY_UP], "move_down": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
	"sprint": [KEY_SHIFT], "interact": [KEY_E, KEY_ENTER],
	"menu": [KEY_ESCAPE], "back": [KEY_ESCAPE],
	"workspace_map": [KEY_TAB, KEY_M], "notification_feed": [KEY_N],
	"media_console": [KEY_P], "confirm": [KEY_ENTER, KEY_KP_ENTER],
	"focus_inspector": [KEY_F],
	"nav_up": [KEY_UP, KEY_W], "nav_down": [KEY_DOWN, KEY_S],
	"nav_left": [KEY_LEFT, KEY_A], "nav_right": [KEY_RIGHT, KEY_D],
	"page_up": [KEY_PAGEUP], "page_down": [KEY_PAGEDOWN],
	"first": [KEY_HOME], "last": [KEY_END],
	"media_toggle": [KEY_SPACE, KEY_E, KEY_ENTER, KEY_KP_ENTER],
	"media_next": [KEY_N, KEY_RIGHT, KEY_D],
	"media_previous": [KEY_B, KEY_LEFT, KEY_A],
	"media_stop": [KEY_X], "media_play": [KEY_KP_0], "media_pause": [KEY_KP_2],
}
const PAD_BUTTONS := {
	"move_up": JOY_BUTTON_DPAD_UP, "move_down": JOY_BUTTON_DPAD_DOWN,
	"move_left": JOY_BUTTON_DPAD_LEFT, "move_right": JOY_BUTTON_DPAD_RIGHT,
	"sprint": JOY_BUTTON_LEFT_STICK, "interact": JOY_BUTTON_A,
	"menu": JOY_BUTTON_START, "back": JOY_BUTTON_B,
	"workspace_map": JOY_BUTTON_Y, "notification_feed": JOY_BUTTON_LEFT_SHOULDER,
	"media_console": JOY_BUTTON_RIGHT_SHOULDER, "confirm": JOY_BUTTON_A,
	"nav_up": JOY_BUTTON_DPAD_UP, "nav_down": JOY_BUTTON_DPAD_DOWN,
	"nav_left": JOY_BUTTON_DPAD_LEFT, "nav_right": JOY_BUTTON_DPAD_RIGHT,
	"first": JOY_BUTTON_RIGHT_STICK, "last": JOY_BUTTON_BACK,
	"media_toggle": JOY_BUTTON_A, "media_next": JOY_BUTTON_DPAD_RIGHT,
	"media_previous": JOY_BUTTON_DPAD_LEFT, "media_stop": JOY_BUTTON_Y,
	"media_play": JOY_BUTTON_X, "media_pause": JOY_BUTTON_LEFT_STICK,
}
const PAD_AXES := {
	"move_up": [JOY_AXIS_LEFT_Y, -1.0], "move_down": [JOY_AXIS_LEFT_Y, 1.0],
	"move_left": [JOY_AXIS_LEFT_X, -1.0], "move_right": [JOY_AXIS_LEFT_X, 1.0],
	"nav_up": [JOY_AXIS_LEFT_Y, -1.0], "nav_down": [JOY_AXIS_LEFT_Y, 1.0],
	"nav_left": [JOY_AXIS_LEFT_X, -1.0], "nav_right": [JOY_AXIS_LEFT_X, 1.0],
	"media_next": [JOY_AXIS_LEFT_X, 1.0], "media_previous": [JOY_AXIS_LEFT_X, -1.0],
	"page_up": [JOY_AXIS_TRIGGER_LEFT, 1.0], "page_down": [JOY_AXIS_TRIGGER_RIGHT, 1.0],
}
const PAD_LABELS := {JOY_BUTTON_A: "Pad A", JOY_BUTTON_B: "Pad B", JOY_BUTTON_X: "Pad X", JOY_BUTTON_Y: "Pad Y",
	JOY_BUTTON_START: "Start", JOY_BUTTON_BACK: "Select", JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB",
	JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3", JOY_BUTTON_DPAD_UP: "DUp", JOY_BUTTON_DPAD_DOWN: "DDown",
	JOY_BUTTON_DPAD_LEFT: "DLeft", JOY_BUTTON_DPAD_RIGHT: "DRight"}
static var controller_labels := false
static var active_device := -1
static var _axis_transitions: Dictionary = {}

static func ensure_registered() -> void:
	for action in DEFAULTS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		if not InputMap.action_get_events(action).is_empty():
			continue
		for key in DEFAULTS[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key
			InputMap.action_add_event(action, event)
	for action in DEFAULTS:
		InputMap.action_set_deadzone(action, 0.45)
		if PAD_BUTTONS.has(action):
			var button := InputEventJoypadButton.new()
			button.device = -1
			button.button_index = PAD_BUTTONS[action]
			if not InputMap.action_has_event(action, button): InputMap.action_add_event(action, button)
		if PAD_AXES.has(action):
			var axis := InputEventJoypadMotion.new()
			axis.device = -1
			axis.axis = PAD_AXES[action][0]
			axis.axis_value = PAD_AXES[action][1]
			if not InputMap.action_has_event(action, axis): InputMap.action_add_event(action, axis)

static func pressed(event: InputEvent, action: StringName) -> bool:
	if event is InputEventJoypadMotion and not _axis_edge(event): return false
	if event is InputEventKey and event.physical_keycode == 0:
		# Synthetic/accessibility key events may carry only a logical keycode.
		event = event.duplicate()
		event.physical_keycode = event.keycode
	return event.is_action_pressed(action, false)

static func binding_label(action: StringName, limit: int = 2) -> String:
	var labels: Array[String] = []
	var events := InputMap.action_get_events(action)
	var wanted: Array = events.filter(func(event): return (event is InputEventJoypadButton or event is InputEventJoypadMotion) if controller_labels else event is InputEventKey)
	if wanted.is_empty(): wanted = events
	for event in wanted:
		var text: String = event.as_text()
		if event is InputEventKey:
			text = event.as_text_physical_keycode() if event.physical_keycode != 0 else event.as_text_keycode()
		elif event is InputEventJoypadButton:
			text = PAD_LABELS.get(event.button_index, "Pad %d" % event.button_index)
		elif event is InputEventJoypadMotion:
			text = "LT" if event.axis == JOY_AXIS_TRIGGER_LEFT else "RT" if event.axis == JOY_AXIS_TRIGGER_RIGHT else "LS " + ("Right" if event.axis_value > 0 else "Left") if event.axis == JOY_AXIS_LEFT_X else "LS " + ("Down" if event.axis_value > 0 else "Up")
		text = text.replace(" (Physical)", "").replace("Escape", "Esc").replace("PageUp", "PgUp").replace("PageDown", "PgDn")
		if text not in labels:
			labels.append(text)
		if labels.size() >= maxi(limit, 1):
			break
	return "/".join(labels) if not labels.is_empty() else "UNBOUND"

static func observe_input(event: InputEvent) -> bool:
	var before := controller_labels
	if (event is InputEventJoypadButton and event.pressed) or (event is InputEventJoypadMotion and absf(event.axis_value) >= 0.5):
		controller_labels = true
		active_device = event.device
	elif event is InputEventKey and event.pressed:
		controller_labels = false
		active_device = -1
	return before != controller_labels

static func _axis_edge(event: InputEventJoypadMotion) -> bool:
	var key := "%d:%d" % [event.device, event.axis]
	var previous: Dictionary = _axis_transitions.get(key, {})
	if previous.get("event") == event: return previous.edge
	var direction := int(signf(event.axis_value)) if absf(event.axis_value) >= 0.5 else 0
	var edge: bool = direction != 0 and direction != int(previous.get("direction", 0))
	if _axis_transitions.size() >= 128 and not _axis_transitions.has(key): _axis_transitions.clear()
	_axis_transitions[key] = {"event": event, "direction": direction, "edge": edge}
	return edge

static func release_controller(device: int) -> void:
	# Release only this device's events; held keyboard input remains functional.
	for button in PAD_LABELS:
		var event := InputEventJoypadButton.new()
		event.device = device
		event.button_index = button
		event.pressed = false
		Input.parse_input_event(event)
	for axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]:
		var event := InputEventJoypadMotion.new()
		event.device = device
		event.axis = axis
		event.axis_value = 0
		Input.parse_input_event(event)
	for key in _axis_transitions.keys():
		if String(key).begins_with(str(device) + ":"): _axis_transitions.erase(key)
	if active_device == device:
		controller_labels = false
		active_device = -1
