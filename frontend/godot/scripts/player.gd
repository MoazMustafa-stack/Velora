extends CharacterBody3D

signal interaction_changed(prompt: String)

@export var walk_speed: float = 4.0
@export var sprint_speed: float = 7.0
@export var mouse_sensitivity: float = 0.0025
@export var gravity: float = 18.0

@onready var camera: Camera3D = $Camera3D
@onready var interact_ray: RayCast3D = $Camera3D/InteractRay

var active_interactable: Node = null
var mouse_captured := true

func _ready() -> void:
	_register_controls()
	set_mouse_captured(true)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("release_mouse"):
		set_mouse_captured(not mouse_captured)
		return
	if event is InputEventMouseMotion and mouse_captured:
		rotate_y(-event.relative.x * mouse_sensitivity)
		camera.rotate_x(-event.relative.y * mouse_sensitivity)
		camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-80), deg_to_rad(80))
	if event.is_action_pressed("interact") and mouse_captured and active_interactable:
		active_interactable.interact()

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = -0.1
	var movement := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(movement.x, 0, movement.y)).normalized()
	var speed := sprint_speed if Input.is_action_pressed("sprint") else walk_speed
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	move_and_slide()
	_update_interaction()

func set_mouse_captured(captured: bool) -> void:
	mouse_captured = captured
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE

func _update_interaction() -> void:
	var target: Node = interact_ray.get_collider() if interact_ray.is_colliding() else null
	if target == active_interactable:
		return
	active_interactable = target if target and target.has_method("interact") else null
	interaction_changed.emit(active_interactable.interaction_prompt() if active_interactable else "")

func _register_controls() -> void:
	_register_key("move_forward", KEY_W)
	_register_key("move_back", KEY_S)
	_register_key("move_left", KEY_A)
	_register_key("move_right", KEY_D)
	_register_key("sprint", KEY_SHIFT)
	_register_key("interact", KEY_E)
	_register_key("release_mouse", KEY_ESCAPE)

func _register_key(action: StringName, keycode: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	InputMap.action_add_event(action, event)
