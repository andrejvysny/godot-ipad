# Current State

Updated: 2026-10-01. Scope: Core PoC WP00–WP06. The user confirmed the iPad test environment and
directed building the full editor; formal G1 evidence is still INCOMPLETE.

## Editor (2026-10-01)

`editor_main.tscn` is now the main scene (Input Lab via `--input-lab`). Implemented: TerrainView
(Terrain3D or Simulator preview), ObjectPresenter, ToolController with Select/Place/Paint/Sculpt/Path,
move and yaw/scale/height edits, grounding toggle, delete, sculpt-induced FOLLOW_TERRAIN moves in the
same transaction, EditorSession (recovery, commit, undo/redo, checkpoints, open fixture with
confirmation, verified export, deactivation save, fault injection), Pencil-operated EditorUI with
diagnostics overlay and debug views, Mac consumer with `--verify-only`, stress_100 fixture, iOS
Files/iTunes sharing, and the `--editor-selftest` scripted run.

- Host: **397 Godot tests, 110 Python tests, zero failures**.
- Scripted self-test (synthetic input, not Pencil evidence): **PASS 31/31** on the physical iPad
  Air 4 (Mobile/Vulkan, Debug) and on the Mac (Metal). Evidence:
  [editor-selftest-2026-10-01.md](docs/evidence/editor-selftest-2026-10-01.md).
- iPad Debug self-test frame p95 46.6 ms: below target; Release measurement pending.
- Pending: user Pencil test of the editor, formal G1, device checklist editor section, final report.
  PoC+ not started (needs authorization).

## UI redesign (2026-10-01)

The editor UI was rebuilt from the claude.ai design "World Editor" (ADR 0007). It now has a floating
top bar (world menu with save state, Undo/Redo labelled with the next action plus a contextual
Cancel, Reset view/Export), an icon tool dock, a context bar with scrub fields and switches, a
collapsible right-side Library with Pencil drag-to-place, an object inspector anchored next to the
selection, toasts, an editing-disabled banner, and gesture hints that name the input provider. A
left-handed layout is available. `ToolController.begin/update/finish_drop` keep the drag owned by
the tile (input contract "Library drops"). Host: **408 Godot tests, 110 Python tests, zero
failures**. Only Mac screenshots exist; the iPad layout, glyphs, and Pencil drag are NOT RUN.

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
