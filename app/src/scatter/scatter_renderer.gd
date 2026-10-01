class_name ScatterRenderer
extends Node3D
## Draws the document's scatter layer with one MultiMeshInstance3D per (32 m cell, asset)
## (docs/editor-v2.md §6). Instance Y is the bilinear terrain height (instances without a
## sample are skipped); an align flag tilts the instance to the terrain normal. Cells are rebuilt
## only when marked dirty (scatter edits or height edits under them), once per frame in flush().
## Ground-cover assets cast no shadows. Never mutates the document.

const CELL_M := 32.0
const GROUND_COVER := "ground_cover"
const FLOATS_PER_INSTANCE := 12  # MultiMesh 3D transform buffer: three rows of (basis row, origin)

var last_rebuild_ms := 0.0

var _catalog: AssetCatalog
var _doc: WorldDocument
var _meshes := {}  # asset_id -> Mesh (null cached for assets without a usable mesh)
var _nodes := {}  # Vector2i cell -> {asset_id -> MultiMeshInstance3D}
var _data := {}  # Vector2i cell -> {asset_id -> PackedFloat32Array transform buffer as uploaded}
var _buckets := {}  # Vector2i cell -> {asset_id -> PackedInt32Array layer indices}
var _buckets_valid := false
var _dirty := {}  # Vector2i cell -> true


func setup(catalog: AssetCatalog) -> void:
	_catalog = catalog
	_meshes = {}


func _process(_delta: float) -> void:
	flush()


## Frees everything and draws `doc.scatter` from scratch.
func rebuild_all(doc: WorldDocument) -> void:
	var t0 := Time.get_ticks_usec()
	_doc = doc
	for cell: Vector2i in _nodes.keys():
		_free_cell(cell)
	_buckets_valid = false
	mark_all()
	_flush_dirty()
	last_rebuild_ms = float(Time.get_ticks_usec() - t0) / 1000.0


## Marks every cell overlapping `rect` (world XZ). `heights_only` means instance membership is
## unchanged (a height edit), so the cell index stays valid.
func mark_rect(rect: Rect2, heights_only: bool = false) -> void:
	if not heights_only:
		_buckets_valid = false
	var lo := _cell_of(rect.position.x, rect.position.y)
	var hi := _cell_of(rect.end.x, rect.end.y)
	for cz in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			_dirty[Vector2i(cx, cz)] = true


func mark_all() -> void:
	_buckets_valid = false
	mark_rect(Rect2(WorldConstants.WORLD_MIN, WorldConstants.WORLD_MIN, 256.0, 256.0))


func has_dirty() -> bool:
	return not _dirty.is_empty()


## Rebuilds the dirty cells only. Per-frame work.
func flush() -> void:
	if _dirty.is_empty() or _doc == null:
		return
	var t0 := Time.get_ticks_usec()
	_flush_dirty()
	last_rebuild_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func stats() -> Dictionary:
	var instances := 0
	var multimeshes := 0
	for cell: Vector2i in _data:
		for asset_id: String in _data[cell]:
			instances += (_data[cell][asset_id] as PackedFloat32Array).size() / FLOATS_PER_INSTANCE
			multimeshes += 1
	return {"instances": instances, "cells": _data.size(), "multimeshes": multimeshes,
			"last_rebuild_ms": last_rebuild_ms}


func rendered_count(cell: Vector2i, asset_id: String) -> int:
	var buffer: PackedFloat32Array = (_data.get(cell, {}) as Dictionary).get(asset_id, PackedFloat32Array())
	return buffer.size() / FLOATS_PER_INSTANCE


## Transform of instance `k` of a MultiMesh as last uploaded (the headless renderer cannot read
## it back from the MultiMesh).
func instance_transform(cell: Vector2i, asset_id: String, k: int) -> Transform3D:
	var b: PackedFloat32Array = (_data.get(cell, {}) as Dictionary).get(asset_id, PackedFloat32Array())
	var o := k * FLOATS_PER_INSTANCE
	return Transform3D(Basis(Vector3(b[o], b[o + 4], b[o + 8]), Vector3(b[o + 1], b[o + 5], b[o + 9]),
			Vector3(b[o + 2], b[o + 6], b[o + 10])), Vector3(b[o + 3], b[o + 7], b[o + 11]))


func multimesh_for(cell: Vector2i, asset_id: String) -> MultiMeshInstance3D:
	return (_nodes.get(cell, {}) as Dictionary).get(asset_id)


static func cell_of(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / CELL_M), floori(z / CELL_M))


func _cell_of(x: float, z: float) -> Vector2i:
	return cell_of(clampf(x, WorldConstants.WORLD_MIN, WorldConstants.WORLD_MAX_SAMPLE),
			clampf(z, WorldConstants.WORLD_MIN, WorldConstants.WORLD_MAX_SAMPLE))


func _flush_dirty() -> void:
	if not _buckets_valid:
		_rebucket()
	var cells: Array = _dirty.keys()
	_dirty = {}
	for cell: Vector2i in cells:
		_build_cell(cell)


## One pass over the layer: cell -> asset -> instance indices.
func _rebucket() -> void:
	_buckets = {}
	var layer := _doc.scatter
	for i in layer.count():
		var cell := cell_of(layer.x[i], layer.z[i])
		var by_asset: Dictionary = _buckets.get(cell, {})
		var asset_id := layer.asset_of(i)
		var list: PackedInt32Array = by_asset.get(asset_id, PackedInt32Array())
		list.append(i)
		by_asset[asset_id] = list
		_buckets[cell] = by_asset
	_buckets_valid = true


func _build_cell(cell: Vector2i) -> void:
	var by_asset: Dictionary = _buckets.get(cell, {})
	var existing: Dictionary = _nodes.get(cell, {})
	for asset_id: String in existing.keys():
		if not by_asset.has(asset_id):
			_free_instance(cell, asset_id)
	for asset_id: String in by_asset:
		var mesh := _mesh_for(asset_id)
		if mesh == null:
			continue
		var buffer := _transforms(by_asset[asset_id])
		var count := buffer.size() / FLOATS_PER_INSTANCE
		if count == 0:
			_free_instance(cell, asset_id)
			continue
		var node := _instance_for(cell, asset_id, mesh)
		node.multimesh.instance_count = count
		node.multimesh.buffer = buffer
		var uploaded: Dictionary = _data.get(cell, {})
		uploaded[asset_id] = buffer
		_data[cell] = uploaded
	if (_nodes.get(cell, {}) as Dictionary).is_empty():
		_nodes.erase(cell)
		_data.erase(cell)


## Transform buffer of the instances that have a terrain sample.
func _transforms(indices: PackedInt32Array) -> PackedFloat32Array:
	var layer := _doc.scatter
	var out := PackedFloat32Array()
	out.resize(indices.size() * FLOATS_PER_INSTANCE)
	var o := 0
	for i in indices:
		var x := layer.x[i]
		var z := layer.z[i]
		var h := _doc.sample_height(x, z)
		if is_nan(h):
			continue
		var basis := Basis(Vector3.UP, layer.yaw[i])
		if (layer.flags[i] & ScatterLayer.FLAG_TILT) != 0:
			var normal := _doc.sample_normal(x, z)
			if normal.is_finite():
				basis = Basis(Quaternion(Vector3.UP, normal)) * basis
		basis = basis.scaled(Vector3.ONE * layer.scale[i])
		out[o] = basis.x.x
		out[o + 1] = basis.y.x
		out[o + 2] = basis.z.x
		out[o + 3] = x
		out[o + 4] = basis.x.y
		out[o + 5] = basis.y.y
		out[o + 6] = basis.z.y
		out[o + 7] = h
		out[o + 8] = basis.x.z
		out[o + 9] = basis.y.z
		out[o + 10] = basis.z.z
		out[o + 11] = z
		o += FLOATS_PER_INSTANCE
	out.resize(o)
	return out


func _instance_for(cell: Vector2i, asset_id: String, mesh: Mesh) -> MultiMeshInstance3D:
	var by_asset: Dictionary = _nodes.get(cell, {})
	if by_asset.has(asset_id):
		return by_asset[asset_id]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	var asset := _catalog.get_asset(asset_id)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
			if asset != null and asset.category == GROUND_COVER \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(node)
	by_asset[asset_id] = node
	_nodes[cell] = by_asset
	return node


func _mesh_for(asset_id: String) -> Mesh:
	if _meshes.has(asset_id):
		return _meshes[asset_id]
	var asset := _catalog.get_asset(asset_id) if _catalog != null else null
	var mesh: Mesh = null
	if asset != null and asset.scatter_mesh != "":
		mesh = load(asset.scatter_mesh) as Mesh
	_meshes[asset_id] = mesh
	return mesh


func _free_instance(cell: Vector2i, asset_id: String) -> void:
	var by_asset: Dictionary = _nodes.get(cell, {})
	var node: MultiMeshInstance3D = by_asset.get(asset_id)
	if node != null:
		remove_child(node)
		node.free()
	by_asset.erase(asset_id)
	(_data.get(cell, {}) as Dictionary).erase(asset_id)


func _free_cell(cell: Vector2i) -> void:
	for asset_id: String in (_nodes.get(cell, {}) as Dictionary).keys():
		_free_instance(cell, asset_id)
	_nodes.erase(cell)
	_data.erase(cell)
