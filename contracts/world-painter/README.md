# World Painter contracts

**Status: `world-v4/` FROZEN (task IP-02, ADR 0014). `live-v1/` FROZEN (IP-05, ADR 0015); transport details (pairing, TLS) complete in IP-06.** A change to a frozen file needs an ADR, a new version and regenerated fixtures (`python3 scripts/generate_world_v4_fixtures.py`).

godot-ipad is the canonical owner. Consumers (Fantasy-game, the World Painter addon in other projects, Python validators) copy this directory unchanged with a pinned commit and hash, or take it from the addon archive, which ships it unchanged under `addons/world_painter/contracts/world-painter/` (see Packaging). AssetStudio-owned contracts (`AssetRef`, descriptor, delivery manifest, project lock) are referenced by their `$id` under `https://schemas.assetstudio.invalid/godot-integration/v1/` and are not duplicated here.

| Path | Contract | Version |
|---|---|---|
| `world-v4/asset-locks.schema.json` | `asset_locks.json` inside a world generation | lock subformat 1 |
| `world-v4/objects.schema.json` | `objects.json` for world schema 4 | 4 |
| `world-v4/binary-formats.md` | `scatter.bin` v2, `WPST` scatter preview tile v1, `binding_id` derivation | — |
| `world-v4/authored-hash-v4.md` | `WPOC-AUTHORED-V4` byte stream | 4 |
| `live-v1/envelope.schema.json` | Text message envelope for `world-painter-live` | 1 |
| `live-v1/delta.schema.json` | `delta.json` inside a `world-delta-v1` blob | 1 |

Everything not listed here (manifest `terrain`, region files, `paths.bin`, ZIP rules, exact floats) is identical to schema 3 in [`docs/world-format.md`](../../docs/world-format.md) §11.

## Freeze checklist (IP-02)

- [x] Python validator (`scripts/worldpoc_*.py`, stdlib only) tests against these fixtures (`scripts/tests/test_world_v4_*.py`).
- [x] GDScript validator checked against the same fixtures through the CLI (`scripts/tests/test_world_painter_cli.py`, IP-09).
- [x] Byte vectors cover: empty `km1` and legacy layouts; one object per provider; two versions of one asset; remote scatter; non-ASCII identifiers; control characters in `descriptor_json`; holes; v2→v4 and v3→v4 migration.
- [x] Hostile packages cover schemas 2, 3 and 4 (schema 2/3: `scripts/tests/test_package.py`, `test_hostile_input.py`, `test_layout_format.py`; schema 4: `world-v4/fixtures/invalid/`).
- [x] A fixture `INDEX.json` lists every fixture with its sha256 and expected outcome, matching the AssetStudio contract convention.

## world-v4 fixtures (`world-v4/fixtures/`)

`INDEX.json` entries: `name`, `path` (null for procedural vectors), `kind`, `expected` (`valid`/`invalid`), `sha256` of the file,
`authored_hash` (valid) or `error_substring` (invalid). Packages are deterministic `.worldpoc` ZIPs; regenerate with
`python3 scripts/generate_world_v4_fixtures.py` (`--check` compares). Validate one with
`python3 scripts/validate_world.py <file>`.

| Fixture | Content |
|---|---|
| `km1_flat_empty` | procedural (recipe in INDEX): empty `km1` world, never stored |
| `legacy_flat_empty` | empty legacy 2×2 layout (allowed in schema 4) |
| `one_bundled_object`, `one_remote_object` | one object per provider (1×1 layout) |
| `two_versions` | two assetstudio bindings of one `asset_id` at different `version_id` |
| `remote_scatter` | scatter instances of an assetstudio binding |
| `non_ascii_ids` | non-ASCII and control characters U+0001–U+001F, U+007F, U+2028, `"`, `\`, `/` in descriptor text |
| `holes` | control hole bits set |
| `migrate_v2_source` → `migrate_v2`, `migrate_v3_source` → `migrate_v3` | stored migration pairs with expected hashes |
| `migrate_v2_app_flat`, `migrate_v2_app_gentle_hills` | procedural: `validate_world.py migrate app/fixtures/<name>`, expected hash in INDEX |
| `invalid/*` | hostile v4 packages, one broken rule each (`error_substring` names it) |
| `canonical-lock-vectors.json` | canonical_v1 bytes (U+0000 excluded: Godot strings cannot hold it), float rejection, non-canonical lock bytes, `dec()`, `asset_key`, `binding_id` vectors |
| `generation-vectors.json` | Apply identities (ADR 0017 A2): `source_snapshot_hash` (synthetic and per fixture package), consumer-profile hash, `generation_id` with its pins; Python reference `scripts/world_v4_generation_vectors.py`, INDEX `kind` `vectors` |
| `descriptors/` | AssetStudio descriptor fixtures copied unchanged (`primitive_prop.json`, `primitive_prop_v2.json`) |

Bundled-binding vectors embed the catalog hash of `app/assets/catalog.json` (world-format §8); a catalog change
changes them, so regenerate the fixtures in the same commit.

## Packaging (IP-09)

`python3 scripts/package_world_painter.py` builds `dist/world-painter-addon-<version>.zip` (the addon plus this directory,
fixtures included, at `addons/world_painter/contracts/world-painter/`) and `dist/world-painter-catalog-<id>-<ver>.zip`
(`assets/catalog.json`, `models/`, `render_assets/`; no thumbnails), each with `.sha256` and `.manifest.json`
(contract versions `world-v4`, `live-v1`), plus `world-painter-pins.json`. Install with
`scripts/install_world_painter.py`; usage, pins and the CLI are in [`docs/integration-consumer.md`](../../docs/integration-consumer.md).

The GDScript validator is checked against the fixtures through the CLI: `scripts/tests/test_world_painter_cli.py` runs
`cli.gd validate` on every `world`/`migration` fixture in `INDEX.json` (hash or `error_substring`) and `cli.gd migrate`
on the migration pairs. Procedural vectors (`km1_flat_empty`, canonical lock vectors) stay covered by the app's GDScript tests.
