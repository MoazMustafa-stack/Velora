extends RefCounted
## Non-overlapping fixed regions on the native 320 x 180 canvas.
const STATUS := Rect2(6, 6, 186, 22)
const CONNECTION := Rect2(204, 6, 110, 22)
const FOOTER := Rect2(6, 142, 308, 18)
const HELP := Rect2(6, 164, 308, 12)

static func visibility(modal: bool, critical: bool, has_prompt: bool) -> Dictionary:
	return {"world": not modal, "prompt": not modal and not critical and has_prompt,
		"telemetry": not modal and not critical and not has_prompt}

static func fit(control: Control, region: Rect2) -> void:
	control.position = region.position
	control.size = region.size
	control.clip_contents = true
