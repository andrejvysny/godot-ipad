"""Builders for schema 4 test worlds and golden fixtures (contracts/world-painter/world-v4/fixtures).
Deterministic: fixed IDs, fixed timestamps, flat or stepped terrain. Python stdlib only."""
from __future__ import annotations

import hashlib
import io
import json
import shutil
import struct
import tempfile
import zipfile
from pathlib import Path
from typing import Any

import worldpoc_format as wf
from worldpoc_locks import asset_key, canonical_v1, with_binding_id

FIXTURES_V4 = wf.REPO / "contracts" / "world-painter" / "world-v4" / "fixtures"
ONE_REGION: wf.Layout = ((0, 0), (1, 1))  # x, z in [0, 127.5]
CREATED_WITH = {
	"godot": "4.7.2.stable.official.ed1daf0bf",
	"terrain3d": "1.0.2-stable@0077405b52e353c5e5dc3a094e7ede49833ba6fe",
	"world_painter": "world-v4-fixture-generator-v1",
}
QUAT = [0.0, 0.34289780745545134, 0.0, 0.9393727128473789]
SERVER = "6f1c2a52-3c2e-4d4b-9a57-0b6f6f0c1d2e"
LIBRARY = "prj_0000000000000001"


def world_id(n: int) -> str:
	return "4f000000-0000-4000-8000-%012d" % n


def object_id(n: int) -> str:
	return "00000000-0000-4000-8000-%012d" % n


def descriptor_text(name: str) -> str:
	return (FIXTURES_V4 / "descriptors" / name).read_text(encoding="utf-8")


def ref(asset_id: str = "ast_00000000000000aa", version_id: str = "ver_00000000000000v1") -> dict[str, str]:
	return {"server_id": SERVER, "library_id": LIBRARY, "asset_id": asset_id, "version_id": version_id}


def pins(seed: str, static: bool = False) -> dict[str, Any]:
	def pin(delivery: str, profile: str) -> dict[str, str]:
		return {"delivery_id": delivery, "manifest_sha256": hashlib.sha256((seed + delivery).encode()).hexdigest(),
			"profile_id": profile, "profile_version": "1.0.0"}
	d = {"portable_glb_v1": pin("dlv_00000000000000d1", "portable-default")}
	if static:
		d["godot_static_source_v1"] = pin("dlv_00000000000000d4", "godot-static-source")
	return d


def remote_binding(text: str, asset_ref: dict[str, str], scatter: bool = False, scale: tuple[str, str] = ("0.5", "2"),
		height: tuple[str, str] = ("-0.1", "0.5"), static: bool = False, sha: str | None = None) -> dict[str, Any]:
	"""AssetStudio binding of an exact descriptor text; `sha` overrides descriptor_sha256 (hostile fixtures)."""
	b = {
		"provider": "assetstudio",
		"asset_key": asset_key(asset_ref),
		"asset_ref": asset_ref,
		"descriptor_json": text,
		"descriptor_sha256": sha or hashlib.sha256(text.encode("utf-8")).hexdigest(),
		"deliveries": pins(asset_ref["version_id"], static),
		"policy": {"scatter_allowed": scatter, "scale_range": list(scale), "height_offset_range_m": list(height)},
	}
	return with_binding_id(b)


def stepped(loc: tuple[int, int]) -> bytes:
	"""Compressible non-flat heights: 16-sample steps of 0.25 m."""
	n = wf.REGION_SAMPLES
	row = [((lx // 16 + (loc[0] & 1)) % 4) * 0.25 for lx in range(n)]
	return struct.pack("<%df" % (n * n), *(row * n))


def flat_arrays(layout: wf.Layout, step: bool = False) -> dict[str, dict[tuple[int, int], bytes]]:
	locs = wf.layout_regions(*layout)
	return {
		"heights": {l: (stepped(l) if step else struct.pack("<f", 0.0) * wf.REGION_SAMPLE_COUNT) for l in locs},
		"controls": {l: struct.pack("<I", wf.DEFAULT_CONTROL) * wf.REGION_SAMPLE_COUNT for l in locs},
		"colors": {l: wf.DEFAULT_COLOR * wf.REGION_SAMPLE_COUNT for l in locs},
	}


def holes_controls(layout: wf.Layout) -> dict[tuple[int, int], bytes]:
	"""Control words with the hole bit on a 40x40 block and one stripe; everything else default."""
	out = {}
	for loc in wf.layout_regions(*layout):
		words = [wf.DEFAULT_CONTROL] * wf.REGION_SAMPLE_COUNT
		for z in range(40):
			for x in range(40):
				words[(100 + z) * wf.REGION_SAMPLES + 100 + x] = wf.DEFAULT_CONTROL | wf.HOLE_BIT
		for x in range(wf.REGION_SAMPLES):
			words[7 * wf.REGION_SAMPLES + x] = wf.DEFAULT_CONTROL | wf.HOLE_BIT
		out[loc] = struct.pack("<%dI" % len(words), *words)
	return out


def v4_doc(n: int, layout: wf.Layout, bindings: list[dict[str, Any]], objects: list[dict[str, Any]],
		scatter: list[dict[str, Any]] | None = None, **extra: Any) -> dict[str, Any]:
	doc = {"world_id": world_id(n), "document_revision": 0, "created_with": CREATED_WITH, "layout": layout,
		"bindings": bindings, "objects": objects, "scatter": scatter or []}
	doc.update(flat_arrays(layout))
	doc.update(extra)
	return doc


def obj(n: int, binding: str, x: float, z: float, scale: float = 1.0, offset: float = 0.0) -> dict[str, Any]:
	from worldpoc_v4 import make_object_record_v4
	return make_object_record_v4(object_id(n), binding, [x, offset, z], QUAT, scale, "FOLLOW_TERRAIN", offset)


def scatter_inst(binding: str, x: float, z: float, yaw: float = 0.5, scale: float = 1.0, flags: int = 0) -> dict[str, Any]:
	return {"binding_id": binding, "flags": flags, "x": x, "z": z, "yaw_rad": yaw, "scale": scale}


def build_zip(entries: list[tuple[str, bytes]]) -> bytes:
	"""Deterministic deflate ZIP (fixed timestamps); entry order as given."""
	buf = io.BytesIO()
	with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
		for name, data in entries:
			info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
			info.compress_type = zipfile.ZIP_DEFLATED
			info.external_attr = 0o100644 << 16
			zf.writestr(info, data)
	return buf.getvalue()


def entries_of(gen_dir: Path) -> list[tuple[str, bytes]]:
	m = json.loads((gen_dir / "manifest.json").read_text())
	layout = wf.layout_from_manifest(m["terrain"]["layout"])[0] if "layout" in m["terrain"] else wf.LEGACY_LAYOUT
	return [(n, (gen_dir / n).read_bytes()) for n in ["manifest.json"] + wf.payload_paths(layout, m["schema_version"])]


class Workdir:
	"""Context manager providing a scratch directory."""

	def __enter__(self) -> Path:
		self.path = Path(tempfile.mkdtemp(prefix="wp_v4_"))
		return self.path

	def __exit__(self, *exc: object) -> None:
		shutil.rmtree(self.path, ignore_errors=True)


def package_bytes(doc: dict[str, Any], mutate: Any = None, post: Any = None) -> tuple[bytes, str]:
	"""(.worldpoc bytes, authored hash) of a schema 4 doc. `mutate(gen_dir)` edits files before sealing,
	`post(gen_dir)` after (e.g. to corrupt the sealed manifest)."""
	from worldpoc_write import seal_generation_v4, write_generation_v4
	with Workdir() as tmp:
		gen = tmp / "gen"
		write_generation_v4(gen, doc)
		if mutate is not None:
			mutate(gen)
			seal_generation_v4(gen)
		if post is not None:
			post(gen)
		pkg = tmp / "w.worldpoc"
		wf.write_package(gen, pkg)
		manifest = json.loads((gen / "manifest.json").read_text())
		return pkg.read_bytes(), manifest["authored_content_hash"]


NON_ASCII_NOTE = ("Zlat\u00e1 skala \u2013 \u68ee \U0001f332 " + "".join(chr(c) for c in range(1, 32))
	+ "\x7f\u2028\u2029\"\\/")


def non_ascii_descriptor() -> tuple[str, dict[str, str]]:
	d = json.loads(descriptor_text("primitive_prop.json"))
	r = ref("ast_00000000000000ac")
	r["library_id"] = "prj_0000000000000002"
	d["asset_ref"] = r
	d["licence"] = {"name": NON_ASCII_NOTE, "rights_verified": False}
	d["source_provenance"] = {"generator": "world-v4-fixtures", "method": "procedural", "note": NON_ASCII_NOTE}
	return canonical_v1(d).decode("utf-8"), r
