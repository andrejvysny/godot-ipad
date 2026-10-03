extends TestCase
## End to end over a real loopback WebSocket: PreviewLink (iPad side: LiveSender + LivePeerSocket) against
## LiveListener + LiveReceiverDriver + LiveReplica (desktop side), all in this process. Covers pairing, snapshot and
## commit acks, provisional overlay and cancel, disconnect/resume and re-pair, hostile traffic, commit-ack latency
## and that nothing under res:// changes while a session runs.

const LOC := Vector2i(0, 0)

var catalog: AssetCatalog
var stub: SessionStub
var listener: LiveListener
var driver: LiveReceiverDriver
var link: PreviewLink


func before_each() -> void:
	catalog = AssetCatalog.load_from()[0]
	stub = SessionStub.new()
	stub.document = WorldDocument.create_flat(0.0, ControlCodec.grass_value(), null, catalog)
	tree.root.add_child(stub)
	listener = LiveListener.new()
	tree.root.add_child(listener)
	assert_empty_string(listener.listen(0, "127.0.0.1"), "listen")
	driver = LiveReceiverDriver.new()
	tree.root.add_child(driver)
	driver.setup(listener, catalog, scratch_dir() + "/receiver")
	link = PreviewLink.new()
	tree.root.add_child(link)
	link.setup(stub)
	link.sender.spool = LiveSpool.new(scratch_dir() + "/spool")
	link.sender.scratch_root = scratch_dir() + "/tmp"


func after_each() -> void:
	link.disconnect_link(true)
	listener.stop()
	for n: Node in [link, driver, listener, stub]:
		tree.root.remove_child(n)
		n.free()


func _until(cond: Callable, timeout_ms: int = 8000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		if cond.call():
			return true
		await tree.process_frame
	return false


func _pair() -> void:
	var token := str(listener.pairing_info().token)
	assert_empty_string(link.connect_to("127.0.0.1", listener.port(), false, token), "connect")


func _synced() -> bool:
	return link.sender.baseline_acked() and driver.replica != null and driver.replica.document != null


func _caught_up() -> bool:
	return _synced() and int(link.sender.stats.acked_revision) == stub.document.document_revision \
			and driver.replica.revision() == stub.document.document_revision


func _sculpt(index: int, dh: float) -> void:
	var tx := EditTransaction.new()
	tx.begin(stub.document, "test", "Raise")
	tx.capture_heights(LOC)
	stub.document.get_region(LOC).heights[index] += dh
	stub.document.invalidate_height_range(LOC)
	stub.commit(tx.finish())


func _authored() -> String:
	return CanonicalEncoder.authored_hash(stub.document)


func test_pairing_snapshot_and_commit_ack_match_the_senders_hash() -> void:
	_pair()
	assert_true(await _until(_synced), "snapshot installed and acknowledged")
	assert_eq(driver.replica.authored_hash(), _authored(), "snapshot hash")
	_sculpt(40, 1.5)
	_sculpt(300, -0.5)
	assert_true(await _until(_caught_up), "commits acknowledged")
	assert_eq(driver.replica.authored_hash(), _authored(), "replica reproduces the authored hash")
	assert_eq(CanonicalEncoder.authored_hash(driver.replica.document), _authored(), "recomputed independently")
	assert_eq(driver.replica.stats.resyncs, 0, "no resync")
	assert_true(link.status().ready, "status ready")


func test_preview_overlay_then_commit_and_cancel() -> void:
	_pair()
	await _until(_synced)
	var tx := EditTransaction.new()
	tx.begin(stub.document, "test", "Raise")
	stub.tx_open = tx
	tx.capture_heights(LOC)
	stub.document.get_region(LOC).heights[10] = 3.0
	var base := driver.replica.authored_hash()
	assert_true(await _until(func() -> bool: return not driver.replica.overlay.is_empty()), "overlay arrives")
	assert_eq(driver.replica.authored_hash(), base, "committed replica untouched by the preview")
	stub.tx_open = null
	stub.document.invalidate_height_range(LOC)
	stub.commit(tx.finish())
	assert_true(await _until(_caught_up), "commit acknowledged")
	assert_true(driver.replica.overlay.is_empty(), "commit clears the overlay")
	assert_eq(driver.replica.document.get_height_at_sample(10, 0), 3.0, "final value installed")
	# A cancelled operation clears the overlay again.
	var tx2 := EditTransaction.new()
	tx2.begin(stub.document, "test", "Raise")
	stub.tx_open = tx2
	tx2.capture_heights(LOC)
	stub.document.get_region(LOC).heights[20] = 5.0
	assert_true(await _until(func() -> bool: return not driver.replica.overlay.is_empty()), "second overlay")
	tx2.rollback()
	stub.tx_open = null
	assert_true(await _until(func() -> bool: return driver.replica.overlay.is_empty()), "preview_cancel clears")
	assert_eq(driver.replica.authored_hash(), _authored(), "still the committed state")


func test_dropped_connection_resumes_without_a_new_snapshot() -> void:
	_pair()
	await _until(_synced)
	_sculpt(5, 1.0)
	await _until(_caught_up)
	listener.close_writer("test drop")
	_sculpt(6, 1.0)  # committed while the link is down
	assert_true(await _until(func() -> bool: return not link.is_ready(), 3000), "sender noticed the drop")
	assert_true(await _until(_caught_up, 12000), "resumed and caught up")
	assert_eq(driver.replica.stats.snapshots, 1, "resumed from the spool, no second snapshot")
	assert_eq(driver.replica.authored_hash(), _authored(), "hash")
	assert_true(link.socket.stats.reconnects >= 1, "reconnected with the credential")


func test_new_pairing_after_the_preview_restarts_resnapshots() -> void:
	_pair()
	await _until(_synced)
	_sculpt(7, 2.0)
	await _until(_caught_up)
	var port := listener.port()
	listener.stop()  # revokes the credential: the old sender can no longer resume
	assert_empty_string(listener.listen(port, "127.0.0.1"), "listen again")
	assert_true(await _until(func() -> bool: return link.socket.state == LivePeerSocket.State.REJECTED, 12000),
			"the credential is refused")
	_pair()
	assert_true(await _until(_synced, 12000), "a fresh snapshot is installed")
	assert_eq(driver.replica.authored_hash(), _authored(), "new replica matches")
	assert_eq(driver.replica.stats.snapshots, 1, "new replica got exactly one snapshot")


func test_malformed_traffic_from_the_writer_cannot_change_the_replica() -> void:
	_pair()
	await _until(_synced)
	var base := driver.replica.authored_hash()
	var revision := driver.replica.revision()
	var transport := link.socket.transport
	transport.send_text("not json")
	transport.send_text("{\"protocol\":\"world-painter-live\"}")
	transport.send_binary(PackedByteArray([0x57, 0x50, 0x42, 0x31, 1, 2, 3]))
	transport.send_binary(PackedByteArray())
	var forged := LiveEnvelope.build("commit_ack", driver.replica.session_id, LiveIds.new_id(), {"world_id": "x",
		"stream_id": LiveIds.new_id(), "revision": 99, "authored_hash": base, "visual_ready": true})
	transport.send_text(forged.text)
	assert_true(await _until(func() -> bool: return driver.replica.stats.rejected >= 2, 4000), "rejections counted")
	assert_eq(driver.replica.authored_hash(), base, "hash unchanged")
	assert_eq(driver.replica.revision(), revision, "revision unchanged")
	_sculpt(9, 1.0)
	assert_true(await _until(_caught_up), "the session still works after hostile input")


func test_loopback_commit_ack_latency_and_no_project_writes() -> void:
	var before := ProjectFingerprint.of("res://")
	_pair()
	await _until(_synced)
	var ms: Array[float] = []
	for i in 120:
		var t0 := Time.get_ticks_usec()
		_sculpt(100 + i * 7, 0.25)
		assert_true(await _until(_caught_up, 5000), "commit %d acknowledged" % i)
		ms.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	ms.sort()
	print("LOOPBACK_COMMIT_ACK_MS n=%d p50=%.1f p95=%.1f max=%.1f" % [ms.size(), ms[ms.size() / 2],
		ms[int(ms.size() * 0.95)], ms[ms.size() - 1]])
	assert_eq(driver.replica.authored_hash(), _authored(), "all commits applied")
	link.disconnect_link(true)
	listener.stop()
	assert_eq(ProjectFingerprint.of("res://"), before, "no file under res:// changed during the session")
