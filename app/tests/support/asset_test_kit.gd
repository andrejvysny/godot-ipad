class_name AssetTestKit
extends RefCounted
## Shared fixtures of the AssetStudio provider tests: the tiny contract GLBs, remote bindings built from the
## contract descriptors, hostile GLB builders and a pre-populated exact cache (no network anywhere).

const GLB_V1 := "res://tests/fixtures/primitive_prop.portable.glb.bytes"
const GLB_V2 := "res://tests/fixtures/primitive_prop_v2.portable.glb.bytes"
const SERVER := "6f1c2a52-3c2e-4d4b-9a57-0b6f6f0c1d2e"
const LIBRARY := "prj_0000000000000001"
const ASSET := "ast_00000000000000aa"
const DELIVERY := "dlv_00000000000000d1"
const ARTIFACT := "art_v3j2qb6aa90np9ta"
const V1_ID := "ver_00000000000000v1"
const V2_ID := "ver_00000000000000v2"


static func glb(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path)


static func descriptor_text(name: String) -> String:
	return FileAccess.get_file_as_string(ContractFiles.path("fixtures/descriptors/" + name))


## {"binding": AssetBinding, "manifest": PackedByteArray, "glb": PackedByteArray}: a binding of the contract
## descriptor `descriptor_file` at `version_id`, whose pin names the manifest this kit builds for `glb_bytes`.
static func remote(descriptor_file: String, version_id: String, glb_bytes: PackedByteArray, scatter: bool = false) -> Dictionary:
	var text := descriptor_text(descriptor_file)
	var ref := {"server_id": SERVER, "library_id": LIBRARY, "asset_id": ASSET, "version_id": version_id}
	var sha := CanonicalEncoder.sha256_hex(text.to_utf8_buffer())
	var manifest := _manifest(ref, sha, glb_bytes)
	var b := AssetBinding.new()
	b.provider = AssetBinding.PROVIDER_ASSETSTUDIO
	b.asset_ref = ref
	b.asset_key = AssetBinding.Canonical.asset_key(SERVER, LIBRARY, ASSET, version_id)
	b.descriptor_json = text
	b.descriptor_sha256 = sha
	b.deliveries = {"portable_glb_v1": {"delivery_id": DELIVERY, "manifest_sha256": CanonicalEncoder.sha256_hex(manifest),
		"profile_id": "portable-default", "profile_version": "1.0.0"}}
	b.set_policy(scatter, "0.5", "2", "-0.1", "0.5")
	b.finalize()
	return {"binding": b, "manifest": manifest, "glb": glb_bytes}


static func _manifest(ref: Dictionary, descriptor_sha: String, glb_bytes: PackedByteArray) -> PackedByteArray:
	return JSON.stringify({"asset_ref": ref, "delivery_id": DELIVERY, "dependencies": [], "descriptor_sha256": descriptor_sha,
		"entrypoint": "portable.glb", "files": [{"artifact_id": ARTIFACT, "media_type": "model/gltf-binary", "path": "portable.glb",
		"sha256": CanonicalEncoder.sha256_hex(glb_bytes), "size": glb_bytes.size()}],
		"preparer": {"name": "assetstudio-fixtures", "version": "1.0.0"}, "profile_id": "portable-default",
		"profile_version": "1.0.0", "representation": "portable_glb_v1", "required_capabilities": [],
		"schema_version": 1}).to_utf8_buffer()


## Installs the blobs, documents and reference index of `item` (a remote() result) in an ASBlobCache.
static func seed(cache: RefCounted, item: Dictionary) -> void:
	var b: AssetBinding = item.binding
	var bytes: PackedByteArray = item.glb
	var sha := CanonicalEncoder.sha256_hex(bytes)
	DirAccess.make_dir_recursive_absolute(str(cache.call("staging_path", sha)).get_base_dir())
	var f := FileAccess.open(str(cache.call("staging_path", sha)), FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	cache.call("install_from_staging", cache.call("staging_path", sha), sha, bytes.size())
	cache.call("store_document", "descriptors", b.descriptor_sha256, b.descriptor_json.to_utf8_buffer())
	var manifest_sha := CanonicalEncoder.sha256_hex(item.manifest)
	cache.call("store_document", "manifests", manifest_sha, item.manifest)
	cache.call("write_ref_index", b.asset_key, {"asset_key": b.asset_key, "entries": {"portable_glb_v1": {
		"descriptor_sha256": b.descriptor_sha256, "delivery_id": DELIVERY, "manifest_sha256": manifest_sha}}})


## GLB bytes of a container with `json` and an optional BIN chunk (both 4-byte padded).
static func build_glb(json: Dictionary, bin: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var text := JSON.stringify(json).to_utf8_buffer()
	while text.size() % 4 != 0:
		text.append(0x20)
	var padded := bin.duplicate()
	while padded.size() % 4 != 0:
		padded.append(0)
	var out := PackedByteArray()
	out.resize(12)
	out.encode_u32(0, 0x46546C67)
	out.encode_u32(4, 2)
	var chunk := PackedByteArray()
	chunk.resize(8)
	chunk.encode_u32(0, text.size())
	chunk.encode_u32(4, 0x4E4F534A)
	out.append_array(chunk)
	out.append_array(text)
	if not padded.is_empty():
		chunk.encode_u32(0, padded.size())
		chunk.encode_u32(4, 0x004E4942)
		out.append_array(chunk)
		out.append_array(padded)
	out.encode_u32(8, out.size())
	return out


## The JSON of the one-box fixture GLB, for hostile variants.
static func fixture_json() -> Dictionary:
	var bytes := glb(GLB_V1)
	return JSON.parse_string(bytes.slice(20, 20 + bytes.decode_u32(12)).get_string_from_utf8())


static func fixture_bin() -> PackedByteArray:
	var bytes := glb(GLB_V1)
	var at := 20 + bytes.decode_u32(12)
	return bytes.slice(at + 8, at + 8 + bytes.decode_u32(at))


## A header-only PNG of `w` x `h` (enough for the validator, which reads the IHDR).
static func png_header(w: int, h: int) -> PackedByteArray:
	var b := PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82])
	for v: int in [w, h]:
		b.append_array(PackedByteArray([(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255]))
	b.append_array(PackedByteArray([8, 6, 0, 0, 0]))
	return b


## GLB bytes exported by GLTFDocument from a scene: a sphere of `segments` x `rings` with the given material.
static func sphere_glb(segments: int, rings: int, material: Material = null) -> PackedByteArray:
	var sphere := SphereMesh.new()
	sphere.radial_segments = segments
	sphere.rings = rings
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = sphere
	sphere.material = material
	root.add_child(mi)
	mi.owner = root
	var state := GLTFState.new()
	var doc := GLTFDocument.new()
	doc.append_from_scene(root, state)
	var bytes := doc.generate_buffer(state)
	root.free()
	return bytes
