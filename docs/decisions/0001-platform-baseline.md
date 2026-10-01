# 0001 — Platform baseline

Status: accepted. Initial baseline recorded 2026-09-30; iOS driver superseded by ADR 0006 after physical testing on 2026-10-01.

## Decision

| Item | Pinned value | Evidence |
|---|---|---|
| Godot | 4.7.2.stable.official, commit `ed1daf0bf001b61586d9930840f2f1394092c079` | `godot --version` |
| Export templates | 4.7.2.stable (`ios.zip`, `macos.zip` installed from the official `.tpz`, SHA-512 verified against `SHA512-SUMS.txt`) | `config/toolchain.lock.json` |
| Terrain3D | `v1.0.2-stable`, commit `0077405b52e353c5e5dc3a094e7ede49833ba6fe`, release zip SHA-256 `a0718502…84a2` | vendored in `app/addons/terrain_3d` |
| godot-cpp (native bridge) | `10.0.0-stable`, commit `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`, `api_version=4.7` | `native/ios_input/build.sh` |
| Xcode / iOS SDK | 26.6 (17F113) / 26.5 | `xcodebuild -version` |
| Rendering | method `mobile`; iOS `vulkan`, macOS `metal` | `app/project.godot`, ADR 0006 |

Terrain3D 1.0.2 was chosen because it is the newest stable tag and its API was the one inspected
in the specification. It is a reference, not proof of the best iOS build.

## Consequences and constraints discovered

- **Vendored Terrain3D iOS binary is arm64 device-only with `minos 18.5`.** The app's minimum
  iPadOS is therefore 18.5. The later Simulator helper builds unchanged pinned Terrain3D source
  in an isolated directory and uses a labeled GLES preview; it does not validate device rendering.
- Only the macOS and iOS Terrain3D binaries are vendored (other platforms removed) to keep the
  repository small; `terrain.gdextension` is unmodified.
- The Terrain3D editor plugin is not enabled. No `Terrain3DEditor`, `EditorPlugin` or
  `EditorUndoRedoManager` is used at runtime (spec §2.1, §11.1).
- `input_devices/pointing/emulate_mouse_from_touch=false` and `emulate_touch_from_mouse=false`:
  there must be exactly one input path (spec §6.2).
- `editor/export/convert_text_resources_to_binary=false` so exported model scenes keep the bytes
  that the catalog hash covers (docs/world-format.md §6).
- Landscape only; stretch `canvas_items` with base 1180×820 (iPad Air 11" logical size) so
  viewport units ≈ UIKit points on that device. `CoordinateMapper` converts exactly.
- Terrain gameplay collision is disabled (spec §18.2); picking uses canonical data (ADR 0004).

## Known tool issues

- Godot 4.7.2 `--headless --import` on a fresh `.godot/` completes the import and then crashes
  with signal 11 during editor shutdown. A second run is clean. `scripts/godot_test.py` retries once.
- A script error before `quit()` in a `--script` run leaves Godot running forever; every Godot
  invocation in the tooling has a hard timeout and `stdin=/dev/null`.

## Physical evidence update — 2026-10-01

iPad Air 4 / iPadOS 26.5, user-supplied Pencil 2 model, valid local signing, and active Mobile/Vulkan
are recorded in `docs/evidence/environment.json`. Metal failed with repeated GPU fence timeouts;
Vulkan rendering, orbit, Pencil paint, and Pencil buttons work. Formal G1 remains INCOMPLETE.
See `docs/evidence/ipad-audit-2026-10-01.md`; signing credentials remain outside version control.
