extends SceneTree
const Actions = preload("res://scripts/input_actions.gd")
const Store = preload("res://scripts/settings_store.gd")
const Bindings = preload("res://scripts/key_bindings.gd")
var problems: Array[String] = []
func _initialize() -> void:
	var store := Store.new("/tmp/velora-unused-inspector-settings.json")
	var effective := Bindings.effective(store)
	check(effective.get("focus_inspector", []) == [KEY_F], "Older settings missing the new action get a validated F default")
	check(not Bindings.remap_reason(store, "focus_inspector", [KEY_E]).is_empty(), "Focus action cannot conflict with world interaction")
	check(Bindings.remap_reason(store, "focus_inspector", [KEY_G]).is_empty(), "Inspector focus is remappable")
	check(Bindings.reason(effective).is_empty(), "All defaults remain context-safe")
	if problems.is_empty(): print("R6.04 workshop context binding validation passed")
	quit(0 if problems.is_empty() else 1)
func check(value: bool, message: String) -> void:
	if not value: problems.append(message); push_error(message)
