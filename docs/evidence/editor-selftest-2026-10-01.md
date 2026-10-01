# Editor scripted self-test — 2026-10-01

Evidence class: **SYNTHETIC — not device input evidence.** The self-test (`--editor-selftest`)
drives the real editor (InputSystem routing, ToolController, history, storage, export) with a
scripted provider labelled `SYNTHETIC SELF-TEST INPUT`. Editing contacts are `MOUSE_DEV`, camera
gestures `FINGER`; nothing is reported as Apple Pencil. Physical Pencil, palm, interruption and
calibration gates remain NOT RUN.

## Runs

| Platform | Renderer / driver | Build | Result | Evidence |
|---|---|---|---|---|
| iPad Air 4 (`iPad13,1`), iPadOS 26.5 | Mobile / Vulkan (Terrain3D) | Debug, source fingerprint `5e1830dc…879f` | PASS, 31/31 checks | [ipad-report.json](editor-selftest-2026-10-01/ipad-report.json), [diagnostics](editor-selftest-2026-10-01/ipad-diagnostics.jpg), [paint/path](editor-selftest-2026-10-01/ipad-painted.jpg) |
| Mac (`Mac16,8`) windowed | Mobile / Metal (Terrain3D) | Editor binary | PASS, 31/31 checks | [mac-report.json](editor-selftest-2026-10-01/mac-report.json) |
| iPad Simulator (iOS 18.5, x86_64/Rosetta) | Compatibility / OpenGL ES (canonical preview) | Debug | Booted, UI and terrain preview rendered; run stopped before completion at the user's request | — |

Commands: `venv/bin/python scripts/dev.py selftest` (Mac); device: `dev.py export-ios --project-only`,
`xcodebuild … -sdk iphoneos … -allowProvisioningUpdates build`, `xcrun devicectl device install app`,
`xcrun devicectl device process launch … -- -- --editor-selftest --selftest-quit
--storage-root=user://selftest_worlds`, then `devicectl device copy from … Documents/selftest`.

## Steps covered (both PASS runs)

S01 new working copy of Gentle Hills · S02 orbit/pan/pinch change only the camera (CA-01..03) ·
S03 place lodge, boulder, spruce; boulder anchor exact (OB-01) · S04 tap-select, off-centre drag
without pivot jump (OB-02), yaw/scale/height edits as separate actions · S05 raise across the x=0
region seam and lower · S06 spruce follows terrain, lodge stays fixed, one undo restores both
exactly (TE-11) · S07 dirt paint and path; path leaves objects unchanged (PA-00) · S08 undo/redo
restore exact hashes and object IDs · S09 native CANCEL mid-sculpt rolls back fully (IN-09, TE-12)
· S10 checkpoint + recovery reproduces the authored hash · S11 verified export reloads identically.

iPad final authored hash `4a64b2a3a6bf9b8ba3ba12619e551b9fa94fde4c1002f8b2bfbd0da0d70f5f5b`,
revision 45; the package stayed on the device (`Documents/selftest_worlds/…/exports/`).

## Observations and limits

- iPad Debug frame interval during the scripted run: p50 28.0 ms, p95 46.6 ms; brush p95 12.9 ms.
  Below the 60 fps target; not a Release or sustained measurement (spec §18.1 still NOT RUN).
- The first lodge placement needed a second attempt on the iPad (recorded `attempts: 2`). On the
  Mac the same retry was caused by a startup window focus-out, which the app correctly treats as
  deactivation; the device cause was not isolated.
- The engine logs `Mouse is not supported by this display server` once at iOS startup; it also
  appears in earlier Input Lab device logs and is not raised by application code.
