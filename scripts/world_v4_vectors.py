"""canonical-lock-vectors.json: exact canonical_v1 bytes, rejected inputs, non-canonical lock bytes, dec() and
binding_id/asset_key vectors for the schema 4 lock (ADR 0014 D3, D4). Written ASCII-only so no consumer has to
trust a text encoding."""
from __future__ import annotations

import hashlib
import json
from typing import Any

import worldpoc_format as wf
import world_v4_builders as B
from worldpoc_locks import asset_key, binding_id, bundled_binding, canonical_v1, dec

NOTE = ("U+0000 is excluded: Godot strings cannot hold NUL, so no consumer can represent it. JSON values below are "
	"written with ASCII-only escapes; consumers parse them with a standard JSON parser, then encode. "
	"canonical_hex is the exact output of canonical_v1. Objects are sorted by Unicode code point (not UTF-16 "
	"order), see sort_astral_vs_bmp. Non-string keys cannot occur in JSON; consumers must reject them in-memory.")


def _canonical_cases() -> list[dict[str, Any]]:
	text, _ = B.non_ascii_descriptor()
	values: list[tuple[str, Any]] = [("ctrl_U+%04X" % c, {"s": "a" + chr(c) + "b"}) for c in range(1, 32)]
	values += [
		("all_controls_U+0001_to_U+001F", {"s": "".join(chr(c) for c in range(1, 32))}),
		("quote", {"s": "say \"hi\""}), ("backslash", {"s": "a\\b"}), ("slash_not_escaped", {"s": "a/b"}),
		("del_U+007F_not_escaped", {"s": "a\x7fb"}), ("line_separator_U+2028_not_escaped", {"s": "a b"}),
		("paragraph_separator_U+2029_not_escaped", {"s": "a b"}),
		("latin1_non_ascii", {"s": "Zlatá"}), ("bmp_cjk", {"s": "森"}), ("astral_plane", {"s": "\U0001f332"}),
		("escaped_text_is_data", {"s": "\\u0041 \\n \\\\"}),
		("sort_keys", {"b": 1, "a": 2, "B": 3, "é": 4, "_": 5}),
		("sort_astral_vs_bmp", {"\U0001f332": 1, "": 2, "z": 3}),
		("scalars", {"i": 0, "n": -7, "big": 9007199254740993, "t": True, "f": False, "z": None}),
		("empty_containers", {"a": [], "o": {}, "s": ""}),
		("nested", {"a": [{"y": [1, [2, {"k": "v"}]], "x": None}], "b": {"c": {"d": []}}}),
		("descriptor_json_nested_escapes", {"descriptor_json": text, "descriptor_sha256": hashlib.sha256(text.encode()).hexdigest()}),
	]
	return [{"name": n, "input": v, "canonical_hex": canonical_v1(v).hex()} for n, v in values]


def _reject_cases() -> list[dict[str, str]]:
	cases = [("float_fraction", '{"a":1.5}'), ("float_integral_literal", '{"a":1.0}'), ("float_exponent", '{"a":1e3}'),
		("float_negative_zero", '{"a":-0.0}'), ("float_in_array", '{"a":[1,2.5]}'), ("float_nested", '{"a":{"b":{"c":0.1}}}'),
		("float_top_level", "0.5")]
	return [{"name": n, "json": j, "expected": "reject (float)"} for n, j in cases]


def _non_canonical_cases() -> list[dict[str, str]]:
	texts = [("whitespace", '{"a": 1}'), ("unsorted_keys", '{"b":1,"a":2}'), ("escaped_non_ascii", '{"a":"\\u00e9"}'),
		("escaped_slash", '{"a":"\\/"}'), ("uppercase_hex_escape", '{"a":"\\u001F"}'), ("escaped_del", '{"a":"\\u007f"}'),
		("escaped_line_separator", '{"a":"\\u2028"}'), ("unicode_escape_for_newline", '{"a":"\\u000a"}'),
		("trailing_newline", '{"a":1}\n'), ("duplicate_key", '{"a":1,"a":2}')]
	return [{"name": n, "bytes_hex": t.encode().hex(), "expected": "reject"} for n, t in texts]


def _dec_cases() -> list[dict[str, str]]:
	inputs = ["0.8", "1.25", "-0.2", "0", "-0.0", "1e-7", "-1e-7", "0.1", "0.30000000000000004", "2.5000004", "1e-6",
		"123.4567891", "3", "100", "-0.75", "0.5", "10.0"]
	return [{"input_json": i, "expected": dec(float(i))} for i in inputs]


def _binding_cases() -> list[dict[str, Any]]:
	trusted = wf.load_trusted_catalog()
	text1 = B.descriptor_text("primitive_prop.json")
	text3, ref3 = B.non_ascii_descriptor()
	cases: list[tuple[str, dict[str, Any]]] = [("bundled_default_" + a, bundled_binding(trusted, a)) for a in sorted(trusted["assets"])]
	cases += [
		("remote_primitive_prop", B.remote_binding(text1, B.ref())),
		("remote_primitive_prop_static_scatter", B.remote_binding(text1, B.ref(), scatter=True, static=True)),
		("remote_non_ascii_descriptor", B.remote_binding(text3, ref3)),
	]
	out = []
	for name, b in cases:
		body = {k: v for k, v in b.items() if k != "binding_id"}
		out.append({"name": name, "binding": b, "body_canonical_hex": canonical_v1(body).hex(), "binding_id": binding_id(body)})
	return out


def vectors() -> dict[str, Any]:
	refs = [B.ref(), B.ref(version_id="ver_00000000000000v2"), B.non_ascii_descriptor()[1]]
	return {
		"schema": "world-painter/world-v4/canonical-lock-vectors",
		"note": NOTE,
		"catalog": {"id": wf.load_trusted_catalog()["id"], "sha256": wf.load_trusted_catalog()["sha256"],
			"note": "bundled binding vectors depend on app/assets/catalog.json and its geometry files (world-format section 8)"},
		"binding_id_derivation": "b + sha256_hex('WPBIND1\\n' + canonical_v1(binding without binding_id))[0:32]",
		"canonical": _canonical_cases(),
		"reject_inputs": _reject_cases(),
		"non_canonical_lock_bytes": _non_canonical_cases(),
		"dec": _dec_cases(),
		"asset_keys": [{"asset_ref": r, "asset_key": asset_key(r)} for r in refs],
		"binding_ids": _binding_cases(),
	}


def vectors_json() -> bytes:
	return (json.dumps(vectors(), indent=1, ensure_ascii=True, sort_keys=True) + "\n").encode("ascii")
