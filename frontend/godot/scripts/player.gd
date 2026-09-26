extends CharacterBody2D

const Actions = preload("res://scripts/input_actions.gd")
const PixelArt = preload("res://scripts/pixel_art.gd")

signal interaction_changed(prompt: String)
signal interaction_requested(target: Node)
signal menu_requested

@export var walk_speed := 48.0
@export var sprint_speed := 72.0
@export var animation_interval := 0.14

@onready var sprite: Sprite2D = $Sprite2D
@onready var interaction_detector: Area2D = $InteractionDetector

var facing := Vector2.DOWN
var active_interactable: Node = null
var input_enabled := true
var _animation_time := 0.0
var _animation_step := 0
var _last_prompt := ""
var _texture_cache: Dictionary = {}

func _ready() -> void:
	Actions.ensure_registered()
	_update_detector_position()
	_update_sprite()

func _unhandled_input(event: InputEvent) -> void:
	if Actions.pressed(event, "menu"):
		menu_requested.emit()
	elif input_enabled and Actions.pressed(event, "interact") and active_interactable:
		interaction_requested.emit(active_interactable)

func _physics_process(delta: float) -> void:
	if not input_enabled:
		velocity = Vector2.ZERO
		_update_animation(delta, false)
		return
	var movement := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if movement != Vector2.ZERO:
		_set_facing_from_movement(movement)
	var speed := sprint_speed if Input.is_action_pressed("sprint") else walk_speed
	velocity = movement.normalized() * speed
	move_and_slide()
	_update_animation(delta, movement != Vector2.ZERO)
	_update_interaction()

func set_input_enabled(enabled: bool) -> void:
	input_enabled = enabled
	if not enabled:
		velocity = Vector2.ZERO
		active_interactable = null
		_last_prompt = ""
		interaction_changed.emit("")

func refresh_interaction() -> void:
	if input_enabled:
		_update_interaction()

func _set_facing_from_movement(movement: Vector2) -> void:
	if absf(movement.x) > absf(movement.y):
		facing = Vector2.RIGHT if movement.x > 0 else Vector2.LEFT
	else:
		facing = Vector2.DOWN if movement.y > 0 else Vector2.UP
	_update_detector_position()

func _update_detector_position() -> void:
	match facing:
		Vector2.UP:
			interaction_detector.position = Vector2(0, -14)
		Vector2.LEFT:
			interaction_detector.position = Vector2(-12, 4)
		Vector2.RIGHT:
			interaction_detector.position = Vector2(12, 4)
		_:
			interaction_detector.position = Vector2(0, 14)

func _update_animation(delta: float, moving: bool) -> void:
	if moving:
		_animation_time += delta
		if _animation_time >= animation_interval:
			_animation_time = 0.0
			_animation_step = 1 - _animation_step
	else:
		_animation_time = 0.0
		_animation_step = 0
	_update_sprite()

func _update_sprite() -> void:
	var key := "%s:%d" % [_facing_name(), _animation_step]
	if not _texture_cache.has(key):
		_texture_cache[key] = PixelArt.create_player_texture(facing, _animation_step)
	sprite.texture = _texture_cache[key]

func _facing_name() -> String:
	if facing == Vector2.UP:
		return "up"
	if facing == Vector2.LEFT:
		return "left"
	if facing == Vector2.RIGHT:
		return "right"
	return "down"

func _update_interaction() -> void:
	var closest: Node = null
	var closest_distance := INF
	for area in interaction_detector.get_overlapping_areas():
		var candidate := area.get_parent()
		if not candidate.has_method("interact") or not candidate.has_method("interaction_prompt"):
			continue
		var distance := global_position.distance_squared_to(candidate.global_position)
		if distance < closest_distance:
			closest = candidate
			closest_distance = distance
	active_interactable = closest
	var prompt: String = active_interactable.interaction_prompt() if active_interactable else ""
	if prompt != _last_prompt:
		_last_prompt = prompt
		interaction_changed.emit(prompt)
