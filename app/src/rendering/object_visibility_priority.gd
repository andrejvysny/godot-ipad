class_name ObjectVisibilityPriority
extends RefCounted
## Stable cell slots avoid copying dense membership dictionaries during a render frame.

var _members: Dictionary = {}
var _cell_of: Dictionary = {}
var _slots: Dictionary = {}
var _keys: Array[Vector2i] = []
var _focus := Vector2i(2147483647, 2147483647)
var _selected: Variant
var _cell_cursor := 0
var _record_cursor := 0
var _active_generation := -1
var _wrapped_generation := -1


func clear() -> void:
	_members.clear()
	_cell_of.clear()
	_slots.clear()
	_keys.clear()
	_focus = Vector2i(2147483647, 2147483647)
	_selected = null
	restart()


func upsert(id: String, key: Vector2i) -> void:
	if _cell_of.get(id) == key:
		return
	remove(id)
	if not _members.has(key):
		_members[key] = [] as Array[String]
	var ids: Array[String] = _members[key]
	_slots[id] = ids.size()
	ids.append(id)
	_cell_of[id] = key


func remove(id: String) -> void:
	if not _cell_of.has(id):
		return
	var key: Vector2i = _cell_of[id]
	var ids: Array[String] = _members[key]
	var slot: int = _slots[id]
	ids[slot] = ids.back()
	_slots[ids[slot]] = slot
	ids.pop_back()
	_slots.erase(id)
	_cell_of.erase(id)
	if ids.is_empty():
		_members.erase(key)


func restart() -> void:
	_cell_cursor = 0
	_record_cursor = 0
	_active_generation = -1
	_wrapped_generation = -1


func set_focus(focus: Vector2i, selected: Variant) -> void:
	if focus == _focus and selected == _selected:
		return
	_focus = focus
	_selected = selected
	_keys.clear()
	if selected is Vector2i:
		_keys.append(selected)
	if not _keys.has(focus):
		_keys.append(focus)
	# Fixed near-focus cells bound scheduling work independently of world size.
	for radius in range(1, 4):
		for x in range(-radius, radius + 1):
			for z in range(-radius, radius + 1):
				if maxi(absi(x), absi(z)) != radius:
					continue
				var key := focus + Vector2i(x, z)
				if key != selected:
					_keys.append(key)
	restart()


func next(cells: Dictionary, seen: Dictionary, deadline_usec: int, generation: int = 0) -> String:
	if _active_generation != generation:
		if _active_generation == -1:
			_wrapped_generation = generation
		_active_generation = generation
	while Time.get_ticks_usec() < deadline_usec:
		if _cell_cursor >= _keys.size():
			if _keys.is_empty() or _wrapped_generation == generation:
				return ""
			# Continue the old cursor first, then revisit its prefix under the new camera.
			_wrapped_generation = generation
			_cell_cursor = 0
			_record_cursor = 0
		var key := _keys[_cell_cursor]
		var ids: Array[String] = _members.get(key, [] as Array[String])
		if not cells.has(key) or _record_cursor >= ids.size():
			_cell_cursor += 1
			_record_cursor = 0
			continue
		var id := ids[_record_cursor]
		_record_cursor += 1
		if seen.get(id, -1) != generation:
			return id
	return ""
