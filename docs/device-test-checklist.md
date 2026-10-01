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
3. Start with `xcrun devicectl device process launch --device <device-id> --terminate-existing <bundle id> -- --render-bench`
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
