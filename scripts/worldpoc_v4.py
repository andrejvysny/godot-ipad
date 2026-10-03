"""Schema 4 records, scatter.bin v2 and authored hash V4 (docs/world-format.md §12, ADR 0014,
contracts/world-painter/world-v4). Python stdlib only; mirrors the schema 3 helpers in worldpoc_values.py and
worldpoc_scatter.py. Parsers return (value, error) or error lists and never raise for invalid content."""
from __future__ import annotations

import hashlib
import math
import struct
from typing import Any

from worldpoc_constants import (
	AUTHORED_MAGIC_V4,
	BINDING_ID_RE,
	LEGACY_LAYOUT,
	REGION_SAMPLES,
	SAMPLE_SPACING,
	SCATTER_FLAG_TILT,
	SCATTER_INSTANCE_BYTES,
	SCATTER_MAGIC,
	SCATTER_VERSION_V2,
	SCHEMA_VERSION_LOCK,
	YAW_MAX,
	Layout,
	layout_extent,
	limits_for_schema,
)
from worldpoc_locks import in_range, parse_decimal
from worldpoc_scatter import _Reader, _header, _in_extent, _pack_str
from worldpoc_values import _Stream, f64_hex, show


def make_object_record_v4(object_id: str, binding: str, position: list[float], rotation_xyzw: list[float],
		uniform_scale: float, grounding: str, height_offset_m: float, origin: str = "MANUAL",
		scatter_operation_id: str | None = None) -> dict[str, Any]:
	"""Schema 4 objects.json record: binding_id replaces asset_id/asset_version; f64le bits as in schema 3."""
	return {
		"object_id": object_id,
		"binding_id": binding,
		"position": list(position),
		"rotation_xyzw": list(rotation_xyzw),
		"uniform_scale": uniform_scale,
		"grounding": grounding,
		"height_offset_m": height_offset_m,
		"origin": origin,
		"scatter_operation_id": scatter_operation_id,
		"f64le": {
			"position": [f64_hex(v) for v in position],
			"rotation_xyzw": [f64_hex(v) for v in rotation_xyzw],
			"uniform_scale": f64_hex(uniform_scale),
			"height_offset_m": f64_hex(height_offset_m),
		},
	}


# --- scatter.bin version 2 (binary-formats.md) ------------------------------------------------
def parse_scatter_v2(data: bytes, max_instances: int, layout: Layout = LEGACY_LAYOUT) -> tuple[dict[str, Any] | None, str]:
	"""Returns ({"bindings": [binding_id], "instances": [instance dict with binding_id]}, "")."""
	try:
		return _parse_scatter_v2(data, max_instances, layout), ""
	except ValueError as e:
		return None, "scatter.bin: %s" % e


def _parse_scatter_v2(data: bytes, max_instances: int, layout: Layout) -> dict[str, Any]:
	r = _Reader(data)
	_header(r, SCATTER_MAGIC, SCATTER_VERSION_V2, "scatter.bin")
	binding_count = r.u32()
	if binding_count > limits_for_schema(SCHEMA_VERSION_LOCK)["max_bindings"]:
		raise ValueError("%d bindings exceed the limit" % binding_count)
	table: list[str] = []
	prev = b""
	for i in range(binding_count):
		bid = r.str_()
		key = bid.encode("utf-8")
		if not BINDING_ID_RE.match(bid):
			raise ValueError("binding table entry %d %s is not a binding_id" % (i, show(bid)))
		if i > 0 and key == prev:
			raise ValueError("duplicate binding_id %s in the binding table" % bid)
		if key < prev:
			raise ValueError("binding table is not sorted by binding_id (%s)" % bid)
		prev = key
		table.append(bid)
	count = r.u32()
	if count > max_instances:
		raise ValueError("%d instances exceed the limit of %d" % (count, max_instances))
	need = count * SCATTER_INSTANCE_BYTES
	if r.remaining() < need:
		raise ValueError("truncated data: %d instances need %d bytes, %d remain" % (count, need, r.remaining()))
	if r.remaining() > need:
		raise ValueError("%d trailing bytes after the last instance" % (r.remaining() - need))
	used = [False] * binding_count
	instances: list[dict[str, Any]] = []
	for i in range(count):
		index, flags, x, z, yaw, scale = struct.unpack("<HHffff", r.take(SCATTER_INSTANCE_BYTES))
		tag = "instance %d" % i
		if index >= binding_count:
			raise ValueError("%s binding_index %d is out of range (binding_count %d)" % (tag, index, binding_count))
		if flags & ~SCATTER_FLAG_TILT:
			raise ValueError("%s has unknown flag bits 0x%04x" % (tag, flags))
		if not all(math.isfinite(v) for v in (x, z, yaw, scale)):
			raise ValueError("%s has a non-finite value" % tag)
		if not _in_extent(x, z, layout):
			raise ValueError("%s position (%r, %r) is outside the world extent" % (tag, x, z))
		if abs(yaw) > YAW_MAX:
			raise ValueError("%s yaw %r is outside +-%r" % (tag, yaw, YAW_MAX))
		used[index] = True
		instances.append({"binding_id": table[index], "flags": flags, "x": x, "z": z, "yaw_rad": yaw, "scale": scale})
	for i, u in enumerate(used):
		if not u:
			raise ValueError("binding table entry %s is not referenced by any instance" % table[i])
	return {"bindings": table, "instances": instances}


def write_scatter_v2(instances: list[dict[str, Any]]) -> bytes:
	"""Canonical scatter.bin v2: minimal binding table sorted byte-wise; instance order preserved.
	Instances need binding_id, x, z, yaw_rad, scale and optionally flags."""
	table = sorted({i["binding_id"] for i in instances}, key=lambda b: b.encode("utf-8"))
	index = {b: n for n, b in enumerate(table)}
	out = [SCATTER_MAGIC, struct.pack("<II", SCATTER_VERSION_V2, len(table))]
	out += [_pack_str(b) for b in table]
	out.append(struct.pack("<I", len(instances)))
	for inst in instances:
		out.append(struct.pack("<HHffff", index[inst["binding_id"]], inst.get("flags", 0), inst["x"], inst["z"],
			inst["yaw_rad"], inst["scale"]))
	return b"".join(out)


# --- records and scatter against the lock -------------------------------------------------------
def effective_limits(binding: dict[str, Any]) -> tuple[tuple[float, float], tuple[float, float], bool]:
	"""((scale lo, hi), (height lo, hi), scatter_allowed) of a structurally valid binding's policy."""
	p = binding["policy"]
	return ((parse_decimal(p["scale_range"][0]), parse_decimal(p["scale_range"][1])),
		(parse_decimal(p["height_offset_range_m"][0]), parse_decimal(p["height_offset_range_m"][1])),
		p["scatter_allowed"])


def check_record_against_lock(rec: dict[str, Any], bindings: dict[str, dict[str, Any]] | None,
		layout: Layout = LEGACY_LAYOUT) -> list[str]:
	"""`bindings` is None when the lock itself failed (its error is reported once; no cascade here)."""
	tag = " (object %s)" % rec["object_id"]
	errors: list[str] = []
	b = bindings.get(rec["binding_id"]) if bindings is not None else None
	if bindings is None:
		pass
	elif b is None:
		errors.append("unknown binding %s%s" % (rec["binding_id"], tag))
	else:
		scale, height, _ = effective_limits(b)
		if not in_range(rec["uniform_scale"], *scale):
			errors.append("uniform_scale %r outside the effective policy range %r%s" % (rec["uniform_scale"], list(scale), tag))
		if not in_range(rec["height_offset_m"], *height):
			errors.append("height_offset_m %r outside the effective policy range %r%s" % (rec["height_offset_m"], list(height), tag))
	x, _, z = rec["position"]
	x_min, x_max, z_min, z_max = layout_extent(layout)
	if not (x_min <= x <= x_max and z_min <= z <= z_max):
		errors.append("position X/Z (%r, %r) outside the world extent%s" % (x, z, tag))
	return errors


def check_scatter_lock(scatter: dict[str, Any], bindings: dict[str, dict[str, Any]] | None) -> list[str]:
	if bindings is None:
		return []
	errors: list[str] = []
	for bid in scatter["bindings"]:
		if bid not in bindings:
			errors.append("scatter binding %s is not in asset_locks.json (unknown binding)" % bid)
		elif not bindings[bid]["policy"]["scatter_allowed"]:
			errors.append("scatter binding %s is not scatter_allowed" % bid)
	if errors:
		return errors
	for i, inst in enumerate(scatter["instances"]):
		scale, _, _ = effective_limits(bindings[inst["binding_id"]])
		if not (inst["scale"] > 0.0 and in_range(inst["scale"], *scale)):
			return ["scatter instance %d scale %r outside the effective policy range %r of binding %s"
				% (i, inst["scale"], list(scale), inst["binding_id"])]
	return errors


def referenced_bindings(records: list[dict[str, Any]], scatter: dict[str, Any]) -> set[str]:
	return {r["binding_id"] for r in records} | set(scatter.get("bindings", []))


# --- authored hash V4 (authored-hash-v4.md) -----------------------------------------------------
def authored_hash_v4(lock_bytes: bytes, rules: dict[str, Any],
		region_digests: dict[tuple[int, int], tuple[bytes, bytes, bytes]], scatter_bytes: bytes,
		paths_bytes: bytes, records: list[dict[str, Any]], layout: Layout) -> str:
	"""`records` hold exact float64 values (from f64le bits) and binding_id; digests are raw 32-byte SHA-256."""
	s = _Stream()
	s.raw(AUTHORED_MAGIC_V4)
	s.u32(SCHEMA_VERSION_LOCK)
	s.raw(hashlib.sha256(lock_bytes).digest())
	s.f64(SAMPLE_SPACING)
	s.u32(REGION_SAMPLES)
	for v in (layout[0][0], layout[0][1]):
		s.i32(v)
	for v in (layout[1][0], layout[1][1]):
		s.u32(v)
	s.u8(1 if rules["rock_enabled"] else 0)
	s.i32(int(rules["rock_slope_deg"]))
	s.u8(1 if rules["sand_enabled"] else 0)
	s.i32(int(rules["sand_height_dm"]))
	locs = sorted(region_digests, key=lambda l: (l[1], l[0]))
	s.u32(len(locs))
	for loc in locs:
		s.i32(loc[0])
		s.i32(loc[1])
		for digest in region_digests[loc]:
			s.raw(digest)
	s.raw(hashlib.sha256(scatter_bytes).digest())
	s.raw(hashlib.sha256(paths_bytes).digest())
	ordered = sorted(records, key=lambda r: r["object_id"].encode("utf-8"))
	s.u32(len(ordered))
	for r in ordered:
		s.str_(r["object_id"])
		s.str_(r["binding_id"])
		for v in r["position"]:
			s.f64(v)
		for v in r["rotation_xyzw"]:
			s.f64(v)
		s.f64(r["uniform_scale"])
		s.str_(r["grounding"])
		s.f64(r["height_offset_m"])
		s.str_(r["origin"])
		s.str_(r["scatter_operation_id"] or "")
	return s.digest_hex()
