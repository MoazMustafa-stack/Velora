extends RefCounted
## Bounded navigation only. Owners decide ordering, stable keys and fallback.

var selected := -1
var offset := 0
var page_size: int

func _init(visible_count: int = 1) -> void:
	page_size = maxi(1, visible_count)

func select(index: int, count: int) -> void:
	if count <= 0:
		selected = -1
		offset = 0
		return
	selected = clampi(index, 0, count - 1)
	if selected < offset:
		offset = selected
	elif selected >= offset + page_size:
		offset = selected - page_size + 1
	offset = clampi(offset, 0, maxi(0, count - page_size))

func move(step: int, count: int) -> void:
	select(0 if selected < 0 or count <= 0 else posmod(selected + step, count), count)

func preserve(keys: Array, key: String, fallback: int) -> void:
	var index := keys.find(key) if not key.is_empty() else -1
	select(index if index >= 0 else fallback, keys.size())
