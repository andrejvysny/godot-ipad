extends ApplyProjectCase
## "Apply world snapshot" from the dock down to the broker (ADR 0017 A1, E2E-12/13): the button's readiness gate,
## the freeze round trip with a real child client and a real replica, refusal of snapshots outside the session
## directory, and proof that later live edits and the provisional overlay never reach the accepted generation.

var launcher: PreviewLauncher
var dock: PreviewDock
var client: PreviewBrokerClient
var harness: LiveHarness
var reviews: Array[ApplyReview] = []
var failures_seen: Array[String] = []
var results: Array[Dictionary] = []
var session_id := ""


func before_each() -> void:
	super()
	launcher = PreviewLauncher.new()
	tree.root.add_child(launcher)
	assert_empty_string(launcher.broker.start(), "broker")
	session_id = LiveIds.new_id()
	launcher.session_id = session_id
	launcher.state = "running"
	dock = PreviewDock.new()
	dock.setup(launcher)
	tree.root.add_child(dock)
	dock.controller.context_factory = func() -> ApplyContext: return ctx
	dock.controller.review_ready.connect(func(r: ApplyReview) -> void: reviews.append(r))
	dock.controller.failed.connect(func(m: String) -> void: failures_seen.append(m))
	dock.controller.finished.connect(func(r: Dictionary) -> void: results.append(r))
	client = PreviewBrokerClient.new()
	tree.root.add_child(client)
	assert_empty_string(client.connect_to(launcher.broker.port(), launcher.broker.credential()), "client connect")
	harness = LiveHarness.new()
	harness.setup(scratch_dir())


func after_each() -> void:
	for n: Node in [dock, client, launcher]:
		tree.root.remove_child(n)
		n.free()
	PreviewSession.remove_session(session_id)
	super()


func _until(cond: Callable, timeout_ms: int = 5000) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		if cond.call():
			return true
		await tree.process_frame
	return false


## The preview child's side: freeze the replica's committed document when the editor asks.
func _serve_freeze() -> void:
	client.freeze_requested.connect(func(id: int) -> void:
		client.send_message(FrozenSnapshot.write(harness.replica, PreviewSession.session_dir(launcher.session_id), id)))


func _status(writer: bool, revision: int, visual_ready: bool) -> Dictionary:
	return PreviewStatus.sanitize({"type": "status", "listener": {"port": 8666, "bind": "127.0.0.1", "allow_insecure_lan": false},
		"pairing": {"state": "valid", "token": "", "expires_in_ms": 0},
		"session": {"writer": writer, "paired": true, "overlay": false, "error": ""}, "revision": revision,
		"authored_hash": "ab".repeat(32), "durable_revision": -1, "visual_ready": visual_ready, "missing": []})


func test_apply_is_enabled_only_when_the_replica_is_live_and_visually_ready() -> void:
	dock.set("_status", _status(true, 12, true))
	dock.refresh()
	assert_true(await _until(client.is_ready), "client authenticated")
	dock.refresh()
	var apply := dock.get("_apply") as Button
	assert_false(apply.disabled, "live writer, committed revision, visually ready: " + dock.apply_blocker())
	for case: Array in [[false, 12, true, "iPad"], [true, -1, true, "committed"], [true, 12, false, "visual readiness"]]:
		dock.set("_status", _status(case[0], case[1], case[2]))
		dock.refresh()
		assert_true(apply.disabled, "disabled for %s" % str(case))
		assert_true(apply.tooltip_text.contains(str(case[3])), "the tooltip says why: " + apply.tooltip_text)
	dock.set("_status", _status(true, 12, true))
	launcher.state = "stopped"
	dock.refresh()
	assert_true(apply.disabled, "disabled while the preview is stopped")


func test_freeze_review_and_apply_ignore_later_edits_and_the_overlay() -> void:
	var first := harness.place(ApplyTestKit.SPRUCE, 10.0, 10.0)
	var second := harness.place(ApplyTestKit.BOULDER, -20.0, 5.0)
	harness.connect_and_sync()
	assert_true(await _until(client.is_ready), "client authenticated")
	_serve_freeze()
	# A sculpt operation is open and its provisional preview has reached the overlay.
	var tx := EditTransaction.new()
	tx.begin(harness.doc, "sculpt", "Raise")
	harness.tx_open = tx
	tx.capture_heights(Vector2i(0, 0))
	harness.doc.get_region(Vector2i(0, 0)).heights[300] = 9.0
	harness.link.now_msec += 100
	harness.sender.tick(harness.link.now_msec)
	harness.sender.flush_preview()
	harness.link.settle()
	assert_false(harness.replica.overlay.is_empty(), "the overlay holds provisional state")
	var frozen_revision := harness.replica.revision()
	var frozen_hash := harness.replica.authored_hash()
	dock.set("_status", _status(true, frozen_revision, true))
	dock.refresh()
	assert_eq(dock.controller.request_freeze(), "", "freeze request sent")
	assert_true(await _until(func() -> bool: return not reviews.is_empty() or not failures_seen.is_empty(), 8000), "review arrives")
	assert_eq(failures_seen, [] as Array[String], "no failure")
	var review: ApplyReview = reviews[0]
	assert_eq(review.blockers, PackedStringArray(), "reviewable")
	assert_eq(review.revision, frozen_revision)
	assert_eq(review.authored_hash, frozen_hash, "the committed hash, not the overlay's")
	assert_eq(review.doc.get_region(Vector2i(0, 0)).heights[300], 0.0, "the provisional sculpt is not in the snapshot")
	assert_eq(review.doc.objects.size(), 2)
	# Later live activity: the sculpt commits and another object is placed.
	harness.tx_open = null
	harness.commit(tx.finish())
	var late := harness.place(ApplyTestKit.SPRUCE, 30.0, 30.0)
	harness.link.settle()
	assert_ne(harness.replica.authored_hash(), frozen_hash, "the live replica moved on")
	await dock.controller.confirm(false)
	assert_eq(results.size(), 1)
	assert_true(results[0].ok, str(results[0].get("error")))
	var binding := binding_of(review.world_id)
	assert_eq(binding.authored_hash, frozen_hash, "the accepted snapshot is the reviewed revision")
	var summary := WorldSceneCheck.summarize(review.destination.path_join("generated/world.tscn"), tree)
	assert_true(summary.objects.has(first) and summary.objects.has(second), "frozen objects are in the world")
	assert_false(summary.objects.has(late), "the later object did not leak")
	assert_eq(WorldSceneCheck.compare(summary, review.doc), PackedStringArray())
	assert_eq((summary.regions[Vector2i(0, 0)] as Dictionary).height, CanonicalEncoder.sha256_hex(review.doc.get_region(Vector2i(0, 0)).height_bytes()))


func test_a_snapshot_outside_the_session_directory_is_refused() -> void:
	assert_true(await _until(client.is_ready), "client authenticated")
	var spoof := {"type": "snapshot_frozen", "id": 0, "path": "/tmp", "revision": 1, "authored_hash": "ab".repeat(32),
		"source_snapshot_hash": "cd".repeat(32)}
	client.freeze_requested.connect(func(id: int) -> void:
		spoof["id"] = id
		client.send_message(spoof))
	assert_eq(dock.controller.request_freeze(), "")
	assert_true(await _until(func() -> bool: return not failures_seen.is_empty()), "refused")
	assert_true(failures_seen[0].contains("outside"), failures_seen[0])
	assert_true(reviews.is_empty(), "no review of a foreign path")
	assert_false(dock.controller.busy, "ready for the next request")


func test_a_preview_without_a_world_reports_an_error_instead_of_a_snapshot() -> void:
	assert_true(await _until(client.is_ready), "client authenticated")
	_serve_freeze()
	assert_eq(dock.controller.request_freeze(), "")
	assert_true(await _until(func() -> bool: return not failures_seen.is_empty()), "error reported")
	assert_true(failures_seen[0].contains("no committed world"), failures_seen[0])


func test_frozen_snapshot_keeps_only_the_newest_directories() -> void:
	harness.connect_and_sync()
	var session := scratch_dir() + "/session"
	for i in 4:
		var reply := FrozenSnapshot.write(harness.replica, session, i)
		assert_false(reply.has("error"), str(reply.get("error")))
		assert_true(DirAccess.dir_exists_absolute(reply.path))
	assert_eq(StorageFs.list_dirs(session + "/frozen").size(), FrozenSnapshot.KEEP, "old snapshots are pruned")
