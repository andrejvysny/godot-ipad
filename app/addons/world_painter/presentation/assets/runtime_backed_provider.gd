class_name RuntimeBackedProvider
extends WPAssetProvider
## Shared core of the providers that obtain GLB bytes at runtime (AssetStudioProvider, FakeProvider): fetch the
## bytes (subclass), validate and bake them (RuntimeGlbLoader), register the derived tiers in the shared
## registry/cache and mark the binding prepared in the lock. The order of every prepare is: fetch, load, then a
## cancellation check, then registration, so a cancelled prepare never registers tiers or changes availability.

const CancelToken := preload("res://addons/assetstudio/core/as_cancel_token.gd")
const CACHE_OWNER := "runtime-assets"

var registry: RenderAssetRegistry
var cache: RenderAssetCache
var loader := RuntimeGlbLoader.new()
## Consumer material hook: maps the surfaces of every baked mesh before its tiers are registered (the far box keeps its grey).
var material_mapper: WPMaterialMapper
var last_prepare_ms := 0.0

var _prepared: Dictionary = {}  # binding_id -> RuntimeAssetTiers.Tiers
var _shas: Dictionary = {}  # binding_id -> PackedStringArray of the cached blob shas it needs
var _disclosures: Dictionary = {}  # binding_id -> PackedStringArray of loader disclosures (blended -> cutout, ...)
var _tokens: Dictionary = {}  # binding_id -> cancel token of the in-flight prepare
var _pins: Dictionary = {}  # owner -> PackedStringArray of binding ids
var _blobs: RefCounted  # ASBlobCache or null


## `heavy_gate`: `() -> bool`, true when no editing operation is active (RuntimeGlbLoader.can_run_heavy).
func bind_render(p_registry: RenderAssetRegistry, p_cache: RenderAssetCache, heavy_gate: Callable = Callable()) -> void:
	registry = p_registry
	cache = p_cache
	loader.can_run_heavy = heavy_gate


## Coroutine of the subclass: {"ok": bool, "glb": PackedByteArray, "error": String, "shas": PackedStringArray}.
func _fetch(_binding: AssetBinding, _token: RefCounted) -> Dictionary:
	return {"ok": false, "error": "no byte source"}


func attach(lock: WorldAssetLock) -> void:
	assets = lock
	for id: String in _prepared:
		if lock.has_binding(id):
			lock.mark_prepared(id, (_prepared[id] as RuntimeAssetTiers.Tiers).scatter_ok)


func prepare(binding_id: String, cancel: RefCounted = null) -> void:
	var b: AssetBinding = assets.get_binding(binding_id) if assets != null else null
	if b == null or b.is_bundled() or registry == null or cache == null:
		_emit_later(binding_id, false, "not an AssetStudio binding of the open world")
	elif _prepared.has(binding_id):
		_emit_later(binding_id, true, "")
	elif not (_tokens.has(binding_id) and not (_tokens[binding_id] as RefCounted).call("is_cancelled")):
		var token: RefCounted = cancel if cancel != null else CancelToken.new()
		_tokens[binding_id] = token
		_run(binding_id, b, token)


func _run(id: String, b: AssetBinding, token: RefCounted) -> void:
	var t0 := Time.get_ticks_usec()
	await _next_frame()
	var outcome: Dictionary = await _produce(id, b, token)
	if _tokens.get(id) == token:
		_tokens.erase(id)
	if str(outcome.error) == "" and bool(outcome.ok):
		last_prepare_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	elif str(outcome.error) != "cancelled" and assets != null:
		assets.mark_unprepared(id, str(outcome.error))
	prepared.emit(id, bool(outcome.ok), str(outcome.error))


## Returns {"ok", "error"}; on success the tiers are registered and the lock marked, nothing otherwise.
func _produce(id: String, b: AssetBinding, token: RefCounted) -> Dictionary:
	var fetched: Dictionary = await _fetch(b, token)
	if _cancelled(token):
		return {"ok": false, "error": "cancelled"}
	if not bool(fetched.ok):
		return {"ok": false, "error": str(fetched.error)}
	var baked: RuntimeGlbLoader.Result = await loader.load_glb(fetched.glb, token)
	if _cancelled(token):
		return {"ok": false, "error": "cancelled"}
	if not baked.ok:
		return {"ok": false, "error": baked.error}
	if material_mapper != null:
		material_mapper.map_mesh(id, baked.mesh, WPMaterialMapper.asset_id_of(b))
	var def := assets.definition(id)
	var tiers := RuntimeAssetTiers.build(def, baked, b.scatter_allowed and baked.scatter_ok, "assetstudio:" + b.asset_key)
	var err := RuntimeAssetTiers.register(tiers, registry, cache, CACHE_OWNER)
	if err != "":
		return {"ok": false, "error": err}
	_prepared[id] = tiers
	_shas[id] = fetched.get("shas", PackedStringArray())
	_disclosures[id] = baked.disclosures
	assets.mark_prepared(id, baked.scatter_ok)
	_sync_blob_pins()
	return {"ok": true, "error": ""}


static func _cancelled(token: RefCounted) -> bool:
	return bool(token.call("is_cancelled"))


func _next_frame() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.process_frame


func _emit_later(id: String, ok: bool, error: String) -> void:
	prepared.emit.call_deferred(id, ok, error)


func is_prepared(binding_id: String) -> bool:
	return _prepared.has(binding_id)


## What the runtime loader changed about the asset's materials (e.g. "1 blended material(s) became cutout").
func disclosures(binding_id: String) -> PackedStringArray:
	return _disclosures.get(binding_id, PackedStringArray())


func representation(binding_id: String, tier: String) -> Mesh:
	var t: RuntimeAssetTiers.Tiers = _prepared.get(binding_id)
	if t == null:
		return null
	match tier:
		TIER_SELECTED, TIER_NEAR, TIER_MID:
			return t.selected
		TIER_FAR, TIER_GHOST, TIER_OVERVIEW:
			return t.far
	return null


func instantiate(binding_id: String) -> Node3D:
	var mesh := representation(binding_id, TIER_SELECTED)
	if mesh == null:
		return null
	var root := Node3D.new()
	root.name = "asset_" + binding_id
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	root.add_child(mi)
	return root


func pin(owner: String, binding_ids: PackedStringArray) -> void:
	_pins[owner] = binding_ids.duplicate()
	_sync_blob_pins()


func unpin(owner: String) -> void:
	_pins.erase(owner)
	if _blobs != null:
		_blobs.call("unpin", _blob_owner(owner))
	for id: String in _prepared.keys():
		if not _is_pinned(id):
			_drop(id)
	_sync_blob_pins()


func cancel(binding_id: String) -> void:
	var token: RefCounted = _tokens.get(binding_id)
	if token != null:
		token.call("cancel")


func cancel_all() -> void:
	for id: String in _tokens.keys():
		cancel(id)


func pending_count() -> int:
	return _tokens.size()


func prepared_ids() -> PackedStringArray:
	var ids := PackedStringArray(_prepared.keys())
	ids.sort()
	return ids


func _is_pinned(id: String) -> bool:
	for owner: String in _pins:
		if (_pins[owner] as PackedStringArray).has(id):
			return true
	return false


func _drop(id: String) -> void:
	RuntimeAssetTiers.unregister(id, registry, cache, CACHE_OWNER)
	_prepared.erase(id)
	_shas.erase(id)
	_disclosures.erase(id)
	if assets != null:
		assets.mark_unprepared(id)


static func _blob_owner(owner: String) -> String:
	return "wp-assets:" + owner


## Pinned blobs survive ASBlobCache.prune(): per owner, the files of its prepared bindings.
func _sync_blob_pins() -> void:
	if _blobs == null:
		return
	for owner: String in _pins:
		var shas := PackedStringArray()
		for id: String in (_pins[owner] as PackedStringArray):
			shas.append_array(_shas.get(id, PackedStringArray()))
		if shas.is_empty():
			_blobs.call("unpin", _blob_owner(owner))
		else:
			_blobs.call("pin", _blob_owner(owner), shas)
