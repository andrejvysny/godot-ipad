class_name ObjectPreviewParticipant
extends RefCounted
## Object side of the fixed-area Texture Preview (spec 11.1, 11.3, 11.5). Members: the (at most
## MAX_PREVIEW_OBJECTS) objects whose logical bounds intersect the captured circle. Requests the prepared preview
## textures of their assets through the shared RenderAssetCache, builds one material variant per
## (low material path, preview texture) and binds the members through ObjectRenderWorld preview owners.
## Variants are copies of the low material; the shared low material is never modified, and a missing texture
## leaves that material on the low tier. Objects in pinned cells are bound or returned after the pins release.

const PRIORITY := 5  # spec 12.3 item 5
const SELECTED_PRIORITY := 4
const MAX_PREVIEW_OBJECTS := 128

var build_ms := 0.0  # last publish: variants + binding

var _cache: RenderAssetCache
var _presenter: ObjectPresenter
var _world: ObjectRenderWorld
var _registry: RenderAssetRegistry
var _center := Vector2.ZERO
var _radius := 0.0
var _owner := ""
var _generation := 0
var _members: Dictionary = {}  # id -> asset_id, nearest first
var _truncated := false
var _assets: Dictionary = {}  # asset_id -> {"textures": {tex key -> {key, bytes, failed}}, "variants": Dictionary or null}
var _variant_cache: Dictionary = {}  # "<low path>|<cache key>" -> Material
var _leaving: Dictionary = {}  # id -> true: bound objects to return once their cell is unpinned
var _published := false
var _dirty := false
var _connected := false


func _init(cache: RenderAssetCache, presenter: ObjectPresenter) -> void:
	_cache = cache
	_presenter = presenter
	_world = presenter.render_world()
	_registry = presenter.registry()


## Starts the requests. Returns "" (an area without previewable objects is not an error).
func begin(center: Vector2, radius: float, owner: String, generation: int) -> String:
	_center = center
	_radius = radius
	_owner = owner
	_generation = generation
	_world.overview_changed.connect(_on_changed)
	_connected = true
	_select_members()
	return ""


func previewed_count() -> int:
	var bound := _world.preview_owner_ids()
	var n := 0
	for id in bound:
		if _members.has(id):
			n += 1
	return n


func truncated() -> bool:
	return _truncated


func release_pending() -> bool:
	return not _leaving.is_empty()


## {"requested", "ready", "pending", "missing": Array[String] "<asset>:<texture>", "reasons", "bytes",
## "previewed", "truncated", "deferred"}.
func progress() -> Dictionary:
	var requested := 0
	var ready := 0
	var pending := 0
	var bytes := 0
	var missing: Array[String] = []
	var reasons := {}
	for asset_id: String in _assets:
		var textures: Dictionary = _assets[asset_id].textures
		for tex_key: String in textures:
			var t: Dictionary = textures[tex_key]
			requested += 1
			var st := "UNLOADED" if str(t.key) == "" else _cache.state(str(t.key))
			if st == "READY":
				ready += 1
				bytes += int(t.bytes)
			elif st == "QUEUED" or st == "LOADING":
				pending += 1
			else:
				var id := "%s:%s" % [asset_id, tex_key]
				missing.append(id)
				reasons[id] = str(t.failed) if str(t.failed) != "" else _cache.reason(str(t.key))
	var deferred := 0
	var bound := _world.preview_owner_ids()
	for id: String in _members:
		if not bound.has(id) and _world.is_object_pinned(id):
			deferred += 1
	return {"requested": requested, "ready": ready, "pending": pending, "missing": missing, "reasons": reasons,
		"bytes": bytes, "previewed": previewed_count(), "truncated": _truncated, "deferred": deferred}


## Marks the participant live and binds what can be bound now; the rest follows from service().
func publish() -> String:
	_published = true
	var t0 := Time.get_ticks_usec()
	_bind_members()
	build_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	return ""


## Every frame while published: membership re-evaluation after object changes, retries of bindings that had
## to wait (pins, unbuilt groups) and of objects waiting to return.
func service() -> void:
	if not _published:
		return
	if _dirty:
		_dirty = false
		_select_members()
	_end_leaving()
	_bind_members()


## Returns every bound object to its batch (objects in pinned cells follow in service_release) and drops the
## variants. Cache references are released by the controller.
func release() -> void:
	if _connected and is_instance_valid(_world):
		_world.overview_changed.disconnect(_on_changed)
	_connected = false
	_published = false
	for id in _world.preview_owner_ids():
		if _members.has(id) or _leaving.has(id):
			_leaving[id] = true
	_members.clear()
	_assets.clear()
	_variant_cache.clear()
	_end_leaving()


func service_release() -> void:
	_end_leaving()


func _end_leaving() -> void:
	var ids := PackedStringArray()
	for id: String in _leaving.keys():
		if not _world.is_object_pinned(id):
			ids.append(id)
			_leaving.erase(id)
	if not ids.is_empty():
		_world.end_preview_owners(ids)


func _on_changed(rect: Rect2) -> void:
	if rect.intersects(Rect2(_center - Vector2(_radius, _radius), Vector2(_radius, _radius) * 2.0)):
		_dirty = true


## Bounded membership: nearest first, selected object first, assets without a preview tier skipped.
func _select_members() -> void:
	var candidates := _presenter.objects_in_circle(_center, _radius)
	var selected := _presenter.selected_id()
	var ordered: Array[String] = []
	if selected != "" and candidates.has(selected):
		ordered.append(selected)
	for id in candidates:
		if id != selected:
			ordered.append(id)
	var next: Dictionary = {}
	_truncated = false
	for id in ordered:
		var asset_id := _asset_of(id)
		if not _previewable(asset_id):
			continue
		if next.size() >= MAX_PREVIEW_OBJECTS:
			_truncated = true
			break
		next[id] = asset_id
		_request_asset(asset_id, id == selected)
	var bound := _world.preview_owner_ids()
	for id: String in _members:
		if not next.has(id) and bound.has(id):
			_leaving[id] = true
	_members = next
	_end_leaving()


func _asset_of(id: String) -> String:
	return _presenter.asset_of(id)


func _previewable(asset_id: String) -> bool:
	if not _registry.is_ready(asset_id):
		return false
	var d := _registry.descriptor(asset_id)
	if d == null:
		return false
	for m: Dictionary in d.materials.values():
		if str(m.texture) != "" and d.textures[m.texture].preview != null:
			return true
	return false


func _request_asset(asset_id: String, is_selected: bool) -> void:
	if _assets.has(asset_id):
		return
	var d := _registry.descriptor(asset_id)
	var record := {"textures": {}, "variants": null}
	_assets[asset_id] = record
	var priority := SELECTED_PRIORITY if is_selected else PRIORITY
	for m: Dictionary in d.materials.values():
		var tex_key := str(m.texture)
		var tier: Variant = d.textures[tex_key].preview if tex_key != "" else null
		if tier == null or (record.textures as Dictionary).has(tex_key):
			continue
		var dep := d.dependency(str((tier as Dictionary).dependency))
		var key := RenderAssetCache.resource_key(asset_id, d.asset_version, d.derivative_hash, str(dep.key))
		var entry := {"key": key, "bytes": int(dep.gpu_bytes) + int(dep.staging_bytes), "failed": ""}
		_cache.forget_error(key)
		var tokens := {"preview_generation": _generation, "expect_w": int(tier.width), "expect_h": int(tier.height)}
		var result := _cache.request(key, str(dep.path), "preview_texture", priority, maxi(int(entry.bytes), 1), _owner, tokens)
		if str(result.status) == "rejected":
			entry.failed = str(result.reason)
		(record.textures as Dictionary)[tex_key] = entry


## Binds the members whose asset textures all resolved; objects in pinned cells wait.
func _bind_members() -> void:
	var bound := _world.preview_owner_ids()
	var entries: Dictionary = {}
	for id: String in _members:
		if bound.has(id) or _world.is_object_pinned(id):
			continue
		var variants: Variant = _variants_of(str(_members[id]))
		if variants != null:
			entries[id] = variants
	if not entries.is_empty():
		_world.begin_preview_owners(entries)


## Variants of an asset once every one of its preview textures resolved (ready or failed); null while loading
## or when none is ready.
func _variants_of(asset_id: String) -> Variant:
	var record: Dictionary = _assets.get(asset_id, {})
	if record.is_empty():
		return null
	if record.variants != null:
		return record.variants if not (record.variants as Dictionary).is_empty() else null
	var d := _registry.descriptor(asset_id)
	var textures: Dictionary = record.textures
	for t: Dictionary in textures.values():
		var st := "UNLOADED" if str(t.key) == "" or str(t.failed) != "" else _cache.state(str(t.key))
		if st == "QUEUED" or st == "LOADING":
			return null
	var variants: Dictionary = {}
	for m: Dictionary in d.materials.values():
		var tex_key := str(m.texture)
		if not textures.has(tex_key):
			continue
		var t: Dictionary = textures[tex_key]
		var tex: Texture2D = _cache.get_resource(str(t.key)) as Texture2D if str(t.failed) == "" else null
		var low_path := str(d.dependency(str(m.dependency)).path)
		var variant := _variant(low_path, str(t.key), tex)
		if variant != null:
			variants[low_path] = variant
	record.variants = variants
	return variants if not variants.is_empty() else null


## One material copy per (low material, preview texture), shared by every object using it.
func _variant(low_path: String, tex_key: String, tex: Texture2D) -> Material:
	if tex == null:
		return null
	var vkey := "%s|%s" % [low_path, tex_key]
	if _variant_cache.has(vkey):
		return _variant_cache[vkey]
	var low := ResourceLoader.load(low_path) as StandardMaterial3D
	if low == null:
		return null
	var copy := low.duplicate() as StandardMaterial3D
	copy.albedo_texture = tex
	_variant_cache[vkey] = copy
	return copy
