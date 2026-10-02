# Device test checklist (iPad Air + Apple Pencil)

Every item below is **NOT RUN** until performed on the physical iPad. Initial rendering and
interaction evidence is recorded in `docs/evidence/ipad-audit-2026-10-01.md`; G1 is incomplete.
Desktop and simulator
results never satisfy these items (spec §20.6). Record each result with the evidence template in
§5 under `docs/evidence/device/<test-id>.md`, plus the trace/log/video path.

## 0. Setup (Gate G0 completion)

1. Connect the iPad, trust the Mac, enable Developer Mode (Settings → Privacy & Security).
2. Record in `docs/evidence/environment.json`: iPad model (`xcrun devicectl list devices` →
   model identifier), iPadOS version (≥ 18.5 is required by the pinned Terrain3D binary),
   Pencil model (Settings → Apple Pencil, or "unknown").
3. Create `config/local.signing.json` (gitignored): `{"team_id": "XXXXXXXXXX", "bundle_id": "…"}`.
4. `python3 scripts/dev.py doctor` → no host failures; device items now report the connected iPad.
5. `venv/bin/python scripts/dev.py build-native` then `venv/bin/python scripts/dev.py export-ios --project-only`;
   open the generated Xcode project, select the Personal Team and automatic signing, then Run on
   the connected iPad. A free Apple Account supports personal on-device testing; provisioning
   expires after seven days. Paid membership is not required for this gate.

## 1. Gate G1 — native input and rendering (WP01)

Input Lab is the current default scene. On Mac: `venv/bin/python scripts/dev.py run-mac --input-lab --timeout 120`.
Pressure is disabled for every probe stroke. Record trace and evidence with **Save input trace + evidence**.

| ID | Steps | Pass condition | Evidence |
|---|---|---|---|
| G1-a / IN-01 | Tap and drag with Pencil; tap and drag with one finger; rest palm | Every contact shows the correct source on its **BEGIN** row; no source changes mid-contact; no pressure-based label | trace JSON + screen video |
| G1-b / IN-09 | Start a Pencil drag, then pull down Control Center / press Home; also a system alert | Row shows `CANCEL (native_cancel / app_deactivated)`, never `END`; no stuck contact afterwards | trace + video |
| G1-c / IN-11 | Draw with the pressure-disabled probe | Constant-strength mode shown; probe edit still applies | screenshot + trace |
| G1-d / IN-02 | One/two fingers on buttons, sliders, asset tiles, and the terrain | No button/slider reacts; only camera moves over terrain | video |
| G1-e | Orbit terrain patch; drag Pencil on terrain to paint the probe | Terrain renders with the recorded tested driver and visibly changes (currently Mobile/Vulkan; Metal failed, ADR 0006) | video + active driver shown in overlay |
| G1-f | **Checkpoint probe**, wait for Saved, force-quit, relaunch, **Reload durable probe** | Authored hash identical before/after; raw height/control bytes and object IDs unchanged (evidence JSON) | screenshot of hashes |
| IN-12 | Nine-point calibration (Input Lab → Calibrate) at normal and 50 % 3D scale | All nine offsets ≤ 2 logical points; unchanged with reduced 3D scale | calibration JSON |
| IN-04 | Draw while watching bridge counters | One BEGIN and one terminal per contact; one operation begin/terminal per owned contact; no duplicate mutation. Godot events swallowed. Coalesced/suppressed samples may produce zero or multiple actions | overlay screenshot |

If Mobile + Metal fails to render, record the failure, try only drivers present in the export
template, and stop the native PoC per spec §2.3 if none works.

Collect calibration separately at both render scales; save evidence after each set.
Run overflow/mapping-change cancellation and repeated contact tests separately. A synthetic
`cancel_all("queue_overflow")` only checks application rollback, not actual native overflow.

## 2. Core interaction tests (WP03/WP04)

IN-03, IN-05, IN-06, IN-07, IN-08, CA-01..CA-04, OB-01..OB-05, TE-10, TE-11, PA-00 — perform each
as described in spec §20, with the input trace recorder on (Diagnostics → Record trace). CA-04:
rest the right palm before Pencil-down and keep it down after Pencil-up; repeat 10 strokes; any
camera motion or edit caused by the palm fails the test.

## 3. Persistence and interruption (WP05/WP06)

IO-01 (export → Mac), IO-03 (kill app while "Saving…" is shown; relaunch), device lock/background
during a sculpt stroke (IN-09 variant), 15-minute sustained session (spec §18.1), repeated history
eviction with memory observed in Xcode's memory gauge.

## 4. Transfer procedure (iPad → Mac)

`user://` is the app's `Documents` directory on iOS. Exports are written to
`Documents/worlds/<world_id>/exports/<world_id>-rev-<N>.worldpoc`.

- **Finder:** with `accessible_from_itunes_sharing` enabled in the iOS preset, select the iPad in
  Finder → Files → World Painter → drag the `worlds` folder to the Mac.
- **Command line:**
  `xcrun devicectl device copy from --device <device-id> --domain-type appDataContainer --domain-identifier <bundle id> --source Documents/worlds --destination ./build/from-ipad`
- **Xcode:** Window → Devices and Simulators → the app → ⋯ → Download Container.

Then: `python3 scripts/dev.py validate-world build/from-ipad/…/…worldpoc` and
`python3 scripts/dev.py open-consumer <same path>`. Record which route worked.

## 4a. Render bench (spec §18.1, §18.3, §19)

Measures frame pacing (p50/p95/p99/max, missed-target and >50/>100/>250 ms hitch counts), GPU/CPU render
time with validity, draw counts and settling latency over object count (0 / 1000 / 5000) x profile
(scale_100, scale_075, scale_065, scale_050, plus the diagnostic legacy_shadows_diagnostic) x camera
(overview, ground), plus terrain-hidden diagnostic steps and a repeat of the first step (thermal drift).
The population is a dedicated deterministic "gentle_hills" document with exactly the requested object
count; your world is never changed. Result: **NOT RUN** until a Release build is measured on the iPad.
The report never claims acceptance (`evidence.acceptance` is `NOT_ACCEPTANCE_RUN`).

1. Release export: `venv/bin/python scripts/dev.py export-ios --project-only --release`, then `xcodebuild`
   with `-configuration Release` (same signing setup as section 0); install on the iPad.
2. Cold device: rested, unplugged (or note "charging"), screen brightness fixed, no other apps running.
3. Start with `xcrun devicectl device process launch --device <device-id> --terminate-existing <bundle id> -- -- --render-bench`
   (optional `--bench-counts=0,1000 --bench-frames=300 --bench-warmup=90 --bench-seed=1234
   --bench-profiles=scale_100,scale_050 --bench-cameras=overview,ground --bench-quit`), or tap
   Diagnostics -> **Render bench**.
4. Keep hands off for about 5 minutes ("Render bench running" message). Edits, undo/redo, save, export and
   world switches are blocked meanwhile; Diagnostics -> **Abort bench** stops the run. Any touch during a
   measured step, or leaving the app, aborts the run (`status` `ABORTED`, `abort_reason`
   `input_disturbance` / `app_deactivated` / `user_abort`) and writes a partial report; the state is restored.
5. The report `render-bench-<unix time>.json` lands in `user://traces/` = `Documents/traces`. Retrieve it with
   `xcrun devicectl device copy from --device <device-id> --domain-type appDataContainer --domain-identifier <bundle id> --source Documents/traces --destination ./build/from-ipad`
   and store the JSON under `docs/evidence/` (e.g. `docs/evidence/render-bench-ipad-<date>.json`) with an
   evidence record (section 5).
6. Check: `status` is `COMPLETED`, `evidence.build` is `release`, `evidence.platform_class` is `DEVICE` and
   `evidence.is_target_device` is true, `correctness.restored` is true and the authored hash/revision/history
   values are equal before and after, every step has `"settled": true`, the repeat step matches the first
   step. GPU/CPU percentiles are `null` unless `gpu_status` is `AVAILABLE` (never 0); `frame_*` values are
   wall-clock proxies (`frame_interval_source`), not GPU frame time. Steps marked `"diagnostic": true`
   are ablations, not production profiles.

### 4a.1 Representative scenarios, sustained runs, resource safety (spec §18, §20, §21.4-§21.5)

Scenario mode replaces the legacy matrix when `--bench-scenarios` or `--bench-sustained-minutes` is given
(the legacy flags above keep working without them). Worlds are built in memory from the seed, never saved, and
presented with the bench catalog (`res://assets/bench`); your catalog attachment, document, profile, camera,
selection and Texture Preview state are restored afterwards (a running preview is stopped for the run and not
turned back on).

| Flag | Meaning |
|---|---|
| `--bench-scenarios=a,b` | `terrain_only_legacy`, `terrain_only_1km`, `primitive_1k`, `primitive_5k`, `geometry_forest_10k`, `card_forest_10k`, `mixed_world_10k`, `mixed_world_50k`, `grass_50k`. `asset_diversity` is accepted and reported `NOT_RUN` (only 6 prepared bench assets). |
| `--bench-profiles=` | real profiles `performance`, `balanced`, `detailed` (default `performance`; budget per step is 1000 / profile target fps), legacy `scale_*` / `legacy_shadows_diagnostic`, or the `comparison_*` interventions in §4a.2 |
| `--bench-cameras=` | camera paths `overview`, `focus`, `shallow`, `canopy`, `path`, `travel`, `zoom_transition`, `threshold_oscillation`, `rotation` and workloads `edit_sculpt`, `edit_move`, `preview_cycles` (default: all that fit the scenario) |
| `--bench-seconds=S` | measure window per step (default 10 smoke; acceptance >= 60) |
| `--bench-warmup-seconds=S` | warm-up per step (default 2) |
| `--bench-sustained-minutes=N` | `mixed_world_10k` x `performance`: overview, focus, path, edit_sculpt, preview_cycles, travel, repeated for N minutes (N <= 120). Per-minute aggregates only; `steps` is empty and `sustained.minutes` holds frame p50/p95/p99, hitches, missed, GPU status/p95, thermal, footprint, cache bytes, nodes. |

Each step records scenario, profile, camera path or workload, population (authored meaningful, decorative,
presented), presenter render stats, cache stats, telemetry (thermal and footprint at start and end, safety
state), the frame summary (p50/p95/p99, hitches, `missed_target`, GPU status) and, for edit steps, terrain
presentation latency. `preview_cycles` runs 20 enable/disable cycles and records cache stats around each one
(MEMORY-05/PREVIEW-07). Idle pacing is never enabled. Percentiles come from 0.1 ms histogram bins (the
resolution is in the report). Focus loss aborts the run (`app_deactivated`): keep the app in front.

Host wrapper (Mac, real renderer, hard timeout, report copied to `--output`, labeled **HOST**, never device
evidence):

```
python3 scripts/dev.py render-bench --scenario mixed_world_10k,card_forest_10k --profile performance,detailed \
    --seconds 60 --output build/bench/mixed-mac.json
python3 scripts/dev.py render-bench --sustained-minutes 30 --output build/bench/sustained-mac.json
```

iPad: `--device` prints the `devicectl` launch command (installed Release build, same user args) and the pull
command for `Documents/traces`; nothing ran until a report file was pulled. `--device --run --device-id <id>
--bundle-id <id>` executes the launch, then polls the pull (every 30 s, up to `--timeout`) and prints
`evidence_class` from the pulled report only:

```
python3 scripts/dev.py render-bench --device --scenario mixed_world_50k --profile performance --seconds 60 \
    --output docs/evidence/render-bench-50k-ipad.json
python3 scripts/dev.py render-bench --device --run --device-id <id> --bundle-id <id> --sustained-minutes 30 \
    --output docs/evidence/render-bench-sustained-ipad.json
```

Sustained acceptance is a 30-minute then a 60-minute run on the iPad without external cooling; record charging,
debugger and thermal conditions in the evidence record. A Mac or simulator run proves nothing about the iPad.

Resource safety (observable while a run or normal editing is going): the performance pill appends " · Safety"
(warning colour) when the state is `warning` (thermal serious: nothing stops) or `restricted` (a memory warning
in the last 60 s, thermal critical, or a critical cache allocation rejected as over budget). Restricted stops the
Texture Preview, drops queued speculative loads, trims the cache and refuses re-enabling the preview; the
profile never changes. It clears 60 s after the last trigger; the preview stays off. `status()` exposes
`safety_state`, `safety_reason`, `thermal` and `footprint_mib` (null when unavailable, never 0). Backgrounding
the app also cancels queued loads; returning does not re-enable the preview.

### 4a.2 GODOTIPAD-35 zoom and terrain-only acceptance

Status: **NOT RUN** for this task's physical iPad Release acceptance matrix. A connected device or
a host GPU test does not satisfy these measurements. The external fantasy-game valley must first
be integrated with the shared projection/view policy; the unchanged standalone bench is not proof
of production entry-point parity. See the [task evidence matrix](evidence/godotipad-35-host-2026-10-01/README.md).

Use the existing scenario runner with `comparison_old_distance`, `comparison_size_only`,
`comparison_hlod_only`, `comparison_terrain_only`, `comparison_combined`, and
`comparison_far_terrain`. HLOD-only aliases old distance; size-only also changes tiers. Far-terrain
requests the experimental material explicitly; it is not a user profile. Record returned flags and
actual material mode rather than inferring them from a label.

An initial diagnostic command after installing the current Release build is:

```sh
xcrun devicectl device process launch --device <device-id> --terminate-existing <bundle-id> -- -- \
  --render-bench --bench-scenarios=mixed_world_10k \
  --bench-profiles=comparison_old_distance,comparison_size_only,comparison_hlod_only,comparison_terrain_only,comparison_combined,comparison_far_terrain \
  --bench-cameras=overview,focus,zoom_transition,threshold_oscillation,rotation \
  --bench-seconds=30 --bench-warmup-seconds=10 \
  --storage-root=user://render_bench_worlds --bench-quit
```

Repeat core poses at least three times after warm-up, keeping the same authored world and camera.
The first `--` ends devicectl options; the second passes Godot's user-argument separator to the app.
Repeat at 1.0/0.65/0.5 scale using existing scale interventions and verify display/internal dimensions.
Keep screenshots/readbacks outside timed windows. Record p50/p95/p99 frame intervals, valid CPU/GPU
timing, hitches, represented/submitted counts, queue cost and memory/thermal validity. Confirm zero
ordinary object/scatter/HLOD/ghost/object-preview geometry during terrain-only, then compare against
the same-camera terrain/background-only baseline.

Exercise continuous zoom in both directions, threshold oscillation, rotation, pan/teleport,
altitude/pitch changes, local edits/selection, cancellation/undo/redo, preview suspension/return,
background/resume and pressure handling. Verify finite terrain, raised/lowered edges, holes, seams,
all material slots and unchanged exported entry bytes. Run the existing 30- and 60-minute Release
procedure separately. Host correctness does not establish a speedup or achieved device envelope.

Record live source identity separately from installed build inputs. On an exported device build,
live checkout identity may legitimately be unavailable. Keep unavailable measurements unavailable;
never substitute zero or the previous export fingerprint.

The host/device wrapper also accepts these comparison profiles and `--camera` paths:

```sh
venv/bin/python scripts/dev.py render-bench --scenario mixed_world_10k \
  --profile comparison_old_distance,comparison_combined --camera overview,focus,zoom_transition \
  --seconds 30 --warmup-seconds 10 --output build/bench/zoom-host.json
```

Add `--device --run --device-id <device-id> --bundle-id <bundle-id>` for an installed current Release
build. The wrapper uses separate benchmark storage and pulls a report before claiming a completed run.

## 5. Evidence record template

```
Test ID:
Application commit:
Godot/Terrain3D/native bridge revisions:
Device and OS:
Rendering method/driver:
Fixture/package hash:
Result: PASS | CONDITIONAL | FAIL | NOT RUN
Observed values:
Trace/log/video path:
Known limitation or reproduction steps:
```
