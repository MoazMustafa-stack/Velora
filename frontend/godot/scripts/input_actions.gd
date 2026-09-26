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
	"nav_up": [KEY_UP, KEY_W], "nav_down": [KEY_DOWN, KEY_S],
	"nav_left": [KEY_LEFT, KEY_A], "nav_right": [KEY_RIGHT, KEY_D],
	"page_up": [KEY_PAGEUP], "page_down": [KEY_PAGEDOWN],
	"first": [KEY_HOME], "last": [KEY_END],
	"media_toggle": [KEY_SPACE, KEY_E, KEY_ENTER, KEY_KP_ENTER],
	"media_next": [KEY_N, KEY_RIGHT, KEY_D],
	"media_previous": [KEY_B, KEY_LEFT, KEY_A],
	"media_stop": [KEY_X], "media_play": [KEY_KP_0], "media_pause": [KEY_KP_2],
}

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

static func pressed(event: InputEvent, action: StringName) -> bool:
	if event is InputEventKey and event.physical_keycode == 0:
		# Synthetic/accessibility key events may carry only a logical keycode.
		event = event.duplicate()
		event.physical_keycode = event.keycode
	return event.is_action_pressed(action, false)
