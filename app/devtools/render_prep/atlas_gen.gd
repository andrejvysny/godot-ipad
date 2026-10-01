extends RefCounted
## Procedural cutout atlases (2x2 cells) and bark. Alpha is a soft distance field around chunky
## strokes (0.5 contour at the stroke edge, wide padding) so the scissor contour survives mip
## filtering; RGB is defined everywhere so the importer's alpha-border fix has real colour.

const ATLAS_CELLS := 2


## kind: "pine" | "bush" | "grass". `cell` is the cell size in px; the atlas is 2*cell square.
static func atlas(kind: String, cell: int, seed_value: int) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var size := cell * ATLAS_CELLS
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var palette := _palette(kind)
	for cy in ATLAS_CELLS:
		for cx in ATLAS_CELLS:
			var strokes := _strokes(kind, rng, float(cell))
			_paint_cell(img, Vector2i(cx * cell, cy * cell), cell, strokes, palette, rng)
	return img


static func _palette(kind: String) -> Array[Color]:
	match kind:
		"pine":
			return [Color(0.08, 0.26, 0.12), Color(0.2, 0.44, 0.22)]
		"bush":
			return [Color(0.3, 0.44, 0.1), Color(0.55, 0.68, 0.2)]
	return [Color(0.3, 0.52, 0.14), Color(0.58, 0.76, 0.3)]


## Stroke = [a, b, radius_a, radius_b] in cell pixels (circle when a == b).
static func _strokes(kind: String, rng: RandomNumberGenerator, c: float) -> Array:
	var out: Array = []
	match kind:
		"pine":
			out.append([Vector2(c * 0.5, c * 0.96), Vector2(c * 0.5, c * 0.1), c * 0.06, c * 0.035])
			var pairs := 6 + rng.randi() % 4
			for i in pairs:
				var t := 0.12 + (0.84 / float(pairs)) * float(i)
				var y := c * (1.0 - t)
				for side in [-1.0, 1.0]:
					var reach := c * (0.40 - 0.28 * t) * rng.randf_range(0.75, 1.15)
					var tip := Vector2(c * 0.5 + side * reach, y - reach * rng.randf_range(0.35, 0.9))
					out.append([Vector2(c * 0.5, y), tip, c * 0.05, c * 0.035])
					out.append([tip, tip, c * 0.055, c * 0.055])
		"bush":
			for i in 11:
				var p := Vector2(rng.randf_range(0.22, 0.78), rng.randf_range(0.22, 0.8)) * c
				var r := c * rng.randf_range(0.11, 0.17)
				out.append([p, p, r, r])
				out.append([Vector2(c * 0.5, c * 0.97), p, c * 0.035, c * 0.03])
		_:
			for i in 5:
				var x := c * (0.2 + 0.15 * float(i)) + rng.randf_range(-0.03, 0.03) * c
				var top := Vector2(x + rng.randf_range(-0.16, 0.16) * c, c * rng.randf_range(0.1, 0.35))
				out.append([Vector2(x, c * 0.97), Vector2(lerpf(x, top.x, 0.5), c * 0.55), c * 0.085, c * 0.07])
				out.append([Vector2(lerpf(x, top.x, 0.5), c * 0.55), top, c * 0.07, c * 0.04])
	return out


static func _paint_cell(img: Image, origin: Vector2i, cell: int, strokes: Array, palette: Array[Color], rng: RandomNumberGenerator) -> void:
	var spread := float(cell) * 0.07
	var dist := PackedFloat32Array()
	dist.resize(cell * cell)
	dist.fill(1.0e6)
	for s: Array in strokes:
		var a: Vector2 = s[0]
		var b: Vector2 = s[1]
		var margin := maxf(float(s[2]), float(s[3])) + spread * 2.0
		var x0 := maxi(0, int(minf(a.x, b.x) - margin))
		var x1 := mini(cell - 1, int(maxf(a.x, b.x) + margin))
		var y0 := maxi(0, int(minf(a.y, b.y) - margin))
		var y1 := mini(cell - 1, int(maxf(a.y, b.y) + margin))
		var ab := b - a
		var len2 := maxf(ab.length_squared(), 0.0001)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var p := Vector2(float(x) + 0.5, float(y) + 0.5)
				var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
				var d := p.distance_to(a + ab * t) - lerpf(float(s[2]), float(s[3]), t)
				if d < dist[y * cell + x]:
					dist[y * cell + x] = d
	var seed_shift := rng.randf() * 10.0
	for y in cell:
		for x in cell:
			var d: float = dist[y * cell + x]
			var alpha := clampf(0.5 - d / (2.0 * spread), 0.0, 1.0)
			var n := 0.5 + 0.5 * sin(float(x) * 0.31 + seed_shift) * cos(float(y) * 0.23 + seed_shift * 0.7)
			var base := palette[0].lerp(palette[1], clampf(n * 0.7 + (1.0 - float(y) / float(cell)) * 0.3, 0.0, 1.0))
			img.set_pixel(origin.x + x, origin.y + y, Color(base.r, base.g, base.b, alpha))


static func bark(size: int, seed_value: int) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var phase := rng.randf() * 6.0
	for y in size:
		for x in size:
			var streak := 0.5 + 0.5 * sin(float(x) * 0.9 + phase + 0.4 * sin(float(y) * 0.12))
			var grain := 0.5 + 0.5 * sin(float(x) * 2.3 + float(y) * 0.31 + phase * 2.0)
			var k := 0.55 + 0.3 * streak + 0.15 * grain
			img.set_pixel(x, y, Color(0.36 * k, 0.25 * k, 0.16 * k, 1.0))
	return img


static func resized(img: Image, size: int) -> Image:
	var out := img.duplicate() as Image
	out.resize(size, size, Image.INTERPOLATE_BILINEAR)
	return out


## Atlas cell rectangle in normalised UV space with a half-texel inset against bleeding.
static func cell_rect(i: int, inset: float = 0.004) -> Rect2:
	var cx := i % ATLAS_CELLS
	var cy := (i / ATLAS_CELLS) % ATLAS_CELLS
	var s := 1.0 / float(ATLAS_CELLS)
	return Rect2(Vector2(cx * s + inset, cy * s + inset), Vector2(s - 2.0 * inset, s - 2.0 * inset))
