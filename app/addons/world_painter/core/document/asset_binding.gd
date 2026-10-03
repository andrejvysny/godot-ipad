class_name AssetBinding
extends RefCounted
## One exact asset reference of a world (ADR 0014 D3, D4, D6). Immutable after finalize(): its
## `binding_id` is a hash of its content, so equal selections share one id on every peer and any
## change of version, delivery or policy creates a new binding.

const CanonicalJson := preload("res://addons/assetstudio/core/as_canonical_json.gd")
const Canonical := preload("res://addons/assetstudio/core/as_canonical.gd")
const Schema := preload("res://addons/assetstudio/core/as_schema.gd")
const AssetDescriptor := preload("res://addons/assetstudio/core/as_asset_descriptor.gd")
const AssetRef := preload("res://addons/assetstudio/core/as_asset_ref.gd")

const PROVIDER_BUNDLED := "bundled"
const PROVIDER_ASSETSTUDIO := "assetstudio"
const ID_MAGIC := "WPBIND1\n"
const MAX_DESCRIPTOR_CHARS := 262144
const BUNDLED_KEYS := ["binding_id", "provider", "catalog", "asset_id", "asset_version", "policy"]
const ASSETSTUDIO_KEYS := ["binding_id", "provider", "asset_key", "asset_ref", "descriptor_json",
	"descriptor_sha256", "deliveries", "policy"]
const CATALOG_KEYS := ["id", "version", "sha256"]
const POLICY_KEYS := ["scatter_allowed", "scale_range", "height_offset_range_m"]
const PIN_KEYS := ["delivery_id", "manifest_sha256", "profile_id", "profile_version"]
const REQUIRED_DELIVERY := "portable_glb_v1"
const OPTIONAL_DELIVERY := "godot_static_source_v1"

var binding_id: String = ""
var provider: String = PROVIDER_BUNDLED

# bundled
var catalog_id: String = ""
var catalog_version: int = 0
var catalog_sha256: String = ""
var asset_id: String = ""
var asset_version: int = 0

# assetstudio
var asset_key: String = ""
var asset_ref: Dictionary = {}
var descriptor_json: String = ""
var descriptor_sha256: String = ""
var deliveries: Dictionary = {}
## asset_key -> ProjectAssetLockV1 dependency entry: this binding's own closure (empty for bundled).
var dependencies: Dictionary = {}

# policy (effective limits, ADR 0014 D5)
var scatter_allowed: bool = false
var scale_range := PackedStringArray(["1", "1"])
var height_offset_range_m := PackedStringArray(["0", "0"])
var scale_min: float = 1.0
var scale_max: float = 1.0
var height_offset_min_m: float = 0.0
var height_offset_max_m: float = 0.0


## Canonical decimal of ADR 0014 D3: six fractional digits, trailing zeros and "." stripped, "-0" is "0".
static func dec(x: float) -> String:
	var s := "%.6f" % x
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return "0" if s == "-0" else s


static func eps_of(bound: float) -> float:
	return 1e-6 * maxf(1.0, absf(bound))


func set_policy(p_scatter: bool, scale_lo: String, scale_hi: String, height_lo: String, height_hi: String) -> void:
	scatter_allowed = p_scatter
	scale_range = PackedStringArray([scale_lo, scale_hi])
	height_offset_range_m = PackedStringArray([height_lo, height_hi])
	scale_min = Canonical.parse_decimal(scale_lo).value
	scale_max = Canonical.parse_decimal(scale_hi).value
	height_offset_min_m = Canonical.parse_decimal(height_lo).value
	height_offset_max_m = Canonical.parse_decimal(height_hi).value


func in_scale(v: float) -> bool:
	return is_finite(v) and v > 0.0 and v >= scale_min - eps_of(scale_min) and v <= scale_max + eps_of(scale_max)


func in_height_offset(v: float) -> bool:
	return is_finite(v) and v >= height_offset_min_m - eps_of(height_offset_min_m) \
		and v <= height_offset_max_m + eps_of(height_offset_max_m)


## "b" + 32 lowercase hex digits (no RegEx: callable from the storage worker and the main thread alike).
static func is_valid_id(s: String) -> bool:
	if s.length() != 33 or s[0] != "b":
		return false
	for i in range(1, 33):
		var c := s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
			return false
	return true


## [a-z0-9_]{1,64}, or [a-z0-9_.]{1,64} when `dots` (catalog asset ids are dotted: nature.tree.spruce_a).
static func is_slug(s: String, dots: bool) -> bool:
	if s.is_empty() or s.length() > 64:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 122) or c == 95 or (dots and c == 46)):
			return false
	return true


func is_bundled() -> bool:
	return provider == PROVIDER_BUNDLED


func policy_dict() -> Dictionary:
	return {"scatter_allowed": scatter_allowed, "scale_range": Array(scale_range),
		"height_offset_range_m": Array(height_offset_range_m)}


func to_dict(include_id: bool = true) -> Dictionary:
	var d := {}
	if provider == PROVIDER_BUNDLED:
		d = {"provider": provider, "catalog": {"id": catalog_id, "version": catalog_version, "sha256": catalog_sha256},
			"asset_id": asset_id, "asset_version": asset_version, "policy": policy_dict()}
	else:
		d = {"provider": provider, "asset_key": asset_key, "asset_ref": asset_ref.duplicate(true),
			"descriptor_json": descriptor_json, "descriptor_sha256": descriptor_sha256,
			"deliveries": deliveries.duplicate(true), "policy": policy_dict()}
	if include_id:
		d["binding_id"] = binding_id
	return d


## "b" + first 32 hex of sha256("WPBIND1\n" + canonical_v1(binding without binding_id)); "" if unencodable.
func compute_id() -> String:
	var enc: RefCounted = CanonicalJson.encode(to_dict(false))
	if not enc.ok:
		return ""
	var bytes := ID_MAGIC.to_utf8_buffer()
	bytes.append_array(enc.value)
	return "b" + CanonicalEncoder.sha256_hex(bytes).substr(0, 32)


## Sets `binding_id` from the content; returns it.
func finalize() -> String:
	binding_id = compute_id()
	return binding_id


## Default-policy bundled binding of a trusted catalog entry (ADR 0014 D3).
static func bundled_default(catalog: AssetCatalog, def: AssetDefinition) -> AssetBinding:
	var b := AssetBinding.new()
	b.provider = PROVIDER_BUNDLED
	b.catalog_id = catalog.catalog_id
	b.catalog_version = catalog.catalog_version
	b.catalog_sha256 = catalog.sha256
	b.asset_id = def.asset_id
	b.asset_version = def.version
	b.set_policy(def.scatter_allowed and def.scatter_mesh != "", dec(def.scale_min), dec(def.scale_max),
		dec(def.height_offset_min_m), dec(def.height_offset_max_m))
	b.finalize()
	return b


## Strict parse of one lock binding. Returns [AssetBinding, ""] or [null, error]. The stored
## binding_id must equal the recomputed one.
static func from_dict(d: Variant) -> Array:
	if typeof(d) != TYPE_DICTIONARY:
		return [null, "binding is not an object"]
	var dict: Dictionary = d
	if typeof(dict.get("provider")) != TYPE_STRING:
		return [null, "binding provider must be a string"]
	var b := AssetBinding.new()
	var err := ""
	match dict.provider:
		PROVIDER_BUNDLED:
			err = b._parse_bundled(dict)
		PROVIDER_ASSETSTUDIO:
			err = b._parse_assetstudio(dict)
		_:
			err = "unknown binding provider '%s'" % dict.provider
	if err == "":
		err = b._parse_policy(dict.policy, dict.get("descriptor_json", ""))
	if err != "":
		return [null, err]
	var stored: Variant = dict.binding_id
	if typeof(stored) != TYPE_STRING or not is_valid_id(stored):
		return [null, "binding_id is not b + 32 hex digits"]
	var computed := b.finalize()
	if computed != stored:
		return [null, "binding_id mismatch: stored %s, computed %s" % [stored, computed]]
	return [b, ""]


func _parse_bundled(d: Dictionary) -> String:
	var err := _exact_keys(d, BUNDLED_KEYS, "bundled binding")
	if err != "":
		return err
	provider = PROVIDER_BUNDLED
	if typeof(d.catalog) != TYPE_DICTIONARY:
		return "binding catalog must be an object"
	err = _exact_keys(d.catalog, CATALOG_KEYS, "binding catalog")
	if err != "":
		return err
	if typeof(d.catalog.id) != TYPE_STRING or not is_slug(d.catalog.id, false):
		return "binding catalog.id must match [a-z0-9_]{1,64}"
	if not _is_pos_int(d.catalog.version):
		return "binding catalog.version must be a positive integer"
	if typeof(d.catalog.sha256) != TYPE_STRING or not Schema.matches("sha256", d.catalog.sha256):
		return "binding catalog.sha256 must be 64 lowercase hex digits"
	if typeof(d.asset_id) != TYPE_STRING or not is_slug(d.asset_id, true):
		return "binding asset_id must match [a-z0-9_.]{1,64}"
	if not _is_pos_int(d.asset_version):
		return "binding asset_version must be a positive integer"
	catalog_id = d.catalog.id
	catalog_version = int(d.catalog.version)
	catalog_sha256 = d.catalog.sha256
	asset_id = d.asset_id
	asset_version = int(d.asset_version)
	return ""


func _parse_assetstudio(d: Dictionary) -> String:
	var err := _exact_keys(d, ASSETSTUDIO_KEYS, "assetstudio binding")
	if err != "":
		return err
	provider = PROVIDER_ASSETSTUDIO
	err = AssetRef.validate(d.asset_ref)
	if err != "":
		return err
	var ref: Dictionary = d.asset_ref
	if typeof(d.asset_key) != TYPE_STRING or d.asset_key != Canonical.asset_key(ref.server_id, ref.library_id,
			ref.asset_id, ref.version_id):
		return "asset_key does not match asset_ref"
	err = _parse_descriptor(d.descriptor_json, d.descriptor_sha256, ref)
	if err == "":
		err = _parse_deliveries(d.deliveries)
	if err != "":
		return err
	asset_key = d.asset_key
	asset_ref = ref.duplicate(true)
	descriptor_json = d.descriptor_json
	descriptor_sha256 = d.descriptor_sha256
	deliveries = d.deliveries.duplicate(true)
	return ""


static func _parse_descriptor(text: Variant, sha: Variant, ref: Dictionary) -> String:
	if typeof(text) != TYPE_STRING or text.length() < 2 or text.length() > MAX_DESCRIPTOR_CHARS:
		return "descriptor_json must be a string of 2..%d characters" % MAX_DESCRIPTOR_CHARS
	if typeof(sha) != TYPE_STRING or not Schema.matches("sha256", sha):
		return "descriptor_sha256 must be 64 lowercase hex digits"
	var raw: PackedByteArray = text.to_utf8_buffer()
	if Canonical.sha256_hex(raw) != sha:
		return "descriptor_sha256 mismatch: it does not match descriptor_json"
	var parsed: RefCounted = AssetDescriptor.parse_bytes(raw)
	if not parsed.ok:
		return parsed.message
	if parsed.value.asset_ref.to_dict() != ref:
		return "descriptor asset_ref differs from the binding asset_ref"
	return ""


static func _parse_deliveries(v: Variant) -> String:
	if typeof(v) != TYPE_DICTIONARY:
		return "deliveries must be an object"
	var err := Schema.check_keys(v, PackedStringArray([REQUIRED_DELIVERY]), PackedStringArray([OPTIONAL_DELIVERY]), "deliveries")
	if err != "":
		return err
	for key: String in v:
		err = pin_error(v[key], "deliveries." + key)
		if err != "":
			return err
	return ""


## "" when `pin` is a well-formed delivery pin (also used for dependency entries).
static func pin_error(pin: Variant, field: String) -> String:
	if typeof(pin) != TYPE_DICTIONARY:
		return "%s must be an object" % field
	var err := Schema.check_keys(pin, PackedStringArray(PIN_KEYS), PackedStringArray(), field)
	if err == "":
		err = Schema.check_pattern(pin.delivery_id, "delivery_id", field + ".delivery_id")
	if err == "":
		err = Schema.check_pattern(pin.manifest_sha256, "sha256", field + ".manifest_sha256")
	if err == "":
		err = Schema.check_pattern(pin.profile_id, "slug", field + ".profile_id")
	if err == "":
		err = Schema.check_pattern(pin.profile_version, "slug", field + ".profile_version")
	return err


## Policy ranges are canonical decimals ordered lo <= hi; for AssetStudio they lie within the descriptor's.
func _parse_policy(p: Variant, descriptor_text: Variant) -> String:
	if typeof(p) != TYPE_DICTIONARY:
		return "binding policy must be an object"
	var err := _exact_keys(p, POLICY_KEYS, "binding policy")
	if err != "":
		return err
	if typeof(p.scatter_allowed) != TYPE_BOOL:
		return "policy.scatter_allowed must be a boolean"
	err = Schema.check_decimal_array(p.scale_range, 2, true, "policy.scale_range")
	if err == "":
		err = Schema.check_decimal_array(p.height_offset_range_m, 2, false, "policy.height_offset_range_m")
	if err != "":
		return err
	if Schema.micro(p.scale_range[0]) > Schema.micro(p.scale_range[1]) \
			or Schema.micro(p.height_offset_range_m[0]) > Schema.micro(p.height_offset_range_m[1]):
		return "policy range minimum exceeds its maximum"
	if provider == PROVIDER_ASSETSTUDIO:
		err = _descriptor_range_error(p, str(descriptor_text))
		if err != "":
			return err
	set_policy(p.scatter_allowed, p.scale_range[0], p.scale_range[1], p.height_offset_range_m[0], p.height_offset_range_m[1])
	return ""


static func _descriptor_range_error(p: Dictionary, descriptor_text: String) -> String:
	var desc: Variant = JSON.parse_string(descriptor_text)
	if typeof(desc) != TYPE_DICTIONARY:
		return "descriptor_json is not an object"
	for key in ["scale_range", "height_offset_range_m"]:
		var outer: Array = desc[key]
		var inner: Array = p[key]
		if Schema.micro(inner[0]) < Schema.micro(outer[0]) or Schema.micro(inner[1]) > Schema.micro(outer[1]):
			return "policy.%s lies outside the descriptor's %s" % [key, key]
	return ""


static func _exact_keys(d: Dictionary, keys: Array, what: String) -> String:
	return Schema.check_keys(d, PackedStringArray(keys), PackedStringArray(), what)


static func _is_pos_int(v: Variant) -> bool:
	return (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) and is_finite(float(v)) \
		and float(v) == floorf(float(v)) and float(v) >= 1.0 and float(v) <= 4294967295.0
