# Handoff — working iPad Input Lab

Updated: 2026-10-01. Read `AGENTS.md`, `CURRENT_STATE.md`, `TODO.md`, and
[`docs/evidence/ipad-audit-2026-10-01.md`](docs/evidence/ipad-audit-2026-10-01.md) first.
The user confirmed that the app works and requested this handoff and a local commit.
No push or pull is authorized. Core scope remains WP00–WP06; broader editor work awaits G1.

## What failed and how it was fixed

The physical iPad showed magenta terrain and appeared frozen. Its Mobile/Metal log repeatedly
reported `ERROR: timeout waiting for fence` in `rendering_device_driver_metal3.cpp:54`.
The pinned engine waits up to 1000 ms at that fence. A startup readiness marker was insufficient
to detect this rendering failure.

Launching the same installed app with `--rendering-method mobile --rendering-driver vulkan`
restored terrain rendering and removed those fence errors. The official template already
contains MoltenVK. `app/project.godot` now selects Vulkan on iOS and retains Metal on macOS.
The exact underlying GPU command failure remains unknown; no engine or Terrain3D patch was made.

Earlier Simulator work repaired the native observer target and missing UI panel registration.
During the physical audit, the user initially still reported inactive buttons. A fresh
Vulkan-default diagnostic build, with no further input injection change, responded to Pencil
on both the scale and checkpoint buttons. Do not invent a separate button-fix cause for that
last observation. Finger-inert buttons are intentional; the panel now explains the input roles.

## Source changes and verification

- Added bounded wall-clock frame statistics and a visible tick counter; the existing 250 ms
  stroke-cancellation check now sees real elapsed time instead of a capped process delta.
- Reduced diagnostic label refresh to 4 Hz while keeping input and terrain flushes per frame.
- Added opt-in runtime state every 2 seconds and one screenshot after 5 seconds. Normal
  launches do neither. State collection runs only when a report is due.
- Enabled rotating debug logs and added regressions for wall time, throttling, bounded history,
  lazy report collection, and Pencil-to-button dispatch through the scene.
- Recorded driver choice, source/native fingerprints, failure/success logs, screenshot, and
  device observations. Updated environment metadata and the physical test checklist.

Final host validation: **325 Godot tests and 102 Python tests, zero failures**. Native validation:
**10 tests, zero failures, ASan/UBSan, 200 fuzz rounds**. Doctor: **28 OK, 1 WARN, 1 PENDING,
0 NOT_RUN, 0 FAIL**. The missing deliverable is the Mac consumer; `scons` is supplied through `uvx`.

The installed and user-tested build is identified by `docs/evidence/ipad-audit/runtime-ui.json`.
The last lazy-report refinement was host-tested and exported to an Xcode project, but was not
rebuilt/reinstalled after the user requested handoff. Rebuild before attributing future hardware
measurements to the final source. Generated fingerprints are ignored and refreshed by export.

## Resume commands

```sh
venv/bin/python scripts/dev.py doctor
venv/bin/python scripts/dev.py test --sandbox handoff
bash native/ios_input/build.sh test
venv/bin/python scripts/dev.py export-ios --project-only
```

Use the generated `build/ios/WorldPainter.xcodeproj` to build/sign/install on the connected iPad.
Bundle ID: `sk.andrejvysny.worldpainterpoc`. Ignored `config/local.signing.json` contains local
signing configuration. Refresh Personal Team provisioning if needed; do not commit credentials.
For runtime capture, add `-- --lab-diagnostics` to the app arguments. Engine diagnostic arguments
such as `--log-file user://ipad-diagnostic.log` precede `--`.

Screenshots and traces were explicitly approved for this local audit. Curated evidence is in
`docs/evidence/ipad-audit/`; full copied containers and raw traces remain under ignored
`build/ipad-failure-before/` and `build/ipad-audit-traces/`. Preserve those originals locally.

For Simulator work, see the earlier report and `scripts/simulator.py`. The compatible target
used was `047966A6-F4C7-49A2-810A-105094D91A39` (iPad Air 4 / iOS 18.5 / Rosetta). Recheck available
devices before use. Its GLES preview and synthetic gestures cannot close physical GPU/input gates.

## Remaining work

1. Complete formal G1: source identity/palm, interruptions, nine-point calibration at 100% and
   50%, complete contact lifecycle, and byte-identical physical checkpoint/relaunch recovery.
2. Compare Release performance at both scales with the same scene, camera, and stroke. The
   recorded 100% Debug window had p95 21.909 ms; sustained 60 fps has not been demonstrated.
3. Keep canonical document ownership, duplicate packed-array snapshots, transaction rollback,
   and one late upload per dirty map kind per frame. Optimize measured bottlenecks first.
4. After G1, implement the remaining editor/session/UI, placement and terrain tools, consumer,
   export flow, stress fixture, and final acceptance report.

Unresolved questions: none for handoff. G1 remains INCOMPLETE; no full PoC acceptance is claimed.
