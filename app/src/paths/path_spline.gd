class_name PathSpline
extends RefCounted
## Uniform Catmull-Rom spline through a path's control points (x, z), ends duplicated
## (docs/editor-v2.md §7). Parameter t is in control-point index units: t = i is points[i].

const CLOSEST_STEP_M := 0.25
const ARC_PROBES := 8
const ARC_SLACK := 1.2  # parameter speed varies along a segment; keeps every gap under the step


## Position at parameter t in [0, n - 1] (clamped).
static func eval(points: PackedVector2Array, t: float) -> Vector2:
	var n := points.size()
	if n == 0:
		return Vector2.ZERO
	if n == 1:
		return points[0]
	var tc := clampf(t, 0.0, float(n - 1))
	var i := mini(floori(tc), n - 2)
	return _segment(points, i, tc - float(i))


static func _segment(points: PackedVector2Array, i: int, u: float) -> Vector2:
	var last := points.size() - 1
	var p0 := points[maxi(i - 1, 0)]
	var p1 := points[i]
	var p2 := points[i + 1]
	var p3 := points[mini(i + 2, last)]
	var u2 := u * u
	var u3 := u2 * u
	return 0.5 * (2.0 * p1 + (p2 - p0) * u + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * u2
			+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * u3)


## Curve points spaced at most `step_m` apart; every control point is a sample.
static func sample(points: PackedVector2Array, step_m: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if points.size() < 2 or step_m <= 0.0:
		out.append_array(points)
		return out
	out.append(points[0])
	for i in points.size() - 1:
		var steps := maxi(1, ceili(_arc_length(points, i) * ARC_SLACK / step_m - 1e-6))
		for k in range(1, steps + 1):
			out.append(points[i + 1] if k == steps else _segment(points, i, float(k) / float(steps)))
	return out


static func _arc_length(points: PackedVector2Array, i: int) -> float:
	var total := 0.0
	var prev := points[i]
	for k in range(1, ARC_PROBES + 1):
		var cur := _segment(points, i, float(k) / float(ARC_PROBES)) if k < ARC_PROBES else points[i + 1]
		total += prev.distance_to(cur)
		prev = cur
	return total


## {distance, t, point}: nearest curve point to `p`; t is in control-point index units. Empty
## `points` gives distance INF.
static func closest(points: PackedVector2Array, p: Vector2) -> Dictionary:
	var best := {"distance": INF, "t": 0.0, "point": Vector2.ZERO}
	if points.size() == 1:
		return {"distance": p.distance_to(points[0]), "t": 0.0, "point": points[0]}
	for i in points.size() - 1:
		var steps := maxi(1, ceili(_arc_length(points, i) / CLOSEST_STEP_M))
		var prev := points[i]
		for k in range(1, steps + 1):
			var u1 := float(k) / float(steps)
			var cur := _segment(points, i, u1) if k < steps else points[i + 1]
			var seg := cur - prev
			var len2 := seg.length_squared()
			var f := 0.0 if len2 < 1e-12 else clampf((p - prev).dot(seg) / len2, 0.0, 1.0)
			var q := prev + seg * f
			var d := p.distance_to(q)
			if d < float(best.distance):
				best = {"distance": d, "t": float(i) + (float(k - 1) + f) / float(steps), "point": q}
			prev = cur
	return best


## Polyline length of a raw stroke.
static func length(raw: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, raw.size()):
		total += raw[i - 1].distance_to(raw[i])
	return total


## Points every `spacing_m` along the raw polyline; the first and last raw points are kept (a
## remainder shorter than half a spacing replaces the last emitted point instead of adding one).
static func resample_stroke(raw: PackedVector2Array, spacing_m: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if raw.is_empty() or spacing_m <= 0.0:
		return out
	out.append(raw[0])
	var carried := 0.0
	for i in range(1, raw.size()):
		var seg := raw[i] - raw[i - 1]
		var seg_len := seg.length()
		var d := spacing_m - carried
		while d <= seg_len and seg_len > 0.0:
			out.append(raw[i - 1] + seg * (d / seg_len))
			d += spacing_m
		carried = seg_len - (d - spacing_m) if seg_len > 0.0 else carried
	var end := raw[raw.size() - 1]
	if out.size() == 1:
		out.append(end)
	elif out[out.size() - 1].distance_to(end) > 1e-6:
		if out[out.size() - 1].distance_to(end) < spacing_m * 0.5:
			out[out.size() - 1] = end
		else:
			out.append(end)
	return out
