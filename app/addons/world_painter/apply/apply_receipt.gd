class_name ApplyReceipt
extends RefCounted
## The two receipts of a generation (ADR 0017 A4). `apply_receipt.json` is the tracked recipe: every input that
## makes the generation id, plus what the bake must reproduce. The installation receipt
## (.world_painter/receipts/<dir>.json) is machine-local: hashes of the generated files as installed, so a later
## Apply can tell modified generated content from an untouched one.

const CJson := preload("res://addons/assetstudio/core/as_canonical_json.gd")
const SCHEMA := 1
const KEYS := ["schema_version", "world_id", "document_revision", "authored_hash", "source_snapshot_hash",
	"generation_id", "consumer_profile", "consumer_profile_hash", "pins", "dependencies", "source_files", "content"]


static func build(review: ApplyReview, content: Dictionary) -> Dictionary:
	return {"schema_version": SCHEMA, "world_id": review.world_id, "document_revision": review.revision,
		"authored_hash": review.authored_hash, "source_snapshot_hash": review.source_snapshot_hash,
		"generation_id": review.generation_id, "consumer_profile": review.profile,
		"consumer_profile_hash": review.profile_hash, "pins": review.pins, "dependencies": review.dependency_pins(),
		"source_files": hash_tree(review.staged_source_abs()), "content": content}


static func encode(receipt: Dictionary) -> PackedByteArray:
	var enc: RefCounted = CJson.encode(receipt)
	return enc.value if enc.ok else PackedByteArray()


## [Dictionary, ""] or [{}, error].
static func parse(raw: PackedByteArray) -> Array:
	var parsed: RefCounted = CJson.parse_canonical(raw)
	if not parsed.ok or typeof(parsed.value) != TYPE_DICTIONARY:
		return [{}, "apply_receipt.json is missing or not canonical JSON"]
	var d: Dictionary = parsed.value
	for key: String in KEYS:
		if not d.has(key):
			return [{}, "apply_receipt.json lacks '%s'" % key]
	if int(d.schema_version) != SCHEMA or not LiveIds.is_hash(d.generation_id) or not LiveIds.is_hash(d.authored_hash) \
			or not LiveIds.is_hash(d.source_snapshot_hash) or not ApplyLayout.is_world_id(str(d.world_id)):
		return [{}, "apply_receipt.json has invalid identities"]
	return [d, ""]


static func read(generation_abs: String) -> Array:
	return parse(FileAccess.get_file_as_bytes(generation_abs.path_join(ApplyLayout.RECEIPT_FILE)))


## relative path -> sha256 hex of every file below `dir` (.uid and .import files are Godot machine state).
static func hash_tree(dir: String) -> Dictionary:
	var out := {}
	_walk(dir, "", out)
	return out


static func _walk(base: String, rel: String, out: Dictionary) -> void:
	var here := base.path_join(rel) if rel != "" else base
	for f in DirAccess.get_files_at(here):
		if not (f.ends_with(".uid") or f.ends_with(".import")):
			var r := rel.path_join(f) if rel != "" else f
			out[r] = FileAccess.get_sha256(base.path_join(r))
	for d in DirAccess.get_directories_at(here):
		_walk(base, rel.path_join(d) if rel != "" else d, out)


## Bytes of the installation receipt for the generated files below `generated_abs` (hashed where they are staged;
## the commit renames the directory, so the hashes hold for the installed files). The transaction writes them.
static func installation_bytes(generated_abs: String, generation_id: String) -> PackedByteArray:
	return encode({"schema_version": SCHEMA, "generation_id": generation_id, "files": hash_tree(generated_abs),
		"installed_unix": int(Time.get_unix_time_from_system())})


static func installation_rel(dir_name: String) -> String:
	return ApplyLayout.RECEIPTS_REL.path_join(dir_name + ".json")


## {state, detail, installed_unix}: "absent" (no generated directory), "intact", "modified" or "unverifiable" (the
## directory exists but this machine holds no installation receipt for it).
static func generated_state(dir_name: String, generated_abs: String) -> Dictionary:
	if not DirAccess.dir_exists_absolute(generated_abs):
		return {"state": "absent", "detail": "", "installed_unix": 0}
	var parsed: RefCounted = CJson.parse_strict_utf8(FileAccess.get_file_as_bytes(ApplyLayout.receipt_abs(dir_name)))
	if not parsed.ok or typeof(parsed.value) != TYPE_DICTIONARY or typeof((parsed.value as Dictionary).get("files")) != TYPE_DICTIONARY:
		return {"state": "unverifiable", "detail": "no installation receipt for %s on this machine" % dir_name, "installed_unix": 0}
	var expected: Dictionary = parsed.value.files
	var actual := hash_tree(generated_abs)
	var problems := PackedStringArray()
	for path: String in expected:
		if not actual.has(path):
			problems.append("%s is missing" % path)
		elif actual[path] != expected[path]:
			problems.append("%s was modified" % path)
	for path: String in actual:
		if not expected.has(path):
			problems.append("%s was added" % path)
	var state := "modified" if not problems.is_empty() else "intact"
	return {"state": state, "detail": "; ".join(problems.slice(0, 3)), "installed_unix": int(parsed.value.get("installed_unix", 0))}
