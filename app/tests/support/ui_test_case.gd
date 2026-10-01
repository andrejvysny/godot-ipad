class_name UiTestCase
extends TestCase
## Shared fixture of the Editor v2 interface tests: a session with the real iOS Pencil path (FakeProvider
## samples -> router -> synthetic mouse events -> Controls) and helpers to drive it.

const TerrainTests := preload("res://tests/integration/test_terrain_adapter.gd")
const InputTests := preload("res://tests/integration/test_input_system.gd")
const BOULDER := "nature.rock.boulder_a"
const SIZES: Array[Vector2] = [Vector2(1180, 820), Vector2(1024, 768)]

var sessions: Array = []
var fake: InputTests.FakeProvider
var log_filter: TerrainTests.KnownWarningFilter


func before_each() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ScatterSetStore.DEFAULT_PATH))  # sets saved by a test
	allow_logged_errors()  # the pinned Terrain3D binary logs one known deprecation warning
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


func _start(fixture: String = "flat") -> EditorSession:
	fake = InputTests.FakeProvider.new()
	var s := EditorSession.new()
	s.storage_root = scratch_dir() + "/worlds"
	s.start_fixture = fixture
	s.provider_override = fake
	s.platform_override = "iOS"
	s.build_ui = true
	sessions.append(s)
	tree.root.add_child(s)
	await _frames(3)
	for i in 300:
		if not s.storage.is_busy():
			break
		await tree.process_frame
	return s


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func _center(c: Control) -> Vector2:
	return UiHitTester.screen_rect(c).get_center()


func _rect(c: Control) -> Rect2:
	return UiHitTester.screen_rect(c)


func _feed(s: EditorSession, source: int, phase: int, pos: Vector2, reason: String = "") -> void:
	fake.push(source, 1, phase, pos, reason)
	s.input.run_frame()
	await _frames(3)


func _pencil_click(s: EditorSession, control: Control) -> void:
	var p := _center(control)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, p)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, p)


func _world_tap(s: EditorSession, pos: Vector2) -> void:
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, pos)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.END, pos)


func _ui(s: EditorSession) -> EditorUI:
	return s.ui as EditorUI


func _tool(s: EditorSession, tool_id: String, open := true) -> void:
	s.tools.set_tool(tool_id)
	_ui(s).popover().set_open(open)
	await _frames(2)


func _centre_world(s: EditorSession) -> Vector2:
	return tree.root.get_visible_rect().get_center()


func _select_first(s: EditorSession) -> ObjectRecord:
	var id := s.document.sorted_object_ids()[0]
	s.tools.set_tool("select")
	s.tools.select(id)
	await _frames(3)
	return s.document.get_object(id)


func _object_rect(s: EditorSession, id: String) -> Rect2:
	var camera := s.rig.get_camera()
	var bounds := s.presenter.world_bounds(id)
	var rect := Rect2(camera.unproject_position(bounds.get_endpoint(0)), Vector2.ZERO)
	for i in range(1, 8):
		rect = rect.expand(camera.unproject_position(bounds.get_endpoint(i)))
	return rect


## Relative scrub drag from the middle toward the roomy side of its range; returns the field's rect.
func _scrub_drag(s: EditorSession, field: ScrubField, end_phase: int = PointerSample.Phase.END) -> void:
	var rect := _rect(field)
	var y := rect.get_center().y
	var toward := 0.9 if field.value < (field.min_value + field.max_value) * 0.5 else 0.1
	var from := Vector2(rect.position.x + rect.size.x * 0.5, y)
	var to := Vector2(rect.position.x + rect.size.x * toward, y)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, from)
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, from.lerp(to, 0.5))
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, to)
	if end_phase == PointerSample.Phase.CANCEL:
		await _feed(s, PointerSample.Source.PENCIL, end_phase, to, "native_cancel")
	else:
		await _feed(s, PointerSample.Source.PENCIL, end_phase, to)


func _drag(s: EditorSession, from: Vector2, to: Vector2, end_phase: int = PointerSample.Phase.END) -> void:
	await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.BEGIN, from)
	for i in range(1, 4):
		await _feed(s, PointerSample.Source.PENCIL, PointerSample.Phase.MOVE, from.lerp(to, float(i) / 3.0))
	if end_phase == PointerSample.Phase.CANCEL:
		await _feed(s, PointerSample.Source.PENCIL, end_phase, to, "native_cancel")
	else:
		await _feed(s, PointerSample.Source.PENCIL, end_phase, to)
