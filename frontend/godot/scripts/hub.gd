extends Node2D

const ROOM_WIDTH := 20
const ROOM_HEIGHT := 12
const PixelArt = preload("res://scripts/pixel_art.gd")

@onready var ground: TileMapLayer = $Ground
@onready var walls: TileMapLayer = $Walls
@onready var details: TileMapLayer = $Details

func _ready() -> void:
	var tile_set: TileSet = PixelArt.create_tileset()
	var source_id: int = tile_set.get_meta("velora_source_id")
	ground.tile_set = tile_set
	walls.tile_set = tile_set
	details.tile_set = tile_set

	for y in range(ROOM_HEIGHT):
		for x in range(ROOM_WIDTH):
			ground.set_cell(Vector2i(x, y), source_id, Vector2i(0, 0))

	for x in range(ROOM_WIDTH):
		walls.set_cell(Vector2i(x, 0), source_id, Vector2i(1, 0))
		walls.set_cell(Vector2i(x, ROOM_HEIGHT - 1), source_id, Vector2i(1, 0))
	for y in range(1, ROOM_HEIGHT - 1):
		walls.set_cell(Vector2i(0, y), source_id, Vector2i(1, 0))
		walls.set_cell(Vector2i(ROOM_WIDTH - 1, y), source_id, Vector2i(1, 0))

	for y in range(4, ROOM_HEIGHT - 1):
		details.set_cell(Vector2i(9, y), source_id, Vector2i(2, 0))
		details.set_cell(Vector2i(10, y), source_id, Vector2i(2, 0))
	details.set_cell(Vector2i(9, ROOM_HEIGHT - 2), source_id, Vector2i(3, 0))
	details.set_cell(Vector2i(10, ROOM_HEIGHT - 2), source_id, Vector2i(3, 0))
