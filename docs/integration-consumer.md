# Installing World Painter in another Godot 4.7 project (IP-09)

Consumers vendor **published archives**, never application code. Nothing under `app/src/` is part of the product
addon. Spec: `00_SHARED_INTEGRATION_SPEC.md` §3 (canonical package locations), §9.2 (bundled catalog companion),
§15 (runbook). This replaces the copy list of [`integration-example.md`](integration-example.md) for production use.

## Archives

`python3 scripts/package_world_painter.py [--out-dir dist]` (version = `app/addons/world_painter/plugin.cfg`) writes:

| File | Content |
|---|---|
| `world-painter-addon-<version>.zip` | `addons/world_painter/**` (runtime, terrain, presentation, live, preview, editor, `cli.gd`) plus `addons/world_painter/contracts/world-painter/**` (schemas, binary-format docs, fixtures). No tests, caches or `.godot`. |
| `world-painter-catalog-<catalog_id>-<catalog_version>.zip` | `assets/catalog.json`, `assets/models/**`, `assets/render_assets/**`: the bundled catalog companion. Byte-identical to `app/assets/`. |
| `*.zip.sha256`, `*.manifest.json` | sidecar (`<hex>  <name>`); manifest with version, source commit + dirty flag, contract versions (`world-v4`, `live-v1`), requirements, per-file SHA-256. |
| `world-painter-pins.json` | ready-made `integration.lock.json` entries for both archives. |

The catalog archive holds exactly what the catalog content hash (`docs/world-format.md` §8: `catalog.json` + the
preview/scatter models) and the render registry (`render_assets/index.json`) read. Thumbnails are editor UI only
(the catalog checks their path prefix, never their bytes) and are not shipped. Builds are deterministic: the same tree
gives byte-identical archives.

The addon also needs the **AssetStudio addon** (`assetstudio-addon-<version>.zip` from the asset-studio repo's
`scripts/package_addon.py`) and, for terrain rendering, **Terrain3D 1.0.2-stable** (vendored in this repo as
`app/addons/terrain_3d`, macOS and iOS binaries only; copy it unchanged and record it in your own lock/notes).
`config/rendering_profiles.json` (`res://config/`) is optional: without it `RenderConfig` uses its safe defaults.

## Install and pin

```
python3 scripts/install_world_painter.py --project /path/to/game \
    dist/world-painter-addon-0.1.0.zip dist/world-painter-catalog-poc_nature-2.zip
python3 scripts/install_world_painter.py --project /path/to/game --check dist/world-painter-*.zip
godot --headless --path /path/to/game --import
```

The installer verifies the sidecar and manifest, refuses unsafe entries (absolute paths, `..`, backslashes, links,
anything outside `addons/<name>/` or `assets/`), replaces only the package's own paths (`addons/world_painter/`;
`assets/catalog.json`, `assets/models/`, `assets/render_assets/`) and rewrites only its own entries in
`integration.lock.json` (it can also install the AssetStudio archive; other entries are untouched). `--check` reports
missing, changed and extra files (Godot's `.uid`/`.import` files are ignored) and a lock entry that differs from the
archive. Lock entry (fields as the `assetstudio` entry):

```json
"world_painter": {"source_repository": "andrejvysny/godot-ipad", "source_commit": "<sha>", "source_dirty": false,
  "package_version": "0.1.0", "contract_version": "world-v4/live-v1",
  "archive": "world-painter-addon-0.1.0.zip", "archive_sha256": "<hex>"},
"world_painter_catalog": {"source_repository": "andrejvysny/godot-ipad", "source_commit": "<sha>", "source_dirty": false,
  "package_version": "2", "contract_version": "world-v4/live-v1",
  "archive": "world-painter-catalog-poc_nature-2.zip", "archive_sha256": "<hex>"}
```

Local path overrides (a checkout instead of an archive) are ignored developer config, never the lock.
Release pins must have `source_dirty: false`.

## Headless CLI

`godot --headless --path P --script res://addons/world_painter/cli.gd -- <command> [args]`; one JSON line on stdout.
Exit 0 ok, 1 failed check, 2 usage or I/O. Always run Godot under a timeout with stdin `/dev/null`.

| Command | Result |
|---|---|
| `validate --world <generation dir\|.worldpoc>` | `{ok, schema, authored_hash, errors, availability, catalog}` via `WorldLoader` against `res://assets` (`--assets <res dir>` overrides). `authored_hash` is the hash of the file's own schema. |
| `migrate --world <src> --out <new dir>` | schema 2/3 to 4 with the app/Python rules (ADR 0014 D9); refuses an existing destination and a schema 4 source; re-reads the result and compares hashes before the rename. |
| `bake`, `verify` | Apply/bake and generation verification (ADR 0017); a JSON error and exit 2 when the installed addon lacks them. |

Contract check: `scripts/tests/test_world_painter_cli.py` runs `validate` on every fixture in
`contracts/world-painter/world-v4/fixtures/INDEX.json` and `migrate` on the migration pairs.

## Loading a world

```gdscript
var catalog_result := AssetCatalog.load_from()          # res://assets, trusted catalog
var result := WorldLoader.load_world(path, catalog_result[0])
if result[1] != "":
	push_warning("world rejected: " + result[1])         # never a partial document
```

`examples/minimal_consumer/` does this from a scene with no addons committed.
`python3 scripts/make_minimal_consumer.py` builds the archives, installs them with AssetStudio and Terrain3D into a
temporary copy, imports headless, runs `cli.gd validate` (valid and invalid fixture) and loads a fixture world.

## Preview plugin and Apply

Enable **World Painter** in Project Settings, Plugins (`res://addons/world_painter/plugin.cfg`); AssetStudio must be
enabled too. The dock starts the preview child process and loopback broker for the iPad link
([ADR 0016](decisions/0016-desktop-preview-process.md)). **Apply world snapshot** freezes the replica's committed
document, reviews dependencies and generation identity, and bakes/rolls back through `cli.gd bake|verify`
([ADR 0017](decisions/0017-apply-world-snapshot.md)); the editor is the only writer of project files.

## Material and terrain hooks

- Preview: the profile scene root may define `map_material(slot_id: String, material: Material) -> Material`
  (ADR 0016 P4). Apply: `world_painter/apply/material_mapper` names a script with the same method, static
  (ADR 0017 hooks note). Default preserves every material; the script path and file hash are part of the consumer profile.
- `world_painter/terrain/material`: a `Terrain3DMaterial` resource used instead of the World Painter terrain material in
  the preview and the bake (hashed into the consumer profile). Its shader reads the Terrain3D maps itself and may read
  `rules_*`, `terrain_world_bounds` and `blend_sharpness`; unknown uniforms are ignored.

## Exporting a game with an accepted world

- Runtime needs only `addons/world_painter/runtime/*` (the `WPAcceptedWorldMount` and binding resource) plus the
  generated world. Exclude `addons/world_painter/{editor,preview,apply,cli,live}/*`, `.world_painter/*` and
  `.assetstudio/*` from export presets.
- Terrain3D region files (`generated/terrain/*.res`) are loaded by `data_directory`, not referenced by the scene:
  export with an include filter for `<accepted_world_root>/**` (or "all resources").
- A consumer terrain shader that `#include`s `addons/world_painter/terrain/*.gdshaderinc` needs those files in the pack.
- Gate release automation on `cli.gd -- verify --offline` (World Painter) and the AssetStudio export preflight/wrapper.
  Worked example: Fantasy-game `scripts/integration/export_integration.py`, `docs/integration/fg-05-06.md`.
