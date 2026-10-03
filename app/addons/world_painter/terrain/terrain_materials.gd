class_name TerrainMaterials
extends RefCounted
## Procedural four-material Terrain3DAssets (id 0 grass, 1 dirt, 2 rock, 3 sand; world format
## material slots); no external files.
##
## Pinned Terrain3D 1.0.2 requirements (terrain_3d_assets.cpp _update_texture_files,
## terrain_3d_texture_asset.cpp): every albedo texture must share one size, one Image
## format and one mipmap flag, and likewise every normal texture, or the arrays are not
## built and an error is logged. Missing mipmaps, non-square or non-power-of-two sizes log
## warnings. The shader reads albedo.a as the blend height and normal.a as roughness.

const TEXTURE_SIZE := 128
const FORMAT := Image.FORMAT_RGBA8
const TEXTURE_NAMES := ["grass", "dirt", "rock", "sand"]
## Distinct readable base colors (sRGB 8-bit); per-pixel variation stays small so blends read clearly.
const ALBEDO := [
	Color8(88, 158, 62), Color8(146, 104, 70), Color8(126, 122, 116), Color8(206, 188, 140),
]
const HEIGHT_MEAN := [0.5, 0.5, 0.5, 0.5]
const HEIGHT_VARIATION := [0.12, 0.25, 0.35, 0.08]
const ROUGHNESS := [0.85, 0.95, 0.98, 0.7]
## Slope of the procedural bump per slot: rock strong, sand fine and smooth.
const NORMAL_STRENGTH := [0.15, 0.25, 0.9, 0.12]
const COLOR_VARIATION := [0.06, 0.06, 0.10, 0.04]
## Terrain3DMaterial `blend_sharpness` (pinned shader: exponent = 56 * value + 8). The default 0.5
## (exponent 36) hides partial dirt coverage from light strokes; 0.15 (~16) keeps partial
## coverage visible while a full stroke still reads as dirt. Visual only, never authored data.
const BLEND_SHARPNESS := 0.15


## Optional consumer terrain material (a Terrain3DMaterial .tres/.res, ADR 0016 P4 / ADR 0017 A4): replaces the World
## Painter shader material in the preview and the Apply bake. Its shader must read the Terrain3D maps itself and may
## read the world uniforms of TerrainBake.shader_parameters / TerrainAdapter.rule_uniforms (unknown ones are ignored).
const SETTING := "world_painter/terrain/material"


static func custom_path() -> String:
	return str(ProjectSettings.get_setting(SETTING, ""))


## [duplicate of the consumer material or null, error]; (null, "") when the setting is empty.
static func load_custom() -> Array:
	var path := custom_path()
	if path == "":
		return [null, ""]
	if not path.begins_with("res://") or path.contains("..") or not ResourceLoader.exists(path):
		return [null, "terrain material '%s' is not an existing res:// resource" % path.left(120)]
	var loaded := load(path) as Terrain3DMaterial
	if loaded == null:
		return [null, "terrain material '%s' is not a Terrain3DMaterial" % path.left(120)]
	return [loaded.duplicate() as Terrain3DMaterial, ""]


static func create_assets() -> Terrain3DAssets:
	var assets := Terrain3DAssets.new()
	for id in TEXTURE_NAMES.size():
		assets.set_texture(id, create_texture_asset(id))
	return assets


static func create_texture_asset(id: int) -> Terrain3DTextureAsset:
	var ta := Terrain3DTextureAsset.new()
	ta.name = TEXTURE_NAMES[id]
	ta.albedo_texture = ImageTexture.create_from_image(albedo_image(id))
	ta.normal_texture = ImageTexture.create_from_image(normal_image(id))
	return ta


## RGB = albedo, A = height used by Terrain3D's height blending.
static func albedo_image(id: int) -> Image:
	var base: Color = ALBEDO[id]
	var bytes := PackedByteArray()
	bytes.resize(TEXTURE_SIZE * TEXTURE_SIZE * 4)
	var k := 0
	for y in TEXTURE_SIZE:
		for x in TEXTURE_SIZE:
			var n := _noise(x, y, id)
			var shade: float = 1.0 + (n - 0.5) * 2.0 * (COLOR_VARIATION[id] as float)
			bytes[k] = _u8(base.r * shade)
			bytes[k + 1] = _u8(base.g * shade)
			bytes[k + 2] = _u8(base.b * shade)
			bytes[k + 3] = _u8(HEIGHT_MEAN[id] + (n - 0.5) * 2.0 * HEIGHT_VARIATION[id])
			k += 4
	return _finish(bytes)


## RGB = tangent-space normal from the hash-noise heights (central differences, wrapping so
## the texture tiles), A = roughness.
static func normal_image(id: int) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(TEXTURE_SIZE * TEXTURE_SIZE * 4)
	var rough := _u8(ROUGHNESS[id])
	var strength: float = NORMAL_STRENGTH[id]
	var mask := TEXTURE_SIZE - 1
	var k := 0
	for y in TEXTURE_SIZE:
		for x in TEXTURE_SIZE:
			var dx := _noise((x + 1) & mask, y, id) - _noise((x - 1) & mask, y, id)
			var dy := _noise(x, (y + 1) & mask, id) - _noise(x, (y - 1) & mask, id)
			var n := Vector3(-dx * strength, -dy * strength, 1.0).normalized()
			bytes[k] = _u8(n.x * 0.5 + 0.5)
			bytes[k + 1] = _u8(n.y * 0.5 + 0.5)
			bytes[k + 2] = _u8(n.z * 0.5 + 0.5)
			bytes[k + 3] = rough
			k += 4
	return _finish(bytes)


static func _finish(bytes: PackedByteArray) -> Image:
	var img := Image.create_from_data(TEXTURE_SIZE, TEXTURE_SIZE, false, FORMAT, bytes)
	img.generate_mipmaps()
	return img


## Deterministic tileable-enough hash noise in [0, 1]; no RNG state involved.
static func _noise(x: int, y: int, seed_id: int) -> float:
	var h := (x * 374761393 + y * 668265263 + seed_id * 2246822519) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0xFFFF) / 65535.0


static func _u8(v: float) -> int:
	return clampi(roundi(v * 255.0), 0, 255)
