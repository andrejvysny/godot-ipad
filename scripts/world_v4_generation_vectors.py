"""generation-vectors.json: Python reference of the Apply identities (ADR 0017 A2, INT-SPEC-1.1 section 11):
source_snapshot_hash, consumer-profile hash and generation_id. The GDScript SnapshotIdentity must reproduce every
value (app/tests/unit/test_snapshot_identity.gd is the GDScript side). Written ASCII-only."""
from __future__ import annotations

import hashlib
import io
import json
import struct
import zipfile
from typing import Any

from worldpoc_locks import canonical_v1

SNAPSHOT_MAGIC = b"WPSNAPSHOT1\n"
BAKE_MAGIC = b"WPBAKE1\n"
PIN_KEYS = ("installer_version", "godot_build", "terrain3d_build", "assetstudio_pin", "world_painter_pin")


def lp(text: str) -> bytes:
	raw = text.encode("utf-8")
	return struct.pack("<I", len(raw)) + raw


def snapshot_hash(digests: dict[str, str]) -> str:
	"""digests: relative path -> sha256 hex. Paths in code point order."""
	out = SNAPSHOT_MAGIC
	for path in sorted(digests):
		out += lp(path) + bytes.fromhex(digests[path])
	return hashlib.sha256(out).hexdigest()


def profile_hash(profile: dict[str, Any]) -> str:
	return hashlib.sha256(canonical_v1(profile)).hexdigest()


def generation_id(snapshot_hex: str, profile_hex: str, pins: dict[str, str]) -> str:
	out = BAKE_MAGIC + bytes.fromhex(snapshot_hex) + bytes.fromhex(profile_hex)
	for key in PIN_KEYS:
		out += lp(pins[key])
	return hashlib.sha256(out).hexdigest()


def _sha(text: str) -> str:
	return hashlib.sha256(text.encode()).hexdigest()


def _snapshot_cases() -> list[dict[str, Any]]:
	small = {"manifest.json": _sha("manifest"), "objects.json": _sha("objects")}
	regions = {"manifest.json": _sha("m"), "asset_locks.json": _sha("a"), "objects.json": _sha("o"),
		"paths.bin": _sha("p"), "scatter.bin": _sha("s"), "regions/r_-1_-1.height.f32le": _sha("h-1"),
		"regions/r_0_0.height.f32le": _sha("h0"), "regions/r_10_0.height.f32le": _sha("h10")}
	return [{"name": n, "digests": d, "source_snapshot_hash": snapshot_hash(d)}
		for n, d in (("manifest_and_objects", small), ("code_point_order_with_regions", regions), ("empty", {}))]


def _profiles() -> list[dict[str, Any]]:
	profiles = [
		{"accepted_world_root": "res://worlds", "scatter_collision_bindings": [], "terrain_mapping_sha256": _sha("default")},
		{"accepted_world_root": "res://painted_worlds", "scatter_collision_bindings": ["b" + "0" * 32, "b" + "1" * 32],
			"terrain_mapping_sha256": _sha("consumer-mapping")},
	]
	return [{"profile": p, "canonical_json": canonical_v1(p).decode(), "consumer_profile_hash": profile_hash(p)} for p in profiles]


def _generation_cases(snaps: list[dict[str, Any]], profiles: list[dict[str, Any]]) -> list[dict[str, Any]]:
	base = {"installer_version": "1.0.0", "godot_build": "ed1daf0bf", "terrain3d_build": "1.0.2-stable@0077405b",
		"assetstudio_pin": _sha("assetstudio-archive"), "world_painter_pin": "0.1.0:" + _sha("addon-tree")}
	other = dict(base, godot_build="ffffffff0")
	cases = []
	for name, snap, prof, pins in (("base", snaps[0], profiles[0], base), ("other_godot_build", snaps[0], profiles[0], other),
			("other_profile", snaps[0], profiles[1], base), ("other_snapshot", snaps[1], profiles[0], base)):
		gid = generation_id(snap["source_snapshot_hash"], prof["consumer_profile_hash"], pins)
		cases.append({"name": name, "source_snapshot_hash": snap["source_snapshot_hash"],
			"consumer_profile_hash": prof["consumer_profile_hash"], "pins": pins, "generation_id": gid, "directory_name": gid[:32]})
	return cases


def _fixture_cases(files: dict[str, bytes]) -> list[dict[str, Any]]:
	out = []
	for name in ("one_bundled_object", "holes", "remote_scatter"):
		with zipfile.ZipFile(io.BytesIO(files[name + ".worldpoc"])) as z:
			digests = {i.filename: hashlib.sha256(z.read(i)).hexdigest() for i in z.infolist() if not i.is_dir()}
		out.append({"fixture": name + ".worldpoc", "files": len(digests), "source_snapshot_hash": snapshot_hash(digests)})
	return out


def vectors(files: dict[str, bytes]) -> dict[str, Any]:
	snaps = _snapshot_cases()
	profiles = _profiles()
	return {
		"schema": "world-painter/world-v4/generation-vectors",
		"note": "str = u32 little-endian byte length + UTF-8. source_snapshot_hash = sha256('WPSNAPSHOT1\\n' + for each file "
			"in code point order of its relative path: str(path) + raw sha256) over manifest.json and every declared payload. "
			"consumer_profile_hash = sha256(canonical_v1(profile)). generation_id = sha256('WPBAKE1\\n' + raw snapshot hash + "
			"raw profile hash + str(installer_version) + str(godot_build) + str(terrain3d_build) + str(assetstudio_pin) + "
			"str(world_painter_pin)); the directory name is its first 32 hex digits.",
		"snapshots": snaps,
		"profiles": profiles,
		"generations": _generation_cases(snaps, profiles),
		"fixture_snapshots": _fixture_cases(files),
	}


def vectors_json(files: dict[str, bytes]) -> bytes:
	return (json.dumps(vectors(files), indent=1, ensure_ascii=True, sort_keys=True) + "\n").encode("ascii")
