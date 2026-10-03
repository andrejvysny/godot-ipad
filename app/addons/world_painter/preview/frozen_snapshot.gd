class_name FrozenSnapshot
extends RefCounted
## Child side of `freeze_snapshot` (ADR 0017 A1): writes the replica's committed document, never the overlay of an
## operation in progress, as a schema 4 generation directory under the session root and describes it. The editor
## copies it into its own staging and re-validates it; later live edits cannot change what was written here.

const KEEP := 2
const DIR := "frozen"


## {type, id, path, revision, authored_hash, source_snapshot_hash} or {type, id, error}. `session_dir` is the
## session's user:// directory.
static func write(replica: LiveReplica, session_dir: String, request_id: int) -> Dictionary:
	var reply := {"type": "snapshot_frozen", "id": request_id}
	if replica == null or replica.document == null:
		reply["error"] = "no committed world has been received yet"
		return reply
	var doc := replica.document
	var root := session_dir.path_join(DIR)
	_prune(root)
	var dir := root.path_join("%016x_%d" % [Time.get_ticks_usec(), doc.document_revision])  # name order = age
	var err := WorldCodec.write_generation(dir, doc, WorldCodec.default_created_with())
	var hashed := SnapshotIdentity.source_snapshot_hash(dir) if err == "" else ["", err]
	if err == "" and hashed[1] == "" and CanonicalEncoder.authored_hash(doc) != replica.authored_hash():
		hashed = ["", "the written snapshot does not reproduce the replica's authored hash"]
	if hashed[1] != "":
		StorageFs.remove_tree(dir)
		reply["error"] = str(hashed[1]).left(200)
		return reply
	reply["path"] = ProjectSettings.globalize_path(dir)
	reply["revision"] = doc.document_revision
	reply["authored_hash"] = replica.authored_hash()
	reply["source_snapshot_hash"] = hashed[0]
	return reply


## Keeps the newest KEEP-1 earlier snapshots (the new one makes KEEP).
static func _prune(root: String) -> void:
	var names := Array(StorageFs.list_dirs(root))  # sorted by name, oldest first
	while names.size() >= KEEP:
		StorageFs.remove_tree(root.path_join(names.pop_front()))
