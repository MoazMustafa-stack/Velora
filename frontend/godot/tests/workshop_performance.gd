extends "res://tests/phase_six_performance.gd"
## Reuse the existing 600-frame workload and thresholds, changing composition only.
const Composition = preload("res://tests/workshop_composition.gd")
var fixture: Node
var movement_only := OS.get_environment("VELORA_WORKSHOP_WORKLOAD") == "movement"

func create_main() -> Node:
	var width := int(OS.get_environment("VELORA_WORKSHOP_WIDTH"))
	assert(width in [320, 640])
	fixture = Composition.new(Vector2i(width, width * 9 / 16))
	root.add_child(fixture)
	fixture.present(root)
	return fixture.main

func apply_workload(frame: int) -> void:
	if movement_only:
		release_movement()
		Input.action_press("sprint")
		Input.action_press(["move_right", "move_down", "move_left", "move_up"][(frame / 150) % 4])
	else:
		super.apply_workload(frame)
		if frame % 100 == 0:
			fixture.set_sample(["ready", "waiting", "long-text", "offline", "empty", "ready"][(frame / 100) % 6])

func benchmark_metadata() -> Dictionary:
	return {"card": "R6.01", "native_size": [fixture.native_size.x, fixture.native_size.y],
		"world_viewport": [320, 128], "world_texture_integer_scale": fixture.scale_factor,
		"window_size": [root.size.x, root.size.y],
		"presentation_content_size": [root.content_scale_size.x, root.content_scale_size.y],
		"workload": "movement-only with static synthetic UI" if movement_only else "inherited D6.13 crowded workload plus cycling mock inspector states",
		"scope": "Isolated native blockout; same physics; legacy modals enlarged as texture-coordinate equivalent; no production resolution choice, IO, transport or audio"}
