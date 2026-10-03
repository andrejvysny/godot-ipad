extends TestCase
## Main-thread cost of the live sender on a km1 (64 region) world. Numbers are printed (host Mac, not a device).


func _ms(t0: int) -> float:
	return float(Time.get_ticks_usec() - t0) / 1000.0


func test_main_thread_cost_of_a_one_region_sculpt_commit_on_km1() -> void:
	var h := LiveHarness.new()
	h.setup(scratch_dir(), WorldLayout.km1())
	h.sender.set_document(h.doc)
	h.sender.start_session(LiveHarness.SESSION)
	var t0 := Time.get_ticks_usec()
	h.sender.tick(1000)  # captures the snapshot: the one-off freeze on the main thread
	var capture_ms := _ms(t0)
	h.link.settle(2000)
	assert_true(h.replica.document != null, "km1 snapshot installed")
	assert_eq(h.replica.authored_hash(), CanonicalEncoder.authored_hash(h.doc))
	var loc := Vector2i(1, 1)
	var costs: Array[float] = []
	var tick_costs: Array[float] = []
	for i in 6:
		var tx := EditTransaction.new()
		tx.begin(h.doc, "sculpt", "Raise")
		tx.capture_heights(loc)
		var heights := h.doc.get_region(loc).heights
		for k in 400:  # a ~10 m brush footprint: a few hundred samples inside two tiles
			heights[(10 + (k % 20)) * 256 + 60 + (k / 20) * 2] += 0.1
		h.doc.get_region(loc).heights = heights
		var change := tx.finish()
		h.doc.bump_revision()
		h.history.push_already_applied(change)
		var t1 := Time.get_ticks_usec()
		h.sender.on_committed(change, h.doc.document_revision, true)
		costs.append(_ms(t1))
		var t2 := Time.get_ticks_usec()
		h.sender.tick(h.link.now_msec + 100 * (i + 1))
		h.sender.pump(h.link)
		tick_costs.append(_ms(t2))
		h.link.settle()
	costs.sort()
	tick_costs.sort()
	print("COST km1 snapshot capture (main thread freeze): %.1f ms" % capture_ms)
	print("COST km1 1-region sculpt on_committed (hash + delta + spool): median %.1f ms, max %.1f ms" % [costs[3], costs[5]])
	print("COST km1 tick+pump after a commit: median %.2f ms, max %.2f ms" % [tick_costs[3], tick_costs[5]])
	assert_eq(h.replica.authored_hash(), CanonicalEncoder.authored_hash(h.doc), "km1 replica converged")
	assert_true(costs[5] < 250.0, "commit cost regression: %.1f ms" % costs[5])


func test_preview_sample_cost_on_km1() -> void:
	var h := LiveHarness.new()
	h.setup(scratch_dir(), WorldLayout.km1())
	h.sender.set_document(h.doc)
	h.sender.start_session(LiveHarness.SESSION)
	h.sender.tick(1000)
	h.link.settle(2000)
	var tx := EditTransaction.new()
	tx.begin(h.doc, "sculpt", "Raise")
	h.tx_open = tx
	var loc := Vector2i(1, 1)
	tx.capture_heights(loc)
	var sampler := LivePreviewSampler.new()
	sampler.bind(h.doc, tx)
	var costs: Array[float] = []
	for i in 8:
		var heights := h.doc.get_region(loc).heights
		for k in 400:
			heights[(10 + (k % 20)) * 256 + 60 + (k / 20) * 2 + i] += 0.1
		h.doc.get_region(loc).heights = heights
		var t0 := Time.get_ticks_usec()
		sampler.sample(i * 100, true)
		costs.append(_ms(t0))
		sampler.take()
	costs.sort()
	print("COST km1 preview sample (one dirty region, 2 tiles): median %.2f ms, max %.2f ms" % [costs[4], costs[7]])
	assert_true(costs[7] < 50.0, "preview sample cost regression: %.2f ms" % costs[7])
	tx.rollback()
