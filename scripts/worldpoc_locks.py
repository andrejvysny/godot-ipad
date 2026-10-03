"""Schema 4 asset-binding primitives (ADR 0014 D3-D5, contracts/world-painter/world-v4): canonical JSON,
canonical decimals, AssetStudio asset keys, binding IDs, default bundled policy, range comparison.
Python stdlib only; lock parsing and validation live in worldpoc_lockcheck.py."""
from __future__ import annotations

import hashlib
import json
import re
import struct
from typing import Any

BINDING_MAGIC = b"WPBIND1\n"
# AssetStudio asset-ref.schema.json decimal / positive_decimal (at most 6 fractional digits).
DECIMAL_RE = re.compile(r"^(?!-0$)-?(0|[1-9][0-9]*)(\.[0-9]{0,5}[1-9])?$")
POSITIVE_DECIMAL_RE = re.compile(r"^(0\.[0-9]{0,5}[1-9]|[1-9][0-9]*(\.[0-9]{0,5}[1-9])?)$")


class CanonicalError(ValueError):
	pass


def _check_canonical(obj: Any, path: str) -> None:
	if isinstance(obj, float):
		raise CanonicalError("%s: non-integral scalars must be decimal strings" % path)
	if isinstance(obj, dict):
		for k, v in obj.items():
			if not isinstance(k, str):
				raise CanonicalError("%s: object keys must be strings" % path)
			_check_canonical(v, "%s.%s" % (path, k))
	elif isinstance(obj, list):
		for i, v in enumerate(obj):
			_check_canonical(v, "%s[%d]" % (path, i))
	elif obj is not None and not isinstance(obj, (str, int, bool)):
		raise CanonicalError("%s: unsupported value type %s" % (path, type(obj).__name__))


def canonical_v1(obj: Any) -> bytes:
	"""AssetStudio canonical_v1: reject floats, non-string keys and non-JSON types; sorted keys, no
	whitespace, no ASCII escaping beyond JSON's mandatory set. Raises CanonicalError."""
	_check_canonical(obj, "$")
	try:
		return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
			allow_nan=False).encode("utf-8")
	except (UnicodeEncodeError, ValueError) as e:  # lone surrogate, NaN
		raise CanonicalError(str(e)) from e


def dec(x: float) -> str:
	"""ADR 0014 D3: six fractional digits, trailing zeros and '.' stripped, '-0' written as '0'."""
	s = "%.6f" % x
	if "." in s:
		s = s.rstrip("0").rstrip(".")
	return "0" if s in ("-0", "") else s


def parse_decimal(text: str) -> float:
	"""float64 of a canonical decimal string (caller validated the grammar)."""
	return float(text)


def eps(bound: float) -> float:
	return 1e-6 * max(1.0, abs(bound))


def in_range(v: float, lo: float, hi: float) -> bool:
	"""ADR 0014 D5: inside [lo, hi] up to 1e-6 * max(1, |bound|)."""
	return v >= lo - eps(lo) and v <= hi + eps(hi)


def _length_prefixed(*parts: str) -> bytes:
	out = bytearray()
	for p in parts:
		b = p.encode("utf-8")
		out += struct.pack("<I", len(b)) + b
	return bytes(out)


def asset_key(ref: dict[str, str]) -> str:
	"""AssetStudio asset key: sha256 over server_id, library_id, asset_id, version_id."""
	return hashlib.sha256(_length_prefixed(ref["server_id"], ref["library_id"], ref["asset_id"],
		ref["version_id"])).hexdigest()


def binding_id(binding: dict[str, Any]) -> str:
	"""ADR 0014 D4: 'b' + first 32 hex of sha256('WPBIND1\\n' + canonical_v1(binding without binding_id))."""
	body = {k: v for k, v in binding.items() if k != "binding_id"}
	return "b" + hashlib.sha256(BINDING_MAGIC + canonical_v1(body)).hexdigest()[:32]


def default_policy(asset: dict[str, Any]) -> dict[str, Any]:
	"""ADR 0014 D3 default policy of a catalog entry."""
	return {
		"scatter_allowed": bool(asset.get("scatter_allowed")) and asset.get("scatter_mesh") is not None,
		"scale_range": [dec(asset["scale_min"]), dec(asset["scale_max"])],
		"height_offset_range_m": [dec(asset["height_offset_min_m"]), dec(asset["height_offset_max_m"])],
	}


def bundled_binding(trusted: dict[str, Any], asset_id: str) -> dict[str, Any]:
	"""Bundled binding of a trusted-catalog asset with the default policy and its binding_id."""
	asset = trusted["assets"][asset_id]
	b: dict[str, Any] = {
		"provider": "bundled",
		"catalog": {"id": trusted["id"], "version": int(trusted["version"]), "sha256": trusted["sha256"]},
		"asset_id": asset_id,
		"asset_version": int(asset["version"]),
		"policy": default_policy(asset),
	}
	b["binding_id"] = binding_id(b)
	return b


def with_binding_id(binding: dict[str, Any]) -> dict[str, Any]:
	"""Copy of a binding (without binding_id) with its id set."""
	b = {k: v for k, v in binding.items() if k != "binding_id"}
	b["binding_id"] = binding_id(b)
	return b
