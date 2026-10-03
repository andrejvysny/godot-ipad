class_name WorldAssetLock
extends RefCounted
## Content-addressed, append-only registry binding_id -> AssetBinding (ADR 0014 D2). It may hold
## bindings no record references (after undo, an abandoned brush). It is not history data: a binding
## is immutable and identified by its content. The serialized lock is derived from the references
## (encode_referenced), so the authored hash depends only on referenced content.

const CanonicalJson := preload("res://addons/assetstudio/core/as_canonical_json.gd")
const Schema := preload("res://addons/assetstudio/core/as_schema.gd")

const LOCK_SCHEMA := 1
const LOCK_KEYS := ["schema_version", "bindings", "dependencies"]
const MAX_BINDINGS := 4096
const REMOTE_UNAVAILABLE := "AssetStudio asset is not resolved on this device (its exact bytes are not prepared yet)"

## Trusted bundled catalog (runtime reference, never serialized). Setting it drops derived caches.
var catalog: AssetCatalog:
	set(value):
		catalog = value
		_defs.clear()
		_bundled_ids.clear()

var _bindings: Dictionary = {}  # binding_id -> AssetBinding
var _defs: Dictionary = {}  # binding_id -> AssetDefinition
var _bundled_ids: Dictionary = {}  # catalog asset_id -> default-policy binding_id
var _prepared: Dictionary = {}  # AssetStudio binding_id -> scatter_ok (runtime state, never serialized)
var _failed: Dictionary = {}  # AssetStudio binding_id -> why its bytes could not be prepared


func _init(p_catalog: AssetCatalog = null) -> void:
	catalog = p_catalog


## Registers `b` (finalizing its id when unset); idempotent. Returns its binding_id.
func add(b: AssetBinding) -> String:
	if b.binding_id == "":
		b.finalize()
	if not _bindings.has(b.binding_id):
		_bindings[b.binding_id] = b
	return b.binding_id


func has_binding(id: String) -> bool:
	return _bindings.has(id)


func get_binding(id: String) -> AssetBinding:
	return _bindings.get(id)


func size() -> int:
	return _bindings.size()


func ids() -> PackedStringArray:
	var out := PackedStringArray(_bindings.keys())
	out.sort()
	return out


## Binding id of the default-policy bundled binding of the trusted catalog entry (created on demand);
## "" when there is no catalog or no such entry.
func bundled_binding_for(asset_id: String) -> String:
	if _bundled_ids.has(asset_id):
		return _bundled_ids[asset_id]
	if catalog == null:
		return ""
	var def := catalog.get_asset(asset_id)
	if def == null:
		return ""
	var id := add(AssetBinding.bundled_default(catalog, def))
	_bundled_ids[asset_id] = id
	return id


## Sorted ids referenced by object records or scatter instances (unused scatter slots do not count).
## `object_bindings` (the binding ids of all records, e.g. ObjectChunkCache.binding_ids()) saves the scan of
## every record.
func referenced_ids(doc: WorldDocument, object_bindings: Variant = null) -> PackedStringArray:
	var seen := {}
	if object_bindings != null:
		for id: String in object_bindings:
			seen[id] = true
	else:
		for id: String in doc.objects:
			seen[(doc.objects[id] as ObjectRecord).binding_id] = true
	var layer := doc.scatter
	var slots_used := {}
	for s in layer.slot:
		slots_used[s] = true
	for s: int in slots_used:
		if s >= 0 and s < layer.binding_ids.size():
			seen[layer.binding_ids[s]] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


## Canonical asset_locks.json bytes for `doc`'s references. Returns [PackedByteArray, ""] or [empty, error].
func encode_referenced(doc: WorldDocument, object_bindings: Variant = null) -> Array:
	var rows: Array = []
	var deps := {}
	for id in referenced_ids(doc, object_bindings):
		var b: AssetBinding = _bindings.get(id)
		if b == null:
			return [PackedByteArray(), "binding '%s' is referenced but not in the asset lock" % id]
		rows.append(b.to_dict(true))
		for key: String in b.dependencies:
			if deps.has(key) and deps[key] != b.dependencies[key]:
				return [PackedByteArray(), "conflicting dependency entries for asset_key %s" % key]
			deps[key] = b.dependencies[key].duplicate(true)
	var enc: RefCounted = CanonicalJson.encode({"schema_version": LOCK_SCHEMA, "bindings": rows, "dependencies": deps})
	if not enc.ok:
		return [PackedByteArray(), enc.message]
	return [enc.value, ""]


## Strict parse of asset_locks.json bytes. Returns [WorldAssetLock, ""] or [null, error]. That every binding
## is referenced is checked by the document validator (it needs the records).
static func decode(raw: PackedByteArray, p_catalog: AssetCatalog) -> Array:
	var parsed: RefCounted = CanonicalJson.parse_canonical(raw)
	if not parsed.ok:
		return [null, "asset_locks.json: " + parsed.message]
	var root: Variant = parsed.value
	if typeof(root) != TYPE_DICTIONARY:
		return [null, "asset_locks.json: root is not an object"]
	var err := Schema.check_keys(root, PackedStringArray(LOCK_KEYS), PackedStringArray(), "asset_locks.json")
	if err != "":
		return [null, err]
	if Schema.check_int(root.schema_version, LOCK_SCHEMA, LOCK_SCHEMA, "schema_version") != "":
		return [null, "asset_locks.json: unsupported schema_version %s" % str(root.schema_version)]
	if typeof(root.bindings) != TYPE_ARRAY or typeof(root.dependencies) != TYPE_DICTIONARY:
		return [null, "asset_locks.json: bindings must be an array and dependencies an object"]
	if root.bindings.size() > MAX_BINDINGS:
		return [null, "asset_locks.json: %d bindings exceed the limit of %d" % [root.bindings.size(), MAX_BINDINGS]]
	var lock := WorldAssetLock.new(p_catalog)
	err = lock._read_bindings(root.bindings)
	if err == "":
		err = lock._attach_dependencies(root.dependencies)
	return [null, "asset_locks.json: " + err] if err != "" else [lock, ""]


func _read_bindings(rows: Array) -> String:
	var prev := ""
	for row: Variant in rows:
		var parsed := AssetBinding.from_dict(row)
		if parsed[1] != "":
			return parsed[1]
		var b: AssetBinding = parsed[0]
		if prev != "" and not (prev < b.binding_id):
			return "bindings are not sorted and unique at %s" % b.binding_id
		prev = b.binding_id
		add(b)
	return ""


func _attach_dependencies(deps: Dictionary) -> String:
	var remote: Array = []
	for id in ids():
		var b: AssetBinding = _bindings[id]
		if not b.is_bundled():
			remote.append(b)
	var err := AssetDependencyClosure.error_of(deps, remote)
	if err != "":
		return err
	for b: AssetBinding in remote:
		for key in AssetDependencyClosure.closure_of(b.asset_key, deps):
			b.dependencies[key] = (deps[key] as Dictionary).duplicate(true)
	return ""


## {"unavailable": {binding_id: reason}} over the ids `doc` references (ADR 0014 D8). Never a structural error.
func availability(doc: WorldDocument) -> Dictionary:
	var unavailable := {}
	for id in referenced_ids(doc):
		var reason := unavailable_reason(id)
		if reason != "":
			unavailable[id] = reason
	return {"unavailable": unavailable}


## The provider verified the exact bytes of AssetStudio binding `id` and registered its render tiers.
## `scatter_ok`: the structural scatter budget (<= 2000 triangles, <= 2 materials, <= 1024 px textures) holds.
func mark_prepared(id: String, scatter_ok: bool = false) -> void:
	var b: AssetBinding = _bindings.get(id)
	if b == null or b.is_bundled():
		return
	_prepared[id] = scatter_ok
	_failed.erase(id)
	_defs.erase(id)


func mark_unprepared(id: String, reason: String = "") -> void:
	_prepared.erase(id)
	if reason != "":
		_failed[id] = reason
	_defs.erase(id)


func is_prepared(id: String) -> bool:
	return _prepared.has(id)


## True when the prepared AssetStudio binding passed the structural scatter budget (false while unprepared).
func scatter_budget_ok(id: String) -> bool:
	return bool(_prepared.get(id, false))


## "" when the binding is usable on this device.
func unavailable_reason(id: String) -> String:
	var b: AssetBinding = _bindings.get(id)
	if b == null:
		return "binding is not in the asset lock"
	if not b.is_bundled():
		if _prepared.has(id):
			return ""
		return "%s: %s" % [REMOTE_UNAVAILABLE, _failed[id]] if _failed.has(id) else REMOTE_UNAVAILABLE
	if catalog == null:
		return "no trusted catalog is loaded"
	if b.catalog_id != catalog.catalog_id or b.catalog_version != catalog.catalog_version \
			or b.catalog_sha256 != catalog.sha256:
		return "catalog '%s' v%d (sha256 %s) is not the trusted catalog '%s' v%d (sha256 %s)" % [
			b.catalog_id, b.catalog_version, b.catalog_sha256, catalog.catalog_id, catalog.catalog_version, catalog.sha256]
	var def := catalog.get_asset(b.asset_id)
	if def == null:
		return "asset '%s' is not in the trusted catalog" % b.asset_id
	if def.version != b.asset_version:
		return "asset '%s' v%d is not the trusted v%d" % [b.asset_id, b.asset_version, def.version]
	return ""


## Effective definition for tools and renderers (ADR 0014 D10); null for an unknown id. `asset_id` of the
## result is the render key: the catalog asset id for an available bundled binding, else the binding id.
func definition(id: String) -> AssetDefinition:
	if _defs.has(id):
		return _defs[id]
	var b: AssetBinding = _bindings.get(id)
	if b == null:
		return null
	var def: AssetDefinition
	if b.is_bundled():
		def = _bundled_definition(b)
	else:
		def = _remote_definition(b)
	_defs[id] = def
	return def


func _bundled_definition(b: AssetBinding) -> AssetDefinition:
	var def := AssetDefinition.new()
	if unavailable_reason(b.binding_id) == "":
		var src := catalog.get_asset(b.asset_id)
		for p in src.get_property_list():
			if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				def.set(p.name, src.get(p.name))
	else:
		def.asset_id = b.binding_id
		def.version = b.asset_version
		def.display_name = b.asset_id
		def.category = "unavailable"
		def.footprint_radius_m = 0.5
	_apply_policy(def, b)
	return def


func _remote_definition(b: AssetBinding) -> AssetDefinition:
	var def := AssetDefinition.new()
	def.asset_id = b.binding_id
	def.version = 1
	def.display_name = str(b.asset_ref.asset_id)
	def.category = "assetstudio"
	var d: Dictionary = JSON.parse_string(b.descriptor_json)
	var lo := _vec3(d.bounds_min)
	def.bounds = AABB(lo, _vec3(d.bounds_max) - lo)
	def.anchor_local = _vec3(d.placement_anchor)
	def.footprint_radius_m = maxf(float(_dec(d.footprint_radius_m)), 0.001)
	def.default_grounding = d.default_grounding
	_apply_policy(def, b)
	def.scatter_allowed = b.scatter_allowed and bool(_prepared.get(b.binding_id, true))
	return def


static func _apply_policy(def: AssetDefinition, b: AssetBinding) -> void:
	def.scale_min = b.scale_min
	def.scale_max = b.scale_max
	def.height_offset_min_m = b.height_offset_min_m
	def.height_offset_max_m = b.height_offset_max_m
	def.scatter_allowed = b.scatter_allowed


static func _dec(text: String) -> float:
	return AssetBinding.Canonical.parse_decimal(text).value


static func _vec3(v: Array) -> Vector3:
	return Vector3(_dec(v[0]), _dec(v[1]), _dec(v[2]))
