class_name AssetDefinition
extends RefCounted
## One trusted catalog entry (spec §10.3). Built only by AssetCatalog from the bundled
## catalog.json; world files reference assets by id/version, never by path.

var asset_id: String = ""
var version: int = 0
var display_name: String = ""
var category: String = ""
var preview_scene: String = ""
var scatter_mesh: String = ""  # "" when null in the catalog
var thumbnail: String = ""
var bounds := AABB()
var anchor_local := Vector3.ZERO  # catalog field placement_anchor_local
var footprint_radius_m: float = 0.0
var scale_min: float = 1.0
var scale_max: float = 1.0
var height_offset_min_m: float = 0.0
var height_offset_max_m: float = 0.0
var default_grounding: String = WorldConstants.GROUNDING_FOLLOW
var scatter_allowed: bool = false
var provenance: String = ""
var license: String = ""


func scale_in_range(s: float) -> bool:
	return is_finite(s) and s > 0.0 and s >= scale_min and s <= scale_max


func height_offset_in_range(h: float) -> bool:
	return is_finite(h) and h >= height_offset_min_m and h <= height_offset_max_m
