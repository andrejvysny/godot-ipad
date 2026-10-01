# 0009 — World Editor v2: full redesign including PoC+ features

Status: accepted (2026-10-01). Supersedes ADR 0007 for layout. Device gates stay NOT RUN until
measured on the iPad.

## Context

The claude.ai design project "World Editor v2" (`World Editor v2.dc.html`, with
`terrain-engine.js` as its stand-in terrain model) replaces the five-tool editor with three
modes (Sculpt, Paint, Place), a tool popover, an active-tool chip with an invert toggle, scatter
sets, auto-paint rules, brush alphas and editable paths.

Many of these features are PoC+ in the specification (smooth, flatten, scattering, scatter
erase) or excluded by it (more than two materials, spline paths). On 2026-10-01 the user chose
"Full v2 incl. PoC+" over a Core-only re-skin, which authorizes WP07-class work and the
beyond-spec features for this project. Core evidence and gates are unchanged; PoC+ results are
reported separately from Core results.

## Decision

**Modes and tools.** Sculpt: Raise (invert Lower), Flatten (target height or Pick), Noise
(invert Smooth). Paint: Paint (invert Erase), Spray (invert Erase), Tint (invert Remove), Pick.
Place: Select, Scatter (invert Erase), Erase, Fill (invert Clear), Path. An armed Library asset
places on the next terrain tap in any mode. Invert is an on-screen toggle on the active-tool
chip plus the D key on the Mac. No Pencil double-tap native hook (user decision).

**Materials and rules.** Four material slots (grass, dirt, rock, sand) in the Terrain3D control
map. The control auto bit means "base comes from the auto-paint rules"; manual paint is the
overlay and blend on top. Rules (rock above a slope, sand below a height) are evaluated in a
project shader based on Terrain3D's generated shader, so changing a rule is live and costs no
CPU. Rules are world data (manifest), stored as integers so they stay exact.

**Tint.** Terrain3D's per-region colour map stores tint colour and weight (`rgba8-tint-v1`).
The project shader applies it.

**Scatter.** Scatter instances are a separate compact layer (`scatter.bin`), not object records:
no IDs, no promotion, Y always follows the terrain. This diverges from spec §15 (scattered
objects as records) on purpose: the design scatters dense ground cover (thousands of
instances), which object records with exact-float JSON cannot carry. Scatter erase and Clear
cannot touch manual objects by construction. Rendering uses MultiMesh cells.

**Scatter sets** (asset weights, density, spacing, slope range, align to normal) are app-level
presets in `user://scatter_sets.json`, not world data. A quick mix is a transient set built from
ticked Library assets.

**Paths** are spline records (`paths.bin`) rendered as a terrain-draped ribbon. Drawing a path
also flattens the terrain along it in the same action. Dragging a control point edits only the
curve. This replaces the Core dirt-paint path preset (PA-00 is superseded).

**Brush alphas.** Six procedural shapes (soft, hard, cloud, ring, splat, streak) and three
modes (circle, stamp follows stroke direction, pattern tiles in world space), shared by all
brush tools. `soft` + `circle` keeps the existing continuous kernels exactly.

**Assets.** Catalog `poc_nature` v2 adds four ground-cover assets (grass tuft, fern,
wildflowers, pebbles) with self-contained generated meshes and thumbnails; spruce and boulder
gain scatter meshes.

**Format.** Schema 2 (`docs/world-format.md`). Schema 1 worlds are rejected as an unknown
schema; fixtures are regenerated. There are no external users, so no migration is written.

**Keyboard.** Renaming a scatter set uses a text field; it is optional (sets have default
names), so spec §9's "no required keyboard" still holds.

## Consequences

- The Mac consumer and the Python validator must understand schema 2 before any v2 world can
  round-trip.
- Spec tests TE-06, TE-07 and the SC/PA groups are re-scoped to the v2 model and reported as
  PoC+ results. PA-00 is replaced by path tests.
- The project shader is pinned to Terrain3D 1.0.2's generated shader; a Terrain3D upgrade needs
  the shader regenerated and the rules patch re-applied.
