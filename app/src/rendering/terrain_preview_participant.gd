class_name TerrainPreviewParticipant
extends RefCounted
## Terrain side of the fixed-area Texture Preview (spec 11.4). Picks the material slots the area
## shows, requests their prepared preview textures through the shared RenderAssetCache, builds the two
## compact Texture2DArrays once everything resolved and binds them to the terrain view. Never touches
## the document and never replaces a low-tier binding with an unloaded texture.

const EDGE_PX := 1024  # the only prepared preview tier (assets/terrain/preview)
const PRIORITY := 5  # spec 12.3 item 5
const DIR := "res://assets/terrain/preview/"
const KINDS := ["albedo", "normal"]

var build_ms := 0.0  # Texture2DArray.create_from_images, both arrays
var image_ms := 0.0  # Texture2D.get_image of the ready textures (a readback on a real renderer)

var _cache: RenderAssetCache
var _terrain: TerrainView
var _doc: WorldDocument
var _sources: Dictionary  # slot -> {"albedo": path, "normal": path}
var _slots := PackedInt32Array()  # previewed slot ids, layer order
var _keys: Dictionary = {}  # texture id ("dirt_albedo") -> cache key
var _failed: Dictionary = {}  # texture id -> reason
var _center := Vector2.ZERO
var _radius := 0.0
var _feather := 1.5
var _bound := false


func _init(cache: RenderAssetCache, terrain: TerrainView, doc: WorldDocument, sources: Dictionary = {}) -> void:
	_cache = cache
	_terrain = terrain
	_doc = doc
	_sources = sources if not sources.is_empty() else default_sources()


static func default_sources() -> Dictionary:
	var out := {}
	for slot in TerrainMaterials.TEXTURE_NAMES.size():
		var name: String = TerrainMaterials.TEXTURE_NAMES[slot]
		out[slot] = {"albedo": DIR + name + "_albedo.png", "normal": DIR + name + "_normal.png"}
	return out


## Estimate of one texture's cost while a preview holds it (spec 12.5): the block-compressed texture
## (8 bits per pixel, full mip chain), its staging copy and its layer in the Texture2DArray.
static func estimate_bytes(edge: int) -> int:
	var chain := edge * edge * 4 / 3
	return chain * 3


func slots() -> PackedInt32Array:
	return _slots.duplicate()


## Starts the requests. `generation` tags them for cancel_generation(); returns "" or an error.
func begin(center: Vector2, radius: float, feather: float, max_materials: int, owner: String,
		generation: int) -> String:
	_center = center
	_radius = radius
	_feather = feather
	_slots = TerrainPreviewScan.select_slots(TerrainPreviewScan.slot_weights(_doc, center, radius), max_materials)
	var tokens := {"preview_generation": generation, "expect_w": EDGE_PX, "expect_h": EDGE_PX}
	for slot in _slots:
		var paths: Dictionary = _sources.get(slot, {})
		for kind: String in KINDS:
			var id := "%s_%s" % [TerrainMaterials.TEXTURE_NAMES[slot], kind]
			var path := str(paths.get(kind, ""))
			var key := "terrain_preview|%s|%d" % [id, EDGE_PX]
			_cache.forget_error(key)  # a retry must not inherit an earlier attempt's sticky error
			var result := _cache.request(key, path, "preview_texture", PRIORITY, estimate_bytes(EDGE_PX), owner, tokens)
			if str(result.status) == "rejected":
				_failed[id] = str(result.reason)
			else:
				_keys[id] = key
	return ""


## {"requested", "ready", "pending", "missing": Array[String] of texture ids, "reasons": id -> why, "bytes"}.
func progress() -> Dictionary:
	var ready := 0
	var pending := 0
	var missing: Array[String] = []
	var reasons := _failed.duplicate()
	for slot in _slots:
		for kind: String in KINDS:
			var id := "%s_%s" % [TerrainMaterials.TEXTURE_NAMES[slot], kind]
			var st := "UNLOADED" if not _keys.has(id) else _cache.state(str(_keys[id]))
			if st == "READY":
				ready += 1
			elif st == "QUEUED" or st == "LOADING":
				pending += 1
			else:
				missing.append(id)
				if _keys.has(id) and not reasons.has(id):
					reasons[id] = _cache.reason(str(_keys[id]))
	return {"requested": _slots.size() * KINDS.size(), "ready": ready, "pending": pending, "missing": missing,
		"reasons": reasons, "bytes": ready * estimate_bytes(EDGE_PX)}


## Builds the arrays from the slots whose albedo and normal are both ready and binds them. Returns "" or
## why nothing was bound (the low tier then stays in use). Slots without a pair map to layer -1.
func publish() -> String:
	var albedo: Array[Image] = []
	var normal: Array[Image] = []
	var layer_map := PackedInt32Array([-1, -1, -1, -1])
	var t_images := Time.get_ticks_usec()
	for slot in _slots:
		var name: String = TerrainMaterials.TEXTURE_NAMES[slot]
		var a := _image("%s_albedo" % name)
		var n := _image("%s_normal" % name)
		if a == null or n == null:
			continue
		layer_map[slot] = albedo.size()
		albedo.append(a)
		normal.append(n)
	image_ms = float(Time.get_ticks_usec() - t_images) / 1000.0
	if albedo.is_empty():
		return "no preview texture could be prepared"
	var t0 := Time.get_ticks_usec()
	var albedo_array := Texture2DArray.new()
	var normal_array := Texture2DArray.new()
	if albedo_array.create_from_images(albedo) != OK or normal_array.create_from_images(normal) != OK:
		return "preview textures do not share one format, size and mipmap chain"
	build_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	var err := _terrain.set_texture_preview(_center, _radius, _feather, albedo_array, normal_array, layer_map)
	_bound = err == ""
	return err


## Restores the low tier. Cache references are released by the controller.
func release() -> void:
	if _bound:
		_terrain.clear_texture_preview()
	_bound = false


func is_bound() -> bool:
	return _bound


func _image(id: String) -> Image:
	if not _keys.has(id):
		return null
	var tex := _cache.get_resource(str(_keys[id])) as Texture2D
	return null if tex == null else tex.get_image()
