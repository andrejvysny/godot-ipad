class_name ObjectSizeVisibility
extends RefCounted
## Per-record projection state. Stable slots keep classification work bounded without world-wide sorts.

const CHUNK := 256
var roles: Dictionary = {}
var representations: Dictionary = {}
var hidden: Dictionary = {}  # id -> visibility decision reason
var size_hidden_count := 0
var behind_hidden_count := 0
var evaluated := 0
var profile: Dictionary = {}
var _ids: Array[String] = []
var _slots: Dictionary = {}
var _cursor := 0
var _remaining := 0
var _again := true
var _retries: Dictionary = {}
var _pinned_retries: Dictionary = {}
var _priority_lane := ObjectVisibilityPriority.new()
var _pass_seen: Dictionary = {}  # id -> classification generation
var _generation := 0
var _next_lane := 0
var _store: ObjectBatchStore


func _init(store: ObjectBatchStore) -> void:
	_store = store


func clear() -> void:
	roles.clear()
	representations.clear()
	clear_visibility()
	_priority_lane.clear()
	_pass_seen.clear()
	_ids.clear()
	_slots.clear()
	_cursor = 0
	_remaining = 0
	_again = true
	_retries.clear()


func upsert(id: String, position: Vector3) -> void:
	_pass_seen.erase(id)
	_priority_lane.restart()
	_priority_lane.upsert(id, _store._cell_key(position))
	if not _slots.has(id):
		_slots[id] = _ids.size()
		_ids.append(id)
	request_pass()


func remove(id: String) -> void:
	_priority_lane.remove(id)
	_pass_seen.erase(id)
	_set_hidden_reason(id, "")
	_retries.erase(id)
	_pinned_retries.erase(id)
	if _slots.has(id):
		var slot: int = _slots[id]
		var last: String = _ids.back()
		_ids[slot] = last
		_slots[last] = slot
		_ids.pop_back()
		_slots.erase(id)
	for dict: Dictionary in [roles, representations, hidden]:
		dict.erase(id)
	_remaining = mini(_remaining, _ids.size())
	request_pass()


func request_pass() -> void:
	_generation += 1
	_again = true


func busy() -> bool:
	return _again or _remaining > 0 or not _retries.is_empty() or not _pinned_retries.is_empty()


func rep_of(id: String) -> String:
	return representations.get(id, RenderWorldResources.PLACEHOLDER)


func attach(id: String) -> void:
	var cell: RenderCell = _store._cells[_store._cell_of[id]]
	var desired: String = roles.get(id, str(profile.get("near_min_role", LodPolicy.MID)))
	var rep: String = representations.get(id, "")
	if rep == "":
		rep = _store._res.rep_for(_store._asset[id], desired, _store._priority(cell))
	representations[id] = rep
	if not hidden.has(id):
		_store._batch_add(cell, id, rep)


func step(snapshot: RenderCameraSnapshot, profile: Dictionary, settled: bool, deadline_usec: int) -> void:
	if Time.get_ticks_usec() >= deadline_usec:
		return
	if _remaining == 0 and _again:
		_again = false
		_remaining = _ids.size()
		_generation += 1
		_priority_lane.restart()
	_priority_lane.set_focus(_store._cell_key(_store._focus), _store._cell_of.get(_store._selected))
	var count := 0
	while busy() and count < CHUNK and Time.get_ticks_usec() < deadline_usec:
		var id := _next_record(settled, deadline_usec)
		count += 1
		if id == "":
			continue
		_classify(id, snapshot, profile, settled)
		if _store.owner_of(id) == "" and not hidden.has(id):
			attach(id)
	if _remaining == 0:
		_cursor = 0


func _next_record(settled: bool, deadline_usec: int) -> String:
	var lane := _next_lane
	_next_lane = (_next_lane + 1) % 3
	if lane == 0 and _remaining > 0:
		var id := _priority_lane.next(_store._cells, _pass_seen, deadline_usec, _generation)
		if id != "":
			_pass_seen[id] = _generation
		return id
	if lane == 1 and _remaining > 0:
		_cursor %= _ids.size()
		var id := _ids[_cursor]
		_cursor += 1
		_remaining -= 1
		if _pass_seen.get(id, -1) == _generation:
			return ""
		_pass_seen[id] = _generation
		return id
	if lane == 2:
		return _next_retry(settled)
	return ""


func _next_retry(settled: bool) -> String:
	# A held pin must not starve settled upgrades or the world pass.
	var queue := _pinned_retries
	if settled and not _retries.is_empty():
		queue = _retries
	var id := _first_retry(queue)
	queue.erase(id)
	return id


func _classify(id: String, snapshot: RenderCameraSnapshot, profile: Dictionary, settled: bool) -> void:
	evaluated += 1
	_retries.erase(id)
	_pinned_retries.erase(id)
	if _store.is_object_pinned(id):
		_pinned_retries[id] = true
		return
	if id == _store._selected:
		return
	var bounds := _store._bounds(_store._asset[id])
	var measure := ProjectedBounds.measure((_store._xf[id] as Transform3D) * bounds, snapshot)
	var decision := RenderVisibilityDecision.evaluate(measure, not hidden.has(id), false, profile)
	var show: bool = decision.visible
	_set_visible(id, show, str(decision.reason))
	if not measure.valid or measure.conservative:
		_transition(id, str(profile.get("near_min_role", LodPolicy.MID)), true, settled)
		return
	var desired := LodPolicy.size_role(measure.reference_px, profile, roles.get(id, ""),
			float(profile.get("lod_hysteresis_fraction", 0.2)))
	_transition(id, desired, show, settled)


func _transition(id: String, desired: String, show: bool, settled: bool) -> void:
	roles[id] = desired
	var current := rep_of(id)
	if desired == current:
		return
	if _rank(desired) < _rank(current) and not settled:
		_retries[id] = true
		return
	var rep := _store._res.rep_for(_store._asset[id], desired, 1)
	if current != RenderWorldResources.PLACEHOLDER and rep != desired:
		return
	if rep == current:
		return
	_switch(id, rep, show)


func _switch(id: String, rep: String, show: bool) -> void:
	var owner := _store.owner_of(id)
	if owner == ObjectPreviewOwners.OWNER:
		representations[id] = rep
		_store._preview.retarget_object(id, rep)
	else:
		if owner != "":
			_store._leave_batch(id)
		_store._owner[id] = ""
		representations[id] = rep
		if show:
			_store._batch_add(_store._cells[_store._cell_of[id]], id, rep)


func _set_visible(id: String, show: bool, reason: String) -> void:
	var was_hidden := hidden.has(id)
	_set_hidden_reason(id, "" if show else reason)
	if was_hidden == (not show):
		return
	var owner := _store.owner_of(id)
	if owner == ObjectPreviewOwners.OWNER:
		_store._preview.refresh_visibility()
	elif owner != "promoted":
		if not show and owner != "":
			_store._leave_batch(id)
			_store._owner[id] = ""
		elif show and owner == "":
			attach(id)


static func _rank(role: String) -> int:
	return {LodPolicy.NEAR: 0, LodPolicy.MID: 1, LodPolicy.FAR: 2}.get(role, 3)


func clear_visibility() -> void:
	_retries.clear()
	_pinned_retries.clear()
	hidden.clear()
	size_hidden_count = 0
	behind_hidden_count = 0


func _set_hidden_reason(id: String, reason: String) -> void:
	var previous: String = hidden.get(id, "")
	if previous == reason:
		return
	size_hidden_count += int(reason == "size_hidden") - int(previous == "size_hidden")
	behind_hidden_count += int(reason == "behind") - int(previous == "behind")
	if reason == "":
		hidden.erase(id)
	else:
		hidden[id] = reason


func pending_state() -> Dictionary:
	return {"remaining": _remaining, "pass_requested": _again, "retries": _retries.size(), "pinned_retries": _pinned_retries.size(),
		"records": _ids.size(), "evaluated": evaluated, "generation": _generation}


func _first_retry(queue: Dictionary) -> String:
	for id: String in queue:
		return id
	return ""
