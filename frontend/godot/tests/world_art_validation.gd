extends SceneTree
const Art = preload("res://scripts/pixel_art.gd")
var failed := false

func check(value: bool, message: String) -> void:
	if not value: failed = true; push_error(message)

func _initialize() -> void:
	var masks: Array[String] = []
	for kind in ["code", "browser", "terminal", "map", "media", "notifications", "observatory"]:
		var station: bool = kind in ["code", "browser", "terminal"]
		var texture: ImageTexture = Art.workstation_texture("ready", Art.CYAN, kind) if station else Art.hub_object_texture(kind)
		var again: ImageTexture = Art.workstation_texture("ready", Art.CYAN, kind) if station else Art.hub_object_texture(kind)
		check(texture == again, "Generated textures are cached: " + kind)
		var image := texture.get_image()
		check(image.get_size() == Vector2i(32, 32), "Object uses the 16px grammar")
		var mask := ""
		for y in range(28):
			for x in range(32): mask += "#" if image.get_pixel(x, y).a > 0.5 else "."
		check(mask not in masks, "Silhouette is color-independent and distinct: " + kind)
		masks.append(mask)
	if not failed: print("D6.05 cached world-art validation passed")
	quit(1 if failed else 0)
