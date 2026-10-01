extends RefCounted
## Whitelisted StandardMaterial3D extraction and deterministic .tres text for render derivatives.

const WHITELIST: Array[String] = ["albedo_color", "vertex_color_use_as_albedo", "vertex_color_is_srgb", "roughness",
	"metallic", "cull_mode", "transparency", "alpha_scissor_threshold", "texture_filter"]
const IGNORED: Array[String] = ["resource_local_to_scene", "resource_name", "resource_path", "script", "albedo_texture"]
const CULL_ALLOWED := [BaseMaterial3D.CULL_BACK, BaseMaterial3D.CULL_DISABLED]


## texture_keys: manifest texture keys; a material named like one is bound to it (its LOW png).
## Returns {"key", "props", "alpha_mode", "texture"} or {"error"}.
static func describe(mat: Material, label: String, texture_keys: Array) -> Dictionary:
	var m := mat as StandardMaterial3D
	if mat == null:
		m = StandardMaterial3D.new()
	if m == null or m.get_class() != "StandardMaterial3D":
		return {"error": "%s: only StandardMaterial3D is supported (got %s)" % [label, mat.get_class() if mat != null else "?"]}
	var defaults := StandardMaterial3D.new()
	for p in m.get_property_list():
		var pname: String = p.name
		if not (int(p.usage) & PROPERTY_USAGE_STORAGE) or IGNORED.has(pname) or WHITELIST.has(pname):
			continue
		if m.get(pname) != defaults.get(pname):
			return {"error": "%s: material property '%s' is not allowed" % [label, pname]}
	if m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED and m.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
		return {"error": "%s: transparency mode %d is not allowed (opaque or alpha scissor only)" % [label, m.transparency]}
	if not CULL_ALLOWED.has(m.cull_mode):
		return {"error": "%s: cull mode %d is not allowed (back or disabled)" % [label, m.cull_mode]}
	if m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR and absf(m.alpha_scissor_threshold - 0.5) > 1e-6:
		return {"error": "%s: alpha_scissor_threshold must be 0.5" % label}
	var props := {}
	for name in WHITELIST:
		var v: Variant = m.get(name)
		props[name] = snappedf(v, 0.000001) if typeof(v) == TYPE_FLOAT else v
	var key := m.resource_name
	var texture := ""
	if key != "":
		if not key.is_valid_filename() or key.contains("/") or key.contains(" ") or key.contains("."):
			return {"error": "%s: material name '%s' is not a safe key" % [label, key]}
		if texture_keys.has(key):
			texture = key
	elif m.albedo_texture != null:
		return {"error": "%s: a textured material needs resource_name = manifest texture key" % label}
	if m.albedo_texture != null and texture == "":
		return {"error": "%s: albedo_texture material '%s' does not match a manifest texture key" % [label, key]}
	if key == "":
		key = "m_" + _props_hash(props).substr(0, 8)
	var alpha := "cutout" if m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR else "opaque"
	return {"key": key, "props": props, "alpha_mode": alpha, "texture": texture, "props_hash": _props_hash(props)}


static func _props_hash(props: Dictionary) -> String:
	var text := ""
	for name in WHITELIST:
		text += "%s=%s\n" % [name, var_to_str(props[name])]
	return text.sha256_text()


## texture_res_path: res:// path of the LOW png, or "" for untextured materials.
static func tres_text(desc: Dictionary, texture_res_path: String) -> String:
	var defaults := StandardMaterial3D.new()
	var out := "[gd_resource type=\"StandardMaterial3D\" format=3]\n\n"
	if texture_res_path != "":
		out += "[ext_resource type=\"Texture2D\" path=\"%s\" id=\"1_tex\"]\n\n" % texture_res_path
	out += "[resource]\n"
	var props: Dictionary = desc.props
	var cutout: bool = desc.alpha_mode == "cutout"
	for name in WHITELIST:
		if name == "alpha_scissor_threshold" and not cutout:
			continue
		if not cutout and name == "transparency":
			continue
		if props[name] != defaults.get(name) or name == "alpha_scissor_threshold" or name == "transparency":
			out += "%s = %s\n" % [name, _fmt(props[name])]
	if texture_res_path != "":
		out += "albedo_texture = ExtResource(\"1_tex\")\n"
	return out


static func _fmt(v: Variant) -> String:
	if typeof(v) != TYPE_FLOAT:
		return var_to_str(v)
	var s := "%.6f" % v
	while s.ends_with("0") and not s.ends_with(".0"):
		s = s.substr(0, s.length() - 1)
	return s
