# Input Lab Simulator iteration — 2026-10-01

The user reported incorrect physical-iPad behavior, disconnected the device, and requested
autonomous local Simulator iteration. The physical app successfully built, signed, installed,
and launched, but no formal G1 pass was recorded. This report covers local checks only.

## Target and build

Target: iPad Air 4, iOS 18.5 (22F77), x86_64 through Rosetta on Apple M4 Pro.
Simulator UUID: `047966A6-F4C7-49A2-810A-105094D91A39`.

iOS 26.5 Simulator was installed through official Xcode Components. Runtime metadata lists
arm64 only. The pinned Godot xcframework advertises both simulator architectures, but `lipo`
reports its simulator archive is x86_64 only. The installed iOS 18.5 runtime supports x86_64.
An arm64 simulator build reproduced missing engine symbols; the x86_64 build passes.

The pinned Terrain3D library targets physical iOS only. Initial simulator linking reproduced
`building for 'iOS-simulator', but linking in dylib ... built for 'iOS'`.
Unmodified Terrain3D commit `0077405b52e353c5e5dc3a094e7ede49833ba6fe` was recompiled with
godot-cpp submodule `6388e26dd8a42071f65f764a3ef3d9523dda3d6e`. Only the isolated generated
project is patched; vendored files remain unchanged.

[Pinned Godot platform configuration](https://raw.githubusercontent.com/godotengine/godot/ed1daf0bf001b61586d9930840f2f1394092c079/platform/ios/detect.py)
disables Metal/Vulkan for Simulator. Actual runtime reports `gl_compatibility / opengl3`.
Input Lab therefore uses a labeled, downsampled canonical-data mesh preview. No custom engine
was built. These checks do not validate Terrain3D rendering or physical-device performance.

## Reproduced defects and repairs

- Native observer attached to SwiftUI's hosting view at content scale 1, while Godot's drawable
  uses scale 2. It now locates the pinned `GDTView` descendant and refuses attachment if absent.
  Actual Simulator diagnostics report `GDTViewIOS`, scale 2. Hardware mapping still needs retest.
- Input Lab omitted panel registration with `UiHitTester`; button taps began terrain edits.
  The panel is now registered, with an integration regression for Pencil/finger/hidden-panel routing.
- Diagnostics overlapped labels and extended offscreen. Wrapping, bounded view names, and a dark
  panel improve readability. Simulator preview seams are closed.
- Startup errors are now visible and recorded in `user://input_lab_startup.txt`. Controls remain
  disabled until initialization succeeds, and remain disabled after a startup failure.

## Local results

| Check | Result | Evidence |
|---|---|---|
| Build, install, launch, readable UI and terrain preview | PASS | Xcode/helper logs and Computer Use observation |
| Save Trace without authored mutation | PASS | Revision unchanged; ui_press/ui_release |
| Pressure-off paint | PASS | One stroke changed revision 3 to 4; visible dirt stroke |
| Undo / redo | PASS | Undo revision 5 restores baseline hash; redo revision 6 restores painted hash |
| Nine-point calibration | PASS | Maximum 0.0 logical points at both 100% and 50% render scales |
| Finger tap on Undo | PASS | FINGER source; control and revision unchanged |
| Reload and force-quit/relaunch | PASS | Exact authored hash, terrain payload hashes, and object IDs |
| Independent Python generation validation | PASS | Valid checkpoint; matching authored hash |
| Synthetic camera integration | PASS | Arrow BEGIN/MOVE/MOVE/END changes camera transform without authoring |
| Native continuous MOVE / finger navigation | NOT RUN | Computer Use drag delivered BEGIN/END only, about 0.35 ms apart |
| Pencil, palm, interruption during active contact, native overflow | NOT RUN | Physical-device tests required |
| Device performance and Mobile/Metal Terrain3D | NOT RUN | Simulator uses Rosetta/GLES preview |

Observed Simulator frame readouts were about 116–139 ms, not p95 measurements. These software
rendering observations do not meet or establish device targets. Simulator editing contacts are
deliberately labeled `MOUSE_DEV`, never Pencil. P selects finger mode; arrows generate explicit
synthetic development input. Capture Pointer/Keyboard had to be enabled and cycled after restart.

Painted, redone, and recovered hash:
`06b53479723d553b56a80a40344943d36fc2d7170e53062274cac4f043229247`.
Baseline and exact undo hash:
`0fd783c6766761d1973d43247a8c011f92e4e3110d2c6eae15b3c30f96c2885c`.

Structured results and selected raw traces are preserved in
[simulator/summary.json](simulator/summary.json) and adjacent files. Full copied checkpoint
payloads remain ignored under `build/simulator-evidence/`. The final delivery adds only the
startup control guard after the interaction traces; its source identity is recorded separately.

## Host validation

- 320 Godot tests, zero failures; 102 Python tests, OK.
- Native queue: 10 tests, zero failures; ASan/UBSan; 200 fuzz rounds, 54 injected overflows.
- Native device/simulator builds, final debug export, and isolated simulator Xcode build pass.
- Doctor: 26 OK, 1 WARN, 1 PENDING, 2 NOT_RUN, zero failures.

Temporary logs: `/tmp/wp-simulator-startup-final-tests.log`, `/tmp/wp-native-view-tests.log`,
`/tmp/wp-native-view-fix.log`, `/tmp/wp-simulator-delivery-export.log`,
`/tmp/wp-simulator-delivery-build.log`, `/tmp/wp-simulator-final-doctor.log`.

Physical G1 remains NOT RUN; broad editor/consumer work remains gated. No commits, pushes,
or pulls were performed. Unresolved questions: none; remaining external gate is physical G1.
