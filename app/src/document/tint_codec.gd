class_name TintCodec
extends RefCounted
## Tint-map paint rules (docs/editor-v2.md §4). A sample is the packed u32 R<<24|G<<16|B<<8|A as
## WorldDocument.get_color_at_sample returns it; `rgb` arguments are Vector3i(r, g, b) bytes.

const PRESETS: Array[Dictionary] = [
	{"name": "Dry", "rgb": Vector3i(200, 180, 84)},
	{"name": "Lush", "rgb": Vector3i(38, 108, 40)},
	{"name": "Autumn", "rgb": Vector3i(192, 110, 48)},
]


static func preset_name(index: int) -> String:
	return str(PRESETS[clampi(index, 0, PRESETS.size() - 1)].name)


static func preset_rgb(index: int) -> Vector3i:
	return PRESETS[clampi(index, 0, PRESETS.size() - 1)].rgb


static func pack(rgb: Vector3i, a: int) -> int:
	return (rgb.x << 24) | (rgb.y << 16) | (rgb.z << 8) | (a & 0xFF)


static func rgb_of(rgba: int) -> Vector3i:
	return Vector3i((rgba >> 24) & 0xFF, (rgba >> 16) & 0xFF, (rgba >> 8) & 0xFF)


static func alpha_of(rgba: int) -> int:
	return rgba & 0xFF


## Tints towards `rgb` with coverage `c`: builds weight on an untinted or same-colour sample,
## otherwise first fades the old tint (c <= 0.5) and then replaces it (c > 0.5).
static func tint(start_rgba: int, rgb: Vector3i, c: float) -> int:
	var a := alpha_of(start_rgba)
	var old := rgb_of(start_rgba)
	if a == 0 or old == rgb:
		return pack(rgb, _byte(a + (255.0 - a) * c))
	if c <= 0.5:
		return pack(old, _byte(a * (1.0 - 2.0 * c)))
	return pack(rgb, _byte(255.0 * (2.0 * c - 1.0)))


## Fades the tint weight, keeping the colour.
static func untint(start_rgba: int, c: float) -> int:
	var a := alpha_of(start_rgba)
	return pack(rgb_of(start_rgba), _byte(a * (1.0 - c)))


static func _byte(v: float) -> int:
	return clampi(roundi(v), 0, 255)
