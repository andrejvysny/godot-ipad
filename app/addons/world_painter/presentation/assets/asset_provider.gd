class_name WPAssetProvider
extends RefCounted
## Provider boundary of the presentation layer (INT-SPEC §3 "Runtime boundaries", IP-SPEC §2). A provider turns a
## binding id of the attached world's WorldAssetLock into frozen placement metadata, prepared render tiers and
## selection nodes. Implementations: BundledProvider, AssetStudioProvider, FakeProvider; WorldAssetProviders
## routes by binding provider. Everything except the signal runs on the main thread; nothing here loads scripts
## or scene sources from downloaded content.

## Emitted once per prepare() call, always later than the call (never synchronously). `error` is "" on success,
## "cancelled" when the work was abandoned (nothing was registered), else a short human reason.
signal prepared(binding_id: String, ok: bool, error: String)

const TIER_SELECTED := "selected"
const TIER_NEAR := "near"
const TIER_MID := "mid"
const TIER_FAR := "far"
const TIER_GHOST := "ghost"
const TIER_OVERVIEW := "overview"

## The WorldAssetLock of the open world (bindings, frozen descriptors, availability marks).
var assets: WorldAssetLock


## Binds the provider to the open world's lock. Providers that keep prepared assets across worlds re-mark them.
func attach(lock: WorldAssetLock) -> void:
	assets = lock


func provider_id() -> String:
	return ""


## Frozen placement metadata, no nodes: {binding_id, render_key, provider, display_name, category, bounds (AABB),
## anchor_local, footprint_radius_m, default_grounding, scale_range, height_offset_range_m, scatter_allowed}.
## Empty for an unknown binding. Available before and after prepare().
func describe(binding_id: String) -> Dictionary:
	var def: AssetDefinition = assets.definition(binding_id) if assets != null else null
	if def == null:
		return {}
	return {"binding_id": binding_id, "render_key": def.asset_id, "provider": provider_id(),
		"display_name": def.display_name, "category": def.category, "bounds": def.bounds,
		"anchor_local": def.anchor_local, "footprint_radius_m": def.footprint_radius_m,
		"default_grounding": def.default_grounding, "scale_range": [def.scale_min, def.scale_max],
		"height_offset_range_m": [def.height_offset_min_m, def.height_offset_max_m],
		"scatter_allowed": def.scatter_allowed}


## Starts preparing `binding_id` (fetch, verify, bake, register). The result arrives through `prepared`.
## `cancel` is an optional ASCancelToken; cancel()/cancel_all() also stop the work.
func prepare(_binding_id: String, _cancel: RefCounted = null) -> void:
	pass


func is_prepared(_binding_id: String) -> bool:
	return false


## The mesh of a tier (selected, near, mid, far, ghost, overview) once prepared; null before, for an unknown tier
## or while a bundled mesh is not loaded yet.
func representation(_binding_id: String, _tier: String) -> Mesh:
	return null


## A new Node3D showing the selected tier (the caller owns and frees it); null when not prepared.
func instantiate(_binding_id: String) -> Node3D:
	return null


## Keeps `binding_ids` prepared (and their cached bytes safe from pruning) for `owner`; replaces the owner's set.
func pin(_owner: String, _binding_ids: PackedStringArray) -> void:
	pass


## Drops the owner's pins; assets no owner pins any more are released.
func unpin(_owner: String) -> void:
	pass


## Abandons the in-flight prepare of one binding (it emits prepared(..., "cancelled") and registers nothing).
func cancel(_binding_id: String) -> void:
	pass


func cancel_all() -> void:
	pass


func pending_count() -> int:
	return 0
