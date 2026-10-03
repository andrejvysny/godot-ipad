extends SceneTree
## Deterministic generator of the terrain Texture Preview sources (spec 11.4): per material slot a
## 1024 px albedo (RGB colour, A = the low-tier blend-height pattern scaled up; the shader never
## blends with it) and normal (RGB normal, A = roughness) PNG with finer detail but the same mean
## colour and roughness as TerrainMaterials. Writes app/assets/terrain/preview/<slot>_{albedo,normal}.png.
## Run via `python3 scripts/dev.py prepare-terrain-preview` (hard timeout, stdin=/dev/null).
## The .png.import files next to the outputs are committed; this script never rewrites them.

const TM := preload("res://addons/world_painter/terrain/terrain_materials.gd")
const OUT_DIR := "res://assets/terrain/preview/"
const SIZE := 1024
const SEED := 20261001
## Noise cycles per texture edge of the base octave, per slot (grass, dirt, rock, sand).
const BASE_CYCLES := [10.0, 8.0, 6.0, 14.0]
const OCTAVES := 4
## Normal slope gain relative to TerrainMaterials.NORMAL_STRENGTH (the preview has 8x finer texels).
const SLOPE_GAIN := 5.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var failed := false
	for id in TM.TEXTURE_NAMES.size():
		var field := _field(id)
		var name: String = TM.TEXTURE_NAMES[id]
		failed = _save(_albedo(id, field), OUT_DIR + name + "_albedo.png") or failed
		failed = _save(_normal(id, field), OUT_DIR + name + "_normal.png") or failed
	quit(1 if failed else 0)


## Seamless fractal height field, zero mean and unit standard deviation.
func _field(id: int) -> PackedFloat32Array:
	var noise := FastNoiseLite.new()
	noise.seed = SEED + id * 7919
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = OCTAVES
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5
	noise.frequency = float(BASE_CYCLES[id]) / float(SIZE)
	var f := PackedFloat32Array()
	f.resize(SIZE * SIZE)
	var w := float(SIZE)
	var k := 0
	for y in SIZE:
		for x in SIZE:
			# Four shifted samples blended by position make the tile seamless.
			var fx := float(x) / w
			var fy := float(y) / w
			f[k] = (noise.get_noise_2d(x, y) * (1.0 - fx) * (1.0 - fy)
				+ noise.get_noise_2d(x - SIZE, y) * fx * (1.0 - fy)
				+ noise.get_noise_2d(x, y - SIZE) * (1.0 - fx) * fy
				+ noise.get_noise_2d(x - SIZE, y - SIZE) * fx * fy)
			k += 1
	var mean := 0.0
	for v in f:
		mean += v
	mean /= f.size()
	var variance := 0.0
	for v in f:
		variance += (v - mean) * (v - mean)
	var inv_std := 1.0 / maxf(sqrt(variance / f.size()), 1e-9)
	for i in f.size():
		f[i] = (f[i] - mean) * inv_std
	return f


func _albedo(id: int, field: PackedFloat32Array) -> Image:
	var base: Color = TM.ALBEDO[id]
	# Uniform noise in [0,1] has std 0.2887; the low tier shades by (n - 0.5) * 2 * variation.
	var shade_std: float = float(TM.COLOR_VARIATION[id]) * 2.0 * 0.2887
	var height := _low_height(id)
	var bytes := PackedByteArray()
	bytes.resize(SIZE * SIZE * 4)
	var k := 0
	for i in SIZE * SIZE:
		var shade := 1.0 + field[i] * shade_std
		bytes[k] = TM._u8(base.r * shade)
		bytes[k + 1] = TM._u8(base.g * shade)
		bytes[k + 2] = TM._u8(base.b * shade)
		bytes[k + 3] = height[i]
		k += 4
	return Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, bytes)


## The low-tier blend-height channel upsampled; kept only so the packed format matches.
func _low_height(id: int) -> PackedByteArray:
	var low := TM.albedo_image(id)
	low.clear_mipmaps()
	low.resize(SIZE, SIZE, Image.INTERPOLATE_BILINEAR)
	var data := low.get_data()
	var out := PackedByteArray()
	out.resize(SIZE * SIZE)
	for i in SIZE * SIZE:
		out[i] = data[i * 4 + 3]
	return out


func _normal(id: int, field: PackedFloat32Array) -> Image:
	var rough: int = TM._u8(TM.ROUGHNESS[id])
	var strength: float = float(TM.NORMAL_STRENGTH[id]) * SLOPE_GAIN
	var mask := SIZE - 1
	var bytes := PackedByteArray()
	bytes.resize(SIZE * SIZE * 4)
	var k := 0
	for y in SIZE:
		for x in SIZE:
			var dx := field[y * SIZE + ((x + 1) & mask)] - field[y * SIZE + ((x - 1) & mask)]
			var dy := field[((y + 1) & mask) * SIZE + x] - field[((y - 1) & mask) * SIZE + x]
			var n := Vector3(-dx * strength, -dy * strength, 1.0).normalized()
			bytes[k] = TM._u8(n.x * 0.5 + 0.5)
			bytes[k + 1] = TM._u8(n.y * 0.5 + 0.5)
			bytes[k + 2] = TM._u8(n.z * 0.5 + 0.5)
			bytes[k + 3] = rough
			k += 4
	return Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, bytes)


func _save(img: Image, path: String) -> bool:
	var err := img.save_png(path)
	print("%s: %s" % [path, "ok" if err == OK else "error %d" % err])
	return err != OK
