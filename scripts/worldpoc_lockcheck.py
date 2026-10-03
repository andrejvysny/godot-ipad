"""asset_locks.json parsing and validation (ADR 0014 D4-D8, contracts/world-painter/world-v4/asset-locks.schema.json).

Validators return lists of error strings and never raise for invalid content. Structure is separate from
availability (D8): `availability_report` lists unavailable bindings, it never produces errors."""
from __future__ import annotations

import hashlib
import re
from typing import Any

from worldpoc_constants import BINDING_ID_RE, SHA256_RE, limits_for_schema, SCHEMA_VERSION_LOCK
from worldpoc_locks import (
	CanonicalError, DECIMAL_RE, POSITIVE_DECIMAL_RE, asset_key, binding_id, canonical_v1, in_range, parse_decimal)
from worldpoc_values import FormatError, is_json_int, parse_json_bytes, show

SERVER_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
LIBRARY_RE = re.compile(r"^prj_[0-9a-hjkmnp-tv-z]{16}$")
ASSET_RE = re.compile(r"^ast_[0-9a-hjkmnp-tv-z]{16}$")
VERSION_RE = re.compile(r"^ver_[0-9a-hjkmnp-tv-z]{16}$")
DELIVERY_RE = re.compile(r"^dlv_[0-9a-hjkmnp-tv-z]{16}$")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
CATALOG_ID_RE = re.compile(r"^[a-z0-9_]{1,64}$")
BUNDLED_ASSET_RE = re.compile(r"^[a-z0-9_.]{1,64}$")  # catalog ids use dots (nature.rock.boulder_a)
KEY_RE = re.compile(r"^[0-9a-f]{64}$")
REF_FIELDS = (("server_id", SERVER_RE), ("library_id", LIBRARY_RE), ("asset_id", ASSET_RE), ("version_id", VERSION_RE))
PIN_FIELDS = ("delivery_id", "manifest_sha256", "profile_id", "profile_version")
BINDING_DELIVERIES = ("portable_glb_v1", "godot_static_source_v1")
DEPENDENCY_DELIVERIES = BINDING_DELIVERIES + ("mobile_glb_v1",)
DESCRIPTOR_KEYS = {"schema_version", "asset_ref", "kind", "units", "up_axis", "forward_axis", "bounds_min",
	"bounds_max", "placement_anchor", "footprint_radius_m", "scale_range", "height_offset_range_m",
	"default_grounding", "material_slots", "collision", "preview_warnings", "source_provenance", "licence"}
DESCRIPTOR_MAX_CHARS = 262144


def _exact_keys(d: dict[str, Any], keys: set[str] | tuple[str, ...], tag: str) -> list[str]:
	errors = ["%s has unknown field %s" % (tag, show(k)) for k in sorted(set(d) - set(keys), key=str)]
	return errors + ["%s is missing field '%s'" % (tag, k) for k in sorted(set(keys) - set(d))]


def _str_matches(v: Any, rx: re.Pattern[str]) -> bool:
	return isinstance(v, str) and rx.match(v) is not None


def _check_ref(ref: Any, tag: str) -> list[str]:
	if not isinstance(ref, dict):
		return ["%s must be an object" % tag]
	errors = _exact_keys(ref, [k for k, _ in REF_FIELDS], tag)
	for key, rx in REF_FIELDS:
		if key in ref and not _str_matches(ref[key], rx):
			errors.append("%s.%s %s is malformed" % (tag, key, show(ref[key])))
	return errors


def _check_pin(pin: Any, tag: str) -> list[str]:
	if not isinstance(pin, dict):
		return ["%s must be an object" % tag]
	errors = _exact_keys(pin, PIN_FIELDS, tag)
	for key, rx in (("delivery_id", DELIVERY_RE), ("manifest_sha256", SHA256_RE), ("profile_id", SLUG_RE),
			("profile_version", re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$"))):
		if key in pin and not _str_matches(pin[key], rx):
			errors.append("%s.%s %s is malformed" % (tag, key, show(pin[key])))
	return errors


def _range(v: Any, rx: re.Pattern[str], tag: str) -> tuple[tuple[float, float] | None, list[str]]:
	if not (isinstance(v, list) and len(v) == 2 and all(_str_matches(c, rx) for c in v)):
		return None, ["%s must be two canonical decimal strings" % tag]
	lo, hi = parse_decimal(v[0]), parse_decimal(v[1])
	if lo > hi:
		return None, ["%s minimum exceeds maximum" % tag]
	return (lo, hi), []


def check_policy(p: Any, tag: str) -> tuple[dict[str, Any] | None, list[str]]:
	"""Grammar of a policy; returns {"scatter_allowed", "scale": (lo, hi), "height": (lo, hi)} on success."""
	if not isinstance(p, dict):
		return None, ["%s must be an object" % tag]
	errors = _exact_keys(p, ("scatter_allowed", "scale_range", "height_offset_range_m"), tag)
	if errors:
		return None, errors
	if not isinstance(p["scatter_allowed"], bool):
		errors.append("%s.scatter_allowed must be a boolean" % tag)
	scale, e1 = _range(p["scale_range"], POSITIVE_DECIMAL_RE, tag + ".scale_range")
	height, e2 = _range(p["height_offset_range_m"], DECIMAL_RE, tag + ".height_offset_range_m")
	errors += e1 + e2
	if errors:
		return None, errors
	return {"scatter_allowed": p["scatter_allowed"], "scale": scale, "height": height}, []


def _within(inner: tuple[float, float], outer: tuple[float, float]) -> bool:
	return in_range(inner[0], *outer) and in_range(inner[1], *outer)


def _check_bundled(b: dict[str, Any], tag: str, trusted: dict[str, Any]) -> list[str]:
	keys = ("binding_id", "provider", "catalog", "asset_id", "asset_version", "policy")
	errors = _exact_keys(b, keys, tag)
	cat = b.get("catalog")
	if not isinstance(cat, dict):
		errors.append("%s.catalog must be an object" % tag)
	else:
		errors += _exact_keys(cat, ("id", "version", "sha256"), tag + ".catalog")
		if not _str_matches(cat.get("id"), CATALOG_ID_RE):
			errors.append("%s.catalog.id %s is malformed" % (tag, show(cat.get("id"))))
		if not is_json_int(cat.get("version")) or isinstance(cat.get("version"), bool) or cat["version"] < 1:
			errors.append("%s.catalog.version must be a positive integer" % tag)
		if not _str_matches(cat.get("sha256"), SHA256_RE):
			errors.append("%s.catalog.sha256 is malformed" % tag)
	if not _str_matches(b.get("asset_id"), BUNDLED_ASSET_RE):
		errors.append("%s.asset_id %s is malformed" % (tag, show(b.get("asset_id"))))
	if not is_json_int(b.get("asset_version")) or isinstance(b.get("asset_version"), bool) or b["asset_version"] < 1:
		errors.append("%s.asset_version must be a positive integer" % tag)
	policy, perr = check_policy(b.get("policy"), tag + ".policy")
	errors += perr
	if errors or policy is None:
		return errors
	asset = available_catalog_asset(b, trusted)
	if asset is not None:
		errors += _check_catalog_limits(policy, asset, tag)
	return errors


def available_catalog_asset(b: dict[str, Any], trusted: dict[str, Any]) -> dict[str, Any] | None:
	"""The trusted catalog entry a (structurally valid) bundled binding names, or None when unavailable."""
	cat = b["catalog"]
	if cat["id"] != trusted["id"] or cat["version"] != trusted["version"] or cat["sha256"] != trusted["sha256"]:
		return None
	asset = trusted["assets"].get(b["asset_id"])
	if asset is None or int(asset["version"]) != b["asset_version"]:
		return None
	return asset


def _check_catalog_limits(policy: dict[str, Any], asset: dict[str, Any], tag: str) -> list[str]:
	errors: list[str] = []
	if not _within(policy["scale"], (asset["scale_min"], asset["scale_max"])):
		errors.append("%s.policy.scale_range is outside catalog limits [%r, %r]" % (tag, asset["scale_min"], asset["scale_max"]))
	if not _within(policy["height"], (asset["height_offset_min_m"], asset["height_offset_max_m"])):
		errors.append("%s.policy.height_offset_range_m is outside catalog limits [%r, %r]"
			% (tag, asset["height_offset_min_m"], asset["height_offset_max_m"]))
	if policy["scatter_allowed"] and not (asset.get("scatter_allowed") and asset.get("scatter_mesh") is not None):
		errors.append("%s.policy.scatter_allowed is true but the catalog asset does not allow scatter" % tag)
	return errors


def _is_float_free(v: Any) -> bool:
	if isinstance(v, float):
		return False
	if isinstance(v, dict):
		return all(_is_float_free(x) for x in v.values())
	return all(_is_float_free(x) for x in v) if isinstance(v, list) else True


def _decimal3(v: Any) -> list[float] | None:
	if isinstance(v, list) and len(v) == 3 and all(_str_matches(c, DECIMAL_RE) for c in v):
		return [parse_decimal(c) for c in v]
	return None


def check_descriptor(text: str, ref: dict[str, str]) -> tuple[dict[str, Any] | None, list[str]]:
	"""Structure of a frozen AssetStudio descriptor (D6): required keys, constants, decimals, bounds, asset_ref."""
	try:
		d = parse_json_bytes(text.encode("utf-8"))
	except (FormatError, UnicodeEncodeError) as e:
		return None, ["descriptor_json is not valid JSON: %s" % show(str(e), 120)]
	if not isinstance(d, dict):
		return None, ["descriptor_json is not a JSON object"]
	errors = _exact_keys(d, DESCRIPTOR_KEYS, "descriptor")
	if errors:
		return None, errors
	if not _is_float_free(d):
		errors.append("descriptor contains a float literal")
	for key, want in (("schema_version", 1), ("kind", "model3d"), ("units", "m"), ("up_axis", "+Y"), ("forward_axis", "+Z")):
		if d[key] != want or isinstance(d[key], bool):
			errors.append("descriptor.%s must be %r" % (key, want))
	if d["asset_ref"] != ref:
		errors.append("descriptor.asset_ref does not equal the binding's asset_ref")
	lo, hi, anchor = _decimal3(d["bounds_min"]), _decimal3(d["bounds_max"]), _decimal3(d["placement_anchor"])
	if lo is None or hi is None or anchor is None:
		errors.append("descriptor bounds_min, bounds_max and placement_anchor must be three canonical decimals")
	elif any(a > b for a, b in zip(lo, hi)) or all(a == b for a, b in zip(lo, hi)):
		errors.append("descriptor bounds are not ordered with a positive extent")
	if not _str_matches(d["footprint_radius_m"], POSITIVE_DECIMAL_RE):
		errors.append("descriptor.footprint_radius_m must be a positive canonical decimal")
	scale, e1 = _range(d["scale_range"], POSITIVE_DECIMAL_RE, "descriptor.scale_range")
	height, e2 = _range(d["height_offset_range_m"], DECIMAL_RE, "descriptor.height_offset_range_m")
	errors += e1 + e2
	if d["default_grounding"] not in ("FOLLOW_TERRAIN", "WORLD_FIXED"):
		errors.append("descriptor.default_grounding is not allowed")
	if not isinstance(d["material_slots"], list) or not isinstance(d["preview_warnings"], list) \
			or not isinstance(d["source_provenance"], dict) or not isinstance(d["licence"], dict):
		errors.append("descriptor material_slots, preview_warnings, source_provenance or licence has the wrong type")
	if errors:
		return None, errors
	d["_scale"], d["_height"] = scale, height
	return d, []


def _check_assetstudio(b: dict[str, Any], tag: str) -> list[str]:
	keys = ("binding_id", "provider", "asset_key", "asset_ref", "descriptor_json", "descriptor_sha256", "deliveries", "policy")
	errors = _exact_keys(b, keys, tag)
	if errors:
		return errors
	ref = b["asset_ref"]
	errors += _check_ref(ref, tag + ".asset_ref")
	if not _str_matches(b["asset_key"], KEY_RE):
		errors.append("%s.asset_key is malformed" % tag)
	elif not errors and asset_key(ref) != b["asset_key"]:
		errors.append("%s.asset_key does not equal the key of asset_ref" % tag)
	errors += _check_deliveries(b["deliveries"], tag + ".deliveries", True, BINDING_DELIVERIES)
	policy, perr = check_policy(b["policy"], tag + ".policy")
	errors += perr
	text = b["descriptor_json"]
	if not isinstance(text, str) or not (2 <= len(text) <= DESCRIPTOR_MAX_CHARS):
		return errors + ["%s.descriptor_json must be a string of 2..%d characters" % (tag, DESCRIPTOR_MAX_CHARS)]
	if not _str_matches(b["descriptor_sha256"], SHA256_RE):
		return errors + ["%s.descriptor_sha256 is malformed" % tag]
	try:
		raw = text.encode("utf-8")
	except UnicodeEncodeError:
		return errors + ["%s.descriptor_json is not valid UTF-8" % tag]
	if hashlib.sha256(raw).hexdigest() != b["descriptor_sha256"]:
		return errors + ["%s.descriptor_sha256 mismatch: descriptor_json hashes to %s" % (tag, hashlib.sha256(raw).hexdigest())]
	if errors:
		return errors
	desc, derr = check_descriptor(text, ref)
	errors += ["%s: %s" % (tag, e) for e in derr]
	if desc is not None and policy is not None:
		if not _within(policy["scale"], desc["_scale"]):
			errors.append("%s.policy.scale_range is outside the descriptor's scale_range" % tag)
		if not _within(policy["height"], desc["_height"]):
			errors.append("%s.policy.height_offset_range_m is outside the descriptor's height_offset_range_m" % tag)
	return errors


def _check_deliveries(d: Any, tag: str, require_portable: bool, allowed: tuple[str, ...]) -> list[str]:
	if not isinstance(d, dict):
		return ["%s must be an object" % tag]
	errors = ["%s has unknown delivery %s" % (tag, show(k)) for k in sorted(set(d) - set(allowed), key=str)]
	if require_portable and "portable_glb_v1" not in d:
		errors.append("%s must contain portable_glb_v1" % tag)
	elif not d:
		errors.append("%s must not be empty" % tag)
	for k in allowed:
		if k in d:
			errors += _check_pin(d[k], "%s.%s" % (tag, k))
	return errors


def parse_lock(data: bytes, trusted: dict[str, Any]) -> tuple[dict[str, Any] | None, list[str]]:
	"""Structure of asset_locks.json bytes (canonical form, grammar, sorted unique recomputed IDs, provider fields,
	policy and descriptor limits, dependencies grammar). Reference-dependent rules: check_dependencies."""
	limits = limits_for_schema(SCHEMA_VERSION_LOCK)
	if len(data) > limits["max_lock_bytes"]:
		return None, ["asset_locks.json is %d bytes (limit %d)" % (len(data), limits["max_lock_bytes"])]
	try:
		lock = parse_json_bytes(data)
	except FormatError as e:
		return None, ["asset_locks.json is not valid JSON: %s" % e]
	try:
		if canonical_v1(lock) != data:
			return None, ["asset_locks.json is not canonical (re-encoding differs from the stored bytes)"]
	except CanonicalError as e:
		return None, ["asset_locks.json is not canonical: %s" % show(str(e), 160)]
	if not isinstance(lock, dict):
		return None, ["asset_locks.json is not a JSON object"]
	errors = _exact_keys(lock, ("schema_version", "bindings", "dependencies"), "asset_locks.json")
	if errors:
		return None, errors
	if lock["schema_version"] != 1 or isinstance(lock["schema_version"], bool):
		errors.append("asset_locks.json schema_version must be 1")
	if not isinstance(lock["bindings"], list):
		return None, errors + ["asset_locks.json bindings must be an array"]
	if len(lock["bindings"]) > limits["max_bindings"]:
		return None, errors + ["asset_locks.json has %d bindings (max %d)" % (len(lock["bindings"]), limits["max_bindings"])]
	errors += _check_bindings(lock["bindings"], trusted)
	errors += _check_dependency_grammar(lock["dependencies"])
	return (lock, []) if not errors else (None, errors)


def _check_bindings(bindings: list[Any], trusted: dict[str, Any]) -> list[str]:
	errors: list[str] = []
	prev = ""
	for i, b in enumerate(bindings):
		tag = "binding %d" % i
		if not isinstance(b, dict):
			errors.append(tag + " is not an object")
			continue
		bid = b.get("binding_id")
		if not _str_matches(bid, BINDING_ID_RE):
			errors.append("%s binding_id %s is malformed" % (tag, show(bid)))
			continue
		tag = "binding %s" % bid
		if i > 0 and bid == prev:
			errors.append("duplicate binding_id %s" % bid)
		elif bid < prev:
			errors.append("bindings are not sorted by binding_id (%s)" % bid)
		prev = max(prev, bid)
		provider = b.get("provider")
		if provider == "bundled":
			errors += _check_bundled(b, tag, trusted)
		elif provider == "assetstudio":
			errors += _check_assetstudio(b, tag)
		else:
			errors.append("%s has unknown provider %s" % (tag, show(provider)))
			continue
		try:
			if binding_id(b) != bid:
				errors.append("%s binding_id mismatch (recomputed %s)" % (tag, binding_id(b)))
		except CanonicalError as e:
			errors.append("%s cannot be canonicalized: %s" % (tag, show(str(e), 120)))
	return errors


def _check_dependency_grammar(deps: Any) -> list[str]:
	if not isinstance(deps, dict):
		return ["asset_locks.json dependencies must be an object"]
	errors: list[str] = []
	for key in sorted(deps, key=str):
		errors += _check_dependency(key, deps[key])
	return errors


def _check_dependency(key: Any, e: Any) -> list[str]:
	tag = "dependency %s" % show(key, 20)
	if not _str_matches(key, KEY_RE) or not isinstance(e, dict):
		return [tag + " has a malformed key or entry"]
	errors = _exact_keys(e, ("asset_ref", "descriptor_sha256", "deliveries", "requires"), tag)
	if errors:
		return errors
	errors += _check_ref(e["asset_ref"], tag + ".asset_ref")
	if not _str_matches(e["descriptor_sha256"], SHA256_RE):
		errors.append(tag + ".descriptor_sha256 is malformed")
	errors += _check_deliveries(e["deliveries"], tag + ".deliveries", False, DEPENDENCY_DELIVERIES)
	req = e["requires"]
	if not (isinstance(req, list) and all(_str_matches(r, KEY_RE) for r in req)):
		errors.append(tag + ".requires must be an array of asset keys")
	elif req != sorted(set(req)):
		errors.append(tag + ".requires must be sorted and unique")
	if not errors and asset_key(e["asset_ref"]) != key:
		errors.append(tag + " key does not equal the key of its asset_ref")
	return errors


def _closure(deps: dict[str, Any], roots: set[str]) -> tuple[set[str], list[str]]:
	errors: list[str] = []
	seen: set[str] = set()
	state: dict[str, int] = {}

	def visit(key: str) -> None:
		if state.get(key) == 2:
			return
		if state.get(key) == 1:
			errors.append("dependencies contain a cycle through %s" % key)
			return
		state[key] = 1
		seen.add(key)
		if key in deps:
			for r in deps[key]["requires"]:
				if r not in deps:
					errors.append("dependency %s requires missing key %s" % (key, r))
				visit(r)
		state[key] = 2

	for k in sorted(roots):
		visit(k)
	return seen, errors


def check_dependencies(lock: dict[str, Any], referenced: set[str]) -> list[str]:
	"""D6: dependencies equal exactly the closure of the referenced AssetStudio bindings."""
	deps = lock["dependencies"]
	roots: dict[str, list[dict[str, Any]]] = {}
	for b in lock["bindings"]:
		if b["provider"] == "assetstudio" and b["binding_id"] in referenced:
			roots.setdefault(b["asset_key"], []).append(b)
	closure, errors = _closure(deps, set(roots))
	for key in sorted(closure - set(deps)):
		errors.append("dependencies are missing the entry for asset_key %s" % key)
	for key in sorted(set(deps) - closure):
		errors.append("dependencies has entry %s outside the closure of the referenced bindings" % key)
	for key, bindings in roots.items():
		if key not in deps:
			continue
		e = deps[key]
		for b in bindings:
			if e["asset_ref"] != b["asset_ref"] or e["descriptor_sha256"] != b["descriptor_sha256"]:
				errors.append("dependency %s does not match binding %s (asset_ref or descriptor_sha256)" % (key, b["binding_id"]))
			for name, pin in b["deliveries"].items():
				if e["deliveries"].get(name) != pin:
					errors.append("dependency %s lacks delivery pin %s of binding %s" % (key, name, b["binding_id"]))
	return errors


def availability_report(lock: dict[str, Any], trusted: dict[str, Any]) -> list[str]:
	"""D8: unavailable bindings (informational). Bundled: catalog identity or asset/version differs from the
	trusted catalog. AssetStudio: always unavailable until a resolver exists (IP-03)."""
	report: list[str] = []
	for b in lock["bindings"]:
		if b["provider"] == "assetstudio":
			report.append("binding %s (assetstudio %s) is unavailable: no resolver" % (b["binding_id"], b["asset_ref"]["asset_id"]))
		elif available_catalog_asset(b, trusted) is None:
			report.append("binding %s (bundled %s v%d) is unavailable: not in the trusted catalog %s v%d"
				% (b["binding_id"], show(b["asset_id"]), b["asset_version"], trusted["id"], trusted["version"]))
	return report
