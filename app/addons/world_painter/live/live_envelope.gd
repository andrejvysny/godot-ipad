class_name LiveEnvelope
extends RefCounted
## Strict build/parse of live-protocol text messages (INT-SPEC-1.1 §10.2, ADR 0015 L3). UTF-8 JSON, at most
## 64 KiB (8 KiB before authentication). Unknown envelope keys, unknown types and unknown or missing payload keys
## are errors; numbers are normalized to int; nothing is ever deserialized into Godot objects.
## Results are Dictionaries {ok, error, ...}; expected failures never push_error.

const PROTOCOL := "world-painter-live"
const VERSION := 1
const MAX_TEXT_BYTES := 65536
const MAX_PRE_AUTH_BYTES := 8192
const MAX_STR := 1024
const MAX_LIST := 64
const MAX_INT := 9007199254740992  # 2^53: larger JSON numbers are not exact integers
const MAX_SNAPSHOT_BYTES := 276824064  # WorldLimits schema 4 archive limit (264 MiB)
const MAX_CHUNK := 262144
const ENVELOPE_KEYS := ["protocol", "protocol_version", "session_id", "stream_id", "message_id", "type", "payload"]
const BLOB_KINDS := ["snapshot", "commit", "preview"]
const BLOB_FORMATS := ["worldpoc-v4", "world-delta-v1"]

## Payload key sets per type: {key: kind}. Kinds: id (32 hex), hash (64 hex), str, int, bool, strs, ints, flat
## (object of str -> int|bool|str), reasons (object of str -> str), enum:a|b.
const SPECS := {
	"hello": {"req": {"role": "enum:sender|receiver", "protocol_versions": "ints", "auth": "auth", "app": "str",
		"capabilities": "strs"}, "opt": {}},
	"hello_result": {"req": {"accepted": "bool"}, "opt": {"session_credential": "hash", "limits": "flat",
		"receiver": "receiver", "reason": "str"}},
	"resume": {"req": {"world_id": "str", "stream_id": "id", "revision": "int", "authored_hash": "hash"}, "opt": {}},
	"resume_result": {"req": {"mode": "enum:continue|snapshot", "revision": "int", "authored_hash": "hash"}, "opt": {}},
	"blob_begin": {"req": {"transfer_id": "id", "kind": "enum:snapshot|commit|preview",
		"format": "enum:worldpoc-v4|world-delta-v1", "total_bytes": "int", "chunk_size": "int", "chunk_count": "int",
		"sha256": "hash"}, "opt": {"operation_id": "str", "base_revision": "int", "base_authored_hash": "hash",
		"target_revision": "int", "target_authored_hash": "hash", "preview_seq": "int"}},
	"blob_end": {"req": {"transfer_id": "id"}, "opt": {}},
	"blob_abort": {"req": {"transfer_id": "id", "reason": "str"}, "opt": {}},
	"snapshot_ack": {"req": {"world_id": "str", "stream_id": "id", "revision": "int", "authored_hash": "hash",
		"visual_ready": "bool"}, "opt": {}},
	"commit_ack": {"req": {"world_id": "str", "stream_id": "id", "revision": "int", "authored_hash": "hash",
		"visual_ready": "bool"}, "opt": {}},
	"preview_cancel": {"req": {"operation_id": "str"}, "opt": {}},
	"resync_required": {"req": {"reason": "str"}, "opt": {"revision": "int", "authored_hash": "hash"}},
	"assets_needed": {"req": {"binding_ids": "strs"}, "opt": {}},
	"asset_status": {"req": {"ready": "bool", "unavailable": "reasons"}, "opt": {}},
	"ping": {"req": {"nonce": "int"}, "opt": {}},
	"pong": {"req": {"nonce": "int"}, "opt": {}},
	"session_close": {"req": {"reason": "str"}, "opt": {}},
	"error": {"req": {"code": "str", "message": "str"}, "opt": {}},
}


## {ok, text, error}. `payload` must already hold exactly the keys of `type`.
static func build(type: String, session_id: String, stream_id: String, payload: Dictionary,
		message_id: String = "") -> Dictionary:
	var checked := check_payload(type, payload)
	if not checked.ok:
		return _fail(checked.error)
	if not LiveIds.is_id(session_id) or not LiveIds.is_id(stream_id):
		return _fail("session_id and stream_id must be 32 lowercase hex characters")
	var env := {"protocol": PROTOCOL, "protocol_version": VERSION, "session_id": session_id, "stream_id": stream_id,
		"message_id": message_id if message_id != "" else LiveIds.new_id(), "type": type, "payload": checked.payload}
	var text := JSON.stringify(env, "", true)
	var cap := MAX_PRE_AUTH_BYTES if type == "hello" else MAX_TEXT_BYTES
	if text.to_utf8_buffer().size() > cap:
		return _fail("%s message exceeds %d bytes" % [type, cap])
	return {"ok": true, "text": text, "error": ""}


## {ok, error, envelope: {session_id, stream_id, message_id, type, payload}}. Before authentication only a hello
## within 8 KiB is accepted. `expect_session` (when non-empty) must equal the message's session_id.
static func parse(text: String, authenticated: bool, expect_session: String = "") -> Dictionary:
	var cap := MAX_TEXT_BYTES if authenticated else MAX_PRE_AUTH_BYTES
	if text.length() > cap or text.to_utf8_buffer().size() > cap:
		return _fail("message exceeds %d bytes" % cap)
	var json := JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return _fail("message is not a JSON object")
	var env: Dictionary = json.data
	var err := _check_envelope(env)
	if err != "":
		return _fail(err)
	if not authenticated and env.type != "hello":
		return _fail("only hello is accepted before authentication")
	if expect_session != "" and env.session_id != expect_session:
		return _fail("message belongs to another session")
	if typeof(env.payload) != TYPE_DICTIONARY:
		return _fail("payload must be an object")
	var checked := check_payload(env.type, env.payload)
	if not checked.ok:
		return _fail(checked.error)
	return {"ok": true, "error": "", "envelope": {"session_id": env.session_id, "stream_id": env.stream_id,
		"message_id": env.message_id, "type": env.type, "payload": checked.payload}}


static func _check_envelope(env: Dictionary) -> String:
	for k: Variant in env:
		if not ENVELOPE_KEYS.has(k):
			return "unknown envelope key '%s'" % str(k)
	for k: String in ENVELOPE_KEYS:
		if not env.has(k):
			return "envelope is missing '%s'" % k
	if env.protocol != PROTOCOL or typeof(env.protocol_version) not in [TYPE_INT, TYPE_FLOAT] \
			or float(env.protocol_version) != float(VERSION):
		return "unsupported protocol or version"
	for k in ["session_id", "stream_id", "message_id"]:
		if not LiveIds.is_id(env[k]):
			return "envelope %s is not 32 lowercase hex characters" % k
	if typeof(env.type) != TYPE_STRING or not SPECS.has(env.type):
		return "unknown message type '%s'" % str(env.type).left(40)
	return ""


## {ok, error, payload} with ints normalized. Exact key sets: every `req` key present, no key outside req+opt.
static func check_payload(type: String, payload: Dictionary) -> Dictionary:
	if not SPECS.has(type):
		return {"ok": false, "error": "unknown message type '%s'" % type.left(40)}
	var spec: Dictionary = SPECS[type]
	var out := {}
	for k: Variant in payload:
		if not (spec.req.has(k) or spec.opt.has(k)):
			return {"ok": false, "error": "%s: unknown payload key '%s'" % [type, str(k).left(40)]}
	for k: String in spec.req:
		if not payload.has(k):
			return {"ok": false, "error": "%s: missing payload key '%s'" % [type, k]}
	for k: String in payload:
		var kind: String = spec.req[k] if spec.req.has(k) else spec.opt[k]
		var v: Variant = _norm(kind, payload[k])
		if v == null:
			return {"ok": false, "error": "%s: invalid value for '%s'" % [type, k]}
		out[k] = v[0]
	if type == "blob_begin":
		var err := _check_blob_begin(out)
		if err != "":
			return {"ok": false, "error": err}
	return {"ok": true, "error": "", "payload": out}


## null when invalid, else [normalized].
static func _norm(kind: String, v: Variant) -> Variant:
	if kind.begins_with("enum:"):
		return [v] if typeof(v) == TYPE_STRING and kind.substr(5).split("|").has(v) else null
	match kind:
		"id":
			return [v] if LiveIds.is_id(v) else null
		"hash":
			return [v] if LiveIds.is_hash(v) else null
		"str":
			return [v] if typeof(v) == TYPE_STRING and (v as String).length() <= MAX_STR else null
		"int":
			return [int(v)] if _is_uint(v) else null
		"bool":
			return [v] if typeof(v) == TYPE_BOOL else null
		"strs", "ints":
			return _norm_list(kind, v)
		"flat", "reasons":
			return _norm_map(kind, v)
		"auth":
			return _norm_exact(v, {"pairing_token": "hash"}, {"session_credential": "hash"})
		"receiver":
			return _norm_exact(v, {"profile": "str"}, {})
	return null


static func _norm_exact(v: Variant, a: Dictionary, b: Dictionary) -> Variant:
	if typeof(v) != TYPE_DICTIONARY or (v as Dictionary).size() != 1:
		return null
	var key: Variant = (v as Dictionary).keys()[0]
	var spec: Dictionary = a if a.has(key) else b
	if not spec.has(key):
		return null
	var n: Variant = _norm(spec[key], (v as Dictionary)[key])
	return null if n == null else [{key: n[0]}]


static func _norm_list(kind: String, v: Variant) -> Variant:
	if typeof(v) != TYPE_ARRAY or (v as Array).size() > MAX_LIST:
		return null
	var out := []
	for item: Variant in v:
		var n: Variant = _norm("str" if kind == "strs" else "int", item)
		if n == null:
			return null
		out.append(n[0])
	return [out]


static func _norm_map(kind: String, v: Variant) -> Variant:
	if typeof(v) != TYPE_DICTIONARY or (v as Dictionary).size() > MAX_LIST:
		return null
	var out := {}
	for k: Variant in v:
		if typeof(k) != TYPE_STRING or (k as String).length() > MAX_STR:
			return null
		var item: Variant = v[k]
		var n: Variant = _norm("str", item)
		if kind == "flat" and n == null:
			n = _norm("int", item) if typeof(item) != TYPE_BOOL else _norm("bool", item)
		if n == null:
			return null
		out[k] = n[0]
	return [out]


static func _check_blob_begin(p: Dictionary) -> String:
	var total: int = p.total_bytes
	var size: int = p.chunk_size
	if total < 1 or total > MAX_SNAPSHOT_BYTES:
		return "blob_begin: total_bytes out of range"
	if size < 1 or size > MAX_CHUNK:
		return "blob_begin: chunk_size out of range"
	if int(p.chunk_count) != chunks_for(total, size):
		return "blob_begin: chunk_count does not equal ceil(total_bytes / chunk_size)"
	var kind: String = p.kind
	if (kind == "snapshot") != (p.format == "worldpoc-v4"):
		return "blob_begin: format does not match kind"
	var required: Array = []
	if kind == "commit":
		required = ["operation_id", "base_revision", "base_authored_hash", "target_revision", "target_authored_hash"]
	elif kind == "preview":
		required = ["operation_id", "base_revision", "preview_seq"]
	for k: String in required:
		if not p.has(k):
			return "blob_begin: %s transfer needs '%s'" % [kind, k]
	var allowed: Array = ["transfer_id", "kind", "format", "total_bytes", "chunk_size", "chunk_count", "sha256"] + required
	for k: String in p:
		if not allowed.has(k):
			return "blob_begin: '%s' is not allowed for a %s transfer" % [k, kind]
	return ""


@warning_ignore("integer_division")
static func chunks_for(total: int, chunk_size: int) -> int:
	return (total + chunk_size - 1) / chunk_size


static func _is_uint(v: Variant) -> bool:
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return false
	var f := float(v)
	return is_finite(f) and f >= 0.0 and f == floorf(f) and f <= float(MAX_INT)


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "text": "", "error": msg}
