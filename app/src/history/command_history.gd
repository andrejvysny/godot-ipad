class_name CommandHistory
extends RefCounted
## Bounded value-based undo/redo deque (spec §16.2). Session-local, never persisted.
## `_cursor` = number of entries currently applied; entries at index >= _cursor are redo.

var max_actions: int = 20
var max_bytes: int = 64 * 1024 * 1024
var evicted_count: int = 0

var _entries: Array[WorldChange] = []
var _cursor := 0


func _init(p_max_actions: int = 20, p_max_bytes: int = 64 * 1024 * 1024) -> void:
	max_actions = p_max_actions
	max_bytes = p_max_bytes


## `change` has already been applied to the document; it is not executed again.
func push_already_applied(change: WorldChange) -> void:
	_entries.resize(_cursor)  # a new action discards the redo branch
	_entries.append(change)
	_cursor += 1
	while _entries.size() > max_actions or (total_bytes() > max_bytes and _entries.size() > 1):
		_entries.pop_front()
		_cursor -= 1
		evicted_count += 1


func can_undo() -> bool:
	return _cursor > 0


func can_redo() -> bool:
	return _cursor < _entries.size()


## Restores before-values, bumps the revision, and returns the change for presentation.
func undo(doc: WorldDocument) -> WorldChange:
	if not can_undo():
		return null
	_cursor -= 1
	var c := _entries[_cursor]
	c.apply_to(doc, false)
	doc.bump_revision()
	return c


func redo(doc: WorldDocument) -> WorldChange:
	if not can_redo():
		return null
	var c := _entries[_cursor]
	_cursor += 1
	c.apply_to(doc, true)
	doc.bump_revision()
	return c


func clear() -> void:
	_entries.clear()
	_cursor = 0


func size() -> int:
	return _entries.size()


func cursor() -> int:
	return _cursor


func total_bytes() -> int:
	var t := 0
	for e in _entries:
		t += e.payload_bytes
	return t


func peek_undo_label() -> String:
	return _entries[_cursor - 1].label if can_undo() else ""


func peek_redo_label() -> String:
	return _entries[_cursor].label if can_redo() else ""
