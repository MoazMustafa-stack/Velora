extends SceneTree
## Public visual contract. Pure generated images; no backend, preferences or IO.
const Tokens = preload("res://ui/design_tokens.gd")
const W = Tokens.Workshop
const Art = preload("res://scripts/pixel_art.gd")
const Sheet = preload("res://tests/workshop_style_sheet.gd")
var failures: Array[String] = []

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	check(W.CANVAS == Vector2i(640, 360), "Owner-approved native canvas")
	check(W.HEADER == Rect2i(0, 0, 640, 24), "Compact header")
	check(W.WORLD == Rect2i(0, 24, 640, 256), "World remains dominant")
	check(W.INSPECTOR == Rect2i(0, 280, 640, 80), "Bounded lower inspector")
	check(W.WORLD_VIEW == Vector2i(320, 128), "Canvas density never rescales physics")
	for color in [W.TEXT, W.MUTED, W.READY, W.WAITING, W.FAILURE, W.DISABLED]:
		check(contrast(color, W.PANEL) >= 4.5, "Panel text and state markers have at least 4.5:1 contrast")
	var fallback: ImageTexture = Art.workshop_object_texture("unknown")
	check(fallback.get_size() == Vector2(32, 32), "World objects retain existing physics footprint")
	check(Art.workshop_object_texture("untrusted-kind", "invalid-state") == Art.workshop_object_texture("unknown", "offline"), "Unknown keys normalize before cache lookup")
	check(Art.workshop_icon_texture("untrusted-kind") == Art.workshop_icon_texture("unknown"), "Unknown applications share the bounded category fallback")
	check(Art.workshop_icon_texture("unknown").get_size() == Vector2(16, 16), "Native inspector icon size")
	check(Art.workshop_footprint_texture().get_size() == Vector2(32, 18), "Visible world bases match the existing collision footprint")
	check(Art.workshop_footprint_texture() == Art.workshop_footprint_texture(), "World bases are generated once")
	var failed_selected: Image = Art.workshop_object_texture("code", "failure", true).get_image()
	check(failed_selected.get_pixel(0, 0) == W.FOCUS and failed_selected.get_pixel(27, 25) == W.FAILURE, "Selection decoration never hides failure state")
	check(failed_selected.get_data() != Art.workshop_object_texture("code", "failure", true, true).get_image().get_data(), "Input ownership remains distinct on failed objects")
	var silhouettes: Array[String] = []
	var icons: Array[String] = []
	for kind in ["code", "browser", "terminal", "map", "media", "notifications", "observatory", "unknown"]:
		var object: ImageTexture = Art.workshop_object_texture(kind)
		check(object == Art.workshop_object_texture(kind), "No repeated generation for " + kind)
		var mask := alpha_mask(object.get_image())
		check(mask not in silhouettes, "Distinct color-independent world silhouette: " + kind)
		silhouettes.append(mask)
		var icon_mask := alpha_mask(Art.workshop_icon_texture(kind).get_image())
		check(icon_mask not in icons, "Category remains distinct at 16px: " + kind)
		icons.append(icon_mask)
	var states: Array[PackedByteArray] = []
	for state in ["ready", "waiting", "failure", "offline", "disabled", "selected", "focused"]:
		var frame: Image = Art.workshop_object_texture("code", state).get_image()
		var monochrome := frame.duplicate() as Image
		for y in range(32):
			for x in range(32):
				var pixel := frame.get_pixel(x, y)
				# Binary light/dark proof: status cannot depend on hue alone.
				var light := 1.0 if pixel.get_luminance() > 0.5 else 0.0
				monochrome.set_pixel(x, y, Color(light, light, light, pixel.a))
		check(monochrome.get_data() not in states, "State has a distinct non-color marker: " + state)
		states.append(monochrome.get_data())
	var sheet := Sheet.new()
	root.add_child(sheet)
	await process_frame
	await process_frame
	for child in sheet.get_children():
		if child is Control:
			check(Rect2(Vector2.ZERO, Vector2(W.CANVAS)).encloses(child.get_rect()), "Native typography and icons stay within the sheet")
		if child is Label:
			check(child.clip_text and child.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS, "Labels are bounded, with honest overflow indication")
	sheet.queue_free()
	await process_frame
	if failures.is_empty(): print("R6.02 workshop visual contract passed")
	quit(0 if failures.is_empty() else 1)

func alpha_mask(image: Image) -> String:
	var result := ""
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			result += "#" if image.get_pixel(x, y).a > 0.5 else "."
	return result

func contrast(a: Color, b: Color) -> float:
	var light := a.srgb_to_linear().get_luminance()
	var dark := b.srgb_to_linear().get_luminance()
	return (maxf(light, dark) + 0.05) / (minf(light, dark) + 0.05)
