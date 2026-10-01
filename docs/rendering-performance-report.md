# Rendering performance — implementation report

Spec: `docs/rendering-performance-spec.md` (2026-10-01). Decisions: `docs/decisions/0010-rendering-performance.md`.
Evidence classes are kept apart: **HOST** (Mac, Debug, windowed or headless) never counts as iPad evidence;
**DEVICE** results are listed only where a Release build was measured on the physical iPad Air 4.

## 1. Commits and work packages

Start `191b2da` (spec reviewed at `762f079`; the v2 editor with scatter, paths and the project shader had
landed since). End: see `git log 191b2da..HEAD` (23 commits at the time of writing, all local, none pushed).

| WP | Commits | Result |
|---|---|---|
| WP00 bench | `f8bdd33` | Session-exclusive bench, input/edit/profile/preview blocked with abort, dedicated deterministic populations, restore on every exit path, metric validity, evidence identity |
| WP01 profiles | `72d3ac3` | Manual Performance/Balanced/Detailed (Performance at launch, deferred during operations), shadows/effects off everywhere, spatial picking, bounded inspector/debug work, hide vegetation, performance indicator |
| WP04 1 km | `b58aeb1`, `5118ecd` | WorldLayout + schema 3 (legacy byte-identical), centralized limits, layout-aware tools/camera, New 1 km world, 50k round trip, incremental checkpoint encoding |
| WP02 assets | `d4f658d`, `ac32ea3` | Render-asset registry/descriptor (GDScript + Python), cache, offline preparation tool, editor + bench registries |
| WP03 batches | `0bd0e30` | ObjectRenderWorld: cell batches, promotion, ghosts, placeholders, readiness gating, ActiveEditArea |
| WP05 LOD/HLOD | `593b6c9`, `2357753`, `b82e4c3`, `9de52a5`, `01488ac` | LodPolicy, per-cell LOD, overview proxies with strict cut and area focus, scatter on tiers with nested decorative density bands, configurable group levels |
| WP06 terrain/preview | `f459148`, `e5fff93` | Shader trim, upload accounting, terrain + object Texture Preview |
| WP07 lifecycle/bench | `2f84a77`, `0c26751`, `9cff725`, `9f8c520`, `83ae119` | Native telemetry, safety state, scenarios/sustained bench, screenshots, pipeline warm-up, export verification, spatial edit-path queries |
| WP08 docs | `4258ad1`, `3c53c30`, `56dec5f`, this report | Spec copy, schema 3 and render-asset contracts, ADR 0010, architecture |

## 2. Schema and contract changes

- World format schema 3 (`docs/world-format.md` §11) for non-legacy layouts; legacy 2 × 2 worlds keep schema 2
  byte-for-byte (fixtures unchanged, `generate_fixtures.py --check` passes). Opening never rewrites a file.
- Render derivatives (`docs/render-assets.md`, schema 1) in a separate registry; the logical catalog hash is
  unchanged. Bench assets use a separate bench catalog.
- `config/rendering_profiles.json` (+ synced `app/config` copy); dead `storage.max_*` keys removed from
  `poc_defaults.json`.

## 3. Tests

- `python3 scripts/dev.py test` → **Godot 1002 tests, 0 failures; Python 221 tests, OK** (baseline at start:
  652 + 160).
- `python3 scripts/dev.py test --rendered` (Mac, Metal) → 11 tests, 0 failures. One run in a shared session
  reported 19 failures (black pixels) that did not reproduce on the immediate rerun; treat the rendered suite as
  sensitive to the desktop state.
- `python3 scripts/generate_fixtures.py --check` OK; `dev.py prepare-render-assets --check` no differences;
  `dev.py validate-render-assets` all prepared assets READY (bench heavy tree NOT_READY by design);
  `dev.py verify-export` on the Release iOS export: 117 entries checked, 0 missing, 0 unexpected.
- Spec §21.2 ids covered by automated tests: ASSET-01–06, BATCH-01–08, PICK-01–03, EDIT-01–06, LOD-01–05,
  DENSITY-01–03, PREVIEW-01–07, PROFILE-01–05, MEMORY-01–05, TERRAIN-01–03 (TERRAIN-03 rendered on the Mac),
  WORLD-01–04, UI-01–02, BENCH-01–05.

## 4. HOST measurements (Mac16,8, Debug, not device evidence)

From `docs/evidence/rendering-host-2026-10-01/` (Performance profile, bench catalog worlds on the 1 km layout).
Frame intervals on the Mac are vsync-bound and not meaningful for the iPad; the useful numbers are workload
counts.

| Scenario / camera | Draws | Primitives | Notes |
|---|---:|---:|---|
| mixed_world_10k overview | 144 | 457 k | 16 × 256 m proxies, 0 individual objects |
| mixed_world_10k focus | 125 | 579 k | ~3,000 individual objects, rest grouped |
| card_forest_10k focus | 69 | 805 k | leaf-card overlap |
| mixed_world_50k overview | 155 | 533 k | whole world from proxies |
| mixed_world_50k focus | 204 | 2.74 M | dense patches: ~9,100 individual far-tier objects inside the 1.6 R ring |
| mixed_world_50k edit_sculpt p95 | — | — | 60.7 ms → 17.4 ms after replacing the whole-document regrounding scan |

Other HOST numbers: checkpoint main-thread cost at 50k objects 790–840 ms → 1–4 ms (after first encode);
km1 terrain initialize ~160 ms; 100k-instance scatter brush stroke 60.8 ms → 0.9 ms per frame; 50k overview
settle ~0.6 s; warm-up 30 draws, ~210 ms once at startup. A 64 m overview level cut the 50k focus primitives by
only 6–7 % and was not shipped.

Known HOST limitation: these reports carry the stale `source_sha256` of the last export
(`88017c39…`); identify them by commit instead.

## 5. Device results (iPad Air 4, Release)

See §8 for the device session status. Results are recorded here only once measured.

## 6. Supported workload envelope (initial, uncalibrated)

Profiles are the spec's INITIAL values (Performance 0.65 scale, 60 fps target; Balanced 0.75; Detailed 1.0,
30 fps). Representative content: 6 prepared bench assets (geometry-heavy broadleaf 412–11,384 triangles per
tier, leaf-card pine 288–4,096, card shrub, rock, structure, grass cards). Overview groups 128 m / 256 m. Ground
cover drawn up to 4 × the profile ground-cover radius with halving density bands. The dense 50k focus view
(~2.7 M primitives on the Mac) is the highest-risk workload for the iPad and the first candidate for
calibration (far tier cost, group handoff distance).

## 7. NOT_RUN / NOT_MET / limitations / deviations

- `asset_diversity` (8–32 material families): NOT_RUN — only 6 prepared bench assets.
- Production-like (artist) assets: none; all bench content is generated.
- Idle rendering reduction: not implemented (optional in the spec).
- Mac consumer has no overview renderer (it shows individual tiers only).
- Erase strokes on ~100k scatter instances cost ~7 ms per frame on the Mac (index shift after removal).
- Deviations (ADR 0010): layout before renderer; schema 3; one mesh per tier; trimmed project shader instead of
  the Terrain3D lightweight shader; bench catalog; ground-cover distance bands instead of a hard radius cutoff
  (a hard cutoff left a normal focus view without grass).

## 8. Reproduction

- Host: `python3 scripts/dev.py test`, `--rendered`; `python3 scripts/dev.py render-bench --scenario
  mixed_world_10k --profile performance --seconds 10 --screenshots --output build/bench/x.json`.
- Device: `docs/device-test-checklist.md` §4a/§4a.1 (Release export, install, `--render-bench` with scenarios or
  `--bench-sustained-minutes`, pull `Documents/traces`).
