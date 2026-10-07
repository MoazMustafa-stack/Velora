extends RefCounted
## IDs only. The live Core registry and launch policy remain authoritative.
const Store = preload("res://scripts/settings_store.gd")
const DEFAULTS := {"editor": "code.desktop", "browser": "firefox.desktop", "terminal": "kitty.desktop"}
const MAX_CHOICES := 512

static func desktop_id(settings: RefCounted, slot: String) -> String:
	if not DEFAULTS.has(slot): return ""
	var saved: String = settings.station_desktop_id(slot)
	return saved if Store._valid_desktop_id(saved) else DEFAULTS[slot]

static func choose_reason(slot: String, id: String, registry: Dictionary) -> String:
	if not DEFAULTS.has(slot) or not Store._valid_desktop_id(id): return "INVALID STATION ID"
	if not registry.has(id): return "APP UNAVAILABLE // REFRESH REGISTRY"
	return ""

static func choices(registry: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	# Only validated IDs/names enter the chooser, never Exec or command fields.
	var ids: Array = registry.keys()
	ids.sort()
	for id in ids:
		if not id is String or not Store._valid_desktop_id(id) or not registry[id] is Dictionary: continue
		var name := String(registry[id].get("name", id)).replace("\n", " ").replace("\r", " ").replace("\t", " ").left(128)
		result.append({"id": id, "name": name if not name.strip_edges().is_empty() else id})
		if result.size() == MAX_CHOICES: break
	result.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0 if a.name != b.name else a.id < b.id)
	return result
