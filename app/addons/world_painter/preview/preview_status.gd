class_name PreviewStatus
extends RefCounted
## The child's `status` and `snapshot_frozen` messages (ADR 0016 P3): built by the child, sanitized by the editor so
## the dock never shows or stores anything outside this shape. Everything is bounded (strings 256, lists 32).

const MAX_STR := 256
const MAX_MISSING := 32
const MAX_PATH := 1024


## Child side: the status message from live values.
static func build(listener: LiveListener, replica: LiveReplica, extra: Dictionary) -> Dictionary:
	var info := listener.pairing_info()
	var missing: Array = []
	var visual_ready := true
	var revision := -1
	var hash := ""
	var stats := {}
	if replica != null and replica.document != null:
		revision = replica.revision()
		hash = replica.authored_hash()
		visual_ready = bool(extra.get("visual_ready", true))
		for id: String in (extra.get("missing", {}) as Dictionary):
			if missing.size() < MAX_MISSING:
				missing.append({"binding_id": id, "reason": str(extra.missing[id])})
		stats = replica.stats
	return {"type": "status",
		"listener": {"port": listener.port(), "bind": listener.bind_address(),
			"allow_insecure_lan": listener.allow_insecure_lan},
		"pairing": {"state": info.state, "token": info.token, "expires_in_ms": info.expires_in_ms},
		"session": {"writer": listener.writer_connected(), "paired": listener.has_credential(),
			"overlay": bool(extra.get("overlay", false)), "error": str(extra.get("error", ""))},
		"revision": revision, "authored_hash": hash, "durable_revision": -1,
		"visual_ready": visual_ready, "missing": missing,
		"stats": {"snapshots": int(stats.get("snapshots", 0)), "commits": int(stats.get("commits", 0)),
			"previews": int(stats.get("previews", 0)), "resyncs": int(stats.get("resyncs", 0))}}


## Editor side: a clean copy with defaults for anything missing or of the wrong type.
static func sanitize(m: Dictionary) -> Dictionary:
	var listener: Dictionary = _dict(m.get("listener"))
	var pairing: Dictionary = _dict(m.get("pairing"))
	var session: Dictionary = _dict(m.get("session"))
	var stats: Dictionary = _dict(m.get("stats"))
	var missing: Array = []
	var rows: Variant = m.get("missing")
	if typeof(rows) == TYPE_ARRAY:
		for row: Variant in rows:
			if missing.size() < MAX_MISSING and typeof(row) == TYPE_DICTIONARY:
				missing.append({"binding_id": _str(row.get("binding_id")), "reason": _str(row.get("reason"))})
	return {"listener": {"port": _int(listener.get("port")), "bind": _str(listener.get("bind")),
			"allow_insecure_lan": _bool(listener.get("allow_insecure_lan"))},
		"pairing": {"state": _str(pairing.get("state")), "token": _hash(pairing.get("token")),
			"expires_in_ms": _int(pairing.get("expires_in_ms"))},
		"session": {"writer": _bool(session.get("writer")), "paired": _bool(session.get("paired")),
			"overlay": _bool(session.get("overlay")), "error": _str(session.get("error"))},
		"revision": _int(m.get("revision", -1)), "authored_hash": _hash(m.get("authored_hash")),
		"durable_revision": _int(m.get("durable_revision", -1)), "visual_ready": _bool(m.get("visual_ready")),
		"missing": missing,
		"stats": {"snapshots": _int(stats.get("snapshots")), "commits": _int(stats.get("commits")),
			"previews": _int(stats.get("previews")), "resyncs": _int(stats.get("resyncs"))}}


## `path` is an absolute directory (it may exceed MAX_STR); the editor validates it against the session directory.
static func sanitize_frozen(m: Dictionary) -> Dictionary:
	var path: Variant = m.get("path")
	return {"id": _int(m.get("id")), "error": _str(m.get("error")),
		"path": (path as String).left(MAX_PATH) if typeof(path) == TYPE_STRING else "",
		"revision": _int(m.get("revision", -1)), "authored_hash": _hash(m.get("authored_hash")),
		"source_snapshot_hash": _hash(m.get("source_snapshot_hash"))}


static func _dict(v: Variant) -> Dictionary:
	return v if typeof(v) == TYPE_DICTIONARY else {}


static func _str(v: Variant) -> String:
	return (v as String).left(MAX_STR) if typeof(v) == TYPE_STRING else ""


static func _bool(v: Variant) -> bool:
	return typeof(v) == TYPE_BOOL and v


static func _int(v: Variant) -> int:
	return int(v) if typeof(v) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(v)) else 0


static func _hash(v: Variant) -> String:
	return v if LiveIds.is_hash(v) else ""
