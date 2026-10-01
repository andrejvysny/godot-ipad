# World Painter Core PoC

A native Godot iPad world editor feasibility probe. The current runnable app is **Input Lab**:
Pencil edits a canonical terrain document, fingers navigate, and checkpoints preserve authored
bytes. The complete editor and independent Mac consumer remain gated on physical-device G1.
Desktop input and automated tests do not establish Pencil, palm, rendering, or latency results.

The editor itself is **World Editor v2** (ADR 0009, `docs/editor-v2.md`): Sculpt (Raise, Flatten, Noise),
Paint (Paint, Spray, Tint, Pick over four materials with live auto-paint rules), and Place (Select,
Scatter, Erase, Fill, Path) modes, six brush alphas, scatter sets, spline paths, and a
Library with a set editor. Manual iPad checks for it are in `docs/device-test-checklist-v2.md`
(all NOT RUN).

The tested iPad configuration is now **Mobile/Vulkan**. Native Metal produced magenta output
and repeated GPU fence timeouts on iPad Air 4 / iPadOS 26.5. Vulkan restored terrain rendering,
orbit, painting, and Pencil buttons. See [the device audit](docs/evidence/ipad-audit-2026-10-01.md).

## Quick start

Use the versions pinned in `config/toolchain.lock.json`. Activate the existing Python virtual
environment, or create one with `python3 -m venv venv`. Python tooling uses only the standard library.

```sh
venv/bin/python scripts/dev.py doctor
venv/bin/python scripts/dev.py test --sandbox host
venv/bin/python scripts/dev.py run-mac --input-lab --timeout 120
venv/bin/python scripts/dev.py run-mac --timeout 120        # World Editor v2
venv/bin/python scripts/dev.py selftest                     # scripted v2 end-to-end run (synthetic input)
venv/bin/python scripts/dev.py prepare-render-assets        # [--catalog poc|bench|all] [--check]: bench generator, render derivatives, texture import
venv/bin/python scripts/dev.py validate-render-assets       # validate the editor and bench render-asset registries
venv/bin/python scripts/dev.py prepare-terrain-preview      # regenerate app/assets/terrain/preview PNGs (deterministic)
venv/bin/python scripts/dev.py render-bench --scenario mixed_world_10k --profile performance --output out.json  # windowed Mac run, HOST evidence only; --device prints iPad commands
venv/bin/python scripts/dev.py export-ios --project-only && venv/bin/python scripts/dev.py verify-export  # [--pck PATH]: the exported PCK holds every required render/config file
bash native/ios_input/build.sh test
```

Left mouse acts as development Pencil; right drag orbits; middle drag or Shift-right drag pans;
wheel pinches. These are explicitly desktop development inputs. On iPad, only the native typed
Pencil path can edit. Native failure cancels the operation and selects UNKNOWN-only fallback.

## Input Lab

Draw over terrain to paint a pressure-independent probe. Crossing UI or missing terrain pauses
the stroke; re-entry begins a new interpolation segment. Escape or native cancellation restores
all touched control buffers. A completed stroke is one undoable transaction and requests a
checkpoint. Checkpoint controls refuse an active operation; reload waits for pending storage.

Use **Checkpoint probe**, wait for **Saved revision**, then **Reload durable probe**. Force-quit
and relaunch to test startup recovery. Save trace/evidence JSON before and after reopening to
compare authored hashes, IDs, and region payload hashes. Data is stored under `user://input_lab/`;
traces and metadata are stored under `user://traces/`.

Run **Nine-point calibration** at both 100% and 50% render scale. Tap each crosshair with Pencil.
Controls hide during calibration and return after the final contact ends. Save evidence after
each set. Report offsets in logical points; the acceptance limit is 2 points. The radius slider
is a finger-inert UI probe on iPad; cancellation restores its starting value.

The panel permanently explains that Pencil operates buttons and paints, while fingers only
navigate. Its tick counter and frame interval use monotonic wall time; a stationary counter
indicates a stalled main loop. Diagnostic labels refresh at 4 Hz, while input and terrain uploads
continue every frame. Saved trace evidence includes a bounded 600-frame timing window.

Debug builds write rotating session logs under `user://logs/`. For an explicit diagnostic run,
pass `-- --lab-diagnostics` to the app. This overwrites `user://input_lab_runtime.json` every
2 seconds with frame, input, UI, upload, and save state, and captures one rendered frame after
5 seconds as `user://input_lab_frame.png`. Normal launches do not write these periodic reports
or capture screenshots. Reports are observations, not automatic device-gate passes.

## iPad development signing

Paid Apple Developer Program membership is not required for personal on-device testing.
Sign in to Xcode with an Apple Account, select **Personal Team**, and configure automatic signing.
Free provisioning expires after seven days; rebuild/reinstall as needed. See
[Apple's membership comparison](https://developer.apple.com/support/compare-memberships/).

Create ignored `config/local.signing.json` using the actual ten-character team ID:

```json
{"team_id": "YOURTEAMID", "bundle_id": "sk.andrejvysny.worldpainterpoc"}
```

```sh
bash native/ios_input/build.sh ios
venv/bin/python scripts/build_fingerprint.py
venv/bin/python scripts/dev.py export-ios --project-only
```

Open the generated project in Xcode, select the connected iPad, and Run. This path generates a
debug development project rather than distributing an IPA. Keep all signing keys and profiles
outside source control. Follow `docs/device-test-checklist.md`; G1 remains NOT RUN until the
physical Pencil/finger, calibration, interruption, and durable probe tests have evidence.

## Device build, install and self-test

```sh
venv/bin/python scripts/dev.py export-ios --project-only
xcodebuild -project build/ios/WorldPainter.xcodeproj -scheme WorldPainter -configuration Debug \
  -sdk iphoneos -destination generic/platform=iOS -derivedDataPath build/ios/deriveddata-live \
  CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build
xcrun devicectl device install app --device DEVICE_ID PATH_TO.app
xcrun devicectl device process launch --device DEVICE_ID sk.andrejvysny.worldpainterpoc
```

Release builds use `export-ios --release` and `-configuration Release`. Scripted on-device
self-test: launch arguments `-- -- --editor-selftest --selftest-quit --storage-root=user://selftest_worlds`.
Engine diagnostic arguments such as `--log-file user://ipad-diagnostic.log` precede `--`;
`-- --lab-diagnostics` enables Input Lab runtime capture. Rebuild before attributing hardware
measurements to a source state; the build fingerprint identifies the measured build.

## Local iPad Simulator

The installed iOS 26.5 runtime is arm64-only, but the pinned official Godot simulator archive
contains only x86_64. Use an iPad Air 4 with the installed iOS 18.5 runtime and Rosetta.
The pinned engine disables Metal/Vulkan in Simulator. Input Lab therefore shows an explicit
GLES canonical-data preview; it does not establish Terrain3D or physical-device G1 results.
The vendored Terrain3D files and engine templates remain unchanged.

```sh
venv/bin/python scripts/dev.py export-ios --project-only
venv/bin/python scripts/simulator.py --fetch-sources --build-terrain --device SIMULATOR_UUID
```

The helper downloads the pinned Terrain3D source and its pinned godot-cpp submodule, compiles
an x86_64 simulator library, and modifies only an isolated generated project in
`build/ios-simulator/`. Signing is disabled for this simulator build. Subsequent iterations
can omit `--fetch-sources --build-terrain`.

Enable **Capture Pointer** in Simulator; re-enable it after restarting the app if input stops.
In development mode, native direct touches are labeled `MOUSE_DEV` to exercise probe editing
and UI. Press **P** to switch to native finger navigation and inert controls. Arrow keys queue
explicit synthetic finger gestures through the same provider/router/camera path; these are
development integration checks, not native MOVE-delivery evidence. Pressure is always off.
Computer Use's instantaneous drag emitted BEGIN/END without MOVE in this environment.

Simulator calibration and persistence evidence live in the same trace/checkpoint locations
as device data. `user://input_lab_startup.txt` records readiness or a startup failure.

## Contracts and scope

- Product contract: `Godot_iPad_World_Editor_PoC_Specification.md`.
- Data format: `docs/world-format.md`; input ownership: `docs/input-contract.md`.
- Architecture and pinned deviations: `docs/architecture.md`, `docs/decisions/`.
- Tracking: Plane project `GODOTIPAD` (work items + "Current state" page). The repository keeps
  code-coupled documentation only.

Core PoC is WP00–WP06. ADR 0009 additionally authorizes the v2 editor features (smooth/flatten, scatter,
paths, four materials, rules, tint) for this project; their device results are reported separately.
Vendored Terrain3D stays pinned and unmodified. No commit, push, or pull occurs without instruction.
