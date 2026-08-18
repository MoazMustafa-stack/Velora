extends CharacterBody2D

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
	_register_controls()
	_update_detector_position()
	_update_sprite()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu"):
		menu_requested.emit()
	elif input_enabled and event.is_action_pressed("interact") and active_interactable:
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

func _set_facing_from_movement(movement: Vector2) -> void:
	if absf(movement.x) > absf(movement.y):
		facing = Vector2.RIGHT if movement.x > 0 else Vector2.LEFT
	else:
		facing = Vector2.DOWN if movement.y > 0 else Vector2.UP
	_update_detector_position()

func _update_detector_position() -> void:
	var offsets := {
		Vector2.UP: Vector2(0, -14),
		Vector2.DOWN: Vector2(0, 14),
		Vector2.LEFT: Vector2(-12, 4),
		Vector2.RIGHT: Vector2(12, 4),
	}
	interaction_detector.position = offsets.get(facing, Vector2(0, 14))

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

func _register_controls() -> void:
	_ensure_action("move_up", [KEY_W, KEY_UP])
	_ensure_action("move_down", [KEY_S, KEY_DOWN])
	_ensure_action("move_left", [KEY_A, KEY_LEFT])
	_ensure_action("move_right", [KEY_D, KEY_RIGHT])
	_ensure_action("sprint", [KEY_SHIFT])
	_ensure_action("interact", [KEY_E, KEY_ENTER])
	_ensure_action("menu", [KEY_ESCAPE])

func _ensure_action(action: StringName, keys: Array[int]) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	if not InputMap.action_get_events(action).is_empty():
		return
	for keycode in keys:
		var event := InputEventKey.new()
		event.physical_keycode = keycode
		InputMap.action_add_event(action, event)
