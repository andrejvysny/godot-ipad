# Repository Guidelines

## Project Structure & Module Organization

World Painter PoC is a Godot iPad world editor with macOS development support. `app/project.godot` defines the project; `app/src/` groups document, input, camera, terrain, tools, history, and storage modules. Scenes live in `app/scenes/`, assets in `app/assets/`, and reference worlds in `app/fixtures/`. `native/ios_input/` contains the C++/Objective-C++ input bridge. `scripts/` provides Python tooling. Read the product specification, `docs/world-format.md`, `docs/input-contract.md`, and `docs/decisions/` before changing contracts. Do not edit vendored `app/addons/terrain_3d/`.

## Build, Test, and Development Commands

Run from the repository root using Python 3.10+ and the toolchain pinned in `config/toolchain.lock.json`:

- `python3 scripts/dev.py doctor`: check environment, dependency hashes, fixtures, and configuration.
- `python3 scripts/dev.py run-mac`: launch the desktop app.
- `python3 scripts/dev.py test`: import Godot resources, run GDScript suites, then Python tests.
- `python3 scripts/godot_test.py --suite unit --filter history`: run focused tests; use `--sandbox NAME` for isolated import caches.
- `native/ios_input/build.sh macos`: build host bridge frameworks; use `ios` for device/simulator xcframeworks. Requires Xcode and `uvx`.
- `python3 scripts/dev.py export-ios`: export with local signing configuration.
- `python3 scripts/generate_fixtures.py --check`: verify fixture bytes without modifying them.

Use wrappers for Godot runs: they enforce hard timeouts and disconnected stdin.

## Coding Style & Naming Conventions

Use typed GDScript, tab indentation, `snake_case` files/functions, and `PascalCase` reusable `class_name` declarations. Keep pure logic in `RefCounted` classes. Match nearby Python indentation; use type hints and `pathlib`. No repository-wide formatter or linter is configured. Keep changes simple; explain non-obvious invariants in comments. `WorldDocument` owns authored data; scene nodes and Terrain3D are projections. Mutate through transactions and duplicate packed-array snapshots.

## Testing Guidelines

GDScript uses the custom `TestCase` runner in `app/tests/`; Python uses `unittest` in `scripts/tests/`. Name files and test methods `test_*`. Add regression cases for changed behavior, especially byte formats, hostile packages, and input cancellation. No numeric coverage threshold is configured. Desktop tests cannot establish iPad/Pencil results; keep device gates `NOT RUN` until hardware measurements exist.

## Commit & Pull Request Guidelines

No commits exist yet, so history provides no convention. Use concise imperative subjects. PRs should describe behavior, link relevant issues/spec sections, list validation, and include screenshots for UI changes. Track phased work in `TODO.md`. Never commit signing files, credentials, or generated caches; never auto-commit, push, or pull.
