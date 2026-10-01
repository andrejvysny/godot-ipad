class_name BrushMath
extends RefCounted
## Scalar brush math shared by the kernels (spec §12.1, §12.2, §13.1, §15.5). Distances are
## world metres in X/Z. Kernels use the continuous limit of dabs along a segment, so results do
## not depend on callback rate or resampling spacing.

const PRESSURE_MIN_FACTOR := 0.2
## Segments shorter than this are treated as a point dab.
const MIN_SEGMENT_LENGTH := 1e-6
## Fraction of the path radius painted at full strength (hard core keeps the visible width
## equal to the width setting).
const PATH_CORE := 0.6


## (1 - q^2)^2 for q in [0, 1], 0 beyond.
static func falloff(q: float) -> float:
	var a := absf(q)
	if a >= 1.0:
		return 0.0
	var s := 1.0 - a * a
	return s * s


static func path_falloff(q: float) -> float:
	var a := absf(q)
	if a <= PATH_CORE:
		return 1.0
	if a >= 1.0:
		return 0.0
	var t := (a - PATH_CORE) / (1.0 - PATH_CORE)
	var s := 1.0 - t * t
	return s * s


## Unavailable or disabled pressure is full strength, never zero.
static func pressure_factor(pressure_valid: bool, pressure: float, enabled: bool,
		min_factor: float = PRESSURE_MIN_FACTOR) -> float:
	if not (enabled and pressure_valid) or is_nan(pressure):
		return 1.0
	return min_factor + (1.0 - min_factor) * clampf(pressure, 0.0, 1.0)


## Target resampling spacing from spec §12.1; kernels are continuous and do not depend on it.
static func resample_spacing(radius: float) -> float:
	return minf(radius / 4.0, WorldConstants.SAMPLE_SPACING / 2.0)


## Mean of falloff(|p - s(u)| / r) over u in [0, L] along a segment, closed form.
## `a` = along-segment coordinate of the sample relative to the segment start, `h2` = squared
## perpendicular distance. With w = a - u the integrand is (k - w^2/r^2)^2, k = 1 - h2/r^2,
## supported on |w| <= c = sqrt(r^2 - h2).
static func integrated_falloff(h2: float, a: float, length: float, r: float) -> float:
	var r2 := r * r
	if length < MIN_SEGMENT_LENGTH:
		return falloff(sqrt(h2 + a * a) / r)
	if h2 >= r2:
		return 0.0
	var c := sqrt(r2 - h2)
	var w0 := maxf(a - length, -c)
	var w1 := minf(a, c)
	if w0 >= w1:
		return 0.0
	var k := 1.0 - h2 / r2
	var c3 := 2.0 * k / (3.0 * r2)
	var c5 := 1.0 / (5.0 * r2 * r2)
	var w0s := w0 * w0
	var w1s := w1 * w1
	var f1 := w1 * (k * k - c3 * w1s + c5 * w1s * w1s)
	var f0 := w0 * (k * k - c3 * w0s + c5 * w0s * w0s)
	return (f1 - f0) / length


## Max over s in [0, L] of lerp(pf_a, pf_b, s / L) * falloff(sqrt(h2 + (s - a)^2) / r): the
## continuous limit of coverage-max dabs along a segment whose pressure factor varies linearly.
## With w = s - a and g = (pf_b - pf_a) / L, interior maxima satisfy
## 5g w^2 + 4 pf(a) w - g k r^2 = 0 (k = 1 - h2/r^2); endpoints and the closest point are also
## candidates. Evaluating only the closest point would make the result depend on sample density.
static func max_weighted_falloff(h2: float, a: float, length: float, r: float, pf_a: float, pf_b: float) -> float:
	if length < MIN_SEGMENT_LENGTH:
		return pf_a * falloff(sqrt(h2 + a * a) / r)
	var r2 := r * r
	if h2 >= r2:
		return 0.0
	var g := (pf_b - pf_a) / length
	var best := _weighted(h2, a, r, pf_a, g, clampf(a, 0.0, length))
	if g == 0.0:
		return best
	best = maxf(best, _weighted(h2, a, r, pf_a, g, 0.0))
	best = maxf(best, _weighted(h2, a, r, pf_a, g, length))
	var qa := 5.0 * g
	var qb := 4.0 * (pf_a + g * a)
	var qc := -g * (1.0 - h2 / r2) * r2
	# Numerically stable roots: q = -(b + sign(b) sqrt(b^2 - 4ac)) / 2, w = q/a and c/q.
	var q := -0.5 * (qb + (1.0 if qb >= 0.0 else -1.0) * sqrt(qb * qb - 4.0 * qa * qc))
	if q != 0.0:
		best = maxf(best, _weighted(h2, a, r, pf_a, g, clampf(a + q / qa, 0.0, length)))
		best = maxf(best, _weighted(h2, a, r, pf_a, g, clampf(a + qc / q, 0.0, length)))
	return best


static func _weighted(h2: float, a: float, r: float, pf_a: float, g: float, s: float) -> float:
	var w := s - a
	return (pf_a + g * s) * falloff(sqrt(h2 + w * w) / r)
