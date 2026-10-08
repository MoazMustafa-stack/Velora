extends RefCounted
## Empty means measured data is usable; otherwise show a concise state label.
static func label(metric: Dictionary, nullable_field := "") -> String:
	match String(metric.get("availability", "unavailable")):
		"available":
			if not nullable_field.is_empty() and metric.get(nullable_field) == null:
				return "WARMING"
			return ""
		"warming_up": return "WARMING"
		"offline": return "OFFLINE"
		_: return "UNAVAILABLE"
