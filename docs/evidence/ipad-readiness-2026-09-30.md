# iPad development readiness — 2026-09-30

This document preserves the initial audit snapshot. Its missing Input Lab and signing
configuration observations are historical. See `host-input-lab-2026-10-01.md` and
`CURRENT_STATE.md` for subsequent implementation and deployment status.

## Physical device

Live `xcrun devicectl device info details` confirms AV iPad is a physical iPad Air
(4th generation), iPad13,1, running iPadOS 26.5 (23F77), paired and connected over USB.
After the user enabled Developer Mode and restarted, `developerModeStatus` is `enabled`
and `ddiServicesAvailable` is `true`. Instruments (`xcrun xctrace list devices`) now
lists it online. CoreDevice advertises application installation, launch, process control,
profiling, file transfer, and screen viewing. These capabilities are not an app test result.

The device meets the vendored Terrain3D binary's arm64 architecture and iOS 18.5 minimum.
Actual Metal rendering, native input, performance, and Pencil behavior remain NOT RUN.
Pencil model and availability have not been established.

## Host verification

- Apple M4 Pro MacBook Pro, 24 GB memory; macOS 26.6.2 (25G83).
- Xcode 26.6 (17F113), iOS SDK 26.5.
- Godot 4.7.2.stable.official.ed1daf0bf; installed iOS/macOS template hashes match the lock.
- Terrain3D 1.0.2 binaries match pinned hashes; native bridge artifacts are present.
- Python 3.14.7; uvx available. Global scons is absent, but the native build wrapper uses pinned scons through uvx.
- Doctor: 24 OK, 1 WARN, 3 PENDING, 2 NOT_RUN, 0 FAIL.
- Full host suites: Godot 306 tests, 0 failures; Python 98 tests, OK.
- Native C++ queue: 10 tests, 0 failures, ASan/UBSan enabled; fuzz case ran 200 rounds.

The initial sandboxed Godot run failed because it could not create user:// storage directories.
The rerun with host filesystem access passed. Terrain integration emitted a deprecated
`instance_reset_physics_interpolation()` warning. Host tests do not validate device rendering.
Logs: `/tmp/godot-ipad-audit-doctor.log`, `/tmp/godot-ipad-audit-tests-host.log`,
`/tmp/godot-ipad-audit-native.log` (temporary files).

## Codebase assessment

The implementation has substantial tested foundations: canonical world data, exact control
and float encoding, transactions/history, input routing and coordinate mapping, native UIKit
input observation, threaded checkpoints/recovery, hostile-package validation, terrain projection
and canonical picking, camera logic, and paint/sculpt kernels.

The runnable application is incomplete. `app/scenes/editor_main.tscn` contains only an empty
Node3D. Input Lab and Mac consumer scenes are absent. EditorSession, ToolController,
ObjectPresenter, and the editor UI described by architecture documentation are absent from
the source tree. That document describes intended composition beyond current implementation.
TODO work-package statuses also understate implemented foundations.

The iOS preset configures Mobile/Metal and minimum OS 18.5. Files/iTunes sharing options are
false, although the device checklist describes a Finder sharing route requiring them enabled.
Terrain3D's iOS binary is device-only, so a simulator cannot validate the full terrain path.
Native bridge artifacts being present does not prove successful iOS export, linking, or launch.

## Remaining gates

1. Configure an Apple development team, certificate, provisioning, and a unique bundle ID.
   `security find-identity -v -p codesigning` currently reports 0 valid identities.
   `config/local.signing.json` is absent; the export wrapper refuses without it.
2. Implement and wire Input Lab, then export a development Xcode project and build for this iPad.
3. Install and launch a signed app; validate Mobile/Metal terrain rendering and native bridge attachment.
4. Perform Gate G1 with physical Pencil/finger gestures, cancellation, calibration, duplicate-event
   checks, pressure-disabled operation, probe editing, and save/relaunch verification.
5. Complete editor composition, then test sustained performance, interruption, and iPad-to-Mac export.

The iPad is now available as a development target. Project deployment still requires signing;
meaningful editor testing requires missing application composition. No device acceptance gate
has passed, and no application was installed during this audit.
