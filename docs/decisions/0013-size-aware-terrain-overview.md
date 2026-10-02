# 0013 — Size-aware visibility and terrain-only extreme overview

Status: accepted implementation direction (2026-10-01), GODOTIPAD-35. Target-device performance,
exact-valley integration and material adoption remain evidence gates.

## Context

The existing distance-based cell LOD can draw tiny objects unnecessarily and chooses the same tier
for heterogeneous asset sizes. Settled-only decisions delay downgrades during continuous navigation.
At an extreme overview, individual trees and 3D canopy proxies are not required by the amended
product preferences. The reported valley belongs to the separate `fantasy-game` repository; its
standalone benchmark does not use the editor's rendering owners.

## Decision

Keep `LodPolicy` as the pure policy authority and share `RenderCameraSnapshot`/`ProjectedBounds`
across objects, scatter and overview. Normalize conservative projected sizes to an 820 px display
height. Keep display and internal render dimensions distinct. Invalid/near-plane bounds fail
conservatively rather than being classified as tiny.

Use initial 2/3 px object and 3/4 px decorative hide/show thresholds, 32/160 px tier thresholds,
20% tier hysteresis and 250 ms upgrade settling. Apply ready downgrades during navigation and
schedule upgrades under existing resource/build budgets. Preserve logical records, dense slot
identity and independent visibility reasons. Selected/local edit exemptions must remain bounded.

Add a projection-based terrain-only view mask. Enter at world extent ratio <=1.10 and downward
pitch >=45 degrees; exit above 1.30 or below 35 degrees. Publish the mask before renderer work,
suppress ordinary objects/scatter/HLOD and suspend object preview preparation without discarding
its request. First contact focuses a local area before placement. This deliberately amends
PREF-06/PREF-07/PREF-21 only at extreme overview; intermediate views still retain composition.

Retain full terrain shading by default. Provide an explicit benchmark-only `overview_experiment`
that skips lighting-only normal samples before fetching them. Keep the base normal whenever it
drives overlay height blending. Do not adopt it without device A/B and visual evidence.

Fix finite clipmap edges in the app-owned shader: clamp outside vertex sample coordinates to
authored sample bounds and discard outside fragments, while leaving geometry XZ and authored data
unchanged. Preserve holes and missing interior regions. Retain mesh defaults 48/7; a 64/10
experiment did not establish correct corners by itself. Keep shader includes app-owned with pinned
Terrain3D attribution. Do not add a second terrain mesh or change sample spacing/elevations.

## Consequences and limits

Comparison variants remain developer diagnostics. The HLOD-only variant aliases the prior
distance-policy baseline; the size-only variant combines projected tiers with tiny-object culling,
so it does not isolate those two effects independently. Reports disclose this coupling.

Live source fingerprint/commit/dirty state and recorded installed-build inputs are separate fields.
An exported device build cannot inspect the live checkout; unavailable identity/metrics remain
unavailable rather than being copied from another run.

No appearance cache was added: its target-device profiling prerequisite has not been established.
No performance multiplier or calibrated iPad threshold is claimed. Physical iPad Release evidence
and the external valley's integration remain separate from desktop correctness evidence. The
external repository was inspected read-only and requires approved integration before scene gates
can pass. See the rendering report and GODOTIPAD-35 evidence matrix for current scope.
