# World Painter PoC — agent notes

Product contract: `Godot_iPad_World_Editor_PoC_Specification.md` (Core PoC = WP00–WP06). The user authorized the
World Editor v2 redesign incl. PoC+ features on 2026-10-01: `docs/decisions/0009-world-editor-v2.md`, behaviour spec
`docs/editor-v2.md`, design source `docs/design/`. Report PoC+ results separately from Core results.
Format contract: `docs/world-format.md` (schema 2). Input contract: `docs/input-contract.md`. Decisions: `docs/decisions/`.

## Layout
- `app/` Godot 4.7.2 project (typed GDScript). `app/src/<module>/`, tests in `app/tests/{unit,integration}/test_*.gd`.
- `native/ios_input/` GDExtension source (Obj-C++, godot-cpp 10.0.0 api 4.7); built xcframeworks land in `app/addons/wp_native_input/bin/`.
- `scripts/` Python 3 stdlib-only tooling (`dev.py`, `validate_world.py`, `generate_fixtures.py`, shared `worldpoc_format.py`), tests in `scripts/tests/`.
- `app/addons/terrain_3d/` vendored Terrain3D 1.0.2-stable (macOS + iOS binaries only). Do not edit.

## Commands
- `python3 scripts/dev.py test` — Godot import + GDScript tests + Python tests (nonzero on failure).
- Godot must ALWAYS run with a hard timeout and stdin=/dev/null: a script error before `quit()` leaves it running forever.
- Direct: `godot --headless --path app --script res://tests/run_tests.gd -- --suite=unit --filter=name` (after `godot --headless --path app --import`).

## GDScript conventions
- Tabs, static typing everywhere, `class_name` for reusable classes, RefCounted for pure logic (testable headless).
- `:=` fails when the right side is Variant (e.g. `loc.x * 256` from an untyped loop var) — annotate explicitly.
- Packed arrays are shared by reference: `duplicate()` every snapshot.
- JSON: all numbers parse as float; Godot's number parser is not correctly rounded — exact floats use `f64le` hex (ADR 0003).
- Control map values are raw uint32 in PackedInt32Array; read with `& 0xFFFFFFFF`; never via Color/float math.
- `NAN` means "no sample"; never substitute 0 or the world origin for a missing hit.
- Expected validation failures return error strings; do not `push_error` for them (the test runner fails tests on logged errors).
- Comments only for non-obvious invariants (input ownership, byte formats, coordinate spaces).

## Evidence rules
- Never claim a device/iPad/Pencil result from desktop or simulator runs. Device gates stay NOT RUN until measured.
