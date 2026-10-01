# 0010 — Rendering performance architecture, manual profiles, no shadows

Status: accepted (2026-10-01). Implements `docs/rendering-performance-spec.md` (WP00–WP08). Device
performance gates stay NOT RUN until measured on the physical iPad Air 4 in a Release build.

## Context

The spec targets a ~1 km world with 10,000–50,000 meaningful placements plus decorative scatter on
an iPad Air 4. The editor drew one instantiated scene per object with shadows on, used a fixed
2 × 2 region layout and had no way to represent distant forests cheaply. The spec was reviewed
against `762f079`; implementation started at `191b2da`, after the v2 editor (scatter layer, paths,
4-material project shader) had landed.

## Decisions

**Manual profiles, no automatic switching.** Performance / Balanced / Detailed live in
`config/rendering_profiles.json` (validated; invalid config falls back to built-in spec values and
reports the error). Every launch starts in Performance; nothing is persisted. A request during an
operation is deferred and applied once when it ends. Slow frames never change the profile, scale
or density; resource safety (`SessionSafety`) stops optional work but keeps the profile.

**No cast shadows, no screen effects** in any production path (light, terrain, batches, promoted
nodes, ghosts, overlays, scatter, paths). Legacy shadow runs exist only as a labelled bench
ablation.

**Layout worlds are schema 3.** A rectangular region layout (preset `km1` = 8 × 8 regions,
1024 m) with centralized per-schema limits and authored hash V3. The legacy 2 × 2 layout keeps
writing schema 2 byte-identically, so existing fixtures and saved worlds never change. Order of
work: layout (WP04) before the new renderer (WP02/WP03), so the renderer was written
layout-aware.

**Render derivatives are a separate registry.** Prepared tiers (selected/near/mid/far/ghost,
overview metadata, low/preview textures) live in `app/assets/render_assets/` with their own
schema (`docs/render-assets.md`), bound to the logical catalog by id/version and source hash.
The logical catalog hash is untouched. Benchmark-only assets (geometry-heavy and leaf-card
vegetation, rock, structure, grass, one unprepared heavy tree) use a separate bench catalog and
registry. Preparation is an offline Godot devtool (SceneState, no instantiation; bakes multipart
transforms; whitelisted materials; coverage-checked cutout mips); no automatic decimation. The
runtime never loads catalog preview scenes; missing derivatives make an asset NOT_READY
(placement refused, existing records drawn as bounded placeholders).

**One multi-surface mesh per tier, one MultiMesh per (cell, asset, tier).** Objects use 32 m
cells, ground cover 16 m; dense slots with swap-removal, cell-local transforms, conservative
batch AABBs, partial/full uploads and scheduled coarse-first builds. The selected object is
promoted to a pooled node with the selected tier; every object has exactly one visible owner.

**LOD and overview.** `LodPolicy` picks near/mid/far per cell from projected size (normalised to
a reference FOV and viewport) with 20 % hysteresis and settled-navigation switching;
`OverviewRenderer` draws deterministic 3D canopy/solid proxies for 128 m and 256 m groups, built
on worker threads from registry overview descriptors, with a strict non-overlapping cut and
per-group invalidation. A tap on a grouped area focuses the camera instead of selecting a hidden
object.

**Decorative density = scatter ground cover only.** Thinning applies to registry-decorative
scatter assets, as a deterministic nested subset (FNV-1a over asset id, position bits and a
world seed), denser inside the active area and frozen during an operation. Manual objects and
scattered trees/rocks are never thinned.

**Terrain.** The existing app-owned project shader was trimmed (macro variation, detiling, depth
blur, a redundant lookup) instead of re-basing on Terrain3D's lightweight shader: that shader's
single-sample blend would change painted coverage. Steep-slope projection is kept (ALU only).
Texture Preview binds a compact 1024 px array sampled only inside a fixed feathered world area,
using the low-tier blend weights; objects in that area get per-material preview variants on
pooled nodes (never mutating shared low materials).

**Persistence at 50k objects.** objects.json and the authored hash are encoded incrementally
(document put/remove journal + per-record chunk cache) and finished on the storage worker, so a
checkpoint costs ~1–4 ms on the main thread on the Mac after the first full encode.

**Measurement.** RenderBench owns the session while running (input/edit/profile/preview requests
refused, abort control), presents dedicated deterministic worlds, restores everything on every
exit path, reports metric validity (no fake 0 ms GPU), evidence identity and fingerprints, and
offers representative scenarios, camera paths, render-side edit workloads and bounded sustained
runs. Native `WPPlatformTelemetry` reports thermal state, footprint and memory warnings,
separately from the input bridge.

## Consequences

- World files at the 1 km layout need this build or later (schema 3); legacy worlds are unchanged.
- New assets need a prepared registry entry before they can be placed
  (`python3 scripts/dev.py prepare-render-assets`).
- `asset_diversity` (8–32 material families) cannot be benchmarked with the 6 prepared bench
  assets and is reported NOT_RUN.
- Every performance number from the Mac or headless runs is HOST evidence only.
- The overview supports 1-4 configurable group levels (`cells.overview_levels_m`); the shipped value stays
  `[128, 256]`. HOST bench `mixed_world_50k`/performance with `[64, 128, 256]` cut the focus/shallow
  primitives by only ~7 % (2.74 M to 2.55 M; 64 m proxies add ~225 k triangles; the remaining individual
  cells lie inside the 1.6 x tree-detail-radius circle), so it was not adopted.
