class_name ObjectChunkCache
extends RefCounted
## Incremental encoder state for checkpoint snapshots (docs/rendering-performance-spec.md §16.6).
## Keeps, per object, the bytes of its objects.json entry and of its canonical hash encoding, in
## sorted id order, so a snapshot re-encodes only the objects changed since the previous one.
## Main thread only. Relies on the WorldDocument convention that stored records are replace-only
## (never mutated in place) and on the document's put/remove journal; a record count mismatch
## (a direct write to `objects`) falls back to a full rebuild. The returned arrays are shallow
## copies of immutable byte arrays, safe to hand to the storage worker.

const INDENT := "    "  # an objects.json entry sits two levels deep

## Records encoded by the most recent chunks() call (diagnostics, tests).
var last_encoded := 0

var _doc_id := 0
var _ids: Array = []  # sorted object ids, String
var _json: Array = []  # PackedByteArray per id: indented JSON text of the entry
var _canon: Array = []  # PackedByteArray per id: CanonicalEncoder.encode_object bytes


## {json: Array, canon: Array} for `doc`'s objects in sorted id order.
func chunks(doc: WorldDocument) -> Dictionary:
	last_encoded = 0
	var changes: Variant = doc.take_object_changes(get_instance_id())
	if changes == null or doc.get_instance_id() != _doc_id:
		_rebuild(doc)
	else:
		_apply(doc, changes)
		if _ids.size() != doc.objects.size():
			_rebuild(doc)
	_doc_id = doc.get_instance_id()
	return {"json": _json.duplicate(), "canon": _canon.duplicate()}


static func json_chunk(rec: ObjectRecord) -> PackedByteArray:
	var text := JSON.stringify(rec.to_dict(), "  ", true, true)
	return (INDENT + text.replace("\n", "\n" + INDENT)).to_utf8_buffer()


static func canon_chunk(rec: ObjectRecord) -> PackedByteArray:
	var e := CanonicalEncoder.new()
	CanonicalEncoder.encode_object(e, rec)
	return e.bytes()


func _rebuild(doc: WorldDocument) -> void:
	_ids = Array(doc.sorted_object_ids())
	_json = []
	_canon = []
	_json.resize(_ids.size())
	_canon.resize(_ids.size())
	for i in _ids.size():
		var rec := doc.get_object(_ids[i])
		_json[i] = json_chunk(rec)
		_canon[i] = canon_chunk(rec)
	last_encoded = _ids.size()


func _apply(doc: WorldDocument, changes: Dictionary) -> void:
	for id: String in changes:
		var at := _ids.bsearch(id, true)
		var known: bool = at < _ids.size() and _ids[at] == id
		var rec := doc.get_object(id)
		if rec == null:
			if known:
				_ids.remove_at(at)
				_json.remove_at(at)
				_canon.remove_at(at)
			continue
		last_encoded += 1
		if known:
			_json[at] = json_chunk(rec)
			_canon[at] = canon_chunk(rec)
		else:
			_ids.insert(at, id)
			_json.insert(at, json_chunk(rec))
			_canon.insert(at, canon_chunk(rec))
