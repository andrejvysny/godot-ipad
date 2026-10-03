extends TestCase
## Editor broker (ADR 0016 P3) over real loopback sockets: authentication deadline, wrong and one-time credentials,
## the request allowlist, and the asset round trip (editor resolver -> broker -> child resolver -> AssetStudioProvider)
## including every refusal the child must make on its own (path outside the cache root, hash, size, manifest).

const BlobCache := preload("res://addons/assetstudio/core/as_blob_cache.gd")
const Registry := preload("res://addons/assetstudio/core/as_connection_registry.gd")
const AssetRef := preload("res://addons/assetstudio/core/as_asset_ref.gd")

var broker: PreviewBroker
var nodes: Array[Node] = []


func before_each() -> void:
	broker = PreviewBroker.new()
	tree.root.add_child(broker)
	assert_empty_string(broker.start(), "broker start")


func after_each() -> void:
	broker.stop()
	tree.root.remove_child(broker)
	broker.free()
	for n in nodes:
		if is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.free()
	nodes.clear()


func _until(cond: Callable, timeout_ms: int = 4000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		if cond.call():
			return true
		await tree.process_frame
	return false


func _raw() -> BrokerChannel:
	var s := StreamPeerTCP.new()
	assert_eq(s.connect_to_host("127.0.0.1", broker.port()), OK, "connect")
	return BrokerChannel.new(s)


## Polls `c` until it produced a message or died; returns the messages.
func _recv(c: BrokerChannel, ms: int = 3000) -> Array[Dictionary]:
	var got: Array[Dictionary] = []
	await _until(func() -> bool:
		got.append_array(c.poll())
		return not got.is_empty() or not c.is_alive())
	return got


func _hello(c: BrokerChannel, credential: String) -> Array[Dictionary]:
	await _until(func() -> bool: return c.is_connected_now())
	c.send({"type": "hello", "credential": credential})
	return await _recv(c)


func test_wrong_credential_is_refused_and_the_real_one_still_works() -> void:
	var bad := _raw()
	var reply := await _hello(bad, LiveIds.new_secret())
	assert_false(reply.is_empty() or reply[0].get("accepted", false), "refused")
	assert_false(broker.child_connected(), "no child")
	var good := _raw()
	reply = await _hello(good, broker.credential())
	assert_true(not reply.is_empty() and reply[0].get("accepted", false) == true, "accepted")
	assert_true(broker.child_connected(), "child connected")


func test_credential_is_one_time() -> void:
	var credential := broker.credential()
	var first := _raw()
	await _hello(first, credential)
	assert_true(broker.child_connected(), "first child")
	var second := _raw()
	var reply := await _hello(second, credential)
	assert_false(not reply.is_empty() and reply[0].get("accepted", false) == true, "replay refused")


func test_silent_client_is_closed_at_the_auth_deadline() -> void:
	broker.auth_deadline_msec = 300
	var c := _raw()
	assert_true(await _until(func() -> bool:
		c.poll()
		return not c.is_alive(), 3000), "closed")
	assert_false(broker.child_connected(), "no child")


func test_first_frame_must_be_hello() -> void:
	var c := _raw()
	await _until(func() -> bool: return c.is_connected_now())
	c.send({"type": "status"})
	assert_true(await _until(func() -> bool:
		c.poll()
		return not c.is_alive(), 3000), "closed")
	assert_eq(broker.rejected, 1, "counted")


func test_oversized_pre_auth_frame_is_closed() -> void:
	var c := _raw()
	await _until(func() -> bool: return c.is_connected_now())
	var frame := PackedByteArray()
	frame.resize(4)
	frame.encode_u32(0, BrokerChannel.MAX_PRE_AUTH_FRAME + 1)
	frame.append_array(PackedByteArray([0x7B]))
	c.stream.put_data(frame)
	assert_true(await _until(func() -> bool:
		broker.get_tree()  # keep frames running
		c.poll()
		return not c.is_alive(), 3000), "closed")


func test_non_allowlisted_request_is_rejected_and_ends_the_connection() -> void:
	var c := _raw()
	await _hello(c, broker.credential())
	c.authenticated = true
	c.send({"type": "run_command", "cmd": "OS.execute"})
	var reply := await _recv(c)
	assert_true(not reply.is_empty() and reply[0].type == "error" and reply[0].code == "not_allowed", "error reply")
	assert_true(await _until(func() -> bool:
		c.poll()
		return not broker.child_connected(), 3000), "connection dropped")


func test_status_is_sanitized_before_it_reaches_the_dock() -> void:
	var c := _raw()
	await _hello(c, broker.credential())
	c.authenticated = true
	var seen: Array[Dictionary] = []
	broker.status_received.connect(func(s: Dictionary) -> void: seen.append(s))
	c.send({"type": "status", "revision": 7, "authored_hash": "zz", "visual_ready": "yes", "extra": "x".repeat(100),
		"listener": {"port": 8666, "bind": "127.0.0.1", "allow_insecure_lan": true}, "missing": [5, {"binding_id": "b", "reason": "r"}]})
	assert_true(await _until(func() -> bool: return not seen.is_empty()), "status received")
	var s: Dictionary = seen[0]
	assert_eq(s.revision, 7, "revision")
	assert_eq(s.authored_hash, "", "a malformed hash is dropped")
	assert_eq(s.visual_ready, false, "non-bool is false")
	assert_false(s.has("extra"), "unknown keys are dropped")
	assert_eq((s.missing as Array).size(), 1, "only well-formed rows")


# --- Assets ---------------------------------------------------------------------------------------

## A seeded exact cache, an editor resolver on it and a connected child client.
func _asset_rig() -> Dictionary:
	var dir := scratch_dir() + "/as"
	var cache: RefCounted = BlobCache.new(dir + "/cache")
	var item := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.glb(AssetTestKit.GLB_V1))
	AssetTestKit.seed(cache, item)
	var resolver := PreviewAssetResolver.new(Registry.new(dir), cache, scratch_dir() + "/no_project")
	tree.root.add_child(resolver)
	nodes.append(resolver)
	broker.asset_resolver = resolver
	var client := PreviewBrokerClient.new()
	tree.root.add_child(client)
	nodes.append(client)
	assert_empty_string(client.connect_to(broker.port(), broker.credential()), "client connect")
	assert_true(await _until(client.is_ready), "client authenticated")
	return {"item": item, "resolver": resolver, "client": client, "cache": cache}


func test_asset_round_trip_serves_only_blob_cache_paths() -> void:
	var rig := await _asset_rig()
	var item: Dictionary = rig.item
	var reply: Dictionary = await (rig.client as PreviewBrokerClient).request_assets(item.binding.to_dict(true))
	assert_eq(reply.state, "ready", str(reply.get("error", "")))
	var root: String = (rig.resolver as PreviewAssetResolver).blob_root()
	for path: String in reply.files.values():
		assert_true(path.begins_with(root + "/"), "inside the blob root: " + path)
	var verified: RefCounted = BrokerAssetResolver.verify(item.binding, reply, root)
	assert_true(verified.get("ok"), "verified: " + str(verified.get("message")))


func test_unknown_row_and_unpinned_delivery_are_refused_by_the_editor() -> void:
	var rig := await _asset_rig()
	var row: Dictionary = (rig.item.binding as AssetBinding).to_dict(true)
	row["asset_key"] = "tampered"
	var reply: Dictionary = await (rig.client as PreviewBrokerClient).request_assets(row)
	assert_eq(reply.state, "error", "tampered row refused")
	var other := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V2_ID, AssetTestKit.glb(AssetTestKit.GLB_V2))
	reply = await (rig.client as PreviewBrokerClient).request_assets((other.binding as AssetBinding).to_dict(true))
	assert_eq(reply.state, "error", "an asset that is not in the exact cache is not fetched elsewhere")


func test_child_refuses_paths_outside_the_cache_root_and_modified_files() -> void:
	var rig := await _asset_rig()
	var item: Dictionary = rig.item
	var binding: AssetBinding = item.binding
	var reply: Dictionary = await (rig.client as PreviewBrokerClient).request_assets(binding.to_dict(true))
	var root: String = (rig.resolver as PreviewAssetResolver).blob_root()
	# Outside the root: a byte-identical copy elsewhere must still be refused.
	var elsewhere := ProjectSettings.globalize_path(scratch_dir()) + "/copy.glb"
	var f := FileAccess.open(elsewhere, FileAccess.WRITE)
	f.store_buffer(item.glb)
	f.close()
	var moved := reply.duplicate(true)
	moved.files = {"portable.glb": elsewhere}
	assert_error_contains(str(BrokerAssetResolver.verify(binding, moved, root).get("message")), "outside", "outside the root")
	var traversal := reply.duplicate(true)
	traversal.files = {"portable.glb": root + "/../copy.glb"}
	assert_false(BrokerAssetResolver.verify(binding, traversal, root).get("ok"), "traversal refused")
	# Manifest text that does not hash to the locked sha.
	var forged := reply.duplicate(true)
	forged.manifest = str(reply.manifest).replace("portable.glb", "evil.glb")
	assert_error_contains(str(BrokerAssetResolver.verify(binding, forged, root).get("message")), "manifest", "manifest")
	# A cached file with other content: hash mismatch (same size).
	var blob: String = reply.files["portable.glb"]
	var tampered: PackedByteArray = (item.glb as PackedByteArray).duplicate()
	tampered[tampered.size() - 1] = (tampered[tampered.size() - 1] + 1) % 256
	var w := FileAccess.open(blob, FileAccess.WRITE)
	w.store_buffer(tampered)
	w.close()
	assert_error_contains(str(BrokerAssetResolver.verify(binding, reply, root).get("message")), "hash", "hash mismatch")
	# A truncated file: size mismatch.
	w = FileAccess.open(blob, FileAccess.WRITE)
	w.store_buffer(item.glb.slice(0, 10))
	w.close()
	assert_error_contains(str(BrokerAssetResolver.verify(binding, reply, root).get("message")), "size", "size mismatch")


func test_asset_provider_prepares_a_binding_through_the_broker() -> void:
	var rig := await _asset_rig()
	var item: Dictionary = rig.item
	var catalog: AssetCatalog = AssetCatalog.load_from()[0]
	var doc := WorldDocument.new()
	doc.assets.catalog = catalog
	doc.assets.add(item.binding)
	var record := ObjectRecord.new()
	record.object_id = ObjectRecord.new_uuid_v4()
	record.binding_id = (item.binding as AssetBinding).binding_id
	record.set_position(0.0, 0.25, 0.0)
	record.uniform_scale = 1.0
	doc.put_object(record)
	var assets := PreviewAssets.new(catalog, rig.client, (rig.resolver as PreviewAssetResolver).blob_root())
	assets.attach(doc)
	var id: String = (item.binding as AssetBinding).binding_id
	assert_true(await _until(func() -> bool: return doc.assets.is_prepared(id), 6000), "prepared through the broker: " + doc.assets.unavailable_reason(id))
	assert_eq(assets.assetstudio.prepared_ids(), PackedStringArray([id]), "tiers registered")
	assets.shutdown()
