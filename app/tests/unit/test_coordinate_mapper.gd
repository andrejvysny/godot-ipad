extends TestCase
## CoordinateMapper math with realistic iPad metrics (spec §6.3, IN-12 logic).
## Base viewport 1180x820, stretch canvas_items + expand: scale = min(win.x/1180, win.y/820),
## no offset, so root final transform = uniform scale s.

const BASE := Vector2(1180, 820)
const UIKIT := InputProvider.SPACE_UIKIT_POINTS


## Returns [final_transform, viewport_size] Godot computes for a window in pixels.
func _stretch(window_px: Vector2) -> Array:
	var s := minf(window_px.x / BASE.x, window_px.y / BASE.y)
	return [Transform2D(0.0, Vector2(s, s), 0.0, Vector2.ZERO), window_px / s]


func _ipad(points: Vector2, scale: float) -> CoordinateMapper:
	var st := _stretch(points * scale)
	var m := CoordinateMapper.new()
	m.configure(UIKIT, {"view_size_points": points, "content_scale": scale}, st[0], st[1])
	return m


func test_viewport_space_is_identity() -> void:
	var m := CoordinateMapper.new()
	m.configure(InputProvider.SPACE_VIEWPORT, {}, Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO), BASE)
	assert_eq(m.map(Vector2(123.5, 456.25)), Vector2(123.5, 456.25))
	assert_eq(m.unmap(Vector2(10, 20)), Vector2(10, 20))


func test_ipad_air_11_points_map_one_to_one() -> void:
	var m := _ipad(Vector2(1180, 820), 2.0)
	assert_eq(m.viewport_size(), BASE)
	assert_near(m.viewport_units_per_point(), 1.0, 1e-6)
	assert_eq(m.map(Vector2(590, 410)), Vector2(590, 410))
	assert_eq(m.map(Vector2(1180, 820)), Vector2(1180, 820))
	assert_near(m.points_to_viewport(5.0), 5.0, 1e-6, "orbit threshold")


func test_ipad_pro_13_points_scale_into_base_viewport() -> void:
	var m := _ipad(Vector2(1366, 1024), 2.0)
	var s := minf(2732.0 / 1180.0, 2048.0 / 820.0)
	assert_near(m.viewport_size().x, 1180.0, 1e-3, "width fits base")
	assert_near(m.viewport_size().y, 2048.0 / s, 1e-3, "height expands")
	var mapped := m.map(Vector2(683, 512))
	assert_near(mapped.x, 683.0 * 2.0 / s, 1e-3)
	assert_near(mapped.y, 512.0 * 2.0 / s, 1e-3)
	var corner := m.map(Vector2(1366, 1024))
	assert_near(corner.x, m.viewport_size().x, 1e-3, "far corner")
	assert_near(corner.y, m.viewport_size().y, 1e-3)
	assert_near(m.viewport_units_per_point(), 2.0 / s, 1e-6)
	assert_near(m.points_to_viewport(5.0), 10.0 / s, 1e-6)
	assert_near(m.viewport_to_points(m.points_to_viewport(2.0)), 2.0, 1e-6)


func test_generation_bumps_only_on_change() -> void:
	var m := CoordinateMapper.new()
	var st := _stretch(Vector2(2360, 1640))
	assert_true(m.configure(UIKIT, {"content_scale": 2.0}, st[0], st[1]))
	var g := m.generation
	assert_false(m.configure(UIKIT, {"content_scale": 2.0}, st[0], st[1]), "same inputs")
	assert_eq(m.generation, g)
	var rotated := _stretch(Vector2(1640, 2360))
	assert_true(m.configure(UIKIT, {"content_scale": 2.0}, rotated[0], rotated[1]), "orientation")
	assert_eq(m.generation, g + 1)
	assert_true(m.configure(UIKIT, {"content_scale": 3.0}, rotated[0], rotated[1]), "scale")
	assert_true(m.configure(InputProvider.SPACE_VIEWPORT, {"content_scale": 3.0}, rotated[0], rotated[1]))
	assert_eq(m.generation, g + 3)


func test_invalid_content_scale_falls_back_to_one() -> void:
	var m := CoordinateMapper.new()
	m.configure(UIKIT, {"content_scale": 0.0}, Transform2D.IDENTITY, BASE)
	assert_eq(m.content_scale(), 1.0)
	m.configure(UIKIT, {"content_scale": NAN}, Transform2D.IDENTITY, BASE)
	assert_eq(m.content_scale(), 1.0)


## Records the viewport-local position Godot itself computes for OS-space events.
class EventSpy:
	extends Node
	var positions: Array[Vector2] = []

	func _input(e: InputEvent) -> void:
		if e is InputEventScreenTouch:
			positions.append((e as InputEventScreenTouch).position)


func test_map_matches_godot_event_transform_on_real_root_at_any_3d_scale() -> void:
	# Ground truth is Godot's own Viewport._make_input_local on the real root window: push
	# window-pixel events with push_input(ev, false) and compare with mapper.map(pixels / scale).
	var root := tree.root
	var spy := EventSpy.new()
	root.add_child(spy)
	var old_scale := root.scaling_3d_scale
	var window_px := Vector2(root.size)
	var worst := 0.0
	for render_scale: float in [1.0, 0.5]:
		root.scaling_3d_scale = render_scale
		var m := CoordinateMapper.new()
		m.configure(UIKIT, {"content_scale": 2.0}, root.get_final_transform(), root.get_visible_rect().size)
		for fx: float in [0.0, 0.37, 1.0]:
			for fy: float in [0.0, 0.5, 0.91]:
				var px := window_px * Vector2(fx, fy)
				var ev := InputEventScreenTouch.new()
				ev.pressed = true
				ev.position = px
				var before := spy.positions.size()
				root.push_input(ev, false)
				if spy.positions.size() > before:
					worst = maxf(worst, m.map(px / 2.0).distance_to(spy.positions.back()))
	root.scaling_3d_scale = old_scale
	var observed := spy.positions.size()
	root.remove_child(spy)
	spy.free()
	assert_eq(observed, 18, "every event observed")
	assert_near(worst, 0.0, 1e-3, "mapper == Godot's own event transform (3D scale 1.0 and 0.5)")


func test_singular_root_transform_invalidates_mapping_without_engine_error() -> void:
	var m := _ipad(Vector2(1180, 820), 2.0)
	assert_true(m.is_valid())
	var g := m.generation
	assert_true(m.configure(UIKIT, {"content_scale": 2.0}, Transform2D(0.0, Vector2.ZERO, 0.0, Vector2.ZERO),
			Vector2.ZERO), "degenerate window is a mapping change")
	assert_eq(m.generation, g + 1)
	assert_false(m.is_valid())
	assert_false(m.map(Vector2(10, 10)).is_finite(), "no position rather than (0, 0) over the rail")
	assert_false(is_finite(m.viewport_units_per_point()), "no zero orbit threshold")
	assert_false(is_finite(m.viewport_to_points(3.0)))
	var st := _stretch(Vector2(2360, 1640))
	assert_true(m.configure(UIKIT, {"content_scale": 2.0}, st[0], st[1]))
	assert_true(m.is_valid(), "recovers when the window is usable again")
	assert_eq(m.map(Vector2(590, 410)), Vector2(590, 410))


func test_nine_point_round_trip_within_two_points() -> void:
	for cfg: Array in [[Vector2(1180, 820), 2.0], [Vector2(1366, 1024), 2.0], [Vector2(1133, 744), 2.0]]:
		var points: Vector2 = cfg[0]
		var scale: float = cfg[1]
		var m := _ipad(points, scale)
		var st := _stretch(points * scale)
		var final: Transform2D = st[0]
		var vs := m.viewport_size()
		for fx: float in [0.0, 0.5, 1.0]:
			for fy: float in [0.0, 0.5, 1.0]:
				var target := Vector2(vs.x * fx, vs.y * fy)
				# Independent forward model: where UIKit reports the touch, quantized to pixels
				# like Godot's own iOS view does.
				var px := (final * target).round()
				var raw := px / scale
				var err_pt := m.viewport_to_points(m.map(raw).distance_to(target))
				assert_true(err_pt <= 2.0, "%s@%s target %s error %.3f pt" % [points, scale, target, err_pt])
