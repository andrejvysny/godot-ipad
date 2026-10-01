# TODO

Updated: 2026-10-01. Scope: Core PoC WP00–WP06 only (WP07/PoC+ not authorized). Physical iPad Air 4 / Pencil testing confirms the Mobile/Vulkan baseline; full G1 remains INCOMPLETE.

## World Editor v2 (2026-10-01, ADR 0009) — full redesign incl. PoC+

Source: claude.ai design "World Editor v2" (`World Editor v2.dc.html`, `terrain-engine.js`).
User authorized full scope incl. PoC+ (4 materials, rules, tint, alphas, flatten/noise/smooth,
scatter/fill/sets, spline paths). Invert = on-screen button + D key (no Pencil double-tap hook).

- [x] P0 Contracts: ADR 0009, `docs/world-format.md` schema 2
- [x] P1a Format schema 2, GDScript: constants, RegionBuffers color, ScatterLayer, PathLayer, rules,
  WorldDocument, codec/manifest/validator/zip limits, CanonicalEncoder V2, history capture, adapter colour upload
- [x] P1b Format schema 2, Python mirror (`scripts/worldpoc_*`), tests
- [x] P2 Catalog v2 (4 ground-cover assets + scatter meshes + thumbnails), fixtures regenerated, cross-language hash check
- [x] P3 Editor v2 behaviour spec (`docs/editor-v2.md`); ToolController v2 (modes/tools/invert/settings)
- [x] P4 Brush engine v2: alphas, 4-layer paint/erase, spray, tint, pick; flatten (+pick height), noise/smooth
- [x] P5 Terrain shader: 4 textures, auto-paint rules, tint, rule highlight (Mac rendered check)
- [x] P6 Scatter: MultiMesh renderer, scatter/erase brush, fill/clear lasso, sets store, quick mix
- [x] P7 Paths: draw (flatten + record), draped ribbon, handle edit, delete
- [x] P8 UI v2: top bar, mode rail + popover, chip + invert, Library (Objects/Sets), set editor, inspector, ghost, hints, toasts
- [x] P9 Mac consumer schema 2, selftest, docs (architecture, input contract, checklist), Mac screenshot review
- [ ] P10 iPad build + user device check (NOT RUN until measured)

## UI redesign (2026-10-01, ADR 0007)

Source: claude.ai design "World Editor" proposal 1a. Search field, Unicode glyph icons, and an
inspector that follows a dragged object were rejected. They respectively require a keyboard,
fail to render on iPad, and would pause a world-owned Pencil.

- [x] ToolController Library-drop API (`begin/update/finish_drop`) + 3 tests; input contract + ADR 0007
- [x] UI rewrite: UiKit tokens, icons, ScrubField, ToolDock, ContextBar, ObjectInspector, AssetLibrary
  (drag-to-place), WorldMenu, HistoryBar, EditorUI layout (handedness), toasts/banner/hints
- [x] test_editor_ui rewrite + new layout/drop/inspector tests; 408 Godot + 110 Python tests, 0 failures
- [x] Mac screenshot review (Metal, Mac development input); fixture/recovered world names via `source_label`
- [x] iPad Debug build installed + launched on iPad Air 4 (source fingerprint `7bda435d…`)
- [ ] User Pencil/palm check of the new layout (drag-to-place, inspector, right-side Library)
- [ ] Cosmetic: scrub accent edge line crosses right-aligned value text at high fill

## Sculpt/paint visibility on iPad (2026-10-01, ADR 0008)

User report: Sculpt shows the ring but no visible shape change on iPad; Paint partial in places.

- [x] Mac rendered GPU readback (Metal, Vulkan, Mobile): uploaded layers match the document
- [x] Root cause on Mac: magnitudes too small (rate × strength × pressure × spread) + steep blend
- [x] Tuning: sculpt 5 m/s, sculpt strength 1.0, pressure gamma 0.5, blend sharpness 0.15
- [x] Diagnostics: `verify_gpu()` + "Verify GPU" button, stroke probe in overlay, `dev.py test --rendered`
  (416 Godot + 112 Python tests pass; rendered GPU test passes on Mac Metal and Vulkan, Mobile renderer)
- [x] Mac selftest screenshots: sculpt relief and soft-edged paint now visible (were invisible before)
- [x] iPad Debug build installed + launched on iPad Air 4 (source fingerprint `f874ee2f…`)
- [x] iPad check (user, build `f874ee2f…`): sculpt + paint work as expected. No probe numbers captured.
- [ ] Optional: record stroke-probe numbers (pressure range, Δh) as evidence before any re-tune
- [x] Mac selftest S04 tap-select failed because the anchored inspector covered the neighbouring boulder.
  Fixed: the inspector now avoids other objects' screen points (`ObjectInspector.choose_position`).
  Mac selftest PASS, all steps.
- [x] Faint bright line on terrain: projection matches the world's west edge (x = -128 m), the crease
  where the 4 loaded regions meet Terrain3D's flat world background. Not a seam or edit bug.
- [ ] Optional cosmetic: hide outside-world terrain (`world_background` NONE) or mark the world edge

## Editor build (started 2026-10-01)

User reported the iPad test environment works and directed building the full editor. Phases 3–5
are unblocked by that direction; formal G1 evidence is still INCOMPLETE and device gates stay NOT RUN.
Scope = Core PoC (WP03–WP06). PoC+ (smooth/flatten/forest/clearing) not started.

Gap vs spec: input, camera, document, storage, history, terrain adapter/picker, brush kernels and
strokes exist and are tested. Missing: ObjectPresenter, tools (select/place/move/transform/delete,
paint/sculpt/path wiring, TE-11 induced moves, brush ring), EditorSession, EditorUI (rail, asset
strip, status row, tool panels, confirm dialog, diagnostics overlay, debug views), editor_main as
main scene, Mac consumer + verify-only + integration example, export UI, iOS file sharing,
stress_100 fixture, fault-injection hooks, final report.

- [x] A: `TerrainView` base; TerrainAdapter + SimulatorTerrainPreview implement it. Fixed preview
  geometry drawn at 2× world scale (sample units, not metres): misaligned with canonical picking.
- [x] B: ObjectPresenter (nodes, OBB pick, ghost, selection, anchors, IDs) + tests
- [x] F: stress_100 fixture (100 proxies) + parity tests
- [x] C: ToolController + brush/place/select/move/object-edit operations + brush ring + tests
- [x] E: Mac consumer scene, `--verify-only`, WorldLoader, integration example, dev.py test
- [x] D: EditorSession + EditorUI + editor_main.tscn as main scene (Input Lab via `--input-lab`)
- [x] G: iOS preset file sharing (Files app / iTunes) for transfer
- [x] H: in-app scripted self-test (`--editor-selftest`): Mac PASS, physical iPad PASS (synthetic input,
  Vulkan); Simulator boots and renders, run stopped early by user. See `docs/evidence/editor-selftest-2026-10-01.md`
- [ ] I: docs: architecture (done), state files (done); device checklist editor section, final-poc-report pending
- [ ] J: user Pencil test of the editor on the iPad (demo sequence §21.1, palm, interruption); formal G1
- [ ] K: Release-build performance at 100%/50% scale (Debug self-test p95 46.6 ms)

Host validation: 397 Godot tests, 110 Python tests, zero failures (2026-10-01).
Open questions: PoC+ (smooth/flatten/forest) authorization.

## Previous (Input Lab / device audit)

- [x] iPad failure audit: startup, rendering, native input, storage, and test coverage inspected. Device Metal logs reproduce repeated fence timeouts; Mobile/Vulkan renders and accepts orbit/paint (user confirmed).
- [x] Apply focused fixes: iOS Mobile/Vulkan, wall-clock stall diagnostics, 4 Hz labels, opt-in/lazy runtime capture, explicit Pencil/finger roles. Preserve input ownership and per-frame terrain batching.
- [x] Validate: 325 Godot tests, 102 Python tests, 10 native sanitizer tests; zero failures. Physical terrain/orbit/paint and Pencil scale/checkpoint buttons work. Formal G1 remains open.
- [x] Write handoff, audit, ADR, curated device evidence, and current-state tracking.
- [x] Prepare the authorized initial local project commit, excluding signing/caches and unrelated agent-memory files. No push or pull.

Audit questions: none for handoff. Remaining evidence: formal physical G1 and sustained performance.

- [x] Redeploy corrected Input Lab to live USB iPad: signed build, install, launch, and native-provider startup marker verified (2026-10-01). Simulator stopped.

- [x] Local iPad Simulator iteration: isolated x86_64 build, explicit GLES preview, native drawable attachment, panel hit registration, paint/undo/redo, nine-point calibration at both scales, exact durable recovery, independent validation, and synthetic camera integration. Simulator did not establish continuous native MOVE/palm/Pencil behavior. Later physical audit confirms basic interaction; G1 remains INCOMPLETE.
- [x] Phase 1: repair foundations and tracking; host regressions pass.
- [ ] Phase 2: build Input Lab; verify host composition, then signed iPad G1.
- [ ] Phase 3: editor composition and placement (blocked on G1).
- [ ] Phase 4: wire paint, sculpt, and path (blocked on G1).
- [ ] Phase 5: export, consumer, and acceptance (blocked on G1).

Unresolved questions: none. Simulator results cannot close physical Pencil/palm G1.

## Batch-1 follow-ups (reported by agents; need lead fix or decision)

- [x] `app/project.godot`: add `rendering/textures/vram_compression/import_etc2_astc=true` (required for iOS export)
- [x] `ObjectRecord.from_dict`: type-check `grounding`/`origin` before comparing; expose `_matches_uuid` publicly as `is_uuid()` (used by several storage files)
- [x] `TestCase.assert_near`/`assert_vec_near`: the `%g` format is unsupported in GDScript and logs formatting errors on failure
- [x] Test sandboxes share one `user://` (same project name) and the runner deletes `user://test_scratch`, so parallel runs can interfere. Give each sandbox its own user dir.
- [x] Unify the cancel-reason vocabulary: `view_changed`/`unknown`/`invalid_phase` vs `InputRouter.CANCEL_REASONS`; `provider_failed('queue overflow')` vs `queue_overflow`
- [x] Fatal bridge failure: rollback, stop observer, clear old provider contacts, banner plus UNKNOWN fallback; editing disabled. Overflow remains recoverable cancellation.
- [x] TE-03: retain ≤1 blend-level tolerance for defined traces. Shipped presets and common curves pass callback-batching tests. Different independently sampled polylines are a different test; the existing brush fixture differs by 1 level.
- [x] Expose `brush.input_latency_s` (code default 0.05 s) in `config/poc_defaults.json` and in the app copy; the tool owner must pass it through
- [x] Adapter flush policy: finish all mutations, flush late once per map kind per frame. Completion schedules a final update; no second same-frame upload.
- [x] `docs/world-format.md` §7: add the extra ZIP rules the implementations enforce (EOCD at size-22, no trailing data, CD bounds, no ZIP64 locator, local-header checks); fix the sentence about NaN-like control patterns (a NaN pattern always has base id ≥ 15, so it is never supported)
- [x] ADR 0004: add measured picker vs Terrain3D `get_intersection` error numbers
- [x] Terrain3D gotchas for the composition root: `free_editor_textures=false`, set `collision_mode` after material/assets, a 4.4-compat deprecation warning appears when Terrain3D first enters the tree
- [ ] Review or remove agent-created `AGENTS.md` and `.claude/agent-memory/` (gitignore?)
- [x] Format library split into constants, values, terrain, package and facade modules (<500 lines each); public imports preserved. Split `dev.py` when next touched.

## WP00 — baseline

- [x] Environment inspection, templates installed, Terrain3D 1.0.2 vendored + pinned
- [x] project.godot, .gitignore, CLAUDE.md, catalog.json, poc_defaults.json, proxy asset scenes, thumbnails
- [x] Foundation classes + test runner + sandboxed runner
- [x] Python tooling: dev.py (doctor/test/run-mac/export-ios/validate-world/open-consumer/build-native/fixtures), worldpoc_format.py, validate_world.py, generate_fixtures.py
- [x] Fixtures flat + gentle_hills (deterministic, `--check` passes)
- [x] toolchain.lock.json, docs/evidence/environment.json, ADRs 0001–0005
- [x] README.md (quick start and commands)

## WP01 — input lab and native feasibility

- [x] GDExtension native input bridge + xcframeworks; compiled and observed on device as `ios_native_uikit`, attached to `GDTViewIOS`
- [x] PointerSample, providers (iOS native, Mac dev, Godot-touch fallback), CoordinateMapper, InputTrace, UiHitTester, InputSystem, InputRouter + trace replays
- [x] Host Input Lab composition: `input_lab.tscn`: source diagnostics, 9-point calibration, terrain patch + one object, probe edit, save/load probe, trace recording, 3D-scale toggle
- [ ] Device gate G1: INCOMPLETE (basic rendering/orbit/paint/Pencil buttons verified; formal palm, interruption, calibration, lifecycle and persistence evidence remains; see `docs/device-test-checklist.md`)

## WP02 — document, transactions, storage

- [x] AssetCatalog, WorldValidator, generation codec, ZIP inspector, package export/import, WorldStorage worker (recovery, pruning, coalescing, fault injection)
- [x] Python validator; cross-language authored hash matches the fixtures
- [x] GDScript fixture manifest/hash parity

## WP03 — navigation and placement

- [x] OrbitCameraController / OrbitCameraRig / FrameStats
- [x] TerrainAdapter + TerrainPicker
- [ ] ObjectPresenter (nodes, OBB picking, ghost, selection, anchor/ID debug)
- [ ] ToolController + Select/Place/move/yaw/scale/height/delete/grounding + slider transactions
- [ ] EditorSession + `editor_main.tscn` composition root (recovery on start, open fixture with confirm, commit/undo/redo/checkpoint)
- [ ] EditorUI (Pencil-only rail, asset strip, status row, tool panels, confirm dialog, errors) + DiagnosticsOverlay + debug views

## WP04 — paint and sculpt

- [x] Brush kernels, stroke timeline, sculpt/paint strokes, path falloff (pure logic)
- [ ] Paint/Sculpt/Path tools wired to input; follow-terrain induced object moves in the same transaction (TE-11); brush ring preview; blend debug view in UI

## WP05 — export and Mac consumer

- [ ] Export action in UI; `mac_consumer.tscn` (+ `--verify-only` headless mode); integration example; test of `dev.py open-consumer`; transfer procedure (drafted in the checklist)
- [ ] Enable `accessible_from_itunes_sharing` (and `_files_app`) in the iOS preset for transfer

## WP06 — interruption, performance, evidence

- [ ] stress_100 fixture (100 proxy objects), app-deactivation checkpoint, fault-injection UI hooks, sustained-session procedure
- [ ] `docs/final-poc-report.md` with PASS/CONDITIONAL/FAIL/NOT RUN for every core test

## Verification / next gate

- Host suites: 325 Godot tests / 102 Python tests, no failures (2026-10-01).
- Native queue: 10 tests, no failures; ASan/UBSan; 200 fuzz rounds.
- Native observer compiles for device and simulator. Physical Mobile/Metal failure reproduced; Mobile/Vulkan restored rendering and basic interaction. Signed diagnostic build tested; final lazy-report refinement host-tested and exported, not reinstalled. See `docs/evidence/ipad-audit-2026-10-01.md`.
- Xcode platform support installed; Personal Team automatic signing created one valid Apple Development identity. Simulator runtime iOS 26.5 is installed.
- Input Lab is the default scene until G1. Full editor/consumer implementation remains gated.
- Simulator findings fixed: observe `GDTViewIOS` (scale 2), not SwiftUI hosting view (scale 1); register the Input Lab panel so buttons do not paint terrain; wrap diagnostics and add panel contrast. Evidence: `docs/evidence/simulator/summary.json`.
