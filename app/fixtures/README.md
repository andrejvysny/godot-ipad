# Bundled fixtures

Read-only generation directories in the world format (`docs/world-format.md`, schema 1), generated
on the Mac by `python3 scripts/generate_fixtures.py` and committed as bytes (spec §3.2). Opening a
fixture creates a new working-document copy; these files are never edited in place.

Verify the committed bytes: `python3 scripts/generate_fixtures.py --check` (regenerates into a temp
directory and byte-compares; exit 1 on mismatch). Validate: `python3 scripts/validate_world.py app/fixtures/<name>`.

Common to both: `document_revision` 0, no objects, every control word `0x00400000`
(base 0 = grass, overlay 1 = dirt, blend 0), catalog `poc_nature` v1 with the catalog hash of the
bundled catalog at generation time. Changing `app/assets/catalog.json` or a referenced model scene
changes the catalog hash, so the fixtures must then be regenerated and `config/toolchain.lock.json`
updated.

| Fixture | world_id | authored_content_hash |
|---|---|---|
| `flat` | `0f1a7000-0000-4000-8000-000000000001` | `d5072791614659d3ea2f0f9f66b959b2556b95937afc9bb57b84e622b6b05bb3` |
| `gentle_hills` | `0e111150-0000-4000-8000-000000000002` | `6a34a9fbd86e99f6387386f699f101e898a599938e054ef5e267f4033064823f` |

The GDScript `CanonicalEncoder.authored_hash` of both fixtures was checked equal to these values
(throwaway Godot 4.7.2 probe loading the region bytes into a `WorldDocument`).

## flat

All heights 0.0 m.

## gentle_hills

Height at world `(x, z) = (g * 0.5)` is computed in float64, then packed as float32:

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
