class_name ControlCodec
extends RefCounted
## Terrain3D 1.0.2 packed control value (src/terrain_3d_util.h at commit 0077405b).
## The value is a raw uint32 bit pattern stored in FORMAT_RF image memory. It is never
## a meaningful float: do not normalize, filter, interpolate, or pass it through Color.
##
## Bits 27-31 base texture id | 22-26 overlay id | 14-21 blend (0..255)
## 10-13 uv rotation | 7-9 uv scale | 3-6 reserved | 2 hole | 1 navigation | 0 auto-shader

const BASE_SHIFT := 27
const OVERLAY_SHIFT := 22
const BLEND_SHIFT := 14
const ID_MASK := 0x1F
const BLEND_MASK := 0xFF
const AUTO_BIT := 0x1
const NAV_BIT := 0x2
const HOLE_BIT := 0x4
const U32 := 0xFFFFFFFF

const FIELD_MASK_BASE := ID_MASK << BASE_SHIFT
const FIELD_MASK_OVERLAY := ID_MASK << OVERLAY_SHIFT
const FIELD_MASK_BLEND := BLEND_MASK << BLEND_SHIFT
## Everything the painter owns; all other bits are preserved verbatim.
const PAINT_OWNED_MASK := FIELD_MASK_BASE | FIELD_MASK_OVERLAY | FIELD_MASK_BLEND | AUTO_BIT


static func decode(value: int) -> Dictionary:
	var v := value & U32
	return {
		"base_id": (v >> BASE_SHIFT) & ID_MASK,
		"overlay_id": (v >> OVERLAY_SHIFT) & ID_MASK,
		"blend": (v >> BLEND_SHIFT) & BLEND_MASK,
		"auto": (v & AUTO_BIT) != 0,
		"hole": (v & HOLE_BIT) != 0,
		"other_bits": v & ~PAINT_OWNED_MASK & U32,
	}


static func get_base(value: int) -> int:
	return ((value & U32) >> BASE_SHIFT) & ID_MASK


static func get_overlay(value: int) -> int:
	return ((value & U32) >> OVERLAY_SHIFT) & ID_MASK


static func get_blend(value: int) -> int:
	return ((value & U32) >> BLEND_SHIFT) & BLEND_MASK


## Returns `existing` with only the named fields replaced. Unknown keys are ignored.
static func encode(existing: int, changed: Dictionary) -> int:
	var v := existing & U32
	if changed.has("base_id"):
		v = (v & ~FIELD_MASK_BASE) | ((int(changed.base_id) & ID_MASK) << BASE_SHIFT)
	if changed.has("overlay_id"):
		v = (v & ~FIELD_MASK_OVERLAY) | ((int(changed.overlay_id) & ID_MASK) << OVERLAY_SHIFT)
	if changed.has("blend"):
		v = (v & ~FIELD_MASK_BLEND) | ((int(changed.blend) & BLEND_MASK) << BLEND_SHIFT)
	if changed.has("auto"):
		v = (v & ~AUTO_BIT) | (AUTO_BIT if changed.auto else 0)
	return v & U32


## PoC paint invariant: base = grass, overlay = dirt, manual blend, auto-shader off.
## Blend 0 = pure grass, 255 = pure dirt. Reserved/unrelated bits are preserved.
static func encode_paint(existing: int, dirt_blend_u8: int) -> int:
	var v := (existing & U32) & ~PAINT_OWNED_MASK
	v |= WorldConstants.MATERIAL_GRASS << BASE_SHIFT
	v |= WorldConstants.MATERIAL_DIRT << OVERLAY_SHIFT
	v |= (clampi(dirt_blend_u8, 0, 255) & BLEND_MASK) << BLEND_SHIFT
	return v & U32


## Dirt coverage in [0, 1] as seen by the paint tools. Values whose base/overlay are not
## the grass/dirt invariant are interpreted by the base id alone (dirt base = fully dirt).
static func dirt_blend01(value: int) -> float:
	var base := get_base(value)
	var overlay := get_overlay(value)
	if base == WorldConstants.MATERIAL_GRASS and overlay == WorldConstants.MATERIAL_DIRT:
		return float(get_blend(value)) / 255.0
	return 1.0 if base == WorldConstants.MATERIAL_DIRT else 0.0


static func quantize_blend(blend01: float) -> int:
	return clampi(roundi(clampf(blend01, 0.0, 1.0) * 255.0), 0, 255)


## Default grass value used by fixtures: base 0, overlay 1, blend 0, all flags clear.
static func grass_value() -> int:
	return encode_paint(0, 0)


## Validation used by loaders: texture ids must reference the two material slots.
static func is_supported(value: int) -> bool:
	return get_base(value) < WorldConstants.MATERIAL_SLOTS.size() \
		and get_overlay(value) < WorldConstants.MATERIAL_SLOTS.size()


## Exact bit pattern -> RF image. Bit reinterpretation, not numeric conversion.
static func control_to_image(control: PackedInt32Array) -> Image:
	var n := WorldConstants.REGION_SAMPLES
	return Image.create_from_data(n, n, false, Image.FORMAT_RF, control.to_byte_array())


static func image_to_control(image: Image) -> PackedInt32Array:
	assert(image.get_format() == Image.FORMAT_RF)
	return image.get_data().to_int32_array()
