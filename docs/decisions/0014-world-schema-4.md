# ADR 0014: World schema 4 and exact asset bindings (IP-02)

Status: accepted 2026-10-02. Implements INT-SPEC-1.1 §9 and IP-SPEC-1.1 §3. Contract files:
`contracts/world-painter/world-v4/`. Format doc: `docs/world-format.md` §12.

## Context

Schema 2/3 worlds reference assets as `asset_id` + integer `asset_version` of one trusted bundled catalog
(`poc_nature`). Schema 4 replaces that with a world-specific dependency lock (`asset_locks.json`) so a world can
reference exact AssetStudio versions next to bundled assets. Everything else is schema 3.

## Decisions

### D1. Writers always write schema 4; readers accept 2, 3, 4

- Every checkpoint, export and new world is schema 4, on every layout including legacy 2×2.
- Schema 2/3 generations stay readable (their V2/V3 authored hash is still verified on read) and are converted in
  memory to bundled bindings (D3). Opening never rewrites a file.
- Bundled fixtures under `app/fixtures/` stay schema 2/3 (they are migration inputs). Schema 4 golden fixtures live
  in `contracts/world-painter/world-v4/fixtures/`.

### D2. In-memory model

- `ObjectRecord.binding_id: String` replaces `asset_id` + `asset_version`.
- `ScatterLayer` slot table becomes `binding_ids: PackedStringArray` (no versions). Encoding writes scatter.bin v2.
- `WorldDocument.assets: WorldAssetLock` is a content-addressed, append-only registry `binding_id -> AssetBinding`.
  It may hold bindings no record references (e.g. after undo). It is **not** history data: a binding is immutable
  and identified by its content, so undo/redo never touches it.
- The serialized lock is derived: only bindings referenced by at least one object record or scatter instance,
  sorted by `binding_id`, plus the AssetStudio dependency closure of those bindings. Hence the authored hash depends
  only on referenced content and is identical after undo+redo.
- `WorldDocument.catalog_id/catalog_version/catalog_sha256` are removed. `WorldDocument.source_schema: int` records
  the schema a document was read from (2, 3 or 4; 4 for new worlds). It is not authored data.
- `WorldAssetLock.catalog` holds the trusted bundled `AssetCatalog` (runtime reference, not serialized).

### D3. Bundled bindings and default policy

A bundled binding is `{"provider":"bundled","catalog":{"id","version","sha256"},"asset_id","asset_version","policy"}`
plus `binding_id`. The default policy for a catalog entry (used by placement, scatter and migration) is:

- `scale_range = [dec(scale_min), dec(scale_max)]`, `height_offset_range_m = [dec(height_offset_min_m), dec(height_offset_max_m)]`
- `scatter_allowed = catalog.scatter_allowed AND catalog.scatter_mesh != null`

`dec(x)`: round to 6 fractional digits (`"%.6f"`, Python `f"{x:.6f}"`), strip trailing zeros and a trailing
`.`, and write `-0` as `0`. This is robust to the 1-ulp error of Godot's JSON float parser, so both languages
produce identical strings and therefore identical binding IDs. Output must satisfy the AssetStudio canonical decimal
grammar (`asset-ref.schema.json` `decimal`/`positive_decimal`).

Policy constraints: bundled ranges lie within the catalog entry's limits; `scatter_allowed` may be true only when
the catalog allows scatter. AssetStudio ranges lie within the descriptor's `scale_range`/`height_offset_range_m`.

### D4. binding_id and canonical bytes

- `binding_id = "b" + sha256_hex("WPBIND1\n" + canonical_v1(binding_without_binding_id))[0:32]` (UTF-8 bytes).
- `canonical_v1` is AssetStudio `canonical_v1`: Python `json.dumps(obj, sort_keys=True, separators=(",",":"),
  ensure_ascii=False, allow_nan=False).encode("utf-8")` after rejecting floats, non-string keys and non-JSON types.
- GDScript uses the vendored AssetStudio addon writer `res://addons/assetstudio/core/as_canonical_json.gd`
  (`encode()`, `is_canonical()`), pinned in `app/integration.lock.json`. World Painter does not carry a second
  canonical writer. Python (stdlib-only tooling) implements the one-line definition above in `worldpoc_locks.py`.
- `asset_locks.json` stored bytes are exactly `canonical_v1(lock)`. Readers hash the received bytes and reject
  bytes that differ from re-encoding the parsed value (`is_canonical`).

### D5. Effective limits and comparisons

`policy` ranges are the effective limits for `uniform_scale`, `height_offset_m` (objects) and scatter `scale`.
Bounds are parsed from canonical decimals to float64. A value `v` is inside `[lo, hi]` when
`v >= lo - eps(lo)` and `v <= hi + eps(hi)` with `eps(b) = 1e-6 * max(1, |b|)` (covers float32 scatter values and
parser ulp noise). Scatter instances require effective `scatter_allowed = true`.

### D6. AssetStudio bindings (structure only in IP-02)

Fields per INT-SPEC §9.2 and `asset-locks.schema.json`. Validation:

- `asset_key` equals the AssetStudio key of `asset_ref` (`sha256(len32le+utf8 per field: server_id, library_id,
  asset_id, version_id)`).
- `descriptor_sha256 == sha256(descriptor_json UTF-8 bytes)`, checked before parsing. The descriptor is then parsed
  and validated (GDScript: `as_asset_descriptor.gd`; Python: required keys, `schema_version` 1, `kind` `model3d`,
  units/axes constants, canonical decimals, ordered bounds, `asset_ref` equal to the binding's).
- `deliveries.portable_glb_v1` is required; optional `godot_static_source_v1`.
- `dependencies` (same structure as ProjectAssetLockV1 `dependencies`) must contain exactly the closure: for every
  referenced AssetStudio binding an entry at its `asset_key` with equal `asset_ref`, `descriptor_sha256`, and
  deliveries that include each of the binding's delivery pins; every `requires` key present; `requires` sorted and
  unique; no cycles; no entry outside the closure. A lock with only bundled bindings has `"dependencies": {}`.
- Byte availability is not structure (D8).

### D7. Schema 4 files

- `manifest.json`: schema 3 manifest with `schema_version: 4`, `terrain` exactly the schema 3 object (always
  including `layout`, also for the legacy layout), `catalog` replaced by
  `"asset_lock": {"path": "asset_locks.json", "sha256": "<hex>"}`. `payload_files` = `asset_locks.json`,
  `objects.json`, `paths.bin`, `scatter.bin` + 3 files per region (`4 + 3n`), sorted byte-wise.
- `objects.json`: `{"schema_version": 4, "objects": [...]}`; record field `binding_id` instead of
  `asset_id`/`asset_version`. Every `binding_id` must exist in the lock.
- `scatter.bin` v2 per `binary-formats.md`. `paths.bin` v1 unchanged.
- Authored hash: `authored-hash-v4.md` (`WPOC-AUTHORED-V4\n`).
- Limits: schema 3 limits plus `asset_locks.json` ≤ 8 MiB, ≤ 4,096 bindings, ZIP entries ≤ 198.
- Every lock binding is referenced (unreferenced bindings rejected).

### D8. Structure versus availability

`WorldValidator` separates:

- **structural errors** (reject the generation): format, hashes, limits, lock grammar/canonical bytes, binding_id
  mismatch, policy outside limits, records outside effective limits, unknown binding referenced, etc.
- **availability** (report, never reject): a bundled binding whose `catalog` identity differs from the trusted
  catalog or whose asset/version is not in it; an AssetStudio binding (always unavailable in IP-02; IP-03 adds the
  resolver). Effective limits of an unavailable binding still come from its policy, so records stay validated.

A structurally valid world with unavailable bindings opens in **read-only recovery**: the editor shows the world,
keeps every record, refuses authoring operations with a visible reason, and offers export/save-as. Recovery
(`find_latest_valid`) skips a generation only for structural errors.

### D9. Migration (schema 2/3 to 4)

- In memory: each catalog asset used by objects or scatter becomes a bundled binding with the default policy (D3)
  of the trusted catalog entry. Object IDs, transform bits, grounding, origin, scatter order/records, region bytes,
  rules and paths are unchanged. No asset is remeasured or replaced.
- The first checkpoint of a document whose `source_schema < 4` is the explicit upgrade: before writing, storage
  records the source generation in `<world>/pins.json` and writes `<world>/migrations/<dest-generation>.json`
  (`{"schema_version":1,"source_generation","source_schema","source_authored_hash","dest_generation",
  "dest_authored_hash"}`). Pruning never deletes a pinned generation. The source generation stays unchanged.
- `scripts/validate_world.py migrate <src> <dest>` performs the same conversion offline and both validators accept
  the result. Migration vectors: `migrate_v2`, `migrate_v3` fixtures with expected hashes.

### D10. Effective asset definitions for presentation

`WorldAssetLock.definition(binding_id) -> AssetDefinition` returns the effective definition used by tools and
renderers: for an available bundled binding, a copy of the catalog entry with scale/height-offset limits and
`scatter_allowed` replaced by the policy; for an unavailable or AssetStudio binding, a definition synthesized from
the frozen descriptor (bounds, anchor, footprint, default grounding; no preview scene/scatter mesh) or, for an
unavailable bundled binding, from policy only with an empty bounds box. `AssetDefinition.asset_id` is the **render
key**: the catalog asset id for available bundled bindings, otherwise the binding id. Render registries are keyed by
render key, so unavailable/remote bindings fall into the existing NOT_READY placeholder path.

## Consequences

- One in-memory model for all schemas; history and checkpoints carry binding IDs only.
- New worlds written by this version cannot be opened by older builds (schema 4 unknown); acceptable for the PoC.
- `WP` class-name prefixes for the extracted addon are deferred (no collision with current consumers; re-check in
  IP-09 packaging).
