class_name RegionBuffers
extends RefCounted
## Canonical terrain data for one region. Row-major: index = row(Z) * 256 + column(X).
## `control` holds raw uint32 bit patterns in PackedInt32Array storage; always read with
## `& 0xFFFFFFFF`. Packed arrays are shared by reference in Godot 4: every snapshot must
## call duplicate(). `color` is the tint map: 4 bytes R,G,B,A per sample (same index order).

var location: Vector2i
var heights: PackedFloat32Array
var control: PackedInt32Array
var color: PackedByteArray


func _init(loc: Vector2i = Vector2i.ZERO) -> void:
	location = loc
	heights = PackedFloat32Array()
	heights.resize(WorldConstants.REGION_SAMPLE_COUNT)
	control = PackedInt32Array()
	control.resize(WorldConstants.REGION_SAMPLE_COUNT)
	color = default_color_bytes()


static var _default_color_template := PackedByteArray()


## Built once: a 64-region world would otherwise spend seconds filling 16M bytes in script.
static func default_color_bytes() -> PackedByteArray:
	if _default_color_template.is_empty():
		var b := PackedByteArray()
		b.resize(WorldConstants.REGION_MAP_BYTES)
		for i in WorldConstants.REGION_SAMPLE_COUNT:
			for c in 4:
				b[i * 4 + c] = WorldConstants.DEFAULT_COLOR_BYTES[c]
		_default_color_template = b
	return _default_color_template.duplicate()


static func filled(loc: Vector2i, height: float, control_value: int) -> RegionBuffers:
	var r := RegionBuffers.new(loc)
	r.heights.fill(height)
	r.control.fill(control_value)
	return r


func duplicate_deep() -> RegionBuffers:
	var r := RegionBuffers.new(location)
	r.heights = heights.duplicate()
	r.control = control.duplicate()
	r.color = color.duplicate()
	return r


func get_control(index: int) -> int:
	return control[index] & 0xFFFFFFFF


## Little-endian bytes. Callers must have checked WorldConstants.host_is_little_endian().
func height_bytes() -> PackedByteArray:
	return heights.to_byte_array()


func control_bytes() -> PackedByteArray:
	return control.to_byte_array()


func color_bytes() -> PackedByteArray:
	return color.duplicate()


func set_from_bytes(height_data: PackedByteArray, control_data: PackedByteArray, color_data: PackedByteArray) -> String:
	if height_data.size() != WorldConstants.REGION_MAP_BYTES:
		return "height map for %s has %d bytes, expected %d" % [location, height_data.size(), WorldConstants.REGION_MAP_BYTES]
	if control_data.size() != WorldConstants.REGION_MAP_BYTES:
		return "control map for %s has %d bytes, expected %d" % [location, control_data.size(), WorldConstants.REGION_MAP_BYTES]
	if color_data.size() != WorldConstants.REGION_MAP_BYTES:
		return "color map for %s has %d bytes, expected %d" % [location, color_data.size(), WorldConstants.REGION_MAP_BYTES]
	color = color_data.duplicate()
	heights = height_data.to_float32_array()
	control = control_data.to_int32_array()
	return ""
