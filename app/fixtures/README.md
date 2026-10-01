# Bundled fixtures

Read-only generation directories in the world format (`docs/world-format.md`, schema 2), generated
on the Mac by `python3 scripts/generate_fixtures.py` and committed as bytes (spec §3.2). Opening a
fixture creates a new working-document copy; these files are never edited in place.

Verify the committed bytes: `python3 scripts/generate_fixtures.py --check` (regenerates into a temp
directory and byte-compares; exit 1 on mismatch). Validate: `python3 scripts/validate_world.py app/fixtures/<name>`.

Common to all: `document_revision` 0, default rules (`rock_enabled` true, `rock_slope_deg` 30,
`sand_enabled` true, `sand_height_dm` -4) and catalog `poc_nature` v2 (seven assets) with the catalog hash
of the bundled catalog at generation time. `flat` and `stress_100` additionally have every control word
`0x00000001` (auto bit set, base 0, overlay 0, blend 0: the auto-paint rule layer only), every tint sample
`FF FF FF 00` (default colour, weight 0), an empty `scatter.bin` (16 bytes) and an empty `paths.bin`
(12 bytes); `gentle_hills` carries authored content, see below. Changing `app/assets/catalog.json` or a
referenced model scene or scatter mesh changes the catalog hash, so the fixtures must then be regenerated.

| Fixture | world_id | authored_content_hash |
|---|---|---|
| `flat` | `0f1a7000-0000-4000-8000-000000000001` | `bedce13a23c1190c8cf01b9c3666a7dc7d2c728c1d85504af34baa84f382279b` |
| `gentle_hills` | `0e111150-0000-4000-8000-000000000002` | `133d5013176873deba05b98c45109fed36e6c3ddbe370627043a6e9e77034934` |
| `stress_100` | `57e55100-0000-4000-8000-000000000003` | `5b864eb39d709f51b2d5980f4b5de7ea9246720ce059e9b2c35d1adc6263bade` |

These are the schema 2 (V2 stream) hashes computed by `scripts/worldpoc_values.py`. They are
cross-checked against the GDScript `CanonicalEncoder` by `test_world_document::test_fixture_authored_hash_matches_manifest_in_godot`,
including the non-empty scatter, path, control and tint data of `gentle_hills`. Heights and objects are
byte-identical to the schema 1 fixtures.

## flat

No objects.

All heights 0.0 m.

## gentle_hills

No objects. Authored content (`scripts/fixture_hills_content.py`, seeded `random.Random(20261001)`,
float64 maths): 550 scatter instances in two patches, one path, a dirt paint patch and a tint patch.

- Forest patch (disc, centre (-52, 28), r 30 m): 150 instances, 90 spruce / 40 fern / 20 boulder.
- Meadow patch (disc, centre (58, 4), r 30 m): 400 instances, 200 grass tuft / 120 wildflowers / 80 pebbles.
- Every instance: slope <= 14 degrees, height >= 0.2 m, at least 1 m beyond the path edge and the dirt
  patch, spaced by half the summed footprints, yaw uniform in [-pi, pi), scale inside the asset range
  (spruce 0.8-1.7, fern 0.8-1.2, boulder 0.5-1.5, grass 0.8-1.2, wildflowers 0.8-1.1, pebbles 0.7-1.3),
  flags 0 or 1 (tilt, probability 0-0.3 per asset).
- One path `0e111150-0000-4000-8000-0000000000a1`, width 2.4 m, 8 points from (-120, -75) to (118, 74).
- Dirt paint: disc centre (30, 12), r 7 m near the lodge area; overlay id 1, blend 255 falling to 0
  over the outer half (smoothstep 0.45-1.0), auto bit kept set, base 0. 593 samples.
- Tint: disc centre (-44, 34), r 18 m, Autumn RGB (192, 110, 48), alpha 200 falling to 0 (smoothstep 0.3-1.0).
  3909 samples. Rules stay default.

Terrain: height at world `(x, z) = (g * 0.5)` is computed in float64, then packed as float32:

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

Height bytes identical to `gentle_hills` (no scatter, path, paint or tint), plus 100 manually placed proxy objects (spec §19 WP06).
Grid index `i = row * 10 + col` (0..99): `x = -90 + 20 * col`, `z = -90 + 20 * row` m.

- Asset by `i % 10`: 0 lodge, 1-4 boulder, 5-9 spruce (10 / 40 / 50).
- `object_id` = `57e55100-0000-4000-8000-<i+1 as 12 hex digits>`.
- Yaw `radians((i * 37) % 360)` about +Y; scale lodge 1.0, boulder `0.5 + 0.25 * (i % 4)`,
  spruce `0.75 + 0.25 * (i % 3)`.
- Grounding = asset default (lodge WORLD_FIXED, others FOLLOW_TERRAIN), `height_offset_m` 0, origin MANUAL.
- `position.y` = canonical bilinear `sample_height(x, z)` of the stored float32 terrain, so FOLLOW_TERRAIN
  consistency holds exactly; lodges use the same y.
