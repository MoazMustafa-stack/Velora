extends StaticBody2D
## One physical, facing-aware interactable archetype; no backend authority.
const Art = preload("res://scripts/pixel_art.gd")
const Actions = preload("res://scripts/input_actions.gd")
const Shell = preload("res://ui/panel_shell.gd")
const NAMES := {"map": "WORKSPACE MAP", "media": "MEDIA CONSOLE", "notifications": "NOTIFICATION FEED", "observatory": "OBSERVATORY"}
const MARKERS := {"map": "MAP", "media": "MEDIA", "notifications": "FEED", "observatory": "SYS"}
signal activated(kind: String)
@export_enum("map", "media", "notifications", "observatory") var object_kind := "map"

func _ready() -> void:
	add_to_group("hub_objects")
	collision_layer = 1
	collision_mask = 0
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	sprite.position = Vector2(0, -5)
	sprite.texture = Art.hub_object_texture(object_kind)
	add_child(sprite)
	var shape := RectangleShape2D.new()
	shape.size = Vector2(32, 18)
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	collision.position = Vector2(0, 5)
	collision.shape = shape
	add_child(collision)
	var area := Area2D.new()
	area.name = "InteractionArea"
	area.collision_layer = 4
	area.collision_mask = 0
	var target_shape := RectangleShape2D.new()
	target_shape.size = Vector2(42, 32)
	var target := CollisionShape2D.new()
	target.shape = target_shape
	area.add_child(target)
	add_child(area)
	var label := Shell.label(MARKERS.get(object_kind, "?"), 7, Art.SOFT_WHITE)
	label.position = Vector2(-20, 15)
	label.size = Vector2(40, 12)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(label)

func interaction_prompt() -> String:
	return "[%s] OPEN  %s" % [Actions.binding_label("interact", 1).to_upper(), NAMES.get(object_kind, "OBJECT")]

func interact() -> void:
	activated.emit(object_kind)
