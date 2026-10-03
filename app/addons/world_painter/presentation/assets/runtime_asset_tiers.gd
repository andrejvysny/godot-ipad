class_name RuntimeAssetTiers
extends RefCounted
## Runtime-derived render tiers of an AssetStudio binding (INT-SPEC §11): selected/near/mid share the baked GLB
## mesh, far/ghost and the grouped overview use a box of the frozen descriptor bounds. They become a
## RenderAssetDescriptor registered in the shared registry/cache under the binding id (the render key), so the
## batch, LOD and overview code consumes them unchanged. Derived data is local cache: never in world files or hashes.

const SELECTED_DEP := "mesh_selected"
const FAR_DEP := "mesh_far"
const FAR_COLOR := Color(0.62, 0.64, 0.66)
const MAGIC := "WPRA-RUNTIME-V1\n"
const BOX_TRIANGLES := 12
const BOX_BYTES := 1024


## One prepared asset: the descriptor plus the two meshes it names.
class Tiers extends RefCounted:
	var key := ""
	var descriptor: RenderAssetDescriptor
	var selected: Mesh
	var far: Mesh
	var selected_bytes := 0
	var scatter_ok := false


## Builds the tiers of `def` (the effective definition: render key, frozen bounds, anchor, footprint) from a
## successful RuntimeGlbLoader.Result. `scatter_ok`: policy.scatter_allowed AND the structural scatter budget.
static func build(def: AssetDefinition, baked: RuntimeGlbLoader.Result, scatter_ok: bool, provenance: String) -> Tiers:
	var t := Tiers.new()
	t.key = def.asset_id
	t.selected = baked.mesh
	t.far = far_box(def.bounds)
	t.selected_bytes = baked.gpu_bytes
	t.scatter_ok = scatter_ok
	var d := RenderAssetDescriptor.new()
	d.asset_id = def.asset_id
	d.asset_version = 1
	d.derivative_hash = CanonicalEncoder.sha256_hex((MAGIC + def.asset_id).to_utf8_buffer())
	d.source_content_hash = d.derivative_hash
	d.category = "prop"
	d.anchor_local = def.anchor_local
	d.bounds = def.bounds
	d.footprint_radius_m = def.footprint_radius_m
	d.provenance = provenance
	d.license = "see descriptor"
	var selected := {"mesh": SELECTED_DEP, "triangles": baked.triangles, "surfaces": baked.surfaces, "aabb": baked.aabb}
	var far := {"mesh": FAR_DEP, "triangles": BOX_TRIANGLES, "surfaces": 1, "aabb": def.bounds}
	for role: String in ["selected", "near", "mid"]:
		d.roles[role] = selected.duplicate()
	for role: String in ["far", "ghost"]:
		d.roles[role] = far.duplicate()
	d.add_dependency_entry(_dependency(def.asset_id, SELECTED_DEP, baked.gpu_bytes))
	d.add_dependency_entry(_dependency(def.asset_id, FAR_DEP, BOX_BYTES))
	var size := def.bounds.size
	d.overview = {"kind": "solid", "shape": "box", "base_y_m": def.bounds.position.y,
		"height_m": maxf(size.y, 0.01), "radius_m": maxf(maxf(size.x, size.z) * 0.5, 0.01), "color": FAR_COLOR}
	t.descriptor = d
	return t


## Box mesh of the frozen descriptor bounds (asset space), one grey opaque material.
static func far_box(bounds: AABB) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var size := Vector3(maxf(bounds.size.x, 0.01), maxf(bounds.size.y, 0.01), maxf(bounds.size.z, 0.01))
	st.append_from(box, 0, Transform3D(Basis.from_scale(size), bounds.get_center()))
	var material := StandardMaterial3D.new()
	material.albedo_color = FAR_COLOR
	st.set_material(material)
	return st.commit()


static func cache_key(key: String, dependency: String) -> String:
	return RenderAssetCache.resource_key(key, 1, CanonicalEncoder.sha256_hex((MAGIC + key).to_utf8_buffer()), dependency)


## Pins both meshes in the cache for `owner` and registers the descriptor. Returns "" or the rejection reason
## (nothing stays registered on failure).
static func register(t: Tiers, registry: RenderAssetRegistry, cache: RenderAssetCache, owner: String) -> String:
	var a := cache.put_runtime(cache_key(t.key, SELECTED_DEP), t.selected, "mesh", t.selected_bytes, owner)
	if str(a.status) == "rejected":
		return "render cache rejected the mesh: %s" % a.reason
	var b := cache.put_runtime(cache_key(t.key, FAR_DEP), t.far, "mesh", BOX_BYTES, owner)
	if str(b.status) == "rejected":
		cache.release_runtime(cache_key(t.key, SELECTED_DEP), owner)
		return "render cache rejected the mesh: %s" % b.reason
	registry.register_runtime(t.descriptor, t.scatter_ok)
	return ""


static func unregister(key: String, registry: RenderAssetRegistry, cache: RenderAssetCache, owner: String) -> void:
	registry.unregister_runtime(key)
	cache.release_runtime(cache_key(key, SELECTED_DEP), owner)
	cache.release_runtime(cache_key(key, FAR_DEP), owner)


static func _dependency(key: String, dep_key: String, gpu_bytes: int) -> Dictionary:
	return {"key": dep_key, "type": "mesh", "rel_path": dep_key, "path": "runtime://" + cache_key(key, dep_key),
		"bytes": maxi(gpu_bytes, 1), "sha256": "0".repeat(64), "gpu_bytes": maxi(gpu_bytes, 1), "staging_bytes": 0}
