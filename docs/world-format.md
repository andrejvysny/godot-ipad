# World format (schema 1)

Contract shared by the Godot app (`app/src/storage`, `app/src/document`) and the Python
tools (`scripts/worldpoc_format.py`). Any change here requires a schema bump and matching
changes and tests on both sides.

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

Supported control layout (`control_schema = "terrain3d-1.0.2-control-v1"`): base id and
overlay id must both be `< 2` (material slots `0 = grass`, `1 = dirt`). All other bits,
including reserved bits 3–6, are opaque and must round-trip unchanged. Control data is
validated as uint32; NaN-like float patterns are not supported because their base texture ID
is outside the two material slots. Raw codec tests still verify arbitrary uint32 reinterpretation.
The hole bit (bit 2) is supported and preserved. Surface sampling returns no sample inside
the containing hole control cell; raw authored heights remain finite and unchanged.

## 2. Generation directory

A complete, immutable saved revision:

```
<generation>/
  manifest.json          written last
  objects.json
  regions/
    r_-1_-1.height.f32le   262144 bytes, little-endian float32
    r_-1_-1.control.u32le  262144 bytes, little-endian uint32
    ... (8 region files)
```

Working storage: `user://worlds/<world_id>/generations/<NNNNNNNN>/` (8-digit decimal,
monotonic). Temporary generations are `<NNNNNNNN>.tmp/` and are ignored by recovery.
Bundled fixtures (`res://fixtures/<name>/`) are generation directories too, read-only.

## 3. manifest.json

```json
{
  "format": "world-painter-poc",
  "schema_version": 1,
  "world_id": "<uuid v4, lowercase>",
  "document_revision": 2,
  "created_with": {"godot": "4.7.2.stable.official.ed1daf0bf", "terrain3d": "1.0.2-stable@0077405b", "world_painter": "<app version or commit>"},
  "catalog": {"id": "poc_nature", "version": 1, "sha256": "<catalog content hash>"},
  "terrain": {
    "sample_spacing_m": 0.5,
    "region_samples": 256,
    "region_locations": [[-1, -1], [0, -1], [-1, 0], [0, 0]],
    "height_encoding": "float32-little-endian",
    "control_encoding": "uint32-little-endian",
    "control_schema": "terrain3d-1.0.2-control-v1",
    "material_slots": {"0": "grass", "1": "dirt"}
  },
  "payload_files": [{"path": "objects.json", "bytes": 123, "sha256": "<hex>"}, ...],
  "authored_content_hash": "<hex>"
}
```

- `payload_files` lists exactly the 9 payload files (objects.json + 8 region files) sorted by
  path, with real byte lengths and lowercase hex SHA-256. Missing or placeholder hashes fail.
- Integers arrive from JSON as floats in Godot; loaders must check they are integral.
- `region_locations` must equal the list above exactly (order included).

## 4. objects.json

```json
{"schema_version": 1, "objects": [ <record>, ... ]}
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
| `origin` | `MANUAL` or `SCATTER` |
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

## 5. Authored content hash

`authored_content_hash = sha256(stream)`, lowercase hex. Stream (integers little-endian,
`str` = u32 byte length + UTF-8, `f64` = IEEE-754 double LE with `-0.0` written as `+0.0`):

```
"WPOC-AUTHORED-V1\n"
u32 schema_version
str catalog.id, u32 catalog.version, str catalog.sha256
f64 sample_spacing_m, u32 region_samples
u32 region_count
per region in canonical order: i32 x, i32 z, 32 raw bytes sha256(height file), 32 raw bytes sha256(control file)
u32 object_count
per object sorted by object_id: str object_id, str asset_id, u32 asset_version,
  f64 position[3], f64 rotation_xyzw[4], f64 uniform_scale, str grounding,
  f64 height_offset_m, str origin, str scatter_operation_id ("" when null)
```

`world_id` and `document_revision` are excluded: the same authored content has the same hash
after undo+redo, reopen, or copy. Implemented by `CanonicalEncoder` (GDScript) and
`authored_hash()` (Python); both are tested against the same vectors.

## 6. Catalog content hash

`catalog.sha256 = sha256(stream)` over raw file bytes, so JSON float parsing never matters:

```
"WPOC-CATALOG-V1\n"
str "catalog.json", 32 raw bytes sha256(catalog.json bytes)
u32 file_count
per referenced geometry file, sorted by res:// path: str path, 32 raw bytes sha256(file bytes)
```

Referenced geometry files are every non-null `preview_scene` and `scatter_mesh`. Thumbnails
are excluded. Model scenes must be self-contained text resources (no `ext_resource`), and the
project sets `editor/export/convert_text_resources_to_binary=false` so exported bytes match.
Same asset ID with a changed pivot or mesh therefore changes the catalog hash and is rejected
as incompatible.

## 7. `.worldpoc` package

A ZIP containing exactly one generation: `manifest.json`, `objects.json`, and the 8 region
files at the paths above (an optional `regions/` directory entry is tolerated). Nothing else.

Validation before extraction (central directory inspected first):

- reject absolute paths, `..` segments, backslashes, duplicate names, unknown names, symlinks
- per-entry uncompressed size limits: region files exactly 262144; `manifest.json` ≤ 64 KiB;
  `objects.json` ≤ 4 MiB; total ≤ 8 MiB; object count ≤ 2000
- archive file size ≤ 16 MiB, entry count 1–16; reject encryption and ZIP64 fields/locators
- EOCD is exactly the final 22 bytes: no archive comment or trailing data; single disk only
- central directory bounds must end immediately before EOCD; reject shifted/prepended data
- Godot additionally checks local headers, matching names/methods/flags, and data bounds before
  extraction; Python zipfile checks local headers during extraction and verifies CRC
- only stored or deflate compression
- extract only into a new temporary directory; then validate as a generation directory
- after decompression, each entry's size must equal the central-directory size

Validation of a generation (both languages): schema/format, required fields, exact region
set and byte lengths, payload hashes, control layout, material slots, catalog identity
(id, version, sha256 must match the trusted catalog exactly), unique object IDs, finite and
bounded heights and transforms, allowed enums, authored hash. Unknown schema or catalog fails
with an explicit diagnostic; there is no remapping or partial load.

## 8. Endianness

Files are little-endian. Godot code converts with `to_byte_array()`/`to_float32_array()`,
which is only correct on little-endian hosts; `WorldConstants.host_is_little_endian()` is
asserted at startup (all Apple targets are little-endian).
