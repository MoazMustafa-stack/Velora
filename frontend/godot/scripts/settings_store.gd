extends RefCounted
## UI-only preferences. Construction/load never writes. Runtime snapshots must
## never enter this store. Bindings and station mappings are future UI inputs,
## not authorization to launch: IDs still require the live trusted registry.

const VERSION := 1
const DEFAULT_PATH := "user://velora-settings.json"
const MAX_BYTES := 16384
const MAX_BINDINGS := 3
const ACTIONS := ["move_up", "move_down", "move_left", "move_right", "sprint",
	"interact", "menu", "workspace_map", "notification_feed", "media_console",
	"back", "confirm", "nav_up", "nav_down", "nav_left", "nav_right",
	"page_up", "page_down", "first", "last", "media_toggle", "media_next",
	"media_previous", "media_stop", "media_play", "media_pause"]
const SLOTS := ["editor", "browser", "terminal"]

var _path: String
var _onboarding := false
var _reduced_motion := false
var _muted := false
var _volume := 0.5
var _bindings: Dictionary = {}
var _stations: Dictionary = {}

func _init(path: String = DEFAULT_PATH) -> void:
	_path = path

func onboarding_completed() -> bool:
	return _onboarding

func set_onboarding_completed(value: bool) -> void:
	_onboarding = value

func reduced_motion() -> bool:
	return _reduced_motion

func set_reduced_motion(value: bool) -> void:
	_reduced_motion = value

func audio_muted() -> bool:
	return _muted

func set_audio_muted(value: bool) -> void:
	_muted = value

func audio_volume() -> float:
	return _volume

func set_audio_volume(value: float) -> void:
	_volume = clampf(value, 0.0, 1.0) if is_finite(value) else 0.5

## Empty means no override: the input contract supplies the default bindings.
func action_keys(action: String) -> Array[int]:
	var result: Array[int] = []
	result.assign(_bindings.get(action, []))
	return result

func set_action_keys(action: String, keys: Array) -> bool:
	if action not in ACTIONS or not _valid_keys(keys):
		return false
	_bindings[action] = keys.duplicate()
	return true

func station_desktop_id(slot: String) -> String:
	return _stations.get(slot, "")

func set_station_desktop_id(slot: String, desktop_id: String) -> bool:
	if slot not in SLOTS or not _valid_desktop_id(desktop_id):
		return false
	_stations[slot] = desktop_id
	return true

func load_settings() -> Error:
	_defaults()
	if not FileAccess.file_exists(_path):
		return OK
	var file := FileAccess.open(_path, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	if file.get_length() > MAX_BYTES:
		return ERR_INVALID_DATA
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return ERR_PARSE_ERROR
	var data: Dictionary = parser.data
	if data.get("version") != VERSION:
		return ERR_INVALID_DATA
	if data.get("onboarding_completed") is bool:
		_onboarding = data.onboarding_completed
	if data.get("reduced_motion") is bool:
		_reduced_motion = data.reduced_motion
	if data.get("audio_muted") is bool:
		_muted = data.audio_muted
	if data.get("audio_volume") is float or data.get("audio_volume") is int:
		set_audio_volume(float(data.audio_volume))
	if data.get("bindings") is Dictionary:
		for action in ACTIONS:
			if data.bindings.get(action) is Array:
				set_action_keys(action, data.bindings[action])
	if data.get("stations") is Dictionary:
		for slot in SLOTS:
			if data.stations.get(slot) is String:
				set_station_desktop_id(slot, data.stations[slot])
	return OK

func save_settings() -> Error:
	var payload := JSON.stringify({"version": VERSION,
		"onboarding_completed": _onboarding, "reduced_motion": _reduced_motion,
		"audio_muted": _muted, "audio_volume": _volume,
		"bindings": _bindings, "stations": _stations})
	if payload.to_utf8_buffer().size() > MAX_BYTES:
		return ERR_INVALID_DATA
	# Same-directory replacement leaves the previous file intact on write failure.
	var temporary := _path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(payload)
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK:
		error = DirAccess.rename_absolute(temporary, _path)
	if error != OK:
		DirAccess.remove_absolute(temporary)
	return error

func reset() -> Error:
	_defaults()
	if FileAccess.file_exists(_path):
		return DirAccess.remove_absolute(_path)
	return OK

func _defaults() -> void:
	_onboarding = false
	_reduced_motion = false
	_muted = false
	_volume = 0.5
	_bindings.clear()
	_stations.clear()

static func _valid_keys(keys: Array) -> bool:
	if keys.is_empty() or keys.size() > MAX_BINDINGS:
		return false
	var seen := {}
	for value in keys:
		if not (value is int or value is float) or not is_finite(float(value)) or float(value) != floorf(float(value)):
			return false
		if float(value) < 0 or float(value) > KEY_SPECIAL + 256:
			return false
		var key := int(value)
		# Named keyboard keys only, no modifier bit fields or arbitrary integers.
		if not ((key >= KEY_A and key <= KEY_Z) or (key >= KEY_0 and key <= KEY_9)
			or key in [KEY_SPACE, KEY_ESCAPE, KEY_TAB, KEY_ENTER, KEY_KP_ENTER,
			KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_SHIFT, KEY_CTRL, KEY_ALT,
			KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN, KEY_KP_0, KEY_KP_2]):
			return false
		if seen.has(key):
			return false
		seen[key] = true
	return true

static func _valid_desktop_id(value: String) -> bool:
	if value.length() <= 8 or value.length() > 255 or not value.ends_with(".desktop"):
		return false
	if value.begins_with(".") or value.contains(".."):
		return false
	for character in value:
		if not (character >= "a" and character <= "z" or character >= "A" and character <= "Z"
			or character >= "0" and character <= "9" or character in [".", "-", "_"]):
			return false
	return true
