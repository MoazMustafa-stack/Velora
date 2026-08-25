extends RefCounted

## Conservative mapping between registered applications and live Hyprland
## windows. Anything ambiguous stays Unknown rather than claiming a false
## desktop ID. Pure functions only: deterministic and unit-testable.

const STATE_UNKNOWN := "unknown"
const STATE_NOT_RUNNING := "not_running"
const STATE_RUNNING := "running"

static func exec_basename(exec: String) -> String:
	var token := exec.strip_edges().split(" ")[0]
	var basename := token.get_file().strip_edges().to_lower()
	return basename

## Returns {desktop_id: {handle, workspace_handle, window_count}} for every
## application that can be matched conservatively. A window class matches at
## most one application; shared classes are dropped as ambiguous.
static func running_applications(applications: Array, windows: Array) -> Dictionary:
	var by_class: Dictionary = {}
	for application in applications:
		if not application is Dictionary:
			continue
		var desktop_id := String(application.get("id", ""))
		if desktop_id.is_empty():
			continue
		var basename := exec_basename(String(application.get("exec", "")))
		if basename.is_empty():
			continue
		if by_class.has(basename):
			# Two applications share this executable name: neither may claim it.
			by_class[basename] = ""
		else:
			by_class[basename] = desktop_id

	var matches: Dictionary = {}
	for window in windows:
		if not window is Dictionary:
			continue
		var class_name_value := String(window.get("class", "")).to_lower()
		if class_name_value.is_empty() or not by_class.has(class_name_value):
			continue
		var desktop_id: String = by_class[class_name_value]
		if desktop_id.is_empty():
			continue
		var handle := String(window.get("handle", ""))
		var entry: Dictionary = matches.get(desktop_id, {
			"handle": "",
			"workspace_handle": "",
			"window_count": 0,
		})
		entry["window_count"] = int(entry["window_count"]) + 1
		if bool(window.get("is_active", false)) or String(entry["workspace_handle"]).is_empty():
			entry["handle"] = handle
			entry["workspace_handle"] = String(window.get("workspace_handle", ""))
		matches[desktop_id] = entry
	return matches

## Full station state for one application given a validated snapshot.
## Unknown whenever Hyprland data is absent; not_running only when the
## session is known and no window matched.
static func station_running_state(
	desktop_id: String,
	snapshot: Dictionary,
	availability: String,
	bound_application: Dictionary
) -> Dictionary:
	if availability != "available" or snapshot.is_empty():
		return {"state": STATE_UNKNOWN, "location": "", "windows": 0}
	if bound_application.is_empty():
		return {"state": STATE_UNKNOWN, "location": "", "windows": 0}

	var running := running_applications([bound_application], snapshot.get("windows", []))
	if not running.is_empty():
		var match: Dictionary = running[desktop_id]
		var workspace_name := _workspace_name(snapshot, String(match["workspace_handle"]))
		return {
			"state": STATE_RUNNING,
			"location": workspace_name,
			"windows": int(match["window_count"]),
		}
	return {"state": STATE_NOT_RUNNING, "location": "", "windows": 0}

static func _workspace_name(snapshot: Dictionary, workspace_handle: String) -> String:
	for workspace in snapshot.get("workspaces", []):
		if workspace is Dictionary and String(workspace.get("handle", "")) == workspace_handle:
			return String(workspace.get("name", ""))
	return ""
