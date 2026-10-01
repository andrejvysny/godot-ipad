class_name RenderAssetCache
extends RefCounted
## Shared deduplicated cache for render-asset mesh/material/texture resources (spec §12).
## Main-thread API. Loads use ResourceLoader threaded requests; completion is polled and
## load_threaded_get is called only for THREAD_LOAD_LOADED. Entries are counted by resolved path,
## so two keys (or owners) naming the same file share one entry and one byte cost. Cancellation is
## logical: queued work is dropped, in-flight work is marked stale and its result discarded on
## completion; the reservation is released only then.

const MIB := 1048576
const KINDS := ["mesh", "material", "texture", "preview_texture"]
const MAX_QUEUE := 512
const MAX_TOMBSTONES := 2048
const TRIM_FRACTION := 0.9


class Entry extends RefCounted:
	var keys: Array[String] = []
	var path: String = ""
	var kind: String = ""
	var state: String = "QUEUED"
	var reason: String = ""
	var bytes: int = 0
	var priority: int = 0
	var seq: int = 0
	var owners: Dictionary = {}  # owner -> tokens
	var pins: Dictionary = {}  # owner -> true
	var fallback: bool = false
	var last_used: int = 0
	var stale: bool = false
	var expect := Vector2i.ZERO
	var resource: Resource


var _soft: int = 384 * MIB
var _ceiling: int = 512 * MIB
var _preview_cap: int = 128 * MIB
var _inflight_cap: int = 2
var _by_key: Dictionary = {}  # key -> Entry
var _by_path: Dictionary = {}  # resolved path -> Entry (unique entries)
var _queue: Array[Entry] = []
var _loading: Array[Entry] = []
var _resident: int = 0
var _reserved: int = 0
var _preview_committed: int = 0  # resident + reserved preview_texture bytes
var _resident_by_kind: Dictionary = {"mesh": 0, "material": 0, "texture": 0, "preview_texture": 0}
var _clock: int = 0
var _seq: int = 0
var _tombstones: int = 0
var _evictions: int = 0
var _discarded: int = 0
var _rejected: int = 0


func _init(budgets: Dictionary = {}) -> void:
	_soft = int(float(budgets.get("managed_soft_mib", 384)) * MIB)
	_ceiling = int(float(budgets.get("managed_ceiling_mib", 512)) * MIB)
	_preview_cap = int(float(budgets.get("preview_mib", 128)) * MIB)
	_inflight_cap = maxi(1, int(budgets.get("inflight_loads", 2)))


static func resource_key(asset_id: String, asset_version: int, derivative_hash: String, dependency_key: String) -> String:
	return "%s|v%d|%s|%s" % [asset_id, asset_version, derivative_hash, dependency_key]


## Returns {"status": "ready"|"queued"|"loading"|"rejected", "reason": String}. Tokens may carry
## generation values for cancel_generation() and the texture expectations expect_w/expect_h.
func request(key: String, path: String, kind: String, priority: int, estimated_bytes: int, owner: String,
		tokens: Dictionary = {}) -> Dictionary:
	if not KINDS.has(kind):
		return _reject("bad_kind")
	if path == "" or key == "":
		return _reject("bad_request")
	var entry: Entry = _by_key.get(key)
	if entry != null and entry.path != path:
		return _reject("key_path_mismatch")
	if entry == null:
		entry = _by_path.get(path)
		if entry != null:
			entry.keys.append(key)
			_by_key[key] = entry
	if entry != null:
		if entry.kind != kind:
			return _reject("kind_conflict")
		return _attach(entry, priority, estimated_bytes, owner, tokens)
	var err := _admit(estimated_bytes, kind)
	if err != "":
		return _reject(err)
	if _queue.size() >= MAX_QUEUE:
		return _reject("queue_full")
	var e := Entry.new()
	e.keys.append(key)
	e.path = path
	e.kind = kind
	e.expect = Vector2i(int(tokens.get("expect_w", 0)), int(tokens.get("expect_h", 0)))
	_by_key[key] = e
	_by_path[path] = e
	_enqueue(e, priority, estimated_bytes, owner, tokens)
	return _ok(e)


func poll(max_ms: float = 1.0) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var out := {"started": 0, "completed": 0, "failed": 0, "discarded": 0}
	var progressed := false
	for e in _loading.duplicate():
		if progressed and _elapsed_ms(t0) > max_ms:
			break
		var st := ResourceLoader.load_threaded_get_status(e.path)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		_loading.erase(e)
		progressed = true
		_finish(e, st, out)
	while _loading.size() < _inflight_cap and not _queue.is_empty():
		if progressed and _elapsed_ms(t0) > max_ms:
			break
		var e := _pop_next()
		progressed = true
		if not ResourceLoader.exists(e.path):
			_set_error(e, "missing_file")
			out.failed += 1
			continue
		if ResourceLoader.load_threaded_request(e.path, "", false, ResourceLoader.CACHE_MODE_REUSE) != OK:
			_set_error(e, "request_failed")
			out.failed += 1
			continue
		e.state = "LOADING"
		_loading.append(e)
		out.started += 1
	if _resident > _soft:
		trim(int(_soft * TRIM_FRACTION))
	return out


## Drops pending work of one owner (String) or of matching generation tokens (Dictionary of
## name -> value). Returns the number of entries cancelled or marked stale.
func cancel(owner_or_tokens: Variant) -> int:
	if typeof(owner_or_tokens) == TYPE_DICTIONARY:
		var n := 0
		for name in owner_or_tokens:
			n += cancel_generation(str(name), owner_or_tokens[name])
		return n
	return _cancel_matching(func(owner: String, _tokens: Dictionary) -> bool: return owner == owner_or_tokens)


func cancel_generation(token_name: String, value: Variant) -> int:
	return _cancel_matching(func(_owner: String, tokens: Dictionary) -> bool:
		return tokens.has(token_name) and tokens[token_name] == value)


## Drops every reference and pin of an owner. Resources stay cached until evicted.
func release(owner: String) -> void:
	for e: Entry in _by_path.values():
		e.owners.erase(owner)
		e.pins.erase(owner)


func pin(key: String, owner: String) -> bool:
	var e: Entry = _by_key.get(key)
	if e == null:
		return false
	e.pins[owner] = true
	return true


func unpin(key: String, owner: String) -> void:
	var e: Entry = _by_key.get(key)
	if e != null:
		e.pins.erase(owner)


func mark_fallback(key: String) -> bool:
	var e: Entry = _by_key.get(key)
	if e == null:
		return false
	e.fallback = true
	return true


## Clears a sticky ERROR entry so the key can be requested again.
func forget_error(key: String) -> void:
	var e: Entry = _by_key.get(key)
	if e != null and e.state == "ERROR":
		_unlink(e)


func get_resource(key: String) -> Resource:
	var e: Entry = _by_key.get(key)
	if e == null or e.state != "READY":
		return null
	_touch(e)
	return e.resource


## "UNLOADED" (unknown key), "QUEUED", "LOADING", "READY", "ERROR" or "RETIRED" (evicted).
func state(key: String) -> String:
	var e: Entry = _by_key.get(key)
	return "UNLOADED" if e == null else e.state


func reason(key: String) -> String:
	var e: Entry = _by_key.get(key)
	return "" if e == null else e.reason


## Evicts LRU unreferenced/unpinned/non-fallback READY entries until resident <= target.
func trim(target_bytes: int = -1) -> int:
	var target := _soft if target_bytes < 0 else target_bytes
	return _evict_lru(_resident - target, "")


## Retires every unreferenced, unpinned READY entry of one kind (a disabled preview's textures);
## entries another owner still references stay. Returns the bytes freed.
func retire_unreferenced(kind: String) -> int:
	var before := _resident
	_evict_lru(_resident, kind)
	return before - _resident


func stats() -> Dictionary:
	var counts := {"QUEUED": 0, "LOADING": 0, "READY": 0, "ERROR": 0}
	var fallback_bytes := 0
	for e: Entry in _by_path.values():
		counts[e.state] = counts.get(e.state, 0) + 1
		if e.fallback and e.state == "READY":
			fallback_bytes += e.bytes
	return {"resident_bytes": _resident, "reserved_bytes": _reserved, "ceiling_bytes": _ceiling,
		"soft_bytes": _soft, "preview_bytes": _preview_committed, "fallback_bytes": fallback_bytes,
		"by_kind": _resident_by_kind.duplicate(), "entries": _by_path.size() - _tombstones,
		"queued": counts.QUEUED, "loading": counts.LOADING, "ready": counts.READY, "errors": counts.ERROR,
		"evictions": _evictions, "discarded_stale": _discarded, "rejected": _rejected}


func _attach(e: Entry, priority: int, estimated_bytes: int, owner: String, tokens: Dictionary) -> Dictionary:
	match e.state:
		"ERROR":
			return _reject(e.reason)
		"RETIRED":
			var err := _admit(estimated_bytes, e.kind)
			if err != "":
				return _reject(err)
			_tombstones -= 1
			_enqueue(e, priority, estimated_bytes, owner, tokens)
		"QUEUED", "LOADING":
			e.stale = false
			e.priority = mini(e.priority, priority)
			e.owners[owner] = tokens
		_:
			e.owners[owner] = tokens
			_touch(e)
	return _ok(e)


func _enqueue(e: Entry, priority: int, estimated_bytes: int, owner: String, tokens: Dictionary) -> void:
	e.state = "QUEUED"
	e.reason = ""
	e.stale = false
	e.bytes = estimated_bytes
	e.priority = priority
	_seq += 1
	e.seq = _seq
	e.owners[owner] = tokens
	_reserved += estimated_bytes
	if e.kind == "preview_texture":
		_preview_committed += estimated_bytes
	_queue.append(e)


func _admit(bytes: int, kind: String) -> String:
	if bytes <= 0:
		return "unknown_estimate"
	if bytes > _ceiling or (kind == "preview_texture" and bytes > _preview_cap):
		return "too_large"
	if kind == "preview_texture" and _preview_committed + bytes > _preview_cap:
		_evict_lru(_preview_committed + bytes - _preview_cap, "preview_texture")
		if _preview_committed + bytes > _preview_cap:
			return "preview_over_budget"
	if _resident + _reserved + bytes > _ceiling:
		_evict_lru(_resident + _reserved + bytes - _ceiling, "")
		if _resident + _reserved + bytes > _ceiling:
			return "over_budget"
	return ""


func _pop_next() -> Entry:
	var best := 0
	for i in range(1, _queue.size()):
		var a := _queue[i]
		var b := _queue[best]
		if a.priority < b.priority or (a.priority == b.priority and a.seq < b.seq):
			best = i
	var e := _queue[best]
	_queue.remove_at(best)
	return e


func _finish(e: Entry, st: int, out: Dictionary) -> void:
	var res: Resource = null
	if st == ResourceLoader.THREAD_LOAD_LOADED:
		res = ResourceLoader.load_threaded_get(e.path)
	if e.stale:
		_discarded += 1
		out.discarded += 1
		_release_reservation(e)
		_unlink(e)
		return
	var err := "load_failed" if res == null else _validate(e, res)
	if err != "":
		_set_error(e, err)
		out.failed += 1
		return
	e.resource = res
	e.state = "READY"
	_reserved -= e.bytes
	_resident += e.bytes
	_resident_by_kind[e.kind] += e.bytes
	_touch(e)
	out.completed += 1


func _validate(e: Entry, res: Resource) -> String:
	match e.kind:
		"mesh":
			return "" if res is ArrayMesh else "wrong_class"
		"material":
			return "" if res is StandardMaterial3D else "wrong_class"
	var tex := res as Texture2D
	if tex == null:
		return "wrong_class"
	if e.expect == Vector2i.ZERO:
		return ""
	if tex.get_width() != e.expect.x or tex.get_height() != e.expect.y:
		return "texture_mismatch"
	var img := tex.get_image()
	return "" if img != null and img.has_mipmaps() else "texture_mismatch"


func _cancel_matching(matches: Callable) -> int:
	var n := 0
	for e: Entry in _by_path.values():
		if e.state != "QUEUED" and e.state != "LOADING":
			continue
		var hit := false
		for owner: String in e.owners.keys():
			if matches.call(owner, e.owners[owner]):
				e.owners.erase(owner)
				hit = true
		if hit and e.owners.is_empty() and e.pins.is_empty():
			_cancel_entry(e)
			n += 1
	return n


func _cancel_entry(e: Entry) -> void:
	if e.state == "QUEUED":
		_queue.erase(e)
		_release_reservation(e)
		_unlink(e)
	else:
		e.stale = true


func _evictable(e: Entry) -> bool:
	return e.state == "READY" and not e.fallback and e.owners.is_empty() and e.pins.is_empty()


## Evicts LRU candidates (optionally of one kind) until at least `needed` bytes are freed.
func _evict_lru(needed: int, only_kind: String) -> int:
	if needed <= 0:
		return 0
	var cands: Array[Entry] = []
	for e: Entry in _by_path.values():
		if _evictable(e) and (only_kind == "" or e.kind == only_kind):
			cands.append(e)
	cands.sort_custom(func(a: Entry, b: Entry) -> bool: return a.last_used < b.last_used)
	var freed := 0
	var n := 0
	for e in cands:
		if freed >= needed:
			break
		freed += e.bytes
		_retire(e)
		n += 1
	return n


func _retire(e: Entry) -> void:
	_resident -= e.bytes
	_resident_by_kind[e.kind] -= e.bytes
	if e.kind == "preview_texture":
		_preview_committed -= e.bytes
	e.resource = null
	e.state = "RETIRED"
	_evictions += 1
	_tombstones += 1
	if _tombstones > MAX_TOMBSTONES:
		_prune_tombstones()


func _prune_tombstones() -> void:
	for e: Entry in _by_path.values():
		if e.state == "RETIRED":
			_unlink(e)
	_tombstones = 0


func _set_error(e: Entry, why: String) -> void:
	_release_reservation(e)
	e.state = "ERROR"
	e.reason = why
	e.resource = null


func _release_reservation(e: Entry) -> void:
	_reserved -= e.bytes
	if e.kind == "preview_texture":
		_preview_committed -= e.bytes


func _unlink(e: Entry) -> void:
	for k in e.keys:
		_by_key.erase(k)
	_by_path.erase(e.path)


func _touch(e: Entry) -> void:
	_clock += 1
	e.last_used = _clock


func _ok(e: Entry) -> Dictionary:
	return {"status": e.state.to_lower(), "reason": ""}


func _reject(why: String) -> Dictionary:
	_rejected += 1
	return {"status": "rejected", "reason": why}


func _elapsed_ms(t0_usec: int) -> float:
	return (Time.get_ticks_usec() - t0_usec) / 1000.0
