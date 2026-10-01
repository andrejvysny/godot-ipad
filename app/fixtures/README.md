# Bundled fixtures

Read-only generation directories in the world format (`docs/world-format.md`, schema 2), generated
on the Mac by `python3 scripts/generate_fixtures.py` and committed as bytes (spec §3.2). Opening a
fixture creates a new working-document copy; these files are never edited in place.

Verify the committed bytes: `python3 scripts/generate_fixtures.py --check` (regenerates into a temp
directory and byte-compares; exit 1 on mismatch). Validate: `python3 scripts/validate_world.py app/fixtures/<name>`.

Common to all: `document_revision` 0, every control word `0x00000001` (auto bit set, base 0,
overlay 0, blend 0: the auto-paint rule layer only), every tint sample `FF FF FF 00` (default colour,
weight 0), default rules (`rock_enabled` true, `rock_slope_deg` 30, `sand_enabled` true,
`sand_height_dm` -4), empty `scatter.bin` (16 bytes) and empty `paths.bin` (12 bytes), catalog
`poc_nature` v1 with the catalog hash of the bundled catalog at generation time. Changing `app/assets/catalog.json` or a referenced model scene
changes the catalog hash, so the fixtures must then be regenerated and `config/toolchain.lock.json`
updated.

| Fixture | world_id | authored_content_hash |
|---|---|---|
| `flat` | `0f1a7000-0000-4000-8000-000000000001` | `be76f01f80f2ae7abbc40272b7030fa9ba2b6da22666e2aa9b9137b5e66fd1dd` |
| `gentle_hills` | `0e111150-0000-4000-8000-000000000002` | `6c38b11259c44ec7c0df2380a141d5f4c679bd65ac419761386e3c4b8749ec9a` |
| `stress_100` | `57e55100-0000-4000-8000-000000000003` | `13f8636ba6481e89b9c3f5fe19b849fe8a4208fa54c262c9090dfd9534b5acff` |

These are the schema 2 (V2 stream) hashes computed by `scripts/worldpoc_values.py`. They have not yet
been cross-checked against the GDScript `CanonicalEncoder` (schema 1 values were). Heights and objects
are byte-identical to the schema 1 fixtures; only control words, the new files and the manifest changed.

## flat

No objects.

All heights 0.0 m.

## gentle_hills

No objects. Height at world `(x, z) = (g * 0.5)` is computed in float64, then packed as float32:

- Sum of Gaussian bumps `amp * exp(-((x-cx)^2 + (z-cz)^2) / (2 * sigma^2))` with
  `(cx, cz, amp, sigma)` = `(-60,-50,11.5,28)`, `(55,-40,9,22)`, `(-45,60,8,25)`, `(40,55,7,30)`,
  `(0,0,3,40)`, `(85,-85,8,9)` (steep slope), `(-90,10,-3,18)` (hollow below 0 m).
- Lodge flat area: `d = |(x,z) - (20,20)|`, `m = 1 - smoothstep(12, 20, d)`,
  `h = h * (1 - m) + h_center * m` with `h_center` the pre-flatten height at `(20, 20)`.
- Clamped to `[-32, 64]` m.

Measured on the committed bytes (`fixture_stats()` in `scripts/generate_fixtures.py`):

| Property | Value | Required |
|---|---|---|
| Max height | 11.960 m | 10–13 m |
| Min height | -2.074 m | < 0 m |
| Max slope (central differences over the grid) | 29.23° | 25–30° (near scatter limit) |
| Lodge flat area, r ≤ 10 m around (20, 20) | 1257 samples at 5.3203 m, stddev 0.000 m | stddev < 0.01 m |

Terrain crosses all four region boundaries: height range along both sample columns/rows of each
seam, per half (all non-zero, so every quadrant varies at the seams):

| Seam | Negative half | Positive half |
|---|---|---|
| x = -0.5 m (last column of regions x=-1) | 3.879 m (z < 0) | 5.454 m (z ≥ 0) |
| x = 0 m (first column of regions x=0) | 3.884 m (z < 0) | 5.462 m (z ≥ 0) |
| z = -0.5 m (last row of regions z=-1) | 5.236 m (x < 0) | 4.469 m (x ≥ 0) |
| z = 0 m (first row of regions z=0) | 5.267 m (x < 0) | 4.453 m (x ≥ 0) |

Determinism: the generator uses only `math.exp`/`math.hypot` in float64 and a float32 pack, and
`--check` confirms byte equality on this Mac (Python 3.14, macOS 26.6.2 arm64). A different libm
could round `exp` differently; the committed bytes, not the formula, are the reference.

## stress_100

Terrain bytes identical to `gentle_hills`, plus 100 manually placed proxy objects (spec §19 WP06).
Grid index `i = row * 10 + col` (0..99): `x = -90 + 20 * col`, `z = -90 + 20 * row` m.

- Asset by `i % 10`: 0 lodge, 1-4 boulder, 5-9 spruce (10 / 40 / 50).
- `object_id` = `57e55100-0000-4000-8000-<i+1 as 12 hex digits>`.
- Yaw `radians((i * 37) % 360)` about +Y; scale lodge 1.0, boulder `0.5 + 0.25 * (i % 4)`,
  spruce `0.75 + 0.25 * (i % 3)`.
- Grounding = asset default (lodge WORLD_FIXED, others FOLLOW_TERRAIN), `height_offset_m` 0, origin MANUAL.
- `position.y` = canonical bilinear `sample_height(x, z)` of the stored float32 terrain, so FOLLOW_TERRAIN
  consistency holds exactly; lodges use the same y.
