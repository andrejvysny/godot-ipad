class_name ScatterBuckets
extends RefCounted
## Spatial buckets of a ScatterLayer: decorative instances in ground-cover cells, the rest in object
## cells (both floor(world XZ / size)). Kept in sync incrementally against a snapshot of the layer:
##   unchanged layer      -> nothing (a repeated mark_all is free);
##   appended instances   -> only the tail is added (a scatter brush stroke);
##   anything else        -> rescan of the marked rect's cells (an erase), or of the whole layer.
## Every sync returns the changed cells as {Vector3i(cx, cz, kind): true}. Cell objects survive a sync,
## so built state stays attached; an emptied cell stays (count() == 0) until its owner drops it.

var sizes := [16.0, 32.0]  # by ScatterCell.DECORATIVE / MEANINGFUL
var cells := [{}, {}]  # kind -> {Vector2i: ScatterCell}

## Resolves a slot's binding id to its render key (the batch key); without it the binding id is the key.
var assets: WorldAssetLock

var _is_decorative: Callable
var _snap := ScatterLayer.new()


func _init(ground_cover_m: float, objects_m: float, is_decorative: Callable) -> void:
	sizes = [ground_cover_m, objects_m]
	_is_decorative = is_decorative


func reset() -> void:
	cells = [{}, {}]
	_snap = ScatterLayer.new()


func cell(kind: int, key: Vector2i) -> ScatterCell:
	return (cells[kind] as Dictionary).get(key)


func key_of(kind: int, x: float, z: float) -> Vector2i:
	var s: float = sizes[kind]
	return Vector2i(floori(x / s), floori(z / s))


func erase(kind: int, key: Vector2i) -> void:
	(cells[kind] as Dictionary).erase(key)


func sync(layer: ScatterLayer, rect: Rect2, whole: bool) -> Dictionary:
	if _is_synced(layer):
		return {}
	if _is_append_only(layer):
		return _append(layer)
	return _rescan(layer, null if whole or not rect.has_area() else rect)


func _is_synced(layer: ScatterLayer) -> bool:
	return layer.count() == _snap.count() and layer.binding_ids == _snap.binding_ids and layer.slot == _snap.slot \
			and layer.x == _snap.x and layer.z == _snap.z and layer.yaw == _snap.yaw \
			and layer.scale == _snap.scale and layer.flags == _snap.flags


func _is_append_only(layer: ScatterLayer) -> bool:
	var n := _snap.count()
	if layer.count() <= n or layer.binding_ids.size() < _snap.binding_ids.size():
		return false
	return layer.binding_ids.slice(0, _snap.binding_ids.size()) == _snap.binding_ids \
			and layer.slot.slice(0, n) == _snap.slot and layer.x.slice(0, n) == _snap.x \
			and layer.z.slice(0, n) == _snap.z and layer.yaw.slice(0, n) == _snap.yaw \
			and layer.scale.slice(0, n) == _snap.scale and layer.flags.slice(0, n) == _snap.flags


## Render key per slot (the catalog asset id of an available bundled binding, else the binding id).
func slot_keys(layer: ScatterLayer) -> PackedStringArray:
	var keys := PackedStringArray()
	keys.resize(layer.binding_ids.size())
	for s in keys.size():
		var def: AssetDefinition = assets.definition(layer.binding_ids[s]) if assets != null else null
		keys[s] = def.asset_id if def != null else layer.binding_ids[s]
	return keys


func _slot_kinds(keys: PackedStringArray) -> PackedByteArray:
	var kinds := PackedByteArray()
	kinds.resize(keys.size())
	for s in kinds.size():
		kinds[s] = ScatterCell.DECORATIVE if bool(_is_decorative.call(keys[s])) else ScatterCell.MEANINGFUL
	return kinds


func _append(layer: ScatterLayer) -> Dictionary:
	var n0 := _snap.count()
	var keys := slot_keys(layer)
	var kinds := _slot_kinds(keys)
	var changed := {}
	for i in range(n0, layer.count()):
		var kind := kinds[layer.slot[i]]
		var key := key_of(kind, layer.x[i], layer.z[i])
		var c := cell(kind, key)
		if c == null:
			c = ScatterCell.new(key, kind)
			(cells[kind] as Dictionary)[key] = c
		c.add(keys[layer.slot[i]], layer.x[i], layer.z[i], layer.yaw[i], layer.scale[i], layer.flags[i])
		changed[Vector3i(key.x, key.y, kind)] = true
	_snap.binding_ids = layer.binding_ids.duplicate()
	_snap.slot.append_array(layer.slot.slice(n0))
	_snap.x.append_array(layer.x.slice(n0))
	_snap.z.append_array(layer.z.slice(n0))
	_snap.yaw.append_array(layer.yaw.slice(n0))
	_snap.scale.append_array(layer.scale.slice(n0))
	_snap.flags.append_array(layer.flags.slice(n0))
	return changed


## Rebuilds the lists of the cells inside `rect` (all cells when null) from the layer and reports the ones
## whose content differs from before. A partial rescan is one pass over the layer with an early reject on
## the union of the cell ranges, so an erase stroke stays cheap on large layers.
func _rescan(layer: ScatterLayer, rect: Variant) -> Dictionary:
	var keys := slot_keys(layer)
	var kinds := _slot_kinds(keys)
	var lo := [Vector2i.ZERO, Vector2i.ZERO]
	var hi := [Vector2i.ZERO, Vector2i.ZERO]
	var fresh := [{}, {}]
	var wx0 := -INF
	var wz0 := -INF
	var wx1 := INF
	var wz1 := INF
	if rect != null:
		var r: Rect2 = rect
		wx0 = INF
		wz0 = INF
		wx1 = -INF
		wz1 = -INF
		for k in 2:
			lo[k] = key_of(k, r.position.x, r.position.y)
			hi[k] = key_of(k, r.end.x, r.end.y)
			var s: float = sizes[k]
			wx0 = minf(wx0, lo[k].x * s)
			wz0 = minf(wz0, lo[k].y * s)
			wx1 = maxf(wx1, (hi[k].x + 1) * s)
			wz1 = maxf(wz1, (hi[k].y + 1) * s)
	var lx := layer.x
	var lz := layer.z
	for i in layer.count():
		var x := lx[i]
		var z := lz[i]
		if x < wx0 or x >= wx1 or z < wz0 or z >= wz1:
			continue
		var kind := kinds[layer.slot[i]]
		var key := key_of(kind, x, z)
		if rect != null and (key.x < lo[kind].x or key.x > hi[kind].x or key.y < lo[kind].y or key.y > hi[kind].y):
			continue
		var f: Dictionary = fresh[kind]
		var c: ScatterCell = f.get(key)
		if c == null:
			c = ScatterCell.new(key, kind)
			f[key] = c
		c.add(keys[layer.slot[i]], x, z, layer.yaw[i], layer.scale[i], layer.flags[i])
	var changed := {}
	for k in 2:
		_merge(k, fresh[k], null if rect == null else [lo[k], hi[k]], changed)
	_snap = layer.clone()
	return changed


func _merge(kind: int, fresh: Dictionary, range_: Variant, changed: Dictionary) -> void:
	var current: Dictionary = cells[kind]
	for key: Vector2i in current.keys():
		if range_ != null and (key.x < range_[0].x or key.x > range_[1].x or key.y < range_[0].y or key.y > range_[1].y):
			continue
		var old: ScatterCell = current[key]
		if fresh.has(key):
			continue
		if old.count() > 0:
			old.take(ScatterCell.new(key, kind))
			changed[Vector3i(key.x, key.y, kind)] = true
	for key: Vector2i in fresh:
		var old: ScatterCell = current.get(key)
		if old == null:
			current[key] = fresh[key]
			changed[Vector3i(key.x, key.y, kind)] = true
		elif not old.same_data(fresh[key]):
			old.take(fresh[key])
			changed[Vector3i(key.x, key.y, kind)] = true
