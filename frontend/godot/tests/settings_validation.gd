extends SceneTree

const Store = preload("res://scripts/settings_store.gd")
var failures: Array[String] = []
var path := ""

func _initialize() -> void:
	# A unique injected path, never the default user settings.
	path = "/tmp/velora-settings-test-%d-%d.json" % [OS.get_process_id(), Time.get_ticks_usec()]
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func write(text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _run() -> void:
	var settings := Store.new(path)
	check(settings.load_settings() == OK and not FileAccess.file_exists(path), "Missing settings do not write")
	check(not settings.reduced_motion() and settings.audio_volume() == 0.5, "Safe defaults")
	settings.set_onboarding_completed(true)
	settings.set_reduced_motion(true)
	settings.set_audio_muted(true)
	settings.set_audio_volume(9.0)
	check(settings.audio_volume() == 1.0, "Volume clamps")
	settings.set_audio_volume(NAN)
	check(settings.audio_volume() == 0.5, "Non-finite volume defaults")
	check(settings.set_action_keys("interact", [KEY_E, KEY_ENTER]), "Allowlisted bindings")
	check(not settings.set_action_keys("execute", [KEY_E]), "Unknown actions rejected")
	for keys in [[], [KEY_E, KEY_E], [KEY_A, KEY_B, KEY_C, KEY_D, KEY_F], [1.5], ["E"], [-1]]:
		check(not settings.set_action_keys("interact", keys), "Malformed bindings rejected")
	check(settings.set_station_desktop_id("editor", "org.example.Editor.desktop"), "Desktop ID accepted")
	for id in ["/usr/bin/app", "../app.desktop", "sh -c app.desktop", "a;id.desktop", "$HOME.desktop", "org.mpris.MediaPlayer2.foo", "x".repeat(256) + ".desktop"]:
		check(not settings.set_station_desktop_id("editor", id), "Unsafe station mapping rejected")
	check(not settings.set_station_desktop_id("unknown", "app.desktop"), "Fixed slots only")
	var copy := settings.action_keys("interact")
	copy.clear()
	check(settings.action_keys("interact").size() == 2, "Accessors do not leak mutable state")
	check(settings.save_settings() == OK, "Save succeeds")
	var restored := Store.new(path)
	check(restored.load_settings() == OK and restored.onboarding_completed() and restored.audio_muted() and restored.reduced_motion(), "Typed preferences round trip")
	check(restored.action_keys("interact") == [KEY_E, KEY_ENTER], "Bindings round trip")
	check(restored.station_desktop_id("editor") == "org.example.Editor.desktop", "Desktop ID round trip")
	write('{"version":1,"reduced_motion":true,"audio_volume":"bad","bindings":{"execute":[65]},"notifications":["private"],"media":{"title":"private"}}')
	check(settings.load_settings() == OK and settings.reduced_motion() and settings.audio_volume() == 0.5, "Partial data defaults field by field")
	check(settings.save_settings() == OK, "Validated fields save")
	var saved := FileAccess.get_file_as_string(path)
	check(not saved.contains("private") and not saved.contains("execute") and not saved.contains("notifications"), "Unknown/live data is never persisted")
	for invalid in ["not json", "[]", '{"version":99,"reduced_motion":true}', '{"reduced_motion":true}', "x".repeat(Store.MAX_BYTES + 1)]:
		write(invalid)
		check(settings.load_settings() != OK and not settings.reduced_motion(), "Corrupt/oversized/unsupported settings fail safe")
	var unrelated := path + ".unrelated"
	var other := FileAccess.open(unrelated, FileAccess.WRITE)
	other.store_string("untouched")
	other.close()
	check(settings.reset() == OK and not FileAccess.file_exists(path), "Reset removes own file")
	check(FileAccess.file_exists(unrelated), "Reset preserves other files")
	DirAccess.remove_absolute(unrelated)
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path + ".tmp")
	if failures.is_empty():
		print("D6.03 settings validation passed.")
	quit(0 if failures.is_empty() else 1)
