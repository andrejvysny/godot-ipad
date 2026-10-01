# Input Lab host verification — 2026-10-01

This earlier snapshot is superseded by `simulator-2026-10-01.md` and `CURRENT_STATE.md`.
Platform installation, signing, physical launch, and subsequent Simulator repairs occurred later.

The foundation repairs and Input Lab composition are implemented. Physical-device Gate G1
remains NOT RUN. The user will perform Pencil and finger tests on the USB-connected iPad.

## Verification

- `venv/bin/python scripts/dev.py test --sandbox release-probe`: 318 Godot tests,
  zero failures; 102 Python tests, OK.
- `bash native/ios_input/build.sh test`: 10 tests, zero failures, ASan/UBSan,
  200 fuzz rounds.
- `bash native/ios_input/build.sh ios`: device and simulator frameworks build successfully.
- `venv/bin/python scripts/dev.py doctor`: 25 OK, 1 WARN, 2 PENDING, 2 NOT_RUN,
  zero failures. Pending items are signing identities and the gated Mac consumer.
- `venv/bin/python scripts/dev.py export-ios --project-only`: debug Xcode export succeeds;
  the export preset is restored byte-for-byte.
- Rendered Mac startup reports Mobile/Metal on Apple M4 Pro. No script errors occurred;
  the pinned Terrain3D compatibility deprecation remains.

Temporary logs: `/tmp/wp-release-probe-tests.log`, `/tmp/wp-native-tests.log`,
`/tmp/wp-native-ios-build.log`, `/tmp/wp-current-doctor.log`,
`/tmp/wp-latest-export.log`, and `/tmp/wp-lab-mac.log`.

## Deployment status

AV iPad is an iPad Air 4 (`iPad13,1`) running iPadOS 26.5 (23F77), connected over USB-C.
Developer Mode is enabled and DDI services are available. Apple Pencil 2 is available
according to the user. The Personal Team is visible in Xcode; ignored local signing
configuration is present and development certificate creation is explicitly approved.

Xcode currently requires its official iOS platform-support component before the physical
destination becomes eligible. That installation is in progress. Successful native linking,
installation, launch, actual iPad renderer, calibration, and persistence remain NOT RUN.
Installing the required simulator runtime does not establish any physical-device result.

Broad editor composition, terrain-tool wiring, and consumer/export acceptance remain gated
on G1. No commits, pushes, or pulls were performed.
