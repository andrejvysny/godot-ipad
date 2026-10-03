extends TestCase
## EditorSession -> LiveSender -> fake link -> LiveReplica: the world_committed signal, the open transaction accessor
## and the scatter hint, with real tools and real undo/redo.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")
const SESSION_ID := "0123456789abcdef0123456789abcdef"

var sessions: Array = []
var log_filter: TerrainTests.KnownWarningFilter


func before_each() -> void:
	allow_logged_errors()
	log_filter = TerrainTests.KnownWarningFilter.new()
	OS.add_logger(log_filter)


func after_each() -> void:
	for s: Variant in sessions:
		if is_instance_valid(s):
			if s.get_parent() != null:
				tree.root.remove_child(s)
			s.free()
	sessions.clear()
	assert_true(log_filter.unexpected.is_empty(), str(log_filter.unexpected))
	OS.remove_logger(log_filter)


func _start() -> EditorSession:
	var s := EditorSession.new()
	s.storage_root = scratch_dir() + "/worlds"
	s.start_fixture = "flat"
	s.provider_override = InputTests.FakeProvider.new()
	s.build_ui = false
	sessions.append(s)
	tree.root.add_child(s)
	await tree.process_frame
	return s


func _live(s: EditorSession) -> FakeLiveLink:
	var sender := LiveSender.new()
	sender.spool = LiveSpool.new(scratch_dir() + "/spool")
	sender.scratch_root = scratch_dir() + "/tmp"
	sender.created_with = WorldCodec.default_created_with()
	var replica := LiveReplica.new(SESSION_ID, s.catalog, scratch_dir() + "/replica")
	var link := FakeLiveLink.new(sender, replica)
	LiveSessionBinding.bind(s, sender)
	sender.start_session(SESSION_ID)
	link.settle()
	return link


func _sample(s: EditorSession, x: float, z: float, t: float) -> PointerSample:
	var sample := PointerSample.new()
	sample.source = PointerSample.Source.PENCIL
	sample.timestamp_s = t
	sample.position_viewport = s.rig.get_camera().unproject_position(Vector3(x, s.document.sample_height(x, z), z))
	return sample


func _act(s: EditorSession, type: String, x: float, z: float, t: float) -> void:
	s._on_tool_action({"type": type, "sample": _sample(s, x, z, t), "over_ui": false})


func _check(s: EditorSession, link: FakeLiveLink, label: String) -> void:
	link.settle()
	assert_eq(link.replica.revision(), s.document.document_revision, label + ": revision")
	assert_eq(link.replica.authored_hash(), s.authored_hash(), label + ": hash")
	assert_eq(CanonicalEncoder.authored_hash(link.replica.document), s.authored_hash(), label + ": recomputed hash")


func test_stroke_preview_commit_undo_redo_and_world_replacement() -> void:
	var s: EditorSession = await _start()
	var link := _live(s)
	_check(s, link, "initial snapshot")
	s.tools.set_tool(ToolController.TOOL_PAINT)
	_act(s, "tool_begin", -6.0, 0.0, 1.0)
	assert_true(s.open_transaction() != null and s.open_transaction().is_open(), "the open operation's transaction is exposed")
	var t := 1.0
	for x in [-4.0, -2.0, 0.0, 2.0, 4.0]:
		t += 0.02
		_act(s, "tool_move", x, 0.0, t)
		link.now_msec += 100
		link.sender.tick(link.now_msec)
		link.settle(4)
	assert_false(link.replica.overlay.is_empty(), "the stroke is previewed while it is in progress")
	assert_eq(link.replica.revision(), 0, "no revision before the commit")
	_act(s, "tool_end", 6.0, 0.0, t + 0.02)
	assert_eq(s.document.document_revision, 1)
	_check(s, link, "stroke commit")
	assert_true(link.replica.overlay.is_empty(), "overlay cleared by the commit")
	assert_eq(s.undo(), "")
	_check(s, link, "undo")
	assert_eq(link.replica.revision(), 2, "undo is a new revision")
	assert_eq(s.redo(), "")
	_check(s, link, "redo")
	var stream := link.sender.stream_id()
	assert_empty_string(s.open_fixture("gentle_hills"))
	assert_ne(link.sender.stream_id(), stream, "world_replaced starts a new stream")
	_check(s, link, "replaced world")


func test_cancelled_stroke_sends_cancel_and_creates_no_revision() -> void:
	var s: EditorSession = await _start()
	var link := _live(s)
	s.tools.set_tool("raise")
	_act(s, "tool_begin", 0.0, 0.0, 1.0)
	_act(s, "tool_move", 3.0, 0.0, 1.1)
	s.tools.advance(1.2)
	link.now_msec += 100
	link.sender.tick(link.now_msec)
	link.settle(4)
	assert_false(link.replica.overlay.is_empty())
	s.cancel_active()
	link.now_msec += 100
	link.sender.tick(link.now_msec)
	link.settle(4)
	assert_true(link.replica.overlay.is_empty(), "preview_cancel cleared the overlay")
	assert_eq(link.sender.stats.preview_cancels, 1)
	_check(s, link, "after cancel")
	assert_eq(s.document.document_revision, 0)


func test_scatter_stroke_previews_wpst_tiles_and_commits_the_whole_file() -> void:
	var s: EditorSession = await _start()
	var link := _live(s)
	s.tools.set_tool("scatter")
	assert_empty_string(s.tools.set_setting("place", "radius", 20.0))
	_act(s, "tool_begin", -10.0, 0.0, 1.0)
	var t := 1.0
	for x in [-6.0, -2.0, 2.0, 6.0, 10.0]:
		t += 0.02
		_act(s, "tool_move", x, 0.0, t)
	s.tools.advance(t + 0.01)
	link.now_msec += 400
	link.sender.tick(link.now_msec)
	link.sender.flush_preview()
	link.now_msec += 400
	link.sender.tick(link.now_msec)
	link.settle(4)
	assert_false(link.replica.overlay.scatter_tiles.is_empty(), "scatter previewed as WPST tiles")
	_act(s, "tool_end", 10.0, 0.0, t + 0.02)
	assert_true(s.document.scatter.count() > 0)
	_check(s, link, "scatter commit")
