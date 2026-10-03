extends TestCase
## WorldPreviewRoot / PreviewDisplay (ADR 0016 P4): the drawn document follows the replica's commits, shows the
## provisional overlay without touching the committed replica, reverts it on cancel, labels INCOMPLETE while assets
## are missing, and keeps placeholders (the object is still presented) for them.

const LOC := Vector2i(0, 0)

var h: LiveHarness
var root: WorldPreviewRoot
var assets: PreviewAssets
var client := PreviewBrokerClient.new()


func before_each() -> void:
	allow_logged_errors()  # the pinned Terrain3D binary logs one known deprecation warning
	h = LiveHarness.new()
	h.setup(scratch_dir())


func after_each() -> void:
	if root != null:
		tree.root.remove_child(root)
		root.free()
		root = null
	if assets != null:
		assets.shutdown()
		assets = null
	client.free()
	client = PreviewBrokerClient.new()


func _root() -> void:
	assets = PreviewAssets.new(h.catalog, client, "")
	root = WorldPreviewRoot.new()
	tree.root.add_child(root)
	root.setup(h.catalog, assets, true, null)
	root.bind_replica(h.replica)


func _frames(n: int = 3) -> void:
	for i in n:
		await tree.process_frame


func _display_hash() -> String:
	return CanonicalEncoder.authored_hash(root.display.doc)


func test_display_follows_snapshot_and_commits() -> void:
	_root()
	h.connect_and_sync()
	await _frames()
	assert_eq(_display_hash(), h.replica.authored_hash(), "snapshot")
	h.sculpt(LOC, 10, 2.0)
	h.place(LiveHarness.SPRUCE, 5.0, 5.0)
	h.link.settle()
	await _frames()
	assert_eq(_display_hash(), h.replica.authored_hash(), "after commits")
	assert_eq(root.presented_revision, h.doc.document_revision, "presented revision")
	assert_eq(root.stats.commits, 2, "two commits applied incrementally")
	assert_eq(root.presenter.authored_object_count(), 1, "object presented")
	assert_true(root.label_text().contains("rev %d" % h.doc.document_revision), "label shows the revision")


func test_overlay_is_drawn_without_touching_the_replica_and_reverts() -> void:
	_root()
	h.connect_and_sync()
	await _frames()
	var committed := h.replica.authored_hash()
	var tx := EditTransaction.new()
	tx.begin(h.doc, "sculpt", "Raise")
	h.tx_open = tx
	tx.capture_heights(LOC)
	h.doc.get_region(LOC).heights[12] = 4.5
	h.link.now_msec += 100
	h.sender.tick(h.link.now_msec)
	h.sender.flush_preview()
	h.link.settle()
	await _frames()
	assert_false(h.replica.overlay.is_empty(), "overlay received")
	assert_eq(root.display.doc.get_height_at_sample(12, 0), 4.5, "overlay value is drawn")
	assert_eq(h.replica.document.get_height_at_sample(12, 0), 0.0, "committed replica untouched")
	assert_eq(h.replica.authored_hash(), committed, "replica hash unchanged")
	tx.rollback()
	h.tx_open = null
	h.link.now_msec += 100
	h.sender.tick(h.link.now_msec)
	h.link.settle()
	await _frames()
	assert_true(h.replica.overlay.is_empty(), "cancelled")
	assert_eq(_display_hash(), committed, "display reverted to the committed state")
	assert_true(root.label_text().find("provisional") < 0, "no provisional note")


func test_missing_asset_is_labelled_incomplete_and_still_presented() -> void:
	var item := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.glb(AssetTestKit.GLB_V1))
	var binding: AssetBinding = item.binding
	binding.dependencies[binding.asset_key] = {"asset_ref": binding.asset_ref, "descriptor_sha256": binding.descriptor_sha256,
		"deliveries": {"portable_glb_v1": (binding.deliveries.portable_glb_v1 as Dictionary).duplicate()}, "requires": []}
	h.doc.assets.add(binding)
	var record := ObjectRecord.new()
	record.object_id = ObjectRecord.new_uuid_v4()
	record.binding_id = (item.binding as AssetBinding).binding_id
	record.set_position(3.0, 0.25, 3.0)
	record.uniform_scale = 1.0
	h.doc.put_object(record)
	_root()
	h.connect_and_sync()
	await _frames(5)
	assert_eq(root.presenter.authored_object_count(), 1, "the object is shown as a placeholder")
	assert_false(root.is_complete(), "not complete without the bytes")
	assert_true(root.label_text().contains("INCOMPLETE"), root.label_text())
	var missing := assets.missing(root.display.doc)
	assert_true(missing.has(record.binding_id), "reported as missing")
	var status := PreviewStatus.build(LiveListener.new(), h.replica, {"missing": missing, "visual_ready": false})
	assert_eq(status.visual_ready, false, "status says incomplete")
	assert_eq((status.missing as Array).size(), 1, "one missing row")


func test_waiting_label_before_any_world() -> void:
	_root()
	assert_true(root.label_text().contains("Waiting"), root.label_text())
