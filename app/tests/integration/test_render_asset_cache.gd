extends TestCase
## RenderAssetCache (spec §12, MEMORY-01..03, ASSET-05): admission, dedup, priority, logical
## cancellation, eviction, validation. Uses small real resources saved to the scratch directory.

const MIB := 1048576.0
const TIMEOUT_MS := 5000


## Budgets in bytes (converted to the MiB the cache expects).
func _cache(ceiling: int, soft: int = -1, inflight: int = 1, preview: int = -1) -> RenderAssetCache:
	return RenderAssetCache.new({
		"managed_ceiling_mib": ceiling / MIB,
		"managed_soft_mib": (ceiling if soft < 0 else soft) / MIB,
		"preview_mib": (ceiling if preview < 0 else preview) / MIB,
		"inflight_loads": inflight})


func _mesh_file(name: String) -> String:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var path := scratch_dir().path_join(name + ".res")
	ResourceSaver.save(mesh, path)
	return path


func _material_file(name: String) -> String:
	var path := scratch_dir().path_join(name + ".res")
	ResourceSaver.save(StandardMaterial3D.new(), path)
	return path


func _texture_file(name: String, w: int, h: int, mipmaps: bool) -> String:
	var img := Image.create_empty(w, h, mipmaps, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	if mipmaps:
		img.generate_mipmaps()
	var path := scratch_dir().path_join(name + ".res")
	ResourceSaver.save(ImageTexture.create_from_image(img), path)
	return path


## Polls until done() or the timeout; returns whether done() became true.
func _pump(cache: RenderAssetCache, done: Callable) -> bool:
	var t0 := Time.get_ticks_msec()
	while not done.call():
		if Time.get_ticks_msec() - t0 > TIMEOUT_MS:
			return false
		cache.poll(2.0)
		await tree.process_frame
	return true


func _settled(cache: RenderAssetCache) -> Callable:
	return func() -> bool: return cache.stats().queued == 0 and cache.stats().loading == 0


func _req(cache: RenderAssetCache, key: String, path: String, owner: String = "o", priority: int = 3,
		bytes: int = 1000, kind: String = "mesh", tokens: Dictionary = {}) -> Dictionary:
	return cache.request(key, path, kind, priority, bytes, owner, tokens)


func test_shared_dependency_counts_once() -> void:
	var cache := _cache(100000)
	var path := _mesh_file("shared")
	var k1 := RenderAssetCache.resource_key("a", 1, "h1", "mesh_far")
	var k2 := RenderAssetCache.resource_key("b", 1, "h2", "mesh_far")
	assert_eq(_req(cache, k1, path, "owner1").status, "queued")
	assert_eq(_req(cache, k2, path, "owner2").status, "queued", "second key joins the entry")
	assert_eq(cache.stats().reserved_bytes, 1000, "reserved once")
	assert_true(await _pump(cache, _settled(cache)), "loads finish")
	var s := cache.stats()
	assert_eq(s.resident_bytes, 1000, "resident once")
	assert_eq(s.entries, 1)
	assert_eq(s.by_kind.mesh, 1000)
	assert_true(cache.get_resource(k1) != null and cache.get_resource(k1) == cache.get_resource(k2), "same resource object")
	assert_eq(_req(cache, k1, path, "owner3").status, "ready")
	assert_eq(cache.stats().resident_bytes, 1000, "still once")


func test_keys_never_alias_across_versions_and_derivatives() -> void:
	var base := RenderAssetCache.resource_key("a", 1, "h1", "m")
	assert_ne(base, RenderAssetCache.resource_key("a", 2, "h1", "m"), "version")
	assert_ne(base, RenderAssetCache.resource_key("a", 1, "h2", "m"), "derivative hash")
	assert_ne(base, RenderAssetCache.resource_key("a", 1, "h1", "n"), "dependency key")
	var cache := _cache(100000)
	var p1 := _mesh_file("v1")
	var p2 := _mesh_file("v2")
	_req(cache, base, p1)
	assert_eq(_req(cache, RenderAssetCache.resource_key("a", 1, "h2", "m"), p2).status, "queued")
	assert_eq(cache.stats().entries, 2, "different files are different entries")
	assert_eq(_req(cache, base, p2).reason, "key_path_mismatch", "a key is bound to one path")


func test_reservation_blocks_admission_before_loads_finish() -> void:
	var cache := _cache(3200, -1, 1)
	for i in 3:
		assert_eq(_req(cache, "k%d" % i, _mesh_file("m%d" % i)).status, "queued")
	var r := _req(cache, "k3", _mesh_file("m3"))
	assert_eq(r.status, "rejected")
	assert_eq(r.reason, "over_budget")
	var s := cache.stats()
	assert_eq(s.reserved_bytes, 3000)
	assert_eq(s.resident_bytes, 0)
	assert_eq(s.queued, 3, "nothing loaded yet")
	assert_eq(s.rejected, 1)
	cache.poll(5.0)
	assert_eq(cache.stats().loading, 1, "one in flight, still reserved")
	assert_eq(_req(cache, "k4", _mesh_file("m4")).reason, "over_budget")
	assert_true(await _pump(cache, _settled(cache)))
	assert_eq(cache.stats().resident_bytes, 3000)
	assert_eq(cache.stats().reserved_bytes, 0)


func test_invalid_estimates_are_rejected_before_any_load() -> void:
	var cache := _cache(5000, -1, 1, 2000)
	var path := _mesh_file("e")
	assert_eq(_req(cache, "a", path, "o", 3, 0).reason, "unknown_estimate")
	assert_eq(_req(cache, "b", path, "o", 3, -5).reason, "unknown_estimate")
	assert_eq(_req(cache, "c", path, "o", 3, 5001).reason, "too_large")
	assert_eq(_req(cache, "d", path, "o", 3, 2001, "preview_texture").reason, "too_large", "above the preview budget")
	assert_eq(_req(cache, "e", path, "o", 3, 10, "scene").reason, "bad_kind")
	assert_eq(cache.stats().queued, 0)
	cache.poll(5.0)
	assert_false(ResourceLoader.has_cached(path), "nothing was loaded")
	assert_eq(cache.state("a"), "UNLOADED")


## Plain resources: two concurrent threaded loads of RenderingServer-backed resources race inside the
## headless dummy renderer (not thread-safe), so the cap is exercised with resources that never touch it;
## they complete as ERROR wrong_class, which is all the cap needs.
func test_in_flight_cap_is_respected() -> void:
	var cache := _cache(100000, -1, 2)
	for i in 6:
		var path := scratch_dir().path_join("plain%d.tres" % i)
		ResourceSaver.save(Resource.new(), path)
		_req(cache, "k%d" % i, path)
	var out := cache.poll(100.0)
	assert_eq(out.started, 2)
	assert_eq(cache.stats().loading, 2)
	var t0 := Time.get_ticks_msec()
	while cache.stats().errors < 6 and Time.get_ticks_msec() - t0 < TIMEOUT_MS:
		cache.poll(100.0)
		assert_true(cache.stats().loading <= 2, "never more than 2 in flight")
		await tree.process_frame
	assert_eq(cache.stats().errors, 6)
	assert_eq(cache.reason("k0"), "wrong_class")


func test_priority_then_fifo_order() -> void:
	var cache := _cache(100000, -1, 1)
	_req(cache, "low", _mesh_file("a"), "o", 5)
	_req(cache, "urgent", _mesh_file("b"), "o", 1)
	_req(cache, "mid1", _mesh_file("c"), "o", 3)
	_req(cache, "mid2", _mesh_file("d"), "o", 3)
	var order: Array[String] = []
	var t0 := Time.get_ticks_msec()
	while cache.stats().ready < 4 and Time.get_ticks_msec() - t0 < TIMEOUT_MS:
		cache.poll(100.0)
		for k in ["low", "urgent", "mid1", "mid2"]:
			if cache.state(k) == "LOADING" and not order.has(k):
				order.append(k)
		await tree.process_frame
	assert_eq(order, ["urgent", "mid1", "mid2", "low"] as Array[String])


func test_poll_always_makes_progress_with_zero_budget() -> void:
	var cache := _cache(100000)
	_req(cache, "k", _mesh_file("z"))
	assert_eq(cache.poll(0.0).started, 1)
	assert_true(await _pump(cache, _settled(cache)), "do not leave a load in flight past the test")


func test_cancel_generation_discards_stale_result_and_releases_reservation_late() -> void:
	var cache := _cache(100000, -1, 1)
	var a := _mesh_file("a")
	var q := _mesh_file("q")
	_req(cache, "A", a, "view", 3, 1000, "mesh", {"gen": 1})
	_req(cache, "Q", q, "view", 3, 700, "mesh", {"gen": 1})
	cache.poll(5.0)
	assert_eq(cache.state("A"), "LOADING")
	assert_eq(cache.state("Q"), "QUEUED")
	assert_eq(cache.cancel_generation("gen", 1), 2)
	assert_eq(cache.state("Q"), "UNLOADED", "queued work is dropped at once")
	assert_eq(cache.stats().reserved_bytes, 1000, "in-flight bytes stay reserved")
	assert_eq(cache.state("A"), "LOADING", "still in flight, marked stale")
	assert_true(await _pump(cache, _settled(cache)))
	var s := cache.stats()
	assert_eq(s.discarded_stale, 1)
	assert_eq(s.reserved_bytes, 0, "released only after completion")
	assert_eq(s.resident_bytes, 0)
	assert_eq(cache.state("A"), "UNLOADED")
	assert_eq(cache.get_resource("A"), null)


func test_new_generation_after_cancel_loads_only_the_latest() -> void:
	# MEMORY-03 cache part: a camera jump cancels obsolete work; only the newest generation lands.
	var cache := _cache(100000, -1, 1)
	for g in range(1, 6):
		if g > 1:
			cache.cancel_generation("gen", g - 1)
		_req(cache, "k%d" % g, _mesh_file("g%d" % g), "view", 3, 1000, "mesh", {"gen": g})
		cache.poll(5.0)
	assert_true(await _pump(cache, _settled(cache)))
	for g in range(1, 5):
		assert_eq(cache.state("k%d" % g), "UNLOADED", "generation %d is gone" % g)
	assert_eq(cache.state("k5"), "READY")
	assert_true(cache.get_resource("k5") != null)
	assert_eq(cache.stats().resident_bytes, 1000)
	assert_eq(cache.stats().reserved_bytes, 0)


func test_cancel_by_owner_and_shared_entries() -> void:
	var cache := _cache(100000, -1, 1)
	var path := _mesh_file("s")
	_req(cache, "k", path, "o1", 3, 1000, "mesh", {"gen": 1})
	_req(cache, "k", path, "o2", 3, 1000, "mesh", {"gen": 2})
	assert_eq(cache.cancel_generation("gen", 1), 0, "another owner still wants it")
	assert_eq(cache.state("k"), "QUEUED")
	assert_eq(cache.cancel("o2"), 1)
	assert_eq(cache.state("k"), "UNLOADED")
	assert_eq(cache.stats().reserved_bytes, 0)
	_req(cache, "j", path, "o3", 3, 1000, "mesh", {"gen": 7})
	assert_eq(cache.cancel({"gen": 7}), 1, "dictionary form")


func test_reviving_a_stale_load_keeps_the_result() -> void:
	var cache := _cache(100000, -1, 1)
	var path := _mesh_file("r")
	_req(cache, "k", path, "o", 3, 1000, "mesh", {"gen": 1})
	cache.poll(5.0)
	cache.cancel_generation("gen", 1)
	assert_eq(_req(cache, "k", path, "o", 3, 1000, "mesh", {"gen": 2}).status, "loading")
	assert_true(await _pump(cache, _settled(cache)))
	assert_eq(cache.state("k"), "READY")
	assert_eq(cache.stats().discarded_stale, 0)


func test_eviction_skips_referenced_pinned_and_fallback_entries() -> void:
	var cache := _cache(4000)
	var keys := ["held", "pinned", "fallback", "free"]
	for k: String in keys:
		_req(cache, k, _mesh_file(k), "owner_" + k)
	assert_true(await _pump(cache, _settled(cache)))
	assert_eq(cache.stats().resident_bytes, 4000)
	cache.release("owner_pinned")
	cache.release("owner_fallback")
	cache.release("owner_free")
	cache.pin("pinned", "ui")
	cache.mark_fallback("fallback")
	var r := _req(cache, "new1", _mesh_file("new1"), "n1")
	assert_eq(r.status, "queued", "evicted the only free entry")
	assert_eq(cache.state("free"), "RETIRED")
	for k in ["held", "pinned", "fallback"]:
		assert_eq(cache.state(k), "READY", k)
	assert_eq(_req(cache, "new2", _mesh_file("new2"), "n2").reason, "over_budget", "nothing left to evict")
	cache.unpin("pinned", "ui")
	assert_eq(_req(cache, "new2", _mesh_file("new2"), "n2").status, "queued")
	assert_eq(cache.state("pinned"), "RETIRED")
	assert_eq(cache.state("fallback"), "READY", "fallback is never evicted")
	assert_eq(cache.stats().evictions, 2)
	assert_eq(cache.get_resource("free"), null)


func test_evicted_entry_can_be_requested_again() -> void:
	var cache := _cache(1500)
	var a := _mesh_file("a")
	_req(cache, "a", a, "o")
	assert_true(await _pump(cache, _settled(cache)))
	cache.release("o")
	assert_eq(_req(cache, "b", _mesh_file("b"), "o").status, "queued")
	assert_eq(cache.state("a"), "RETIRED")
	assert_true(await _pump(cache, _settled(cache)))
	cache.release("o")
	assert_eq(_req(cache, "a", a, "o").status, "queued", "re-admitted after eviction")
	assert_true(await _pump(cache, _settled(cache)))
	assert_eq(cache.state("a"), "READY")
	assert_eq(cache.state("b"), "RETIRED")


func test_trim_has_hysteresis_and_evicts_lru_first() -> void:
	var cache := _cache(20000, 5000)
	for i in 6:
		_req(cache, "k%d" % i, _mesh_file("t%d" % i), "o%d" % i)
	assert_true(await _pump(cache, _settled(cache)))
	for i in 6:
		cache.release("o%d" % i)
	cache.get_resource("k0")  # most recently used: survives longest
	cache.poll(5.0)
	var s := cache.stats()
	assert_true(s.resident_bytes <= 4500, "trimmed to soft x 0.9, got %d" % s.resident_bytes)
	assert_eq(s.resident_bytes, 4000, "evicts only as many entries as needed")
	assert_eq(s.evictions, 2)
	assert_eq(cache.state("k1"), "RETIRED", "least recently used goes first")
	assert_eq(cache.state("k0"), "READY")
	cache.poll(5.0)
	assert_eq(cache.stats().evictions, 2, "no thrashing once below the soft target")
	assert_eq(cache.trim(0), 4, "explicit trim to zero")
	assert_eq(cache.stats().resident_bytes, 0)


func test_trim_keeps_referenced_entries() -> void:
	var cache := _cache(20000, 2000)
	for i in 4:
		_req(cache, "k%d" % i, _mesh_file("h%d" % i), "owner")
	assert_true(await _pump(cache, _settled(cache)))
	assert_eq(cache.stats().evictions, 0, "all referenced")
	assert_eq(cache.stats().resident_bytes, 4000)


func test_class_mismatch_becomes_error_and_releases_reservation() -> void:
	var cache := _cache(100000)
	var path := _mesh_file("wrong")
	assert_eq(_req(cache, "k", path, "o", 3, 1000, "material").status, "queued")
	assert_true(await _pump(cache, _settled(cache)))
	assert_eq(cache.state("k"), "ERROR")
	assert_eq(cache.reason("k"), "wrong_class")
	var s := cache.stats()
	assert_eq(s.errors, 1)
	assert_eq(s.reserved_bytes, 0)
	assert_eq(s.resident_bytes, 0)
	assert_eq(cache.get_resource("k"), null)
	assert_eq(_req(cache, "k", path, "o", 3, 1000, "material").reason, "wrong_class", "sticky")
	cache.forget_error("k")
	assert_eq(_req(cache, "k", path, "o", 3, 1000, "mesh").status, "queued")
	assert_true(await _pump(cache, _settled(cache)))
	assert_eq(cache.state("k"), "READY")


func test_missing_file_becomes_error() -> void:
	var cache := _cache(100000)
	_req(cache, "k", scratch_dir().path_join("nope.res"))
	assert_true(await _pump(cache, _settled(cache)))
	assert_eq(cache.state("k"), "ERROR")
	assert_eq(cache.stats().reserved_bytes, 0)


func test_material_and_texture_kinds_load() -> void:
	var cache := _cache(100000)
	_req(cache, "m", _material_file("mat"), "o", 3, 100, "material")
	_req(cache, "t", _texture_file("tex", 8, 4, true), "o", 3, 500, "texture")
	assert_true(await _pump(cache, _settled(cache)))
	assert_true(cache.get_resource("m") is StandardMaterial3D)
	assert_true(cache.get_resource("t") is Texture2D)
	var by_kind: Dictionary = cache.stats().by_kind
	assert_eq(by_kind.material, 100)
	assert_eq(by_kind.texture, 500)


func test_texture_expectations_are_validated() -> void:
	var cache := _cache(100000)
	var ok := _texture_file("ok", 8, 4, true)
	var wrong_size := _texture_file("wrong_size", 16, 4, true)
	var no_mips := _texture_file("no_mips", 8, 4, false)
	var expect := {"expect_w": 8, "expect_h": 4}
	_req(cache, "ok", ok, "o", 3, 500, "texture", expect)
	_req(cache, "size", wrong_size, "o", 3, 500, "texture", expect)
	_req(cache, "mips", no_mips, "o", 3, 500, "texture", expect)
	assert_true(await _pump(cache, _settled(cache)))
	assert_eq(cache.state("ok"), "READY")
	assert_eq(cache.state("size"), "ERROR")
	assert_eq(cache.reason("size"), "texture_mismatch")
	assert_eq(cache.state("mips"), "ERROR")
	assert_eq(cache.reason("mips"), "texture_mismatch")
	assert_eq(cache.stats().reserved_bytes, 0)


func test_preview_budget_is_inside_the_ceiling() -> void:
	var cache := _cache(10000, -1, 1, 2000)
	var p1 := _req(cache, "p1", _texture_file("p1", 8, 4, true), "o", 3, 1000, "preview_texture")
	var p2 := _req(cache, "p2", _texture_file("p2", 8, 4, true), "o", 3, 1000, "preview_texture")
	assert_eq(p1.status, "queued")
	assert_eq(p2.status, "queued")
	assert_eq(_req(cache, "p3", _texture_file("p3", 8, 4, true), "o", 3, 1000, "preview_texture").reason, "preview_over_budget")
	assert_eq(cache.stats().preview_bytes, 2000)
	assert_eq(_req(cache, "m", _mesh_file("m"), "o", 3, 5000).status, "queued", "ordinary resources still fit")
	assert_true(await _pump(cache, _settled(cache)))
	assert_eq(cache.stats().by_kind.preview_texture, 2000)
	cache.release("o")
	assert_eq(_req(cache, "p3", _texture_file("p3", 8, 4, true), "o", 3, 1000, "preview_texture").status, "queued",
		"unreferenced preview detail is evicted first")
	assert_eq(cache.stats().preview_bytes, 2000)
	assert_eq(cache.stats().evictions, 1)
