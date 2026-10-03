class_name FakeAssetProvider
extends RuntimeBackedProvider
## Test provider: GLB bytes per binding id held in memory, with configurable delay, failure, corruption and
## cancellation, going through the same validate/bake/register path as the AssetStudio provider.

var glb_by_binding: Dictionary = {}  # binding_id -> PackedByteArray
var default_glb := PackedByteArray()  # served for a binding without its own bytes
var delay_frames := 0
var fail_with: Dictionary = {}  # binding_id -> error text
var corrupt: Dictionary = {}  # binding_id -> true: the JSON chunk is damaged
var cancel_during_fetch := false  # cancels the token itself while "downloading"
var fetches := 0


func provider_id() -> String:
	return AssetBinding.PROVIDER_ASSETSTUDIO


func _fetch(binding: AssetBinding, token: RefCounted) -> Dictionary:
	fetches += 1
	for i in delay_frames:
		await _next_frame()
		if _cancelled(token):
			return {"ok": false, "error": "cancelled"}
	if cancel_during_fetch:
		token.call("cancel")
		return {"ok": false, "error": "cancelled"}
	var id := binding.binding_id
	if fail_with.has(id):
		return {"ok": false, "error": str(fail_with[id])}
	if not glb_by_binding.has(id) and default_glb.is_empty():
		return {"ok": false, "error": "no bytes for this binding"}
	var bytes: PackedByteArray = (glb_by_binding.get(id, default_glb) as PackedByteArray).duplicate()
	if corrupt.has(id) and bytes.size() > 24:
		bytes[20] = 0x7F
		bytes[21] = 0x7F
	return {"ok": true, "glb": bytes, "error": "", "shas": PackedStringArray()}
