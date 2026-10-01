class_name BrushDabs
extends RefCounted
## Discrete dabs along a stroke segment for every alpha other than soft + circle
## (docs/editor-v2.md §3): spacing at most SPACING_FACTOR * radius, both end points included.

const SPACING_FACTOR := 0.15
## Segments shorter than this keep the previous stamp angle.
const STAMP_MIN_LENGTH := 0.001
const MAX_DABS := 4096


static func count(length: float, radius: float) -> int:
	if length < BrushMath.MIN_SEGMENT_LENGTH:
		return 1
	return clampi(ceili(length / (SPACING_FACTOR * radius)) + 1, 2, MAX_DABS)


## `n` evenly spaced dab centres from a to b inclusive (a alone when n == 1).
static func centers(a: Vector2, b: Vector2, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		out[i] = a if n == 1 else a.lerp(b, float(i) / float(n - 1))
	return out


## Stroke direction in the XZ plane (stamp mode); `previous` when the segment is under 1 mm.
static func segment_angle(a: Vector2, b: Vector2, previous: float) -> float:
	var d := b - a
	if d.length() < STAMP_MIN_LENGTH:
		return previous
	return atan2(d.y, d.x)


## Mean alpha weight at world point (x, z) over dabs `centers`, or 0 when none reach it.
static func mean_weight(shape: String, mode: String, x: float, z: float, centers_xz: PackedVector2Array,
		radius: float, angle: float) -> float:
	var sum := 0.0
	var r2 := radius * radius
	for c in centers_xz:
		var dx := x - c.x
		var dz := z - c.y
		if dx * dx + dz * dz < r2:
			sum += BrushAlpha.weight(shape, mode, x, z, c, radius, angle)
	return sum / float(centers_xz.size())
