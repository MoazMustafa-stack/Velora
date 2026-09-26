extends SceneTree

const Tokens = preload("res://ui/design_tokens.gd")

func _initialize() -> void:
	assert(Tokens.CANVAS == Vector2i(320, 180))
	assert(Tokens.TILE_SIZE == Vector2i(16, 16))
	assert(Tokens.TONES == {"ready": Color("9af4e7"), "waiting": Color("f5b943"), "failure": Color("e05a67")})
	assert(Tokens.WORLD_AMBER == Color("f5b942"))
	assert(Tokens.WORLD_TEXT == Color("dce6f2"))
	assert(Tokens.PANEL_POSITION.x + Tokens.PANEL_WIDTH <= Tokens.CANVAS.x)
	print("D6.01 design token validation passed.")
	quit()
