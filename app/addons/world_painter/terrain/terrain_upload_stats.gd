class_name TerrainUploadStats
extends RefCounted
## Upload accounting of TerrainAdapter (spec 14.1): bytes and region layers per map kind, coalesced
## marks, phase timings of the last upload and the age of edits at the moment they were uploaded.
## An age is measured from the first mark_dirty of a region/kind to the update_maps call that
## submitted it; the frame that then presents it is not included.

const KIND_NAMES := ["height", "control", "color"]
const AGE_RING := 256

var uploads: PackedInt64Array = PackedInt64Array([0, 0, 0])
var bytes: PackedInt64Array = PackedInt64Array([0, 0, 0])
var coalesced: PackedInt64Array = PackedInt64Array([0, 0, 0])
var copy_ms_last := 0.0
var height_range_ms_last := 0.0
var update_maps_ms_last := 0.0
var last_flush_ms := 0.0
var last_presented_age_ms := 0.0
var _ages := PackedFloat32Array()
var _next := 0


func record_upload(kind: int, regions: int, region_bytes: int, copy_ms: float, range_ms: float, update_ms: float,
		max_age_ms: float, ages_ms: PackedFloat32Array) -> void:
	uploads[kind] += regions
	bytes[kind] += regions * region_bytes
	copy_ms_last = copy_ms
	height_range_ms_last = range_ms
	update_maps_ms_last = update_ms
	last_presented_age_ms = max_age_ms
	for age in ages_ms:
		if _ages.size() < AGE_RING:
			_ages.append(age)
		else:
			_ages[_next] = age
		_next = (_next + 1) % AGE_RING


## `pending`: per map kind, Vector2i -> first mark time (usec).
func to_dict(pending: Array[Dictionary], now_usec: int) -> Dictionary:
	var out := {"last_flush_ms": last_flush_ms, "copy_ms_last": copy_ms_last,
		"height_range_ms_last": height_range_ms_last, "update_maps_ms_last": update_maps_ms_last,
		"last_presented_age_ms": last_presented_age_ms}
	var total := 0
	var oldest := 0.0
	for kind in KIND_NAMES.size():
		var name: String = KIND_NAMES[kind]
		out["uploads_" + name] = uploads[kind]
		out["bytes_uploaded_" + name] = bytes[kind]
		out["coalesced_" + name] = coalesced[kind]
		var marks: Dictionary = pending[kind]
		out["regions_pending_" + name] = marks.size()
		total += marks.size()
		for loc: Vector2i in marks:
			oldest = maxf(oldest, float(now_usec - int(marks[loc])) / 1000.0)
	out.regions_pending = total
	out.oldest_pending_ms = oldest
	return out


## Distribution of recorded upload ages for the bench report.
func latency(pending: Array[Dictionary], now_usec: int) -> Dictionary:
	var sorted := _ages.duplicate()
	sorted.sort()
	var count := sorted.size()
	var oldest := 0.0
	for marks: Dictionary in pending:
		for loc: Vector2i in marks:
			oldest = maxf(oldest, float(now_usec - int(marks[loc])) / 1000.0)
	return {"samples": count, "last_ms": last_presented_age_ms, "oldest_pending_ms": oldest,
		"p50_ms": sorted[count / 2] if count > 0 else 0.0,
		"p95_ms": sorted[mini(count - 1, int(ceil(0.95 * count)) - 1)] if count > 0 else 0.0,
		"max_ms": sorted[count - 1] if count > 0 else 0.0}
