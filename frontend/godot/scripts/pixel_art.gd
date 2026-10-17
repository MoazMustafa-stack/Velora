class_name VeloraPixelArt
extends RefCounted

const Tokens = preload("res://ui/design_tokens.gd")

const TILE_SIZE := Tokens.TILE_SIZE
const DEEP_NAVY := Tokens.WORLD_BACKGROUND
const FLOOR_BLUE := Tokens.WORLD_FLOOR
const FLOOR_LIGHT := Tokens.WORLD_FLOOR_LIGHT
const STEEL_BLUE := Tokens.WORLD_STEEL
const STEEL_LIGHT := Tokens.WORLD_STEEL_LIGHT
const CYAN := Tokens.WORLD_ACCENT
const CYAN_LIGHT := Tokens.READY
const AMBER := Tokens.WORLD_AMBER
const RED := Tokens.FAILURE
const SOFT_WHITE := Tokens.WORLD_TEXT
const SHADOW := Tokens.WORLD_SHADOW
const STATE_MARKERS := Tokens.STATUS_MARKERS
static var _station_cache: Dictionary = {}
static var _object_cache: Dictionary = {}

static func workstation_texture(state: String, accent: Color, kind: String) -> ImageTexture:
	state = state if STATE_MARKERS.has(state) else "offline"
	kind = kind if kind in ["code", "browser", "terminal"] else "code"
	var key := "%s:%s:%s" % [state, kind, accent.to_html()]
	if not _station_cache.has(key):
		_station_cache[key] = create_workstation_texture(state, accent, kind)
	return _station_cache[key]

static func hub_object_texture(kind: String) -> ImageTexture:
	kind = kind if kind in ["map", "media", "notifications", "observatory"] else "observatory"
	if not _object_cache.has(kind):
		_object_cache[kind] = _create_hub_object_texture(kind)
	return _object_cache[kind]

static func _create_hub_object_texture(kind: String) -> ImageTexture:
	var image := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.fill_rect(Rect2i(2, 28, 28, 2), Color(0, 0, 0, 0.4))
	match kind:
		"map":
			image.fill_rect(Rect2i(2, 5, 9, 19), STEEL_LIGHT)
			image.fill_rect(Rect2i(11, 8, 9, 19), SOFT_WHITE)
			image.fill_rect(Rect2i(20, 5, 10, 19), STEEL_LIGHT)
			for x in [6, 15, 24]: image.fill_rect(Rect2i(x, 10, 2, 11), SHADOW)
			image.fill_rect(Rect2i(4, 15, 24, 2), CYAN)
			image.fill_rect(Rect2i(14, 14, 4, 4), AMBER)
		"media":
			image.fill_rect(Rect2i(9, 2, 14, 3), SOFT_WHITE)
			image.fill_rect(Rect2i(2, 8, 28, 18), STEEL_LIGHT)
			for x in [4, 22]:
				image.fill_rect(Rect2i(x, 12, 6, 10), SHADOW)
				image.fill_rect(Rect2i(x + 2, 15, 2, 4), SOFT_WHITE)
			image.fill_rect(Rect2i(12, 11, 8, 11), SHADOW)
			for x in range(4): image.fill_rect(Rect2i(14 + x, 13 + x, 1, 7 - 2 * x), CYAN_LIGHT)
		"notifications":
			image.fill_rect(Rect2i(8, 3, 16, 3), SOFT_WHITE)
			image.fill_rect(Rect2i(6, 6, 20, 16), STEEL_LIGHT)
			image.fill_rect(Rect2i(9, 10, 14, 9), SHADOW)
			image.fill_rect(Rect2i(11, 12, 10, 5), SOFT_WHITE)
			image.fill_rect(Rect2i(15, 22, 3, 7), STEEL_BLUE)
			image.fill_rect(Rect2i(25, 1, 2, 12), AMBER)
			image.fill_rect(Rect2i(27, 1, 4, 4), AMBER)
		"observatory":
			for step in range(4):
				image.fill_rect(Rect2i(5 + step * 4, 15 - step * 3, 6, 7), STEEL_LIGHT)
			image.fill_rect(Rect2i(22, 3, 7, 10), SOFT_WHITE)
			image.fill_rect(Rect2i(24, 5, 3, 6), CYAN)
			image.fill_rect(Rect2i(14, 21, 3, 6), STEEL_BLUE)
			image.fill_rect(Rect2i(9, 27, 13, 2), SOFT_WHITE)
	# Common interaction tick; object identity comes from silhouette, not color.
	image.set_pixel(15, 30, SOFT_WHITE)
	image.set_pixel(16, 31, SOFT_WHITE)
	image.set_pixel(17, 30, SOFT_WHITE)
	return ImageTexture.create_from_image(image)

static func create_tileset() -> TileSet:
	var image := Image.create_empty(64, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	_draw_floor_tile(image, Vector2i(0, 0), false)
	_draw_wall_tile(image, Vector2i(16, 0))
	_draw_floor_tile(image, Vector2i(32, 0), true)
	_draw_threshold_tile(image, Vector2i(48, 0))

	var atlas := TileSetAtlasSource.new()
	atlas.texture = ImageTexture.create_from_image(image)
	atlas.texture_region_size = TILE_SIZE
	for tile_x in range(4):
		atlas.create_tile(Vector2i(tile_x, 0))

	var tile_set := TileSet.new()
	tile_set.tile_size = TILE_SIZE
	tile_set.add_physics_layer()
	tile_set.set_physics_layer_collision_layer(0, 1)
	var source_id := tile_set.add_source(atlas)

	var wall_data := atlas.get_tile_data(Vector2i(1, 0), 0)
	wall_data.add_collision_polygon(0)
	wall_data.set_collision_polygon_points(
		0,
		0,
		PackedVector2Array([
			Vector2(-8, -8),
			Vector2(8, -8),
			Vector2(8, 8),
			Vector2(-8, 8),
		])
	)
	tile_set.set_meta("velora_source_id", source_id)
	return tile_set

static func create_player_texture(facing: Vector2, step: int) -> ImageTexture:
	var image := Image.create_empty(16, 24, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.fill_rect(Rect2i(4, 21, 8, 2), Color(0, 0, 0, 0.35))

	var leg_offset := 1 if step == 1 else 0
	image.fill_rect(Rect2i(5 - leg_offset, 17, 3, 5), STEEL_BLUE)
	image.fill_rect(Rect2i(8 + leg_offset, 17, 3, 5), STEEL_BLUE)
	image.fill_rect(Rect2i(4, 9, 8, 9), Color("26334d"))
	image.fill_rect(Rect2i(5, 10, 6, 2), CYAN)
	image.fill_rect(Rect2i(3, 11, 2, 6), Color("344866"))
	image.fill_rect(Rect2i(11, 11, 2, 6), Color("344866"))
	image.fill_rect(Rect2i(4, 2, 8, 8), Color("c97b48"))
	image.fill_rect(Rect2i(3, 4, 10, 4), Color("3a2335"))

	if facing == Vector2.UP:
		image.fill_rect(Rect2i(5, 5, 6, 2), Color("3a2335"))
		image.fill_rect(Rect2i(7, 12, 2, 4), CYAN_LIGHT)
	elif facing == Vector2.LEFT:
		image.fill_rect(Rect2i(4, 6, 2, 1), SOFT_WHITE)
		image.fill_rect(Rect2i(3, 12, 2, 3), CYAN_LIGHT)
	elif facing == Vector2.RIGHT:
		image.fill_rect(Rect2i(10, 6, 2, 1), SOFT_WHITE)
		image.fill_rect(Rect2i(11, 12, 2, 3), CYAN_LIGHT)
	else:
		image.fill_rect(Rect2i(5, 6, 2, 1), SOFT_WHITE)
		image.fill_rect(Rect2i(9, 6, 2, 1), SOFT_WHITE)
		image.fill_rect(Rect2i(7, 13, 2, 3), CYAN_LIGHT)

	return ImageTexture.create_from_image(image)

static func create_workstation_texture(
	state: String = "offline",
	accent: Color = CYAN,
	station_kind: String = "code"
) -> ImageTexture:
	var image := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.fill_rect(Rect2i(2, 28, 28, 3), Color(0, 0, 0, 0.4))
	image.fill_rect(Rect2i(3, 18, 26, 10), STEEL_BLUE)
	image.fill_rect(Rect2i(5, 20, 22, 6), Color("1b2945"))
	image.fill_rect(Rect2i(8, 3, 16, 15), SHADOW)
	image.fill_rect(Rect2i(9, 4, 14, 13), STEEL_LIGHT)
	match station_kind:
		"code":
			image.fill_rect(Rect2i(6, 4, 2, 14), STEEL_LIGHT)
			image.fill_rect(Rect2i(24, 4, 2, 14), STEEL_LIGHT)
		"browser": image.fill_rect(Rect2i(10, 1, 12, 3), STEEL_LIGHT)
		"terminal": image.fill_rect(Rect2i(5, 5, 22, 12), STEEL_LIGHT)
	image.fill_rect(Rect2i(11, 6, 10, 8), Color("0d3140"))
	image.fill_rect(Rect2i(12, 7, 8, 6), accent.darkened(0.55))
	_draw_station_glyph(image, station_kind, accent)
	image.fill_rect(Rect2i(14, 18, 4, 3), STEEL_LIGHT)
	image.fill_rect(Rect2i(10, 22, 12, 2), Color("50698e"))
	if state == "attention":
		image.fill_rect(Rect2i(12, 8, 8, 4), AMBER)
	# A high-contrast check / exclamation / cross, not a color-only LED.
	image.fill_rect(Rect2i(23, 20, 7, 7), SHADOW)
	var marker: Array = STATE_MARKERS.get(state, STATE_MARKERS.offline)
	for y in range(5):
		for x in range(5):
			if marker[y][x] == "#": image.set_pixel(24 + x, 21 + y, SOFT_WHITE)
	image.set_pixel(15, 30, SOFT_WHITE)
	image.set_pixel(16, 31, SOFT_WHITE)
	image.set_pixel(17, 30, SOFT_WHITE)
	return ImageTexture.create_from_image(image)

static func _draw_station_glyph(image: Image, station_kind: String, accent: Color) -> void:
	if station_kind == "browser":
		image.fill_rect(Rect2i(14, 8, 4, 4), accent)
		image.set_pixel(15, 9, SHADOW)
		image.set_pixel(16, 10, SHADOW)
	elif station_kind == "terminal":
		image.fill_rect(Rect2i(13, 8, 2, 1), accent)
		image.fill_rect(Rect2i(14, 9, 2, 1), accent)
		image.fill_rect(Rect2i(13, 10, 2, 1), accent)
		image.fill_rect(Rect2i(17, 11, 2, 1), accent)
	else:
		image.fill_rect(Rect2i(13, 8, 2, 4), accent)
		image.fill_rect(Rect2i(18, 8, 2, 4), accent)
		image.fill_rect(Rect2i(15, 9, 3, 2), accent)

static func _draw_floor_tile(image: Image, origin: Vector2i, accented: bool) -> void:
	image.fill_rect(Rect2i(origin, TILE_SIZE), FLOOR_BLUE)
	image.fill_rect(Rect2i(origin + Vector2i(1, 1), Vector2i(14, 14)), FLOOR_LIGHT)
	image.set_pixelv(origin + Vector2i(3, 3), STEEL_BLUE)
	image.set_pixelv(origin + Vector2i(12, 11), STEEL_BLUE)
	if accented:
		image.fill_rect(Rect2i(origin + Vector2i(7, 0), Vector2i(2, 16)), CYAN)
		image.fill_rect(Rect2i(origin + Vector2i(6, 0), Vector2i(1, 16)), Color("17424f"))

static func _draw_wall_tile(image: Image, origin: Vector2i) -> void:
	image.fill_rect(Rect2i(origin, TILE_SIZE), DEEP_NAVY)
	image.fill_rect(Rect2i(origin + Vector2i(1, 1), Vector2i(14, 14)), STEEL_BLUE)
	image.fill_rect(Rect2i(origin + Vector2i(1, 1), Vector2i(14, 3)), STEEL_LIGHT)
	image.fill_rect(Rect2i(origin + Vector2i(3, 7), Vector2i(10, 2)), Tokens.WORLD_FLOOR_LIGHT)
	image.set_pixelv(origin + Vector2i(3, 12), AMBER)

static func _draw_threshold_tile(image: Image, origin: Vector2i) -> void:
	image.fill_rect(Rect2i(origin, TILE_SIZE), FLOOR_BLUE)
	for stripe in range(0, 16, 4):
		image.fill_rect(Rect2i(origin + Vector2i(stripe, 5), Vector2i(2, 6)), AMBER)
