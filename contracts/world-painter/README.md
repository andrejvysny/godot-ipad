# World Painter contracts

**Status: DRAFT skeleton (INT-SPEC-1.1 §9–§11).** This directory is frozen by task IP-02 (world format) and IP-05/IP-06 (live protocol). Until then, the schemas below may still change. Golden fixtures and byte vectors do not exist yet; IP-02 generates them.

godot-ipad is the canonical owner. Consumers (Fantasy-game, the World Painter addon in other projects, Python validators) copy this directory unchanged with a pinned commit and hash. AssetStudio-owned contracts (`AssetRef`, descriptor, delivery manifest, project lock) are referenced by their `$id` under `https://schemas.assetstudio.invalid/godot-integration/v1/` and are not duplicated here.

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

- Python and GDScript validators consume these schemas or hand-written equivalents tested against the same fixtures.
- Byte vectors cover: empty `km1` and legacy layouts; one object per provider; two versions of one asset; remote scatter; non-ASCII identifiers; control characters in `descriptor_json`; holes; v2→v4 and v3→v4 migration.
- Hostile packages cover schemas 2, 3 and 4.
- A fixture `INDEX.json` lists every fixture with its sha256 and expected outcome, matching the AssetStudio contract convention.
