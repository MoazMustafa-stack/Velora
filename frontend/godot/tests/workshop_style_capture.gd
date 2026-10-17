extends SceneTree
## Real 640x360 render target with synthetic labels and generated images only.
const Tokens = preload("res://ui/design_tokens.gd")
const W = Tokens.Workshop
const Sheet = preload("res://tests/workshop_style_sheet.gd")
var problems: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(value: bool, message: String) -> void:
	if not value:
		problems.append(message)
		push_error(message)

func run() -> void:
	var output := OS.get_environment("VELORA_WORKSHOP_STYLE_DIR")
	if DisplayServer.get_name() == "headless" or output.is_empty():
		push_error("Native art review requires a real display and VELORA_WORKSHOP_STYLE_DIR")
		quit(2)
		return
	var canvas := SubViewport.new()
	canvas.size = W.CANVAS
	canvas.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(canvas)
	var sheet := Sheet.new()
	canvas.add_child(sheet)
	root.content_scale_size = W.CANVAS
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	var preview := TextureRect.new()
	preview.texture = canvas.get_texture()
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(preview)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	for child in sheet.get_children():
		if child is Control:
			check(Rect2(Vector2.ZERO, Vector2(W.CANVAS)).encloses(child.get_rect()), "Native sheet child remains bounded: " + child.name)
	var frame := canvas.get_texture().get_image()
	check(frame.get_size() == W.CANVAS, "Native render, not resized window pixels")
	check(frame.save_png(output.path_join("workshop-style-native.png")) == OK, "Save native sheet")
	for size in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		var scaled := frame.duplicate() as Image
		scaled.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
		check(scaled.save_png(output.path_join("workshop-style-%dx%d.png" % [size.x, size.y])) == OK, "Save integer export")
	for y in range(frame.get_height()):
		for x in range(frame.get_width()):
			var pixel := frame.get_pixel(x, y)
			var gray := pixel.get_luminance()
			frame.set_pixel(x, y, Color(gray, gray, gray, pixel.a))
	check(frame.save_png(output.path_join("workshop-style-gray.png")) == OK, "Save grayscale sheet")
	var file := FileAccess.open(output.path_join("workshop-style.json"), FileAccess.WRITE)
	check(file != null, "Can save native review evidence")
	if file != null:
		file.store_string(JSON.stringify({"card": "R6.02", "passed": problems.is_empty(), "native_size": [640, 360], "source": "synthetic only", "owner_visual_approval": "pending", "motion": "static assets; no animation in this family", "problems": problems}, "\t") + "\n")
		file.close()
	canvas.queue_free()
	preview.queue_free()
	await process_frame
	print("R6.02 native art sheet exported. Owner visual review remains required.")
	quit(0 if problems.is_empty() else 1)
