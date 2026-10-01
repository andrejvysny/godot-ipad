class_name TerrainMaterials
extends RefCounted
## Procedural two-material Terrain3DAssets (id 0 grass, id 1 dirt); no external files.
##
## Pinned Terrain3D 1.0.2 requirements (terrain_3d_assets.cpp _update_texture_files,
## terrain_3d_texture_asset.cpp): every albedo texture must share one size, one Image
## format and one mipmap flag, and likewise every normal texture, or the arrays are not
## built and an error is logged. Missing mipmaps, non-square or non-power-of-two sizes log
## warnings. The shader reads albedo.a as the blend height and normal.a as roughness.

const TEXTURE_SIZE := 128
const FORMAT := Image.FORMAT_RGBA8
const TEXTURE_NAMES := ["grass", "dirt"]
## Distinct readable base colors; per-pixel variation stays small so blends read clearly.
const ALBEDO := [Color(0.30, 0.55, 0.20), Color(0.52, 0.38, 0.24)]
const HEIGHT_MEAN := [0.5, 0.5]
const HEIGHT_VARIATION := [0.12, 0.25]
const ROUGHNESS := [0.85, 0.95]
const COLOR_VARIATION := 0.06


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
			var shade := 1.0 + (n - 0.5) * 2.0 * COLOR_VARIATION
			bytes[k] = _u8(base.r * shade)
			bytes[k + 1] = _u8(base.g * shade)
			bytes[k + 2] = _u8(base.b * shade)
			bytes[k + 3] = _u8(HEIGHT_MEAN[id] + (n - 0.5) * 2.0 * HEIGHT_VARIATION[id])
			k += 4
	return _finish(bytes)


## RGB = flat tangent-space normal, A = roughness.
static func normal_image(id: int) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(TEXTURE_SIZE * TEXTURE_SIZE * 4)
	var rough := _u8(ROUGHNESS[id])
	for k in range(0, bytes.size(), 4):
		bytes[k] = 128
		bytes[k + 1] = 128
		bytes[k + 2] = 255
		bytes[k + 3] = rough
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
