extends Node
## Rendering-only composition: an unscaled physics world in a small viewport,
## integer-enlarged below the header. No transport, selection or input ownership.
const W = preload("res://ui/design_tokens.gd").Workshop
var world_viewport: SubViewport
var stage: TextureRect
var _panels: Array = []

func configure(world: Node2D, hud: CanvasLayer, panels: Array) -> void:
	_panels = panels
	world_viewport = SubViewport.new()
	world_viewport.name = "WorkshopWorld"
	world_viewport.size = W.WORLD_VIEW
	world_viewport.world_2d = World2D.new()
	world_viewport.disable_3d = true
	world_viewport.gui_disable_input = true
	world_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(world_viewport)
	world.reparent(world_viewport, false)
	var layer := CanvasLayer.new()
	layer.layer = 0
	add_child(layer)
	var background := ColorRect.new()
	background.size = Vector2(W.CANVAS)
	background.color = W.BACKGROUND
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(background)
	stage = TextureRect.new()
	stage.name = "WorkshopWorldView"
	stage.texture = world_viewport.get_texture()
	stage.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	stage.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stage.position = Vector2(W.WORLD.position)
	stage.size = Vector2(W.WORLD.size)
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(stage)
	hud.configure_workshop()
	for panel in _panels:
		panel.transform = Transform2D.IDENTITY.scaled(Vector2(2, 2))
		for child in panel.get_children():
			if child is ColorRect:
				child.set_anchors_preset(Control.PRESET_TOP_LEFT)
				child.position = Vector2(0, 12)
				child.size = Vector2(320, 128)
			elif child is PanelContainer:
				# Compact existing shell spacing only. Domain skins/actions remain
				# legacy; their wider visual redesign belongs to R6.08, not here.
				var style := child.get_theme_stylebox("panel").duplicate() as StyleBox
				style.set_content_margin(SIDE_TOP, 0)
				style.set_content_margin(SIDE_BOTTOM, 0)
				child.add_theme_stylebox_override("panel", style)
				var margin := child.get_child(0) as MarginContainer
				margin.add_theme_constant_override("margin_top", 2)
				margin.add_theme_constant_override("margin_bottom", 2)
				var box := margin.get_child(0) as VBoxContainer
				box.add_theme_constant_override("separation", 2)
	call_deferred("fit_panels")

func fit_panels() -> void:
	for panel in _panels:
		for child in panel.get_children():
			if child is PanelContainer:
				_compact_rows(child)
				child.reset_size()
				# Centre within the world band without covering header/inspector.
				child.position.y = 12 + maxf(0, (128 - child.size.y) / 2.0)

func _compact_rows(parent: Node) -> void:
	for child in parent.get_children():
		if child is PanelContainer and child.has_theme_stylebox_override("panel"):
			# Row styles are instance-owned and retained by selection rendering.
			# Keep that identity; replacing them would break live row highlighting.
			var style: StyleBox = child.get_theme_stylebox("panel")
			style.set_content_margin(SIDE_TOP, 0)
			style.set_content_margin(SIDE_BOTTOM, 0)
		_compact_rows(child)

func forward_world_input(event: InputEvent) -> bool:
	world_viewport.push_input(event)
	return world_viewport.is_input_handled()
