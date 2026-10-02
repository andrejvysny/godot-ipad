# GODOTIPAD-35 — host implementation and open acceptance gates

Evidence class: **HOST**. These checks do not establish physical iPad Release performance or
exact-valley acceptance. Plane GODOTIPAD-35 owns the task; the rendering specification/report and
ADR 0013 are the canonical implementation-coupled documentation.

## Identity and scene routing

The implementation uses the current dirty working tree on `master`, based on
`47cbb912275cf7cd4adf49ab28274f1b697d5ed3`. No commit or installed application is identified by
that base alone. Host rendered evidence below used Godot 4.7.2 `ed1daf0bf`, Mobile/Vulkan on an
Apple M4 Pro. Record the final live source fingerprint independently from installed-build inputs
when collecting benchmark reports; the working tree continues changing during implementation.

The external repository `../fantasy-game` was inspected read-only at clean commit
`ce478c479b101ad21fa98bf5bbb5690fdf9997d5`. `project.godot` selects `scenes/valley.tscn`.
`tools/fg_bench/make_fg_bench.py` copies that project into ignored `build/fg_ipad` and substitutes
the terrain/scenery-only bench scene. It does not route through `EditorSession`, `SessionRender`,
`ObjectRenderWorld` or `OverviewRenderer`. Trees/props use direct MultiMeshes, ground cover uses
field-driven GPU grids and terrain uses custom displaced 64 m PlaneMesh chunks, not Terrain3D.

The placement manifest records 12 zones, 35 distinct assets, 326 asset-zone binary files and 20,600
generated instances; hand-authored overrides are empty. These are source placement counts, not
submitted/rendered counters. Ground cover is a separate procedural population. The existing device
JSON records source commit `ce478c4` and Mobile/Vulkan, but does not prove the exact installed
artifact matches the current checkout. Installed artifact fingerprint: **NOT VERIFIED**.

Selected external source SHA-256 values:

| File | SHA-256 |
|---|---|
| `scenes/valley.tscn` | `bd69df9eedd75b441c27063f32c6cb5ea9e2281ce50da14df0db5715830a5729` |
| `world/generated/manifest.json` | `063f1c0169031b6df8d995756a885cf84f9eb5d6a9623ea8deffad55e97afc58` |
| `world/overrides/valley_overrides.json` | `20c9b38dcf3b01a688e55f965221620339b23831baade7e0147ddc8a29875c87` |
| `terrains/valley/height.res` | `cd65494f7b993c414cb2aa484e920040c80e33219d55865700ccaf0be050578e` |
| `terrains/valley/splat_0.res` | `bf63fc435d86292f522380780b223ec897ec53643ad63faf68877a249d459f07` |
| `terrains/valley/splat_1.res` | `9e7e482369ba6d25827ce4c0b8255b1ce08ad3b621a4b50c80e9a43224765954` |
| `terrains/valley/splat_2.res` | `db1d78f3006bb7e2a9cfb8d85d1a9fe7aaf472659f387fca9c1663923d1e1086` |

The old bench inherits terrain `chunk_range=320` and applies it to chunk visibility. Its overview
camera is 450 m out/550 m up, so far1500 does not guarantee terrain submission. Far250 overview
numbers are already marked invalid in the old device evidence. The new editor terrain correction
does not fix that separate runner. The user explicitly chose godot-ipad-only implementation scope. External integration is therefore
pending by user choice; no external files were changed. A same-path run remains required before
claiming the reported valley has been fixed.

## Implemented scope

One camera snapshot captures projection, transform, display/internal dimensions, render scale and
generation. Conservative transformed asset bounds feed size-aware object/scatter policies. Logical
records remain authored while dense render slots are removed/reinserted. View, size, HLOD and
vegetation reasons compose. Ready downgrades progress while moving; upgrades wait for settling
under bounded scheduling. Existing selected/local edit exemptions and HLOD ownership remain local.

`SessionRenderView` publishes the terrain-only mask before renderer work. It suppresses ordinary
objects/scatter/HLOD, retains selection and authored identity, suspends preview requests and
provides first-contact local focus. Benchmark comparisons explicitly preserve scenario populations;
HLOD-only aliases old distance and size-only also changes projected tiers. These limitations are
reported rather than presented as independent isolated effects.

Full terrain material remains default. `overview_experiment` is an explicit developer intervention:
it skips lighting-only normal/roughness samples before fetching them, retaining base normals when
overlay height-blend weights need them. Preview pixels retain the full path. No cache, automatic
material adoption, canonical terrain change or production mesh reduction was added.

## Rendered terrain reproduction and correction

At maximum km1 zoom and 15-degree pitch, flat terrain height 12 m with default mesh48/LOD7 missed
authored corner probes `(490,-490)` and `(-490,490)`. Camera position was
`(811.5344,446.9,1405.619)`. Supported maximum mesh64/LOD10 still missed one corner. The shader
discarded coarse vertices outside valid regions, removing triangles that crossed the finite edge.

The app-owned correction clamps outside vertex sampling coordinates to true authored sample bounds,
leaves geometry XZ unchanged and discards outside fragments before region lookups. Missing interior
regions and holes retain their discard behavior. Both material modes then passed the same camera
probes. The final regression additionally uses a linear km1 elevation ramp from -13.6 m to 37.575 m,
checks a center hole, finite outer bounds and seam probes at pitches15/80, and checks bounds replacement
from km1 to legacy. Local material checks include all four slots, partial overlay hue and slope normals.

Selected images are correctness artifacts captured outside benchmark timing:

- [Before: flat world with clipped corners](km1_before_pitch15.png).
- [After: raised/lowered edges at pitch15](km1_after_pitch15.png).
- [After: raised/lowered edges at pitch80](km1_after_pitch80.png).
- [Four material slots and partial paint](paint_experiment.png).
- [Terrain normals, full](normals_full.png) and [experimental](normals_experiment.png).

The before/after images deliberately have different elevation fixtures; they are not a controlled
pixel-difference or performance A/B. The final tests compare both material modes on identical fixtures.
The [narrow Vulkan log](terrain-overview-vulkan.log) records two tests, zero failures, 3.8 s and only
the known Terrain3D `instance_reset_physics_interpolation() is deprecated` warning.

## ZOOM acceptance matrix

This maps the task's exact IDs to current evidence scope. A host test covering part of a row does
not establish the entire row or its device/exact-scene extension. Final aggregate suite results are
reported separately by the implementation owner; device and external-scene rows stay open.

| ID | Current evidence and limitation |
|---|---|
| ZOOM-01 | HOST: `test_projection_policy` covers reference/display/internal size, render scale, orthographic and projection generation. Device portrait/resize behavior still requires the physical matrix. |
| ZOOM-02 | HOST: conservative invalid/near/behind/unclipped bounds and existing transformed-batch bounds tests. Exhaustive external asset anchor/long-object fixtures remain unverified. |
| ZOOM-03 | HOST: threshold ties, hysteresis and stationary projection invalidation in projection/LOD suites. Continuous physical navigation remains NOT RUN. |
| ZOOM-04 | HOST: same-cell mixed scales/tier ownership and tiny records with no slot in `test_object_size_visibility`. |
| ZOOM-05 | HOST: hidden move/show/delete, promotion/demotion and existing dense-slot tests; actual device edit/undo sequences remain NOT RUN. |
| ZOOM-06 | HOST: composed masks, vegetation changes and world replacement in object/overview/terrain-only tests. |
| ZOOM-07 | HOST: prompt ready downgrade, settled upgrade, pinning and coarse fallback. Continuous workload performance is unmeasured. |
| ZOOM-08 | HOST: existing overview cut/ownership/stale-result tests plus suppressed/offscreen/zero-budget work tests. |
| ZOOM-09 | HOST: projection/pitch hysteresis, operation deferral/local focus and actual km1 maximum-zoom rendered coverage. Physical transitions remain NOT RUN. |
| ZOOM-10 | HOST: submitted-slot masks, selected identity and preview suspension. Exact-valley submitted GPU geometry and progressive return performance remain unmeasured. |
| ZOOM-11 | HOST: pending/hidden objects not pickable and first-contact placement focuses only. Physical input matrix remains NOT RUN. |
| ZOOM-12 | HOST: existing edit/cancel/history suites plus local pin/visibility coverage. Dense device editing with pending navigation remains NOT RUN. |
| ZOOM-13 | HOST: terrain-only sequences preserve authored identity/history and actual exported ZIP entry payloads. ZIP container metadata equality is not claimed. |
| ZOOM-14 | HOST: preview request/anchor retained through suspension/reentry; existing ownership/budget tests. Device pressure/return performance remains NOT RUN. |
| ZOOM-15 | PARTIAL: zero-budget/stale generations/deletion and existing cache/queue tests. Dense single-cell pressure and fast-reversal envelope need workload evidence. |
| ZOOM-16 | HOST PASS: drawn-frame Vulkan km1 bounds/elevation/hole/seam tests. Exact-valley missing-ground/floating-tree acceptance remains NOT RUN. |
| ZOOM-17 | HOST PASS for procedural terrain: four slots, base/overlay/rules/tint, preview and slope normals. Real valley cutout/mip/material checks remain NOT RUN. |
| ZOOM-18 | CONDITIONAL NOT IMPLEMENTED: no appearance cache; target-device evidence prerequisite is open, not a measured NOT_NEEDED result. |
| ZOOM-19 | PARTIAL: live/installed identity split and same-population comparison flags tested. External valley does not yet use this policy; entry-point parity remains NOT RUN. |
| ZOOM-20 | PARTIAL DEVICE: diagnostic Release core poses and readiness smoke measured on Air4; static rows with pending work do not establish calibration. Corrected three-repeat comparisons, continuous zoom/edit/preview and 30/60-minute sessions remain open. |

## Validation and remaining limits

Final isolated rendered wrapper: 19 filtered checks passed, followed by 222 Python tests. Some
checks have `gpu` in their names without doing a GPU readback; this is not a claim of 19 distinct
GPU image tests. A concurrent desktop benchmark/rendered-test run failed with stale image results;
the isolated rerun passed. Shared desktop rendering therefore remains sensitive to concurrent runs.
Final aggregate headless wrapper: 1,089 Godot tests, zero failures; 223 Python tests, OK.
Doctor:29 OK/1 WARN/0 PENDING/0 NOT_RUN/0 FAIL; fixtures:3 byte-identical; prepared-assets check
unchanged; asset validation retains the intentionally NOT_READY heavy asset. Release export
verification checked 117 entries, zero missing and zero unexpected. Broader suites retain baseline
ObjectDB/RID/resource shutdown leak noise; passing assertions do not establish leak freedom.

The [Debug Metal terrain-floor report](terrain-floor-debug-metal.json) records four 30-second host
steps with 355,424 primitives, 115 draws and no object/HLOD submissions. Its raw GPU samples were
zero and are correctly reported as `NOT_AVAILABLE`, with null GPU percentiles. Display dimensions
were 1180×820, scale 0.65; internal dimensions 767×533 are derived from display size and scale,
not allocation readback. Uncontrolled desktop pacing and concurrent work make this diagnostic,
not calibration. Live source SHA-256 was
`065ffea207dce5666d47312a87fbdec476361dcb8e43d6c5d6e70f89e9e09370`; separately recorded installed
build inputs were `7b704d45b7f53f06b4c2ed26b8b993469f81f68264897e61085aea9ebdb9f6d3`. The scopes
differ; this report does not identify the host execution as that installed artifact.

Physical Release diagnostic results are recorded in the [device evidence](../godotipad-35-device-2026-10-01/README.md).
They prove the combined overview's zero object/scatter/HLOD submission invariant, but do not
establish a controlled same-device speedup, final calibration or cache necessity. Corrected
three-repeat measurements and required sustained sessions remain incomplete. External valley
integration and acceptance are pending under the user's explicit godot-ipad-only scope choice,
not because the iPad is unavailable.
Plane work-item/Page updates require approval; no Plane write or commit was made.
