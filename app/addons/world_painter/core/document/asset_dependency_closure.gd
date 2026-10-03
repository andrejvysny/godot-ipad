class_name AssetDependencyClosure
extends RefCounted
## Validation of the lock's `dependencies` block against its AssetStudio bindings (ADR 0014 D6).
## Entry shape is ProjectAssetLockV1 `dependencies`: {asset_ref, descriptor_sha256, deliveries, requires}.

const Schema := preload("res://addons/assetstudio/core/as_schema.gd")
const Canonical := preload("res://addons/assetstudio/core/as_canonical.gd")
const AssetRef := preload("res://addons/assetstudio/core/as_asset_ref.gd")

const ENTRY_KEYS := ["asset_ref", "descriptor_sha256", "deliveries", "requires"]


## Returns "" when `deps` is exactly the closure of the AssetStudio `bindings` (Array[AssetBinding]).
static func error_of(deps: Dictionary, bindings: Array) -> String:
	for key: Variant in deps:
		if typeof(key) != TYPE_STRING or not Schema.matches("sha256", key):
			return "dependencies key '%s' is not an asset_key" % str(key)
		var err := _entry_error(key, deps[key])
		if err != "":
			return err
	var reach := {}
	for b: AssetBinding in bindings:
		var err := _binding_error(b, deps)
		if err != "":
			return err
		for key in closure_of(b.asset_key, deps):
			reach[key] = true
	for key: String in deps:
		if not reach.has(key):
			return "dependencies entry %s is outside the closure of the bindings" % key
	return _requires_error(deps, reach)


## asset_key + transitive requires, in discovery order. Unknown keys are skipped (error_of reports them).
static func closure_of(root: String, deps: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	var queue: Array[String] = [root]
	while not queue.is_empty():
		var key: String = queue.pop_back()
		if seen.has(key) or not deps.has(key):
			continue
		seen[key] = true
		out.append(key)
		for req: String in deps[key].requires:
			queue.append(req)
	return out


static func _binding_error(b: AssetBinding, deps: Dictionary) -> String:
	if not deps.has(b.asset_key):
		return "dependencies are missing the entry for binding %s (asset_key %s)" % [b.binding_id, b.asset_key]
	var entry: Dictionary = deps[b.asset_key]
	if entry.asset_ref != b.asset_ref or entry.descriptor_sha256 != b.descriptor_sha256:
		return "dependencies entry %s differs from binding %s" % [b.asset_key, b.binding_id]
	for kind: String in b.deliveries:
		if not entry.deliveries.has(kind) or entry.deliveries[kind] != b.deliveries[kind]:
			return "dependencies entry %s lacks the %s pin of binding %s" % [b.asset_key, kind, b.binding_id]
	return ""


static func _entry_error(key: String, e: Variant) -> String:
	if typeof(e) != TYPE_DICTIONARY:
		return "dependencies entry %s is not an object" % key
	var err := Schema.check_keys(e, PackedStringArray(ENTRY_KEYS), PackedStringArray(), "dependencies entry")
	if err == "":
		err = AssetRef.validate(e.asset_ref)
	if err != "":
		return err
	var ref: Dictionary = e.asset_ref
	if Canonical.asset_key(ref.server_id, ref.library_id, ref.asset_id, ref.version_id) != key:
		return "dependencies entry %s does not match its asset_ref" % key
	err = Schema.check_pattern(e.descriptor_sha256, "sha256", "dependencies entry descriptor_sha256")
	if err == "":
		err = _deliveries_error(e.deliveries)
	if err == "":
		err = _requires_shape_error(e.requires)
	return err


static func _deliveries_error(v: Variant) -> String:
	if typeof(v) != TYPE_DICTIONARY:
		return "dependencies deliveries must be an object"
	for kind: Variant in v:
		if typeof(kind) != TYPE_STRING or not Schema.REPRESENTATIONS.has(kind):
			return "dependencies deliveries has unknown representation '%s'" % str(kind)
		var err := AssetBinding.pin_error(v[kind], "dependencies deliveries." + kind)
		if err != "":
			return err
	return ""


static func _requires_shape_error(v: Variant) -> String:
	if typeof(v) != TYPE_ARRAY:
		return "dependencies requires must be an array"
	var prev := ""
	for i in v.size():
		var r: Variant = v[i]
		if typeof(r) != TYPE_STRING or not Schema.matches("sha256", r):
			return "dependencies requires holds a non-asset_key"
		if i > 0 and not (prev < r):
			return "dependencies requires is not sorted and unique"
		prev = r
	return ""


## Every requirement present and no cycle (Kahn's algorithm over the reachable subgraph).
static func _requires_error(deps: Dictionary, reach: Dictionary) -> String:
	var indegree := {}
	for key: String in reach:
		indegree[key] = 0
	for key: String in reach:
		for req: String in deps[key].requires:
			if not reach.has(req):
				return "dependencies entry %s requires %s, which is missing" % [key, req]
			indegree[req] += 1
	var ready: Array[String] = []
	for key: String in indegree:
		if indegree[key] == 0:
			ready.append(key)
	var processed := 0
	while not ready.is_empty():
		var key: String = ready.pop_back()
		processed += 1
		for req: String in deps[key].requires:
			indegree[req] -= 1
			if indegree[req] == 0:
				ready.append(req)
	return "" if processed == reach.size() else "dependencies contain a cycle"
