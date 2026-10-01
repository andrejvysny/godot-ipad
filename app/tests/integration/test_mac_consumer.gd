extends TestCase
## Mac consumer (spec §17.6; IO-01, IO-02, IO-07): same trusted validation, read-only display.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const STRESS := "res://fixtures/stress_100"
var catalog: AssetCatalog
var consumer: MacConsumer
var log_filter: TerrainTests.KnownWarningFilter


func before_each() -> void:
	var loaded := AssetCatalog.load_from()
	assert_empty_string(loaded[1])
	catalog = loaded[0]


func after_each() -> void:
	if is_instance_valid(consumer):
		if consumer.is_inside_tree():
			tree.root.remove_child(consumer)
		consumer.free()
	if log_filter != null:
		assert_true(log_filter.unexpected.is_empty(), str(log_filter.unexpected))
		OS.remove_logger(log_filter)


func _export(source: String, name: String) -> String:
	var out := scratch_dir().path_join(name)
	assert_empty_string(WorldPackage.export_package(source, out, catalog, scratch_dir().path_join("tmp")))
	return out


func test_package_round_trip_matches_source_bytes_and_transforms() -> void:
	var source: WorldDocument = WorldCodec.read_generation(STRESS, catalog)[0]
	var pkg := _export(STRESS, "stress.worldpoc")
	var loaded := WorldLoader.load_world(pkg, catalog, scratch_dir().path_join("tmp"))
	assert_empty_string(loaded[1])
	var doc: WorldDocument = loaded[0]
	assert_eq(doc.objects.size(), 100)
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(STRESS + "/manifest.json"))
	assert_eq(CanonicalEncoder.authored_hash(doc), manifest.authored_content_hash)
	var report := WorldLoader.report(doc, catalog)
	assert_eq(report.authored_hash, manifest.authored_content_hash)
	assert_eq(report.regions.size(), source.regions.size())
	for loc in source.regions:
		var key := "%d,%d" % [loc.x, loc.y]
		var rb: RegionBuffers = source.regions[loc]
		assert_eq(report.regions[key].height_sha256, CanonicalEncoder.sha256_hex(rb.height_bytes()), key)
		assert_eq(report.regions[key].control_sha256, CanonicalEncoder.sha256_hex(rb.control_bytes()), key)
	assert_eq(report.object_ids, Array(source.sorted_object_ids()))
	for id in source.objects:
		var a: ObjectRecord = source.objects[id]
		var asset := catalog.get_asset(a.asset_id)
		var b: ObjectRecord = doc.objects[id]
		assert_true(a.node_transform(asset.anchor_local) == b.node_transform(asset.anchor_local), id)


func test_generation_directory_loads() -> void:
	var loaded := WorldLoader.load_world(STRESS, catalog)
	assert_empty_string(loaded[1])
	assert_eq((loaded[0] as WorldDocument).objects.size(), 100)
	var absolute := ProjectSettings.globalize_path(STRESS)
	assert_empty_string(WorldLoader.load_world(absolute, catalog)[1])
	assert_error_contains(WorldLoader.load_world("res://fixtures/nope", catalog)[1], "World path not found")


func test_altered_catalog_hash_is_rejected() -> void:
	var dir := scratch_dir().path_join("altered")
	StorageFs.make_dir(dir.path_join("regions"))
	for name in ["manifest.json", "objects.json"] + Array(WorldCodec.payload_paths().slice(1)):
		var bytes: PackedByteArray = StorageFs.read_bytes(STRESS.path_join(name))[0]
		if name == "manifest.json":
			var manifest: Dictionary = JSON.parse_string(bytes.get_string_from_utf8())
			manifest.catalog.sha256 = "ab".repeat(32)
			bytes = JSON.stringify(manifest, "\t").to_utf8_buffer()
		assert_empty_string(StorageFs.write_bytes(dir.path_join(name), bytes))
	var pkg := scratch_dir().path_join("altered.worldpoc")
	assert_empty_string(WorldPackage.export_package(dir, pkg, null, scratch_dir().path_join("tmp")))
	var result := WorldLoader.load_world(pkg, catalog, scratch_dir().path_join("tmp"))
	assert_true(result[0] == null)
	assert_error_contains(result[1], "incompatible catalog")


func test_verify_only_reports_without_scene_nodes() -> void:
	var pkg := ProjectSettings.globalize_path(_export(STRESS, "good.worldpoc"))
	consumer = MacConsumer.new()
	consumer.auto_run = false
	var report_path := scratch_dir().path_join("report.json")
	assert_eq(consumer.run(PackedStringArray(["--world=" + pkg, "--verify-only", "--report=" + report_path])), 0)
	assert_eq(consumer.get_child_count(), 0)
	assert_true(consumer.adapter == null)
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(report_path))
	assert_true(report.ok)
	assert_eq(int(report.object_count), 100)
	assert_eq(consumer.run(PackedStringArray(["--world=/nonexistent/x.worldpoc", "--verify-only"])), 1)
	assert_eq(consumer.run(PackedStringArray(["--verify-only"])), 1)
	assert_eq(consumer.get_child_count(), 0)


func test_visual_mode_builds_terrain_and_objects() -> void:
	allow_logged_errors()
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)
	consumer = MacConsumer.new()
	consumer.auto_run = false
	tree.root.add_child(consumer)
	assert_eq(consumer.run(PackedStringArray(["--world=" + STRESS])), 0)
	await tree.process_frame
	assert_true(consumer.adapter != null)
	assert_eq(consumer.presenter.object_count(), 100)
	assert_true(consumer.info_label.text.contains("MAC CONSUMER — read-only"))
	tree.root.remove_child(consumer)
	consumer.free()
	consumer = MacConsumer.new()
	consumer.auto_run = false
	tree.root.add_child(consumer)
	assert_eq(consumer.run(PackedStringArray(["--world=res://fixtures/nope"])), 1)
	assert_true(consumer.info_label.text.contains("Re-export the world"))


func test_visual_mode_renders_gentle_hills_scatter() -> void:
	allow_logged_errors()
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)
	consumer = MacConsumer.new()
	consumer.auto_run = false
	tree.root.add_child(consumer)
	assert_eq(consumer.run(PackedStringArray(["--world=res://fixtures/gentle_hills"])), 0)
	await tree.process_frame
	assert_eq(consumer.layers.stats().instances, 550)
	assert_true(consumer.info_label.text.contains("scatter 550"))
	var report := WorldLoader.report(consumer.document, catalog)
	assert_eq(report.scatter_instance_count, 550)

