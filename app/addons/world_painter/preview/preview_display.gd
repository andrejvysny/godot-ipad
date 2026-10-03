class_name PreviewDisplay
extends RefCounted
## The document the preview draws (ADR 0016 P4): a mirror of the replica's committed document plus the provisional
## overlay, so the committed replica itself is never touched by previews. Region maps, object records, scatter and
## path containers are shared with the replica by reference and only ever replaced (the replica replaces too), so a
## commit costs the touched maps only. Each call returns the "effects" the renderers must be told about:
## {maps: [[map kind, loc]], height_rects: [Rect2], objects: [ids], layers: bool, rules: bool, lock: bool}.

const MAP_OF_KIND := {LiveTiles.KIND_HEIGHT: TerrainView.MAP_HEIGHT, LiveTiles.KIND_CONTROL: TerrainView.MAP_CONTROL,
	LiveTiles.KIND_COLOR: TerrainView.MAP_COLOR}

var doc: WorldDocument

var _applied_tiles: Dictionary = {}  # "x/z/kind" -> [loc, kind]
var _applied_objects: Dictionary = {}  # id -> true
var _scatter_overlaid := false


static func no_effects() -> Dictionary:
	return {"maps": [], "height_rects": [], "objects": [], "layers": false, "rules": false, "lock": false}


## Full mirror of a freshly installed snapshot.
func rebuild_from(src: WorldDocument) -> void:
	doc = WorldDocument.new()
	doc.schema_version = src.schema_version
	doc.layout = src.layout
	doc.world_id = src.world_id
	doc.document_revision = src.document_revision
	doc.source_label = "preview"
	for loc: Vector2i in src.regions:
		var r := RegionBuffers.new(loc)
		var s: RegionBuffers = src.regions[loc]
		r.heights = s.heights
		r.control = s.control
		r.color = s.color
		doc.regions[loc] = r
	doc.objects = src.objects.duplicate()
	doc.rules = src.rules
	doc.scatter = src.scatter
	doc.paths = src.paths
	doc.assets = src.assets
	_applied_tiles.clear()
	_applied_objects.clear()
	_scatter_overlaid = false


## A commit the replica applied (`touched` from LiveDeltaApply).
func apply_commit(src: WorldDocument, touched: Dictionary) -> Dictionary:
	var fx := no_effects()
	doc.document_revision = src.document_revision
	for entry: Array in touched.maps:
		_copy_map(src, entry[0], entry[1], fx)
	for id: String in touched.objects:
		_copy_object(src, id, fx)
	if touched.scatter or touched.paths:
		doc.scatter = src.scatter
		doc.paths = src.paths
		fx.layers = true
	if touched.rules:
		doc.rules = src.rules
		fx.rules = true
	fx.lock = touched.lock
	return fx


## Re-derives everything the overlay shows. Call whenever the overlay changed (including cleared).
func apply_overlay(src: WorldDocument, overlay: LiveOverlay) -> Dictionary:
	var fx := no_effects()
	for entry: Array in _applied_tiles.values():
		_copy_map(src, entry[0], entry[1], fx)
	for id: String in _applied_objects:
		_copy_object(src, id, fx)
	_applied_tiles.clear()
	_applied_objects.clear()
	_overlay_tiles(overlay, fx)
	for id: String in overlay.objects:
		var record: ObjectRecord = overlay.objects[id].record
		if record == null:
			doc.objects.erase(id)
		elif doc.assets.has_binding(record.binding_id):
			doc.objects[id] = record
		else:
			continue  # the binding only arrives with the commit: shown then
		_applied_objects[id] = true
		fx.objects.append(id)
	_overlay_scatter(src, overlay, fx)
	return fx


func _copy_map(src: WorldDocument, loc: Vector2i, kind: String, fx: Dictionary) -> void:
	var s: RegionBuffers = src.regions.get(loc)
	var d: RegionBuffers = doc.regions.get(loc)
	if s == null or d == null:
		return
	match kind:
		LiveTiles.KIND_HEIGHT:
			d.heights = s.heights
			doc.invalidate_height_range(loc)
			fx.height_rects.append(Rect2(Vector2(loc * WorldConstants.REGION_SAMPLES) * WorldConstants.SAMPLE_SPACING,
				Vector2.ONE * float(WorldConstants.REGION_SAMPLES) * WorldConstants.SAMPLE_SPACING))
		LiveTiles.KIND_CONTROL:
			d.control = s.control
		_:
			d.color = s.color
	fx.maps.append([MAP_OF_KIND[kind], loc])


func _copy_object(src: WorldDocument, id: String, fx: Dictionary) -> void:
	if src.objects.has(id):
		doc.objects[id] = src.objects[id]
	else:
		doc.objects.erase(id)
	fx.objects.append(id)


func _overlay_tiles(overlay: LiveOverlay, fx: Dictionary) -> void:
	var groups: Dictionary = {}  # "x/z/kind" -> {loc, kind, updates}
	for t: Dictionary in overlay.tiles.values():
		var key := "%d/%d/%s" % [t.loc.x, t.loc.y, t.kind]
		if not groups.has(key):
			groups[key] = {"loc": t.loc, "kind": t.kind, "updates": {}}
		groups[key].updates[Vector2i(t.tx, t.tz)] = t.bytes
	for key: String in groups:
		var g: Dictionary = groups[key]
		var region: RegionBuffers = doc.regions.get(g.loc)
		if region == null:
			continue
		var base := LiveTiles.bytes_of_region(region, g.kind)
		LiveTiles.set_region_bytes(region, g.kind, LiveTiles.compose(base, g.updates))
		_applied_tiles[key] = [g.loc, g.kind]
		fx.maps.append([MAP_OF_KIND[g.kind], g.loc])
		if g.kind == LiveTiles.KIND_HEIGHT:
			doc.invalidate_height_range(g.loc)
			fx.height_rects.append(Rect2(Vector2(g.loc * WorldConstants.REGION_SAMPLES) * WorldConstants.SAMPLE_SPACING,
				Vector2.ONE * float(WorldConstants.REGION_SAMPLES) * WorldConstants.SAMPLE_SPACING))


## While scatter tiles are previewed they replace the committed instances inside those tiles.
func _overlay_scatter(src: WorldDocument, overlay: LiveOverlay, fx: Dictionary) -> void:
	if overlay.scatter_tiles.is_empty():
		if _scatter_overlaid:
			doc.scatter = src.scatter
			_scatter_overlaid = false
			fx.layers = true
		return
	var replaced := {}
	for key: String in overlay.scatter_tiles:
		replaced[key] = true
	var layer := ScatterLayer.new()
	var base := src.scatter
	for i in base.count():
		var at := LiveTiles.tile_at(base.x[i], base.z[i])
		if not replaced.has("%d/%d/%d/%d" % [at.loc.x, at.loc.y, at.tx, at.tz]):
			layer.add(base.binding_of(i), base.x[i], base.z[i], base.yaw[i], base.scale[i], base.flags[i])
	for t: Dictionary in overlay.scatter_tiles.values():
		_add_preview_tile(layer, t.bytes)
	doc.scatter = layer
	_scatter_overlaid = true
	fx.layers = true


## WPST bytes were validated by WorldDelta.parse; instances of unknown bindings are skipped.
func _add_preview_tile(layer: ScatterLayer, bytes: PackedByteArray) -> void:
	var r := BinReader.new(bytes)
	r.ascii(4)
	r.u32("version")
	var ids := PackedStringArray()
	for i in r.u32("binding_count"):
		ids.append(r.text("binding_id", ScatterLayer.MAX_BINDING_ID_LEN))
	for i in r.u32("instance_count"):
		var index := r.u16("binding_index")
		var flags := r.u16("flags")
		var px := r.f32("x")
		var pz := r.f32("z")
		var yaw := r.f32("yaw")
		var scale := r.f32("scale")
		if r.error == "" and index < ids.size() and doc.assets.has_binding(ids[index]):
			layer.add(ids[index], px, pz, yaw, scale, flags)
