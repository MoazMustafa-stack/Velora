extends SceneTree

const Cursor = preload("res://ui/list_cursor.gd")
const Shell = preload("res://ui/panel_shell.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var cursor := Cursor.new(4)
	cursor.select(99, 10)
	assert(cursor.selected == 9 and cursor.offset == 6)
	cursor.move(1, 10)
	assert(cursor.selected == 0 and cursor.offset == 0)
	cursor.move(-1, 10)
	assert(cursor.selected == 9 and cursor.offset == 6)
	cursor.preserve(["b", "a"], "a", 0)
	assert(cursor.selected == 1 and cursor.offset == 0)
	cursor.preserve(["c"], "missing", 9)
	assert(cursor.selected == 0)
	cursor.select(1, 0)
	assert(cursor.selected == -1 and cursor.offset == 0)
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var shell := Shell.new(layer)
	var rows := VBoxContainer.new()
	shell.box.add_child(rows)
	var row := Shell.row(rows)
	row.summary.text = "Long text ".repeat(100)
	shell.title.text = "TITLE ".repeat(100)
	shell.finish("ARROWS SELECT")
	await process_frame
	await process_frame
	assert(shell.panel.position.x + shell.panel.size.x <= 320)
	assert(row.summary.clip_text and row.detail.clip_text and shell.hint.clip_text)
	layer.queue_free()
	await process_frame
	print("D6.02 panel primitives validation passed.")
	quit()
