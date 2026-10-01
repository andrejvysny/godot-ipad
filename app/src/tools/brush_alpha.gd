class_name BrushAlpha
extends RefCounted
## Procedural brush alphas shared by every brush tool (docs/editor-v2.md §3). Weights are in
## [0, 1]; distances are world metres in X/Z. `soft` + `circle` equals BrushMath.falloff, which
## the kernels keep evaluating with their exact continuous path.

const SHAPES: Array[String] = ["soft", "hard", "cloud", "ring", "splat", "streak"]
const SHAPE_LABELS := {"soft": "Soft", "hard": "Hard", "cloud": "Cloud", "ring": "Ring",
		"splat": "Splat", "streak": "Streak"}
const MODES: Array[String] = ["circle", "stamp", "pattern"]
const MODE_LABELS := {"circle": "Circle", "stamp": "Stamp", "pattern": "Pattern"}
const PATTERN_MIN_TILE_M := 1.5
const PATTERN_TILE_FACTOR := 0.7
const HARD_CORE := 0.82
const RING_RADIUS := 0.66
const RING_WIDTH := 0.16
const STREAK_ASPECT := 0.32
const SPLAT_BLOBS: Array[Vector3] = [Vector3(0.0, 0.0, 0.38), Vector3(0.5, 0.3, 0.26),
		Vector3(-0.45, 0.4, 0.24), Vector3(-0.3, -0.5, 0.28), Vector3(0.42, -0.45, 0.22)]


static func is_exact_soft(shape: String, mode: String) -> bool:
	return shape == "soft" and mode == "circle"


static func hash01(x: float, y: float) -> float:
	var s := sin(x * 127.1 + y * 311.7) * 43758.5453
	return s - floorf(s)


## 2D value noise on the hash lattice with smoothstep interpolation.
static func value_noise(x: float, y: float) -> float:
	var xi := floorf(x)
	var yi := floorf(y)
	var xf := x - xi
	var yf := y - yi
	var u := xf * xf * (3.0 - 2.0 * xf)
	var v := yf * yf * (3.0 - 2.0 * yf)
	var a := hash01(xi, yi)
	var b := hash01(xi + 1.0, yi)
	var c := hash01(xi, yi + 1.0)
	var d := hash01(xi + 1.0, yi + 1.0)
	return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v


## Shape weight at normalised offset (u, v); 0 outside the unit disc.
static func shape_weight(shape: String, u: float, v: float) -> float:
	var q2 := u * u + v * v
	if q2 >= 1.0:
		return 0.0
	var q := sqrt(q2)
	match shape:
		"hard":
			return 1.0 if q < HARD_CORE else (1.0 - q) / (1.0 - HARD_CORE)
		"cloud":
			return (1.0 - q2) * clampf(value_noise(u * 3.0 + 7.0, v * 3.0 + 3.0) * 1.6 - 0.3, 0.0, 1.0)
		"ring":
			var t := (q - RING_RADIUS) / RING_WIDTH
			return exp(-t * t)
		"splat":
			var m := 0.0
			for b: Vector3 in SPLAT_BLOBS:
				var du := u - b.x
				var dv := v - b.y
				m = maxf(m, exp(-(du * du + dv * dv) / (b.z * b.z)))
			return m
		"streak":
			var e := u * u + (v / STREAK_ASPECT) * (v / STREAK_ASPECT)
			return 0.0 if e >= 1.0 else (1.0 - e) * (0.6 + 0.4 * (u + 1.0) * 0.5)
	return BrushMath.falloff(q)


## Weight at world point (x, z) of a dab centred at `center` with `radius`. `angle` is the stroke
## direction in the XZ plane (stamp mode only).
static func weight(shape: String, mode: String, x: float, z: float, center: Vector2, radius: float,
		angle: float = 0.0) -> float:
	if radius <= 0.0:
		return 0.0
	var u := (x - center.x) / radius
	var v := (z - center.y) / radius
	var q2 := u * u + v * v
	if q2 >= 1.0:
		return 0.0
	match mode:
		"stamp":
			var c := cos(-angle)
			var s := sin(-angle)
			return shape_weight(shape, u * c - v * s, u * s + v * c)
		"pattern":
			var tile := pattern_tile(radius)
			var pu := fposmod(x / tile, 1.0) * 2.0 - 1.0
			var pv := fposmod(z / tile, 1.0) * 2.0 - 1.0
			return shape_weight(shape, pu, pv) * (1.0 - smoothstep(0.75, 1.0, sqrt(q2)))
	return shape_weight(shape, u, v)


static func pattern_tile(radius: float) -> float:
	return maxf(PATTERN_MIN_TILE_M, radius * PATTERN_TILE_FACTOR)


## White RGBA8 image whose alpha is the brush weight; previews a dab of `preview_radius_m`.
static func preview_image(shape: String, mode: String, size: int, preview_radius_m: float = 4.0) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var half := size * 0.5
	var scale := preview_radius_m / maxf(half - 1.0, 1.0)
	for py in size:
		for px in size:
			var x := (px + 0.5 - half) * scale
			var z := (py + 0.5 - half) * scale
			var w := weight(shape, mode, x, z, Vector2.ZERO, preview_radius_m, 0.6)
			img.set_pixel(px, py, Color(1, 1, 1, clampf(w, 0.0, 1.0)))
	return img
