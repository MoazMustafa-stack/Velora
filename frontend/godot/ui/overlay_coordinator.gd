extends RefCounted
## Single owner of keyboard context, world lock and focus restoration.
## Inspector visibility is persistent; INSPECTOR means explicit focus, not modal.

enum Mode { NONE, PAUSE, WORKSPACES, NOTIFICATIONS, MEDIA, OBSERVATORY, INSPECTOR }
signal changed(mode: Mode)

var _mode: Mode = Mode.NONE
var current: Mode:
	get: return _mode
var _player: CharacterBody2D
var _hud: CanvasLayer
var _panels: Dictionary
var _prior_focus: WeakRef
var _inspector: Control
var _return_context: Mode = Mode.NONE

func _init(player: CharacterBody2D, hud: CanvasLayer, panels: Dictionary, inspector: Control = null) -> void:
	_player = player
	_hud = hud
	_panels = panels
	_inspector = inspector

func open(mode: Mode) -> void:
	if mode == _mode or mode < Mode.NONE or mode > Mode.INSPECTOR:
		return
	if mode == Mode.INSPECTOR and _inspector == null:
		return
	var was_world := _mode == Mode.NONE
	if mode not in [Mode.NONE, Mode.INSPECTOR] and _mode == Mode.INSPECTOR:
		_return_context = Mode.INSPECTOR
	elif mode in [Mode.NONE, Mode.INSPECTOR]:
		_return_context = Mode.NONE
	_mode = mode
	_hud.set_modal_active(mode not in [Mode.NONE, Mode.INSPECTOR])
	for panel in _panels.values():
		# Hide without emitting a close event that could reenter the coordinator.
		panel.visible = false
	_hud.set_menu_visible(mode == Mode.PAUSE)
	# UI and physics now have different viewports. Focus belongs to the HUD's
	# native UI viewport, never the world SubViewport.
	var viewport := _hud.get_viewport()
	if was_world:
		var focus := viewport.gui_get_focus_owner()
		_prior_focus = weakref(focus) if focus != null else null
	viewport.gui_release_focus()
	if _inspector != null:
		_inspector.set_inspector_focused(false)
	if mode != Mode.NONE:
		_player.set_input_enabled(false)
	if mode == Mode.NONE:
		_player.set_input_enabled(true)
		_player.refresh_interaction()
		if _prior_focus != null:
			var control = _prior_focus.get_ref()
			if is_instance_valid(control) and control.is_visible_in_tree():
				control.grab_focus()
		_prior_focus = null
	elif mode == Mode.INSPECTOR:
		_inspector.set_inspector_focused(true)
	elif _panels.has(mode):
		_panels[mode].open()
	changed.emit(mode)

func close(expected: Mode) -> void:
	# Ignore a late close from a panel that no longer owns input.
	if _mode == expected:
		back()

func toggle(mode: Mode) -> void:
	if _mode == mode: back()
	else: open(mode)

func back() -> void:
	open(_return_context if _mode not in [Mode.NONE, Mode.INSPECTOR] else Mode.NONE)
