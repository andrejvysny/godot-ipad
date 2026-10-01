# Current State

Updated: 2026-10-01. Scope: Core PoC WP00–WP06. Broad editor work remains gated on physical G1.

## Working device baseline

Input Lab works on the tested iPad Air 4 / iPadOS 26.5 with **Mobile/Vulkan**. The user confirmed
visible terrain, finger orbit, Pencil paint, and Pencil activation of the scale and checkpoint
buttons. Native Metal produced magenta terrain and repeated `ERROR: timeout waiting for fence`;
the same installed app worked when launched with Mobile/Vulkan. Vulkan is now the iOS default;
macOS retains Metal. See [the audit](docs/evidence/ipad-audit-2026-10-01.md) and
[ADR 0006](docs/decisions/0006-ipad-vulkan.md).

Input Lab includes canonical terrain, one catalog rock, transactional pressure-independent paint,
camera navigation, history, checkpoint/recovery, traces, calibration, radius control, and
100%/50% render scale. Pencil operates buttons; fingers navigate only. Diagnostics refresh at
4 Hz and use monotonic wall time. Periodic reports and screenshots require `--lab-diagnostics`.

The installed diagnostic build has source fingerprint
`4cf84ef645d08cf622771045ff7146ae06a9e7af6f217431e43889fe9eb8e511`.
The final source additionally defers diagnostic state collection until its 2-second write is
due. That refinement passed host tests and an iOS project export, but was not reinstalled.
Evidence therefore identifies the measured build separately from the final repository state.

## Validation and limits

- Final host suites: **325 Godot tests, 102 Python tests, zero failures**.
- Native queue: **10 tests, zero failures**, ASan/UBSan, 200 fuzz rounds.
- Doctor: 28 OK, 1 WARN (`scons` not on PATH; build uses `uvx`), 1 PENDING (Mac consumer absent),
  0 NOT_RUN, 0 FAIL. This checks environment completeness, not G1 acceptance.
- Signed Debug device build installed and tested; final diagnostic scheduling refinement
  exported successfully. No Release performance run was completed.
- Device runtime report: native `GDTViewIOS` observer attached, 1,877 samples, 258 synthetic
  events, zero queue overflows, IDLE, saved revision 38, successful calibration-button event.
- At 100% scale, the recorded 600-frame window had p50 21.166 ms and p95 21.909 ms. This is
  below 60 fps and is not a sustained performance result.

**G1 is INCOMPLETE.** Formal palm/source identity, interruptions, calibration at both scales,
complete contact lifecycle, and exact physical save/reopen evidence remain open. A successful
checkpoint button and a saved revision counter do not establish byte-identical recovery.

## Earlier foundation and Simulator work

Foundation repairs cover canonical sampling, strict parsing, isolated test storage, import
failure detection, provider failure/cancellation, and transactional UI cancellation. Simulator
inspection fixed two real input defects: the bridge now observes Godot's drawable descendant
(`GDTViewIOS`, scale 2), and Input Lab registers its panel with `UiHitTester`.

The pinned official Simulator engine archive is x86_64-only and disables Metal/Vulkan there.
The local helper uses iOS 18.5/Rosetta and a visibly labeled GLES canonical-data preview.
Simulator checks cover UI routing, paint/history, calibration, durable recovery, independent
validation, and synthetic camera motion. Computer Use did not produce continuous native MOVE
events. None of these results establishes physical Pencil, palm, or Terrain3D GPU behavior.
Details: [Simulator report](docs/evidence/simulator-2026-10-01.md).

No custom engine/template or vendored Terrain3D changes were made. Signing files, copied app
containers, generated builds, and caches remain ignored. Local agent-memory files remain
outside the initial project commit.

## Next actions

1. Rebuild/install the final source when physical testing resumes; record its new fingerprint.
2. Complete physical G1 using `docs/device-test-checklist.md` and bounded, complete traces.
3. Measure Release performance at both render scales under the same scene and stroke workload.
4. After G1 passes, resume editor composition, placement/tools, export/consumer, and acceptance.

Unresolved questions: none for this handoff. External gate: formal physical G1 remains open.
