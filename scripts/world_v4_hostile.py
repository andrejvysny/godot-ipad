"""Hostile schema 4 packages (contracts/world-painter/world-v4/fixtures/invalid): each is a valid world with exactly
one structural rule broken. Returns {name: (package bytes, expected error substring)}."""
from __future__ import annotations

import hashlib
import io
import json
import zipfile
from pathlib import Path
from typing import Any

import worldpoc_format as wf
import world_v4_builders as B
from worldpoc_locks import bundled_binding, with_binding_id
from worldpoc_write import derive_dependencies, lock_bytes_of

BOGUS = "b" + "0123456789abcdef" * 2


def _bundled(asset_id: str, **policy: Any) -> dict[str, Any]:
	b = bundled_binding(wf.load_trusted_catalog(), asset_id)
	if policy:
		b = with_binding_id(dict(b, policy=dict(b["policy"], **policy)))
	return b


def _break_manifest_hash(gen: Path) -> None:
	m = json.loads((gen / "manifest.json").read_text())
	m["asset_lock"]["sha256"] = hashlib.sha256(b"x").hexdigest()
	(gen / "manifest.json").write_bytes(wf.dump_json(m))


def _zip_entries(data: bytes) -> list[tuple[str, bytes]]:
	with zipfile.ZipFile(io.BytesIO(data)) as zf:
		return [(i.filename, zf.read(i)) for i in zf.infolist()]


def hostile_packages(valid: dict[str, dict[str, Any]]) -> dict[str, tuple[bytes, str]]:
	L = B.ONE_REGION
	boulder, spruce, cabin = _bundled("nature.rock.boulder_a"), _bundled("nature.tree.spruce_a"), _bundled("built.lodge.cabin_a")
	rb = B.remote_binding(B.descriptor_text("primitive_prop.json"), B.ref())
	one_object = lambda b: [B.obj(1, b["binding_id"], 10.5, 20.25, 1.3)]  # noqa: E731
	good = valid["one_bundled_object"]
	canon = lock_bytes_of([boulder])
	out: dict[str, tuple[bytes, str]] = {}

	def add(name: str, substring: str, doc: dict[str, Any], **kw: Any) -> None:
		out[name] = (B.package_bytes(doc, **kw)[0], substring)

	add("bad_lock_hash", "asset_lock sha256", good, post=_break_manifest_hash)
	add("lock_not_canonical", "not canonical", B.v4_doc(21, L, [boulder], one_object(boulder),
		lock_bytes=json.dumps(json.loads(canon), indent=1, sort_keys=True).encode()))
	fake = dict(boulder, binding_id=BOGUS)
	add("binding_id_mismatch", "binding_id mismatch", B.v4_doc(22, L, [fake], one_object(fake)))
	add("unreferenced_binding", "is not referenced by any object record or scatter instance",
		B.v4_doc(23, L, [boulder], one_object(boulder), lock_bytes=lock_bytes_of([boulder, spruce])))
	wide = _bundled("nature.rock.boulder_a", scale_range=["0.1", "5"])
	add("policy_outside_catalog", "outside catalog limits", B.v4_doc(24, L, [wide], one_object(wide)))
	narrow = _bundled("nature.rock.boulder_a", scale_range=["0.5", "1"])
	add("object_scale_outside_policy", "uniform_scale", B.v4_doc(25, L, [narrow], one_object(narrow)))
	add("scatter_binding_not_allowed", "is not scatter_allowed", B.v4_doc(26, L, [cabin], [],
		[B.scatter_inst(cabin["binding_id"], 12.5, 14.0)]))
	bad_sha = B.remote_binding(B.descriptor_text("primitive_prop.json"), B.ref(), sha=hashlib.sha256(b"other").hexdigest())
	add("descriptor_sha_mismatch", "descriptor_sha256 mismatch", B.v4_doc(27, L, [bad_sha], one_object(bad_sha)))
	add("dependency_closure_missing", "dependencies are missing the entry", B.v4_doc(28, L, [rb], one_object(rb), dependencies={}))
	add("dependency_closure_extra", "outside the closure", B.v4_doc(29, L, [boulder], one_object(boulder),
		dependencies=derive_dependencies([rb])))
	add("unknown_binding_in_objects", "unknown binding", B.v4_doc(30, L, [boulder],
		one_object(boulder) + [B.obj(2, BOGUS, 11.0, 21.0)]))
	base = _zip_entries(B.package_bytes(good)[0])
	out["zip_199_entries"] = (B.build_zip(base + [("x%d" % i, b"") for i in range(199 - len(base))]), "archive has 199 entries")
	huge = [(n, b"\0" * (8 * 1024 * 1024 + 1) if n == "asset_locks.json" else d) for n, d in base]
	out["oversized_lock"] = (B.build_zip(huge), "limit 8388608")
	return out
