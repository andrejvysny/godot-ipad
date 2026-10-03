extends RefCounted
## Test material mapper (world_painter/apply/material_mapper): named slots become a recognisable material, the slot
## "keep" is declined (null), every call is recorded.

static var calls: Array[String] = []


static func map_material(slot_id: String, material: Material) -> Material:
	calls.append(slot_id)
	if slot_id == "keep":
		return null
	var out := StandardMaterial3D.new()
	out.resource_name = "mapped:" + slot_id
	out.albedo_color = Color(1.0, 0.0, 0.5)
	return out
