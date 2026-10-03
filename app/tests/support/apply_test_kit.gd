class_name ApplyTestKit
extends RefCounted
## Fixtures of the Apply tests (IP-07): a small world with hills, holes, tint, bundled objects, scatter and paths
## written as a frozen schema 4 generation, plus helpers around the test project's accepted world root.

const SPRUCE := "nature.tree.spruce_a"
const BOULDER := "nature.rock.boulder_a"
const GRASS := "nature.cover.grass_tuft_a"
const FERN := "nature.cover.fern_a"


## Legacy 2x2 layout world (every region present) with content of every kind the bake handles.
static func make_doc(catalog: AssetCatalog, layout: WorldLayout = null, scatter_count: int = 300) -> WorldDocument:
	var doc := WorldDocument.create_flat(0.0, ControlCodec.grass_value(), layout, catalog)
	HillsTerrain.fill(doc, 4242)
	_paint(doc)
	for spec: Array in [[SPRUCE, -30.0, 20.0, 0.7, 1.0], [BOULDER, 12.5, -8.25, 2.1, 1.2], [SPRUCE, 40.0, 40.0, -1.3, 0.8]]:
		doc.put_object(_record(doc, spec[0], spec[1], spec[2], spec[3], spec[4]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var extent := doc.layout.world_rect()
	for i in scatter_count:
		var asset := GRASS if i % 3 != 0 else FERN
		doc.scatter.add(doc.assets.bundled_binding_for(asset), rng.randf_range(extent.position.x + 1.0, extent.end.x - 1.0),
				rng.randf_range(extent.position.y + 1.0, extent.end.y - 1.0), rng.randf_range(-3.0, 3.0),
				rng.randf_range(0.8, 1.2), ScatterLayer.FLAG_TILT if i % 5 == 0 else 0, 100000)
	_paths(doc)
	doc.document_revision = 7
	return doc


static func _paint(doc: WorldDocument) -> void:
	var region: RegionBuffers = doc.regions.values()[0]
	for i in 600:
		region.control[i] = ControlCodec.encode(region.control[i], {"base_id": 2, "overlay_id": 1, "blend": 90})
		region.color[i * 4] = 200
		region.color[i * 4 + 1] = 90
		region.color[i * 4 + 2] = 40
		region.color[i * 4 + 3] = 128
	var holed: RegionBuffers = doc.get_region(Vector2i(0, 0))
	for i in range(1000, 1010):
		holed.control[i] = holed.control[i] | ControlCodec.HOLE_BIT


static func _record(doc: WorldDocument, asset_id: String, x: float, z: float, yaw: float, scale: float) -> ObjectRecord:
	var rec := ObjectRecord.new()
	rec.object_id = ObjectRecord.new_uuid_v4()
	rec.binding_id = doc.assets.bundled_binding_for(asset_id)
	var h := doc.sample_height(x, z)
	rec.set_position(x, 0.0 if is_nan(h) else h, z)
	rec.set_yaw(yaw)
	rec.uniform_scale = scale
	return rec


static func _paths(doc: WorldDocument) -> void:
	for spec: Array in [[Vector2(-60, -60), Vector2(-20, -30), Vector2(10, -35), Vector2(50, -10)], [Vector2(5, 5), Vector2(30, 60)]]:
		var rec := PathRecord.new()
		rec.path_id = ObjectRecord.new_uuid_v4()
		rec.width_m = 3.0
		rec.points = PackedVector2Array(spec)
		doc.put_path(rec)


## Writes `doc` as a frozen generation directory and returns its path ("" on failure).
static func write_frozen(doc: WorldDocument, dir: String) -> String:
	var err := WorldCodec.write_generation(dir, doc, WorldCodec.default_created_with())
	return dir if err == "" else ""


## Adds the remote binding of `item` (AssetTestKit.remote) to `doc` with its dependency closure and one object of it
## at (x, z); returns the binding id.
static func add_remote_object(doc: WorldDocument, item: Dictionary, x: float, z: float) -> String:
	var binding: AssetBinding = item.binding
	binding.dependencies[binding.asset_key] = {"asset_ref": binding.asset_ref.duplicate(true),
		"descriptor_sha256": binding.descriptor_sha256, "deliveries": binding.deliveries.duplicate(true), "requires": []}
	doc.assets.add(binding)
	doc.put_object(_record_for(doc, binding.binding_id, x, z))
	return binding.binding_id


static func _record_for(doc: WorldDocument, binding_id: String, x: float, z: float) -> ObjectRecord:
	var rec := ObjectRecord.new()
	rec.object_id = ObjectRecord.new_uuid_v4()
	rec.binding_id = binding_id
	var h := doc.sample_height(x, z)
	rec.set_position(x, 0.0 if is_nan(h) else h, z)
	rec.set_yaw(0.4)
	return rec


## Installs the portable delivery of `item` below `project_root` the way AssetStudio leaves it (receipt, file, import
## marker) and records it in assetstudio.lock.json with an unrelated scene_binding root; returns the asset key.
static func install_delivery(project_root: String, item: Dictionary) -> String:
	var Lock := preload("res://addons/assetstudio/project/as_project_lock.gd")
	var AssetRef := preload("res://addons/assetstudio/core/as_asset_ref.gd")
	var CJson := preload("res://addons/assetstudio/core/as_canonical_json.gd")
	var binding: AssetBinding = item.binding
	var pin: Dictionary = binding.deliveries.portable_glb_v1
	var dir := project_root.path_join("assets/library").path_join(binding.asset_key).path_join(str(pin.manifest_sha256))
	var glb: PackedByteArray = item.glb
	DirAccess.make_dir_recursive_absolute(dir)
	FileAccess.open(dir.path_join("portable.glb"), FileAccess.WRITE).store_buffer(glb)
	FileAccess.open(dir.path_join("portable.glb.import"), FileAccess.WRITE).store_string("[params]\n")
	var receipt := {"schema_version": 1, "asset_key": binding.asset_key, "asset_ref": binding.asset_ref,
		"delivery_id": pin.delivery_id, "representation": "portable_glb_v1", "manifest_sha256": pin.manifest_sha256,
		"descriptor_sha256": binding.descriptor_sha256, "installer_version": "1.0.0",
		"files": [{"path": "portable.glb", "sha256": CanonicalEncoder.sha256_hex(glb), "size": glb.size()}]}
	FileAccess.open(dir.path_join("receipt.json"), FileAccess.WRITE).store_buffer(CJson.encode(receipt).value)
	var lock_path := project_root.path_join("assetstudio.lock.json")
	var lock: RefCounted
	if FileAccess.file_exists(lock_path):
		lock = Lock.parse_bytes(FileAccess.get_file_as_bytes(lock_path)).value
	else:
		lock = Lock.new_empty("0.2.1", "1.0.0")
	lock.call("add_dependency", AssetRef.parse(binding.asset_ref).value, binding.descriptor_sha256, "portable_glb_v1", pin, [])
	lock.call("add_root", "scene_binding", "manual-" + binding.asset_key.left(8), [binding.asset_key])
	FileAccess.open(lock_path, FileAccess.WRITE).store_buffer(lock.call("to_bytes").value)
	return binding.asset_key
