extends RefCounted
## Original, deterministic pixel geometry. No file access, random state, external
## artwork or downloads. Cache keys normalize to a fixed family before lookup.
const Tokens = preload("res://ui/design_tokens.gd")
const W = Tokens.Workshop
const KINDS := ["code", "browser", "terminal", "map", "media", "notifications", "observatory", "unknown"]
const STATES := ["ready", "waiting", "failure", "offline", "disabled", "selected", "focused"]
static var _objects: Dictionary = {}
static var _icons: Dictionary = {}
static var _tiles: ImageTexture
static var _footprint: ImageTexture

## World-only plinth, not an icon element. Its opaque 32x18 outer edge marks
## the exact solid body; no extra physics shape or interaction area is added.
static func footprint_texture() -> ImageTexture:
	if _footprint == null:
		var image := Image.create_empty(32, 18, false, Image.FORMAT_RGBA8)
		image.fill(W.WOOD_DARK)
		image.fill_rect(Rect2i(1, 1, 30, 16), W.WOOD)
		image.fill_rect(Rect2i(1, 1, 30, 2), W.BRASS)
		image.fill_rect(Rect2i(2, 5, 28, 10), W.WOOD_DARK)
		_footprint = ImageTexture.create_from_image(image)
	return _footprint

## Four 16px tiles: floor, a fully solid wall, walkable runner and entry rug.
## Decorative runners have no collision and do not imply raised obstacles.
static func tile_atlas_texture() -> ImageTexture:
	if _tiles != null:
		return _tiles
	var image := Image.create_empty(64, 16, false, Image.FORMAT_RGBA8)
	for index in range(4):
		var origin := Vector2i(index * 16, 0)
		image.fill_rect(Rect2i(origin, Vector2i(16, 16)), W.FLOOR)
		image.fill_rect(Rect2i(origin + Vector2i(1, 1), Vector2i(14, 14)), W.FLOOR_LIGHT)
		image.fill_rect(Rect2i(origin + Vector2i(3, 6), Vector2i(5, 1)), W.FLOOR)
		image.fill_rect(Rect2i(origin + Vector2i(10, 12), Vector2i(4, 1)), W.FLOOR)
		match index:
			1:
				image.fill_rect(Rect2i(origin, Vector2i(16, 16)), W.WOOD_DARK)
				image.fill_rect(Rect2i(origin + Vector2i(1, 2), Vector2i(14, 13)), W.WALL)
				image.fill_rect(Rect2i(origin + Vector2i(0, 0), Vector2i(16, 2)), W.BRASS)
				image.fill_rect(Rect2i(origin + Vector2i(1, 3), Vector2i(14, 2)), W.WALL_LIGHT)
				image.fill_rect(Rect2i(origin + Vector2i(3, 10), Vector2i(10, 1)), W.WOOD_DARK)
			2:
				image.fill_rect(Rect2i(origin + Vector2i(2, 0), Vector2i(12, 16)), W.WOOD_DARK)
				for y in [3, 11]:
					image.fill_rect(Rect2i(origin + Vector2i(4, y), Vector2i(8, 1)), W.WOOD)
			3:
				image.fill_rect(Rect2i(origin + Vector2i(1, 3), Vector2i(14, 10)), W.WOOD_DARK)
				for x in range(3, 14, 4):
					image.fill_rect(Rect2i(origin + Vector2i(x, 5), Vector2i(2, 6)), W.BRASS)
	_tiles = ImageTexture.create_from_image(image)
	return _tiles

static func object_texture(kind: String, state: String, selected := false, focused := false) -> ImageTexture:
	kind = kind if kind in KINDS else "unknown"
	state = state if state in STATES else "offline"
	# State badges and input ownership are independent. Selected/focused remain
	# compatible shorthand for the contact sheet's ready-state examples.
	var decoration := "focused" if focused or state == "focused" else "selected" if selected or state == "selected" else ""
	state = "ready" if state in ["selected", "focused"] else state
	var key := kind + "/" + state + "/" + decoration
	if not _objects.has(key):
		var image := _base_image(kind)
		_draw_state(image, state)
		_draw_selection(image, decoration)
		_objects[key] = ImageTexture.create_from_image(image)
	return _objects[key]

static func icon_texture(kind: String) -> ImageTexture:
	kind = kind if kind in KINDS else "unknown"
	if not _icons.has(kind):
		var image := _base_image(kind)
		image.resize(16, 16, Image.INTERPOLATE_NEAREST)
		_icons[kind] = ImageTexture.create_from_image(image)
	return _icons[kind]

static func _base_image(kind: String) -> Image:
	var image := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	match kind:
		"code":
			# Workbench, asymmetric books and a monitor with bracket glyphs.
			image.fill_rect(Rect2i(2, 18, 28, 4), W.WOOD)
			for x in [4, 26]: image.fill_rect(Rect2i(x, 22, 2, 8), W.WOOD_DARK)
			image.fill_rect(Rect2i(6, 2, 18, 14), W.WALL_LIGHT)
			image.fill_rect(Rect2i(8, 4, 14, 10), W.SHADOW)
			image.fill_rect(Rect2i(14, 16, 4, 2), W.BRASS)
			for x in [10, 18]: image.fill_rect(Rect2i(x, 6, 2, 6), W.READY)
			image.fill_rect(Rect2i(12, 8, 6, 2), W.READY)
			image.fill_rect(Rect2i(26, 10, 4, 8), W.ACCENT)
			image.fill_rect(Rect2i(8, 22, 12, 2), W.BRASS)
		"browser":
			# A globe, rather than another telescope or monitor silhouette.
			image.fill_rect(Rect2i(8, 2, 16, 2), W.BRASS)
			image.fill_rect(Rect2i(4, 4, 24, 4), W.WALL_LIGHT)
			image.fill_rect(Rect2i(2, 8, 28, 8), W.WALL_LIGHT)
			image.fill_rect(Rect2i(4, 16, 24, 4), W.WALL_LIGHT)
			image.fill_rect(Rect2i(8, 20, 16, 2), W.BRASS)
			image.fill_rect(Rect2i(10, 4, 12, 16), W.READY)
			image.fill_rect(Rect2i(6, 8, 20, 8), W.READY)
			image.fill_rect(Rect2i(14, 4, 2, 16), W.WOOD_DARK)
			image.fill_rect(Rect2i(6, 10, 20, 2), W.WOOD_DARK)
			for x in [10, 20]: image.fill_rect(Rect2i(x, 6, 2, 12), W.WOOD_DARK)
			image.fill_rect(Rect2i(14, 22, 4, 6), W.BRASS)
			image.fill_rect(Rect2i(8, 28, 16, 2), W.WOOD)
		"terminal":
			image.fill_rect(Rect2i(2, 4, 28, 20), W.WALL_LIGHT)
			image.fill_rect(Rect2i(4, 6, 24, 16), W.SHADOW)
			for step in range(3): image.fill_rect(Rect2i(8 + step * 2, 8 + step * 2, 2, 2), W.READY)
			image.fill_rect(Rect2i(8, 14, 2, 2), W.READY)
			image.fill_rect(Rect2i(16, 16, 6, 2), W.READY)
			image.fill_rect(Rect2i(6, 24, 20, 6), W.WOOD_DARK)
			image.fill_rect(Rect2i(8, 26, 12, 2), W.BRASS)
		"map":
			image.fill_rect(Rect2i(2, 4, 10, 22), W.BRASS)
			image.fill_rect(Rect2i(12, 8, 8, 22), W.TEXT)
			image.fill_rect(Rect2i(20, 4, 10, 22), W.BRASS)
			for x in [6, 14, 24]: image.fill_rect(Rect2i(x, 10, 2, 12), W.WOOD_DARK)
			image.fill_rect(Rect2i(4, 16, 24, 2), W.READY)
			image.fill_rect(Rect2i(14, 14, 4, 6), W.WOOD_DARK)
		"media":
			image.fill_rect(Rect2i(4, 2, 24, 2), W.BRASS)
			image.fill_rect(Rect2i(2, 10, 28, 18), W.WOOD)
			image.fill_rect(Rect2i(4, 12, 24, 12), W.SHADOW)
			image.fill_rect(Rect2i(8, 14, 12, 2), W.WALL_LIGHT)
			image.fill_rect(Rect2i(6, 16, 16, 4), W.WALL_LIGHT)
			image.fill_rect(Rect2i(8, 20, 12, 2), W.WALL_LIGHT)
			image.fill_rect(Rect2i(12, 16, 4, 4), W.ACCENT)
			image.fill_rect(Rect2i(24, 12, 2, 10), W.READY)
		"notifications":
			image.fill_rect(Rect2i(8, 6, 16, 2), W.BRASS)
			image.fill_rect(Rect2i(6, 8, 20, 14), W.WOOD)
			image.fill_rect(Rect2i(8, 10, 16, 8), W.SHADOW)
			image.fill_rect(Rect2i(10, 12, 12, 4), W.TEXT)
			image.fill_rect(Rect2i(14, 22, 4, 8), W.WOOD_DARK)
			image.fill_rect(Rect2i(24, 2, 2, 12), W.ACCENT)
			image.fill_rect(Rect2i(26, 2, 4, 4), W.ACCENT)
		"observatory":
			for step in range(4): image.fill_rect(Rect2i(4 + step * 4, 16 - step * 4, 8, 8), W.WALL_LIGHT)
			image.fill_rect(Rect2i(24, 2, 6, 10), W.BRASS)
			image.fill_rect(Rect2i(26, 4, 2, 6), W.READY)
			image.fill_rect(Rect2i(14, 22, 4, 6), W.WOOD_DARK)
			image.fill_rect(Rect2i(8, 28, 16, 2), W.BRASS)
		_:
			# Unknown application: toolbox, not a branded icon or executable.
			image.fill_rect(Rect2i(10, 6, 12, 4), W.BRASS)
			image.fill_rect(Rect2i(12, 8, 8, 4), W.SHADOW)
			image.fill_rect(Rect2i(4, 12, 24, 16), W.WOOD_DARK)
			image.fill_rect(Rect2i(6, 14, 20, 6), W.WOOD)
			image.fill_rect(Rect2i(6, 22, 20, 4), W.WALL)
			image.fill_rect(Rect2i(14, 18, 4, 6), W.ACCENT)
	return image

static func _draw_state(image: Image, state: String) -> void:
	var marker_state := state if W.STATUS_MARKERS.has(state) else "ready"
	var ink: Color = {"ready": W.READY, "waiting": W.WAITING, "failure": W.FAILURE, "offline": W.MUTED, "disabled": W.DISABLED}.get(marker_state, W.TEXT)
	image.fill_rect(Rect2i(24, 24, 8, 8), W.SHADOW)
	var marker: Array = W.STATUS_MARKERS[marker_state]
	for y in range(5):
		for x in range(5):
			if marker[y][x] == "#": image.set_pixel(25 + x, 25 + y, ink)
static func _draw_selection(image: Image, state: String) -> void:
	if state in ["selected", "focused"]:
		# Selection = corner brackets. Keyboard owner = continuous doubled rail.
		var length := 8 if state == "selected" else 32
		var thickness := W.OUTLINE_WIDTH if state == "selected" else W.FOCUS_WIDTH
		for origin in [Vector2i(0, 0), Vector2i(32 - length, 0), Vector2i(0, 32 - thickness), Vector2i(32 - length, 32 - thickness)]:
			image.fill_rect(Rect2i(origin, Vector2i(length, thickness)), W.FOCUS)
		for origin in [Vector2i(0, 0), Vector2i(32 - thickness, 0), Vector2i(0, 32 - length), Vector2i(32 - thickness, 32 - length)]:
			image.fill_rect(Rect2i(origin, Vector2i(thickness, length)), W.FOCUS)
