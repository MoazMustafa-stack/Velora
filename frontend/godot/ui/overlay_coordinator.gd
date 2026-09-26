extends RefCounted
## Single owner of modal state, world input lock and focus restoration.

enum Mode { NONE, PAUSE, WORKSPACES, NOTIFICATIONS, MEDIA }

var _mode: Mode = Mode.NONE
var current: Mode:
	get: return _mode
var _player: CharacterBody2D
var _hud: CanvasLayer
var _panels: Dictionary
var _prior_focus: WeakRef

func _init(player: CharacterBody2D, hud: CanvasLayer, panels: Dictionary) -> void:
	_player = player
	_hud = hud
	_panels = panels

func open(mode: Mode) -> void:
	if mode == _mode or mode < Mode.NONE or mode > Mode.MEDIA:
		return
	var was_world := _mode == Mode.NONE
	_mode = mode
	for panel in _panels.values():
		# Hide without emitting a close event that could reenter the coordinator.
		panel.visible = false
	_hud.set_menu_visible(mode == Mode.PAUSE)
	if was_world:
		var viewport := _player.get_viewport()
		var focus := viewport.gui_get_focus_owner()
		_prior_focus = weakref(focus) if focus != null else null
		viewport.gui_release_focus()
		_player.set_input_enabled(false)
	if mode == Mode.NONE:
		_player.set_input_enabled(true)
		_player.refresh_interaction()
		if _prior_focus != null:
			var control = _prior_focus.get_ref()
			if is_instance_valid(control) and control.is_visible_in_tree():
				control.grab_focus()
		_prior_focus = null
	elif _panels.has(mode):
		_panels[mode].open()

func close(expected: Mode) -> void:
	# Ignore a late close from a panel that no longer owns input.
	if _mode == expected:
		open(Mode.NONE)

func toggle(mode: Mode) -> void:
	open(Mode.NONE if _mode == mode else mode)

func back() -> void:
	open(Mode.NONE)
