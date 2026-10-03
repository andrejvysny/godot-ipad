extends TestCase
## Commit deltas derived from WorldChange, delta ZIP round trip, and the incremental authored hash cache.

const LOC := Vector2i(0, 0)
const SPRUCE := "nature.tree.spruce_a"
const BOULDER := "nature.rock.boulder_a"
const PID := "11111111-1111-4111-8111-111111111111"

var _doc: WorldDocument
var _catalog: AssetCatalog


func before_each() -> void:
	_catalog = AssetCatalog.load_from()[0]
	_doc = WorldDocument.create_flat(0.0, ControlCodec.grass_value(), null, _catalog)


func _change(mutator: Callable) -> WorldChange:
	var tx := EditTransaction.new()
	tx.begin(_doc, "t", "t")
	mutator.call(tx)
	return tx.finish()


## Builds the commit delta of `change` and parses it back; {delta, error}.
func _roundtrip(change: WorldChange, forward := true, files := {}) -> Dictionary:
	var path := scratch_dir() + "/commit.delta"
	var ident := {"world_id": _doc.world_id, "stream_id": LiveIds.new_id(), "operation_id": change.operation_id,
		"base_revision": 4, "base_hash": "aa".repeat(32), "target_revision": 5, "target_hash": "bb".repeat(32)}
	var res := WorldDeltaBuilder.build_commit(change, forward, ident, files, path)
	assert_true(res.ok, res.error)
	var parsed := WorldDelta.parse(path, _doc.layout, {"kind": "commit", "stream_id": ident.stream_id})
	assert_true(parsed.ok, parsed.get("error", ""))
	return parsed


func _tiles(delta: Dictionary) -> Array:
	return (delta.tiles as Array).map(func(t: Dictionary) -> String: return "%s:%d,%d:%s" % [str(t.loc), t.tx, t.tz, t.kind])


func test_sculpt_delta_has_exactly_the_changed_tiles_with_absolute_bytes() -> void:
	var change := _change(func(tx: EditTransaction) -> void:
		tx.capture_heights(LOC)
		var h := _doc.get_region(LOC).heights
		h[0] = 1.5  # tile (0,0)
		h[3 * 64 + 5 * 256 + 64 * 256 * 2] = -2.0  # tile (3,2)
		_doc.get_region(LOC).heights = h)
	var delta: Dictionary = _roundtrip(change).delta
	assert_eq(_tiles(delta), ["(0, 0):0,0:height_f32le", "(0, 0):3,2:height_f32le"])
	for t: Dictionary in delta.tiles:
		assert_eq((t.bytes as PackedByteArray).size(), 16384)
	var first := (delta.tiles[0].bytes as PackedByteArray).to_float32_array()
	assert_eq(first[0], 1.5, "absolute after-value")
	assert_eq(delta.upserts.size() + delta.deletes.size(), 0)
	assert_false(delta.has("scatter") or delta.has("paths") or delta.has("lock") or delta.has("rules"))
	var undo: Dictionary = _roundtrip(change, false).delta
	assert_eq((undo.tiles[0].bytes as PackedByteArray).to_float32_array()[0], 0.0, "undo carries the before-value")


func test_paint_tint_and_hole_deltas_use_their_map_kinds() -> void:
	var change := _change(func(tx: EditTransaction) -> void:
		tx.capture_controls(LOC)
		tx.capture_colors(LOC)
		var r := _doc.get_region(LOC)
		r.control[10] = ControlCodec.encode_paint(r.control[10] & 0xFFFFFFFF, 200)
		r.control[100 + 256 * 70] = (r.control[0] & 0xFFFFFFFF) | ControlCodec.HOLE_BIT
		r.color[(3 * 64 + 3 * 64 * 256) * 4] = 9)
	var delta: Dictionary = _roundtrip(change).delta
	assert_eq(_tiles(delta), ["(0, 0):0,0:control_u32le", "(0, 0):1,1:control_u32le", "(0, 0):3,3:color_rgba8"])


func test_object_scatter_path_and_rules_changes_travel_as_whole_values() -> void:
	var id := ObjectRecord.new_uuid_v4()
	var existing := ObjectRecord.new()
	existing.object_id = ObjectRecord.new_uuid_v4()
	existing.binding_id = _doc.assets.bundled_binding_for(SPRUCE)
	_doc.put_object(existing)
	var change := _change(func(tx: EditTransaction) -> void:
		tx.capture_object(id)
		tx.capture_object(existing.object_id)
		var rec := ObjectRecord.new()
		rec.object_id = id
		rec.binding_id = _doc.assets.bundled_binding_for(BOULDER)
		_doc.put_object(rec)
		_doc.remove_object(existing.object_id)
		tx.capture_scatter()
		_doc.scatter.add(rec.binding_id, 1.0, 2.0, 0.0, 1.0, 0)
		tx.capture_path(PID)
		var p := PathRecord.new()
		p.path_id = PID
		p.width_m = 2.0
		p.points = PackedVector2Array([Vector2(0, 0), Vector2(5, 5)])
		_doc.put_path(p)
		tx.capture_rules()
		_doc.rules.sand_height_dm = 3)
	var cache := AuthoredHashCache.new()
	cache.hash_of(_doc)
	var files := {"asset_lock_file": cache.lock_bytes(), "scatter_file": _doc.scatter.encode(),
		"paths_file": PathRecord.encode_all(_doc.paths)}
	var delta: Dictionary = _roundtrip(change, true, files).delta
	assert_eq(delta.upserts.size(), 1)
	assert_eq(delta.upserts[0].object_id, id)
	assert_eq(delta.deletes, [existing.object_id])
	assert_eq((delta.scatter as ScatterLayer).count(), 1, "complete scatter.bin, never patched")
	assert_eq((delta.paths as Dictionary).keys(), [PID])
	assert_eq((delta.rules as TerrainRules).sand_height_dm, 3)
	assert_true(delta.has("lock"))
	var undo: Dictionary = _roundtrip(change, false).delta
	assert_eq(undo.deletes, [id], "undo of a creation deletes it")
	assert_eq(undo.upserts[0].object_id, existing.object_id, "undo of a deletion restores it")
	assert_eq((undo.rules as TerrainRules).sand_height_dm, TerrainRules.defaults().sand_height_dm)


func test_preview_delta_round_trips_tiles_objects_scatter_and_bindings() -> void:
	var path := scratch_dir() + "/preview.delta"
	var tile := PackedByteArray()
	tile.resize(16384)
	tile[0] = 9
	var rec := ObjectRecord.new()
	rec.object_id = ObjectRecord.new_uuid_v4()
	rec.binding_id = _doc.assets.bundled_binding_for(SPRUCE)
	var layer := ScatterLayer.new()
	layer.add(rec.binding_id, 3.0, 4.0, 0.0, 1.0, 0)
	var wpst := LiveScatterTile.encode(layer, PackedInt32Array([0]))
	var ident := {"world_id": _doc.world_id, "stream_id": LiveIds.new_id(), "operation_id": "op1",
		"base_revision": 2, "preview_seq": 4}
	var rows := [_doc.assets.get_binding(rec.binding_id).to_dict(true)]
	var res := WorldDeltaBuilder.build_preview(ident, [{"loc": LOC, "tx": 1, "tz": 2, "kind": LiveTiles.KIND_COLOR,
		"bytes": tile}], [rec], ["22222222-2222-4222-8222-222222222222"], [{"loc": LOC, "tx": 0, "tz": 0, "bytes": wpst}], rows, path)
	assert_true(res.ok, res.error)
	var parsed := WorldDelta.parse(path, _doc.layout, {"kind": "preview", "preview_seq": 4, "operation_id": "op1"})
	assert_true(parsed.ok, parsed.get("error", ""))
	var d: Dictionary = parsed.delta
	assert_eq(d.preview_seq, 4)
	assert_eq(d.target_hash, "", "a preview never carries an authoritative hash")
	assert_eq(d.upserts.size(), 1)
	assert_eq(d.scatter_tiles.size(), 1)
	assert_eq(d.provisional.size(), 1)
	assert_false(d.has("scatter"), "commit-only members are absent")


func test_wpst_validation_rejects_instances_outside_the_tile() -> void:
	var layer := ScatterLayer.new()
	layer.add("b" + "1".repeat(32), 40.0, 4.0, 0.0, 1.0, 0)  # tile x range is [0, 32)
	var bytes := LiveScatterTile.encode(layer, PackedInt32Array([0]))
	assert_false(LiveScatterTile.validate(bytes, Rect2(0, 0, 32, 32)).ok, "outside the tile")
	assert_true(LiveScatterTile.validate(bytes, Rect2(32, 0, 32, 32)).ok)
	assert_false(LiveScatterTile.validate(bytes.slice(0, bytes.size() - 1), Rect2(32, 0, 32, 32)).ok, "truncated")


# --- AuthoredHashCache ------------------------------------------------------------------------------

func test_cache_equals_the_canonical_hash_and_recomputes_only_what_changed() -> void:
	var cache := AuthoredHashCache.new()
	assert_eq(cache.hash_of(_doc), CanonicalEncoder.authored_hash(_doc), "first hash")
	assert_eq(cache.maps_hashed, 12, "four regions x three maps hashed once")
	var change := _change(func(tx: EditTransaction) -> void:
		tx.capture_heights(LOC)
		_doc.get_region(LOC).heights[5] = 1.0)
	cache.invalidate_change(change)
	assert_eq(cache.hash_of(_doc), CanonicalEncoder.authored_hash(_doc), "after a sculpt")
	assert_eq(cache.maps_hashed, 1, "only the changed map")
	assert_eq(cache.objects_encoded, 0)
	var rec := ObjectRecord.new()
	rec.object_id = ObjectRecord.new_uuid_v4()
	rec.binding_id = _doc.assets.bundled_binding_for(SPRUCE)
	var place := _change(func(tx: EditTransaction) -> void:
		tx.capture_object(rec.object_id)
		_doc.put_object(rec))
	cache.invalidate_change(place)
	assert_eq(cache.hash_of(_doc), CanonicalEncoder.authored_hash(_doc), "after placing an object")
	assert_eq(cache.maps_hashed, 0)
	assert_eq(cache.objects_encoded, 1)
	assert_true(cache.lock_binding_ids().has(rec.binding_id), "its binding entered the lock")
	var move := _change(func(tx: EditTransaction) -> void:
		tx.capture_object(rec.object_id)
		var c := rec.clone()
		c.set_position(3.0, 0.0, 3.0)
		_doc.put_object(c))
	cache.invalidate_change(move)
	assert_eq(cache.hash_of(_doc), CanonicalEncoder.authored_hash(_doc), "after moving it")
	assert_eq(cache.objects_encoded, 1)
	var remove := _change(func(tx: EditTransaction) -> void:
		tx.capture_object(rec.object_id)
		_doc.remove_object(rec.object_id))
	cache.invalidate_change(remove)
	assert_eq(cache.hash_of(_doc), CanonicalEncoder.authored_hash(_doc), "after deleting it")
	assert_false(cache.lock_binding_ids().has(rec.binding_id), "unreferenced binding left the lock")


func test_cache_tracks_scatter_paths_rules_and_other_documents() -> void:
	var cache := AuthoredHashCache.new()
	cache.hash_of(_doc)
	var change := _change(func(tx: EditTransaction) -> void:
		tx.capture_scatter()
		_doc.scatter.add(_doc.assets.bundled_binding_for(BOULDER), 4.0, 4.0, 0.0, 1.0, 0)
		tx.capture_path(PID)
		var p := PathRecord.new()
		p.path_id = PID
		p.points = PackedVector2Array([Vector2(0, 0), Vector2(5, 5)])
		_doc.put_path(p)
		tx.capture_rules()
		_doc.rules.rock_enabled = false)
	cache.invalidate_change(change)
	assert_eq(cache.hash_of(_doc), CanonicalEncoder.authored_hash(_doc))
	assert_eq(cache.maps_hashed, 0, "terrain digests were reused")
	var other := WorldDocument.create_flat(1.0, ControlCodec.grass_value(), null, _catalog)
	assert_eq(cache.hash_of(other), CanonicalEncoder.authored_hash(other), "another document instance resets the cache")
