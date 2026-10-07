extends SceneTree
const Model = preload("res://scripts/station_mappings.gd")
const Store = preload("res://scripts/settings_store.gd")
var failed := false
func check(value: bool, message: String) -> void:
	if not value: failed = true; push_error(message)
func _initialize() -> void:
	var store := Store.new("/tmp/velora-mapping-model-no-io.json")
	check(Model.desktop_id(store, "editor") == "code.desktop", "Fixed slot defaults remain unchanged")
	check(Model.desktop_id(store, "unknown").is_empty(), "Unknown station slots are not accepted")
	var registry := {"good.desktop": {"id": "good.desktop", "name": "Good\nApp", "exec": "private command"}}
	for id in ["/usr/bin/code", "sh -c code", "../bad.desktop", "app.desktop --flag", "org.mpris.MediaPlayer2.fake", "missing.desktop"]:
		check(not Model.choose_reason("editor", id, registry).is_empty(), "Untrusted or unknown desktop ID rejected: " + id)
	check(Model.choose_reason("editor", "good.desktop", registry).is_empty(), "Only actual registry IDs can be selected")
	store.set_station_desktop_id("editor", "missing.desktop")
	check(Model.desktop_id(store, "editor") == "missing.desktop", "Missing saved ID remains explicit rather than silently launching a default")
	var choices := Model.choices(registry)
	check(choices.size() == 1 and choices[0].name == "Good App" and not choices[0].has("exec"), "Chooser keeps single-line ID/name only")
	for index in range(600): registry["fake-%d.desktop" % index] = {"name": "Fixture %d" % index}
	check(Model.choices(registry).size() == Model.MAX_CHOICES, "Application chooser is bounded at 512 entries")
	check(not FileAccess.file_exists("/tmp/velora-mapping-model-no-io.json"), "Mapping model does not write settings")
	if not failed: print("D6.12 station ID model and bounded registry chooser passed")
	quit(1 if failed else 0)
