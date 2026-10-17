extends RefCounted
## Session-only inspection identity. Never grants launch permission or owns focus.
## Inputs are complete accepted registry snapshots and currently bound station
## metadata. Only the selected record is retained: no catalog, Exec, icon path,
## node reference, socket, persistence or launch/request state belongs here.

const Store = preload("res://scripts/settings_store.gd")
const DisplayText = preload("res://scripts/display_text.gd")
const MAX_NAME_CHARACTERS := 128
const MAX_CATEGORIES := 8
const MAX_CATEGORY_CHARACTERS := 48

var _nearby_id := ""
var _selected_id := ""
var _name := ""
var _categories: Array[String] = []
var _available := false
var _registry_known := false

## application is the station's already-bound, accepted registry metadata.
## A selected application remains inspectable after the player leaves it.
func observe_nearby(desktop_id: String, application: Dictionary = {}) -> void:
	# The shared syntax guard validates a display identity, not launch authority.
	_nearby_id = desktop_id if Store._valid_desktop_id(desktop_id) else ""
	if _nearby_id.is_empty():
		return
	if _selected_id != desktop_id:
		_selected_id = desktop_id
		_name = desktop_id.left(MAX_NAME_CHARACTERS)
		_categories.clear()
	_apply_application(application)

func _apply_application(application: Dictionary) -> void:
	var name_value = application.get("name", null)
	var categories_value = application.get("categories", [])
	_available = application.get("id", "") == _selected_id and name_value is String \
		and categories_value is Array
	if not _available:
		return
	_name = DisplayText.single_line(name_value, MAX_NAME_CHARACTERS)
	if _name.is_empty():
		_name = _selected_id.left(MAX_NAME_CHARACTERS)
	_categories.clear()
	for index in range(mini(categories_value.size(), MAX_CATEGORIES)):
		var category = categories_value[index]
		if not category is String:
			continue
		_categories.append(DisplayText.single_line(category, MAX_CATEGORY_CHARACTERS))

## Reconcile only the selected record; do not retain or duplicate the catalog.
## Call only for complete accepted snapshots, not a disconnected client's reset.
func update_registry(applications: Array) -> void:
	_registry_known = true
	if _selected_id.is_empty():
		return
	_available = false
	for application in applications:
		if application is Dictionary and application.get("id", "") == _selected_id:
			_apply_application(application)
			return

func view() -> Dictionary:
	# available describes accepted metadata, not permission or current Core health.
	# registry_known means a complete registry event has reached update_registry.
	return {
		"nearby_id": _nearby_id,
		"selected_id": _selected_id,
		"name": _name,
		"categories": _categories.duplicate(),
		"available": _available,
		"registry_known": _registry_known,
	}
