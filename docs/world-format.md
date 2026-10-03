# World format (schemas 2, 3 and 4)

Contract shared by the Godot app (`app/addons/world_painter/core/storage`, `app/addons/world_painter/core/document`) and the Python
tools (`scripts/worldpoc_format.py`). Any change here requires a schema bump and matching
changes and tests on both sides. Schema 2 (ADR 0009) adds four material slots with auto-paint
rules, a tint map, scatter instances and spline paths. Schema 1 data is rejected as an
unknown schema; there is no migration.

Schema 3 (ADR 0010, §11) is schema 2 plus a rectangular terrain layout of 1–64 regions (the
"1 km" preset is 8 × 8 regions) and larger, centralized limits. Sections 1–10 describe schema 2;
§11 lists every schema 3 difference.

Schema 4 (ADR 0014, §12) is schema 3 plus a world-specific asset lock (`asset_locks.json`) that replaces the
single bundled catalog reference. Writers always emit schema 4, on every layout including the legacy 2 × 2
layout. Readers accept schemas 2, 3 and 4; schema 2/3 generations keep their V2/V3 authored hashes and are
converted to bundled bindings in memory or offline (`validate_world.py migrate`, §12.7). The older text of
§§1–11 still describes those schemas (a schema 2/3 world on the legacy layout is schema 2, byte-identical to
before).

## 1. Terrain layout

Fixed for the PoC and mirrored from pinned Terrain3D 1.0.2 (see `WorldConstants`):

| Item | Value |
|---|---|
| Sample spacing | 0.5 m |
| Region samples | 256 × 256 (no duplicated seam row) |
| Regions | `(-1,-1)`, `(0,-1)`, `(-1,0)`, `(0,0)`; canonical order sorted by Z, then X |
| Global sample `g` | world coordinate `g * 0.5`; valid `g ∈ [-256, 255]` on both axes |
| Region of sample | `floor(g / 256)` (arithmetic shift); local index `g - 256 * region` |
| Bilinear extent | `[-128.0, 127.5]` m on X and Z; outside is *no sample* (never 0) |
| Buffer order | row-major: `index = local_z * 256 + local_x` (X column, Z row) |
| Height | float32, finite, `[-32, 64]` m |
| Control | uint32 Terrain3D control value (bit layout in `ControlCodec`) |
| Color | 4 bytes per sample `R, G, B, A` (tint map, §1.2) |

### 1.1 Control and auto-paint rules

`control_schema = "terrain3d-1.0.2-control-v2"`. Base id and overlay id must both be `< 4`
(material slots `0 = grass`, `1 = dirt`, `2 = rock`, `3 = sand`). All other bits, including
reserved bits 3–6, the navigation bit 1, UV rotation and UV scale, are opaque and must
round-trip unchanged. The hole bit (bit 2) is supported and preserved. Surface sampling returns
no sample inside the containing hole control cell; raw authored heights remain finite and
unchanged.

The auto bit (bit 0) selects where the base material comes from:

- **auto bit set**: the rendered base material is the result of the world's auto-paint rules
  (§3 `terrain.rules`) evaluated at the rendered point. The stored base id is ignored for
  rendering but still validated (`< 4`) and preserved. Overlay id and blend still apply on top
  (manual paint over the rule layer).
- **auto bit clear**: base, overlay and blend are all manual.

Rule evaluation (renderer contract, not stored data): start with grass; if `sand_enabled` and
height `< sand_height_dm / 10` m, use sand; then if `rock_enabled` and slope `> rock_slope_deg`
degrees, use rock (rock wins). Edges may be smoothed by the renderer.

New worlds and all bundled fixtures use control `0x00000001` everywhere (auto bit set, base 0,
overlay 0, blend 0): the rule layer only.

### 1.2 Tint map

`color_encoding = "rgba8-tint-v1"`. Per sample: `R, G, B` = tint colour (sRGB 8-bit), `A` =
tint weight (0 = no tint, 255 = full tint). Default `FF FF FF 00`. Any byte value is valid. The
renderer mixes the tint over the material colour by at most 60 % at weight 255.

## 2. Generation directory

A complete, immutable saved revision:

```
<generation>/
  manifest.json          written last
  objects.json
  paths.bin
  scatter.bin
  regions/
    r_-1_-1.color.rgba8    262144 bytes, R,G,B,A per sample
    r_-1_-1.control.u32le  262144 bytes, little-endian uint32
    r_-1_-1.height.f32le   262144 bytes, little-endian float32
    ... (12 region files)
```

Working storage: `user://worlds/<world_id>/generations/<NNNNNNNN>/` (8-digit decimal,
monotonic). Temporary generations are `<NNNNNNNN>.tmp/` and are ignored by recovery.
Bundled fixtures (`res://fixtures/<name>/`) are generation directories too, read-only.

## 3. manifest.json

```json
{
  "format": "world-painter-poc",
  "schema_version": 2,
  "world_id": "<uuid v4, lowercase>",
  "document_revision": 2,
  "created_with": {"godot": "4.7.2.stable.official.ed1daf0bf", "terrain3d": "1.0.2-stable@0077405b", "world_painter": "<app version or commit>"},
  "catalog": {"id": "poc_nature", "version": 2, "sha256": "<catalog content hash>"},
  "terrain": {
    "sample_spacing_m": 0.5,
    "region_samples": 256,
    "region_locations": [[-1, -1], [0, -1], [-1, 0], [0, 0]],
    "height_encoding": "float32-little-endian",
    "control_encoding": "uint32-little-endian",
    "control_schema": "terrain3d-1.0.2-control-v2",
    "color_encoding": "rgba8-tint-v1",
    "material_slots": {"0": "grass", "1": "dirt", "2": "rock", "3": "sand"},
    "rules": {"rock_enabled": true, "rock_slope_deg": 30, "sand_enabled": true, "sand_height_dm": -4}
  },
  "payload_files": [{"path": "objects.json", "bytes": 123, "sha256": "<hex>"}, ...],
  "authored_content_hash": "<hex>"
}
```

- `payload_files` lists exactly the 15 payload files (objects.json, paths.bin, scatter.bin and
  the 12 region files) sorted by path (byte-wise), with real byte lengths and lowercase hex
  SHA-256. Missing or placeholder hashes fail.
- Integers arrive from JSON as floats in Godot; loaders must check they are integral.
- `region_locations` must equal the list above exactly (order included).
- `terrain.rules` has exactly these four keys. `rock_enabled`/`sand_enabled` are JSON booleans.
  `rock_slope_deg` is an integer in `[10, 60]`; `sand_height_dm` an integer in `[-30, 30]`
  (decimetres, so −0.4 m is `-4`). Integers keep the values exact without `f64le`.
- Defaults for new worlds and fixtures: the example values above.

## 4. objects.json

```json
{"schema_version": 2, "objects": [ <record>, ... ]}
```

Records sorted by `object_id` (byte-wise ascending). Record fields:

| Field | Rule |
|---|---|
| `object_id` | lowercase UUID string, unique |
| `asset_id`, `asset_version` | must exist in the trusted catalog with that version |
| `position` | 3 finite numbers; world position of the placement anchor; X/Z within the bilinear extent |
| `rotation_xyzw` | 4 finite numbers, unit length within 1e-6 |
| `uniform_scale` | finite, within the asset's `[scale_min, scale_max]`, > 0 |
| `grounding` | `FOLLOW_TERRAIN` or `WORLD_FIXED` |
| `height_offset_m` | finite, within the asset's height-offset limits |
| `origin` | `MANUAL` (schema 2 writers only produce `MANUAL`; `SCATTER` stays valid) |
| `scatter_operation_id` | `null` or lowercase UUID |
| `f64le` | exact values, see below |

**Exact float values (ADR 0003).** Godot 4.7's JSON number parser is not correctly rounded,
so decimal fields alone cannot reproduce the saved float64 values. Every record carries
`"f64le": {"position": [h,h,h], "rotation_xyzw": [h,h,h,h], "uniform_scale": h, "height_offset_m": h}`
where each `h` is the 16-hex-digit little-endian byte encoding of the IEEE-754 double
(Python: `struct.pack('<d', v).hex()`; `0.1` → `9a9999999999b93f`). Loaders use the bits and
reject a record whose bits are missing, malformed, non-finite, or differ from the decimal by
more than `1e-9 * max(1, |decimal|)`.

`FOLLOW_TERRAIN` consistency (`position.y == terrain_height(x, z) + height_offset_m`) is checked
as a separate report, never by re-snapping on load.

## 5. scatter.bin

Scatter instances (ground cover, scattered trees and rocks). Instances have no IDs and always
follow the terrain: an instance's Y is the bilinear surface height at its X/Z, so sculpting
moves instances without changing this file. Little-endian, `str` = u32 byte length + UTF-8:

```
"WPSC"                      4 ASCII bytes
u32 version = 1
u32 asset_count
per asset: str asset_id, u32 asset_version
u32 instance_count
per instance (20 bytes): u16 asset_index, u16 flags, f32 x, f32 z, f32 yaw_rad, f32 scale
```

- The asset table lists exactly the assets referenced by at least one instance, sorted by
  `asset_id` byte-wise, without duplicates. Each must exist in the trusted catalog with that
  version and have `scatter_allowed = true` and a non-null `scatter_mesh`.
- `asset_index < asset_count`. `flags` bit 0 = tilt to the terrain normal; all other bits 0.
- `x`, `z` finite and within the bilinear extent; `yaw_rad` finite with `|yaw_rad| <= 3.1416`;
  `scale` finite and within the asset's `[scale_min, scale_max]`.
- `instance_count <= 20000`. Instance order is significant and preserved (it is the document
  order; undo restores it exactly). No trailing bytes.
- Empty file: `"WPSC"`, 1, 0, 0 (16 bytes).

## 6. paths.bin

Spline paths. Each path is a uniform Catmull-Rom curve through its control points (end points
duplicated), rendered as a terrain-draped ribbon of the given width.

```
"WPPA"                      4 ASCII bytes
u32 version = 1
u32 path_count
per path: str path_id, f32 width_m, u32 point_count, point_count × (f32 x, f32 z)
```

- Paths sorted by `path_id` byte-wise; ids are lowercase UUID v4 strings, unique.
- `path_count <= 256`; `point_count` in `[2, 256]`; `width_m` finite in `[1, 6]`.
- Points finite and within the bilinear extent. No trailing bytes.
- Empty file: `"WPPA"`, 1, 0 (12 bytes).

## 7. Authored content hash

`authored_content_hash = sha256(stream)`, lowercase hex. Stream (integers little-endian,
`str` = u32 byte length + UTF-8, `f64` = IEEE-754 double LE with `-0.0` written as `+0.0`,
`u8` bool = 0 or 1):

```
"WPOC-AUTHORED-V2\n"
u32 schema_version
str catalog.id, u32 catalog.version, str catalog.sha256
f64 sample_spacing_m, u32 region_samples
u8 rock_enabled, i32 rock_slope_deg, u8 sand_enabled, i32 sand_height_dm
u32 region_count
per region in canonical order: i32 x, i32 z, 32 raw bytes sha256(height file),
  32 raw bytes sha256(control file), 32 raw bytes sha256(color file)
32 raw bytes sha256(scatter.bin), 32 raw bytes sha256(paths.bin)
u32 object_count
per object sorted by object_id: str object_id, str asset_id, u32 asset_version,
  f64 position[3], f64 rotation_xyzw[4], f64 uniform_scale, str grounding,
  f64 height_offset_m, str origin, str scatter_operation_id ("" when null)
```

`world_id` and `document_revision` are excluded: the same authored content has the same hash
after undo+redo, reopen, or copy. Implemented by `CanonicalEncoder` (GDScript) and
`authored_hash()` (Python); both are tested against the same vectors.

## 8. Catalog content hash

`catalog.sha256 = sha256(stream)` over raw file bytes, so JSON float parsing never matters:

```
"WPOC-CATALOG-V1\n"
str "catalog.json", 32 raw bytes sha256(catalog.json bytes)
u32 file_count
per referenced geometry file, sorted by res:// path: str path, 32 raw bytes sha256(file bytes)
```

Referenced geometry files are every non-null `preview_scene` and `scatter_mesh`. Thumbnails
are excluded. Model scenes and scatter meshes must be self-contained text resources (no
`ext_resource`), and the project sets `editor/export/convert_text_resources_to_binary=false` so
exported bytes match. Same asset ID with a changed pivot or mesh therefore changes the catalog
hash and is rejected as incompatible.

## 9. `.worldpoc` package

A ZIP containing exactly one generation: `manifest.json`, `objects.json`, `paths.bin`,
`scatter.bin` and the 12 region files at the paths above (an optional `regions/` directory
entry is tolerated). Nothing else.

Validation before extraction (central directory inspected first):

- reject absolute paths, `..` segments, backslashes, duplicate names, unknown names, symlinks
- per-entry uncompressed size limits: region files exactly 262144; `manifest.json` ≤ 64 KiB;
  `objects.json` ≤ 4 MiB; `scatter.bin` ≤ 512 KiB; `paths.bin` ≤ 640 KiB; total ≤ 12 MiB;
  object count ≤ 2000
- archive file size ≤ 20 MiB, entry count 1–20; reject encryption and ZIP64 fields/locators
- EOCD is exactly the final 22 bytes: no archive comment or trailing data; single disk only
- central directory bounds must end immediately before EOCD; reject shifted/prepended data
- Godot additionally checks local headers, matching names/methods/flags, and data bounds before
  extraction; Python zipfile checks local headers during extraction and verifies CRC
- only stored or deflate compression
- extract only into a new temporary directory; then validate as a generation directory
- after decompression, each entry's size must equal the central-directory size

Validation of a generation (both languages): schema/format, required fields, exact region
set and byte lengths, payload hashes, control layout, material slots, rules, catalog identity
(id, version, sha256 must match the trusted catalog exactly), unique object IDs, finite and
bounded heights and transforms, allowed enums, scatter and path files (§5, §6), authored hash.
Unknown schema or catalog fails with an explicit diagnostic; there is no remapping or partial
load.

## 10. Endianness

Files are little-endian. Godot code converts with `to_byte_array()`/`to_float32_array()`,
which is only correct on little-endian hosts; `WorldConstants.host_is_little_endian()` is
asserted at startup (all Apple targets are little-endian).

## 11. Schema 3: layout worlds

Schema 3 changes only the items below; everything else (sample spacing, region size and
buffer order, height/control/tint encodings, rules, object records, scatter and path record
formats, exact floats, endianness) is identical to schema 2.

### 11.1 Layout

A layout is a rectangle of regions: `min_region = (mx, mz)` and `region_count = (cx, cz)`.

- `cx`, `cz` are integers in `[1, 8]`; `mx`, `mz` integers in `[-8, 7]`; `mx + cx <= 8` and
  `mz + cz <= 8` (every region coordinate lies in `[-8, 7]`, inside Terrain3D's region map).
- Regions: every `(x, z)` with `mx <= x < mx + cx` and `mz <= z < mz + cz`; canonical order sorted
  by Z, then X (row-major), as in schema 2.
- Valid global samples per axis: `g ∈ [256 * m, 256 * (m + c) - 1]`; bilinear extent
  `[128 * m, 128 * (m + c) - 0.5]` m. Outside is *no sample* (never 0). There is no duplicated
  seam row; sampling at the maximum edge clamps the `+1` neighbour index exactly as in schema 2.
- The legacy layout (`min_region (-1, -1)`, `region_count (2, 2)`) is **schema 2 only**. A
  schema 3 world with the legacy layout is rejected, so every world has one canonical encoding.
- Preset `km1` (spec "approximately 1 km"): `min_region (-4, -4)`, `region_count (8, 8)`;
  regions `[-4, 3] × [-4, 3]` (64); samples `[-1024, 1023]`; extent `[-512.0, 511.5]` m;
  nominal size 1024 × 1024 m.

### 11.2 manifest.json

- `"schema_version": 3`.
- `terrain` has exactly the schema 2 keys plus `"layout": {"min_region": [mx, mz], "region_count": [cx, cz]}`
  (exactly these two keys; integers).
- `terrain.region_locations` must equal the layout's region list in canonical order exactly.
- `payload_files` lists exactly `objects.json`, `paths.bin`, `scatter.bin` and the three files of
  every layout region (`3 + 3 * region_count` entries), sorted by path byte-wise.

`objects.json` carries `"schema_version": 3`; `scatter.bin` and `paths.bin` keep their own
version 1 headers.

### 11.3 Limits (centralized: `WorldLimits` in GDScript, `limits_for_schema()` in Python)

| Limit | Schema 2 | Schema 3 |
|---|---:|---:|
| Regions | 4 (fixed list) | 1–64 (layout rectangle) |
| Object records (`objects.json`) | ≤ 2,000 | ≤ 50,000 |
| `objects.json` bytes | ≤ 4 MiB | ≤ 128 MiB |
| Scatter instances | ≤ 20,000 | ≤ 100,000 |
| `scatter.bin` bytes | ≤ 512 KiB | ≤ 4 MiB |
| `paths.bin` bytes | ≤ 640 KiB | ≤ 640 KiB |
| `manifest.json` bytes | ≤ 64 KiB | ≤ 256 KiB |
| Total uncompressed package | ≤ 12 MiB | ≤ 256 MiB |
| Archive file size | ≤ 20 MiB | ≤ 264 MiB |
| Archive entries | 1–20 | 1–197 |

Object records are the meaningful (manual) placements; scatter instances include scattered
trees/rocks and decorative ground cover. Paths keep their schema 2 limits.

**Package inspection order.** The central directory is inspected before `manifest.json` is
read, so ZIP inspection applies the schema 3 envelope: entry count ≤ 197 (including the optional
`regions/` directory entry), total ≤ 256 MiB, archive ≤ 264 MiB, `manifest.json` ≤ 256 KiB,
`objects.json` ≤ 128 MiB, `scatter.bin` ≤ 4 MiB, `paths.bin` ≤ 640 KiB, and region files must be
named `regions/r_<x>_<z>.{height.f32le,control.u32le,color.rgba8}` with integer `x, z ∈ [-8, 7]`
(decimal, `-` sign only for negatives, no leading zeros or `+`) and exactly 262144 bytes. All other
schema 2 ZIP rules are unchanged. After extraction, generation validation applies the limits of
the manifest's schema (a schema 2 package with 2,001 objects still fails) and the exact file set of
its layout.

Limits are admission limits, not a memory guarantee: loaders reject over-limit inputs before
allocating per-record structures where the format allows it (declared counts in binary headers,
byte lengths from the directory listing).

### 11.4 Authored content hash V3

As §7 with magic `"WPOC-AUTHORED-V3\n"`, `u32 schema_version = 3`, and the layout inserted after
`region_samples`:

```
"WPOC-AUTHORED-V3\n"
u32 schema_version
str catalog.id, u32 catalog.version, str catalog.sha256
f64 sample_spacing_m, u32 region_samples
i32 min_region_x, i32 min_region_z, u32 region_count_x, u32 region_count_z
u8 rock_enabled, i32 rock_slope_deg, u8 sand_enabled, i32 sand_height_dm
u32 region_count
... identical to V2 from here (regions in canonical order, scatter/paths hashes, objects)
```

Schema 2 worlds keep the V2 stream and their existing hashes. The writer chooses the schema from
the document's layout (legacy → 2, anything else → 3); opening a file never rewrites it.

### 11.5 Cross-language vector

`km1` flat vector (tested in both languages against one hard-coded hash): layout `km1`, every
height `0.0`, every control `0x00000001`, every tint `FF FF FF 00`, default rules, no objects,
empty `scatter.bin` and `paths.bin` (§5, §6 empty files), catalog identity of the bundled catalog.

## 12. Schema 4: asset bindings

Contract files (normative, frozen): [`contracts/world-painter/world-v4/`](../contracts/world-painter/world-v4/)
(`asset-locks.schema.json`, `objects.schema.json`, `binary-formats.md`, `authored-hash-v4.md`); decisions D1–D10
in [ADR 0014](decisions/0014-world-schema-4.md); shared spec INT-SPEC-1.1 §9. Schema 4 changes only the items below;
terrain, region files, rules, `paths.bin` v1, exact floats, ZIP rules and endianness are schema 3.

### 12.1 Files and manifest

- Generation: `manifest.json`, `asset_locks.json`, `objects.json`, `scatter.bin` (version 2), `paths.bin`,
  `regions/r_<x>_<z>.{height.f32le,control.u32le,color.rgba8}`. Every valid layout is allowed, including the legacy
  2 × 2 layout.
- `manifest.json`: `"schema_version": 4`; `terrain` is the schema 3 object and **always** has `layout`; `catalog` is
  replaced by `"asset_lock": {"path": "asset_locks.json", "sha256": "<hex of the stored bytes>"}`; `payload_files`
  lists `asset_locks.json`, `objects.json`, `paths.bin`, `scatter.bin` and 3 files per region (`4 + 3n`), sorted byte-wise.
- `objects.json`: `{"schema_version": 4, ...}`; each record has `binding_id` instead of `asset_id`/`asset_version`.

### 12.2 asset_locks.json

Stored bytes are exactly `canonical_v1(lock)` (AssetStudio canonical JSON: no floats, sorted keys, no whitespace,
UTF-8; escapes `\"`, `\\`, `\n \r \t \b \f`, other code points below U+0020 as lowercase `\u00xx`, nothing else).
Readers hash the received bytes and reject bytes that differ from re-encoding the parsed value. Fields:
`schema_version` (1), `bindings` (sorted by `binding_id`, unique, ≤ 4,096), `dependencies` (the exact AssetStudio asset-key
structure). A binding is `bundled` (`catalog {id, version, sha256}`, `asset_id`, `asset_version`, `policy`) or
`assetstudio` (`asset_key`, `asset_ref`, `descriptor_json`, `descriptor_sha256`, `deliveries`, `policy`); see the schema.
Bundled `asset_id` uses the catalog grammar `[a-z0-9_.]{1,64}` (catalog ids contain dots).

- `binding_id = "b" + sha256_hex("WPBIND1\n" + canonical_v1(binding without binding_id))[0:32]`; readers recompute it.
- `policy = {scatter_allowed, scale_range, height_offset_range_m}` with canonical decimal strings (`dec(x)`: six
  fractional digits, trailing zeros removed, `-0` written `0`). The default bundled policy of a catalog entry is
  `[dec(scale_min), dec(scale_max)]`, `[dec(height_offset_min_m), dec(height_offset_max_m)]` and
  `scatter_allowed = catalog.scatter_allowed AND catalog.scatter_mesh != null`. Policy ranges lie within the catalog
  entry's limits (when the entry is available) or the descriptor's ranges.
- AssetStudio bindings: `asset_key` equals the key of `asset_ref`; `descriptor_sha256` is checked over the UTF-8 bytes
  of `descriptor_json` before it is parsed; `dependencies` equal exactly the closure of the referenced bindings
  (matching `asset_ref`, `descriptor_sha256`, delivery pins; `requires` sorted, present, acyclic).
- Every binding is referenced by an object record or scatter instance.

Python: `scripts/worldpoc_locks.py`, `worldpoc_lockcheck.py`; vectors: `fixtures/canonical-lock-vectors.json`.

### 12.3 Records and scatter

`uniform_scale` and `height_offset_m` of an object, and `scale` of a scatter instance, lie within the binding's effective
policy range: `lo - eps(lo) <= v <= hi + eps(hi)` with `eps(b) = 1e-6 * max(1, |b|)`. A scatter binding needs
`policy.scatter_allowed = true`. `scatter.bin` version 2 (`binary-formats.md`) stores a sorted binding table instead of
the asset table; the 20-byte instance record is unchanged.

### 12.4 Limits

Schema 3 limits (§11.3) plus `asset_locks.json` ≤ 8 MiB, ≤ 4,096 bindings and ≤ 198 archive entries (197 without
the lock). ZIP inspection runs before the manifest is read: it accepts the `asset_locks.json` entry (≤ 8 MiB) and 198
entries; an archive without that entry is held to 197.

### 12.5 Authored content hash V4

`authored-hash-v4.md` (`"WPOC-AUTHORED-V4\n"`): the V3 stream with the catalog identity replaced by the raw SHA-256 of
the lock bytes and `asset_id`/`asset_version` replaced by `binding_id`.

### 12.6 Structure versus availability

Structural errors reject a generation. Availability is reported separately and never fails validation: a bundled
binding whose catalog identity differs from the trusted catalog or whose asset/version is not in it, and every
AssetStudio binding (no resolver yet). `validate_world.py` prints it as `Availability`, `--json` as `availability`.

### 12.7 Migration and fixtures

`python3 scripts/validate_world.py migrate SRC DEST [--package OUT.worldpoc]` converts a schema 2/3 generation
directory or package into a new schema 4 generation directory (DEST must not exist): each catalog asset in use becomes a
bundled binding with the default policy; region bytes, rules, `paths.bin`, object IDs, transform bits, and scatter
records (order, positions, yaw, scale, flags) are unchanged. Authored hashes change by design.

Golden fixtures and vectors: `contracts/world-painter/world-v4/fixtures/` (`INDEX.json`, regenerated and verified by
`python3 scripts/generate_world_v4_fixtures.py [--check]`). The `km1_flat_empty` vector is procedural (recipe in
`INDEX.json`), like §11.5.
