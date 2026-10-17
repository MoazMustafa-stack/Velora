extends RefCounted
## Keyboard transactions validate complete active contexts before mutation.
const Actions = preload("res://scripts/input_actions.gd")
const Store = preload("res://scripts/settings_store.gd")
const CONTEXTS := [
	["move_up", "move_down", "move_left", "move_right", "sprint", "interact", "menu", "back", "workspace_map", "notification_feed", "media_console", "focus_inspector"],
	["menu", "back", "focus_inspector", "workspace_map", "notification_feed", "media_console", "confirm"],
	["menu", "back", "confirm", "nav_up", "nav_down", "nav_left", "nav_right", "page_up", "page_down", "first", "last"],
	["menu", "back", "workspace_map", "confirm", "nav_up", "nav_down", "nav_left", "nav_right", "first", "last"],
	["menu", "back", "notification_feed", "nav_up", "nav_down", "nav_left", "nav_right", "page_up", "page_down", "first", "last"],
	["menu", "back", "media_console", "nav_up", "nav_down", "page_up", "page_down", "first", "last", "media_toggle", "media_next", "media_previous", "media_stop", "media_play", "media_pause"],
]

static func effective(settings: RefCounted) -> Dictionary:
	var result := {}
	for action in Actions.DEFAULTS:
		var saved: Array = settings.action_keys(action)
		result[action] = saved.duplicate() if not saved.is_empty() else Actions.DEFAULTS[action].duplicate()
		if action in ["menu", "back"] and KEY_ESCAPE not in result[action]: result[action].append(KEY_ESCAPE)
	return result

static func reason(bindings: Dictionary) -> String:
	for action in Actions.DEFAULTS:
		if not Store._valid_keys(bindings.get(action, [])): return "INVALID KEY // " + action.to_upper()
		if action not in ["menu", "back"] and KEY_ESCAPE in bindings[action]: return "ESC RESERVED // CANCEL / RECOVERY"
	for context in CONTEXTS:
		var owners := {}
		for action in context:
			for key in bindings[action]:
				if owners.has(key) and not (action in ["menu", "back"] and owners[key] in ["menu", "back"]):
					return "CONFLICT // " + String(owners[key]).replace("_", " ").to_upper()
				owners[key] = action
	return ""

static func remap_reason(settings: RefCounted, action: String, keys: Array) -> String:
	if action not in Actions.DEFAULTS or not Store._valid_keys(keys): return "INVALID KEY OR ACTION"
	var proposed := effective(settings)
	proposed[action] = keys.duplicate()
	if action in ["menu", "back"] and KEY_ESCAPE not in proposed[action]: proposed[action].append(KEY_ESCAPE)
	return reason(proposed)

static func apply(settings: RefCounted) -> bool:
	var bindings := effective(settings)
	var valid := reason(bindings).is_empty()
	if not valid: bindings = Actions.DEFAULTS.duplicate(true)
	Actions.ensure_registered()
	for action in Actions.DEFAULTS:
		# Reset only keys, leaving fixed controller events intact.
		var current: Array[int] = []
		for event in InputMap.action_get_events(action):
			if event is InputEventKey: current.append(event.physical_keycode if event.physical_keycode != 0 else event.keycode)
		if current == bindings[action]: continue
		for event in InputMap.action_get_events(action):
			if event is InputEventKey: InputMap.action_erase_event(action, event)
		for key in bindings[action]:
			var event := InputEventKey.new()
			event.physical_keycode = int(key)
			InputMap.action_add_event(action, event)
		Input.action_release(action)
	return valid
