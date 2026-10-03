# ADR 0017: Apply world snapshot, offline bake and rollback (IP-07)

Status: accepted 2026-10-02. Implements INT-SPEC-1.1 §11 "Snapshot and generation identities", "Explicit Apply" and
IP-SPEC-1.1 §7. Builds on ADR 0014 (schema 4), 0016 (preview process/broker).

## Decisions

### A1. Freeze

The dock's **Apply world snapshot** sends `freeze_snapshot` over the broker. The child writes the replica's current
**committed** document (never the overlay) as a schema 4 generation directory under its session root and replies
`snapshot_frozen {path, revision, authored_hash, source_snapshot_hash}`. The editor copies it into editor-owned
staging (`.assetstudio/` is AssetStudio's; World Painter uses `.world_painter/staging/<id>/`, git-ignored) and
re-validates it with the world validator before showing the review. Later live edits cannot change the candidate.

### A2. Identities

- `source_snapshot_hash` = SHA-256 of `"WPSNAPSHOT1\n"` + for each source file sorted by relative path:
  `str path` + 32 raw SHA-256 bytes; files = `manifest.json` + every declared payload.
- `generation_id` = SHA-256 of `"WPBAKE1\n"` + raw source snapshot hash + raw consumer-profile hash + `str` installer
  version, Godot build id (`Engine.get_version_info().hash`), Terrain3D build id (pinned version string), AssetStudio
  addon pin (archive sha256 from `integration.lock.json`), World Painter addon pin (plugin.cfg version + addon tree
  hash). `str` = u32 LE length + UTF-8. Directory name = first 32 hex.
- Consumer-profile hash = SHA-256 of the canonical JSON of the profile settings (`world_painter/apply/*` project
  settings + terrain material mapping resource bytes). Vectors for both encodings live in
  `contracts/world-painter/world-v4/fixtures/` (`generation-vectors.json`).

### A3. Review and preflight

Show world id, revision, authored hash, new/changed AssetStudio dependencies (vs the project lock), missing desktop
deliveries, destination. Refuse when: any required binding is unavailable on the desktop, an import is pending, a
target scene is unsaved, or the current accepted generation's `generated/` content differs from its installation
receipt (offer new destination or explicit discard).

### A4. Bake (`addons/world_painter/apply/`)

Output `<accepted_world_root>/<world_id>/revisions/<generation_id>/` (`accepted_world_root` = project setting
`world_painter/apply/accepted_world_root`, default `res://worlds`):

- `source/` — the frozen generation files unchanged (tracked).
- `apply_receipt.json` — canonical JSON: generation id inputs, source snapshot hash, authored hash, revision, per
  dependency asset_key/delivery ids, consumer profile hash, bake tool versions (tracked).
- `generated/world.tscn` + `generated/terrain/` — reproducible output (may be git-ignored; rebuilt by `cli.gd bake`).
  Terrain: a `Terrain3D` node whose data directory is `generated/terrain/`, regions filled from the exact height/
  control/color buffers through the pinned Terrain3D public API and saved with its save API; materials/rules through
  the consumer's terrain mapping (default: the World Painter terrain shader). Objects: one instance per manual
  record named by `object_id` (meta `wp_object_id`), transform from `node_transform(anchor)`; AssetStudio bindings
  instance the installed desktop delivery (portable GLB import or relocated source entry scene) recorded in the
  project lock under root `{"owner_kind": "world_generation", "owner_id": "<world_id>/<generation_id>"}`; bundled
  bindings instance `res://assets/` catalog scenes. Scatter: `MultiMeshInstance3D` per (32 m cell, binding), no
  collision unless the consumer policy opts a binding in. Paths: baked ribbon meshes from `PathRibbon`. No network,
  preview or editor scripts in the output.
- `.world_painter/receipts/<generation_id>.json` — machine-local installation receipt with hashes of generated files
  (ignored).

### A5. Transaction

Bake into staging first and validate (reload `world.tscn` headless, count objects/scatter instances, compare terrain
buffers). Then one AssetStudio `ProjectMutationCoordinator` transaction: `add_dir(staged generation → revisions/
<generation_id>)`, `add_write(<world_id>/binding.tres)` (a `WPAcceptedWorldBinding` resource: world_id,
source_snapshot_hash, authored_hash, generation_id, scene: PackedScene path), `add_write(assetstudio.lock.json)` with the
new `world_generation` root added (other roots untouched). The plugin calls `recover_project` on enable and before
run/export so an interrupted Apply ends in the old or the new complete state. The previous generation stays on disk;
**Rollback** is another transaction pointing `binding.tres` (and the lock root) back to it.

### A6. Runtime

`WPAcceptedWorldMount` (Node3D) instantiates `binding.tres`'s scene; it never contacts AssetStudio or loads world
source at runtime. Game scripts, lights and player stay outside the generated root.

### A7. CLI

`cli.gd -- validate --world <dir|pkg>`, `bake --locked --world <world_id> [--generation <id>]` (rebuild generated/
from tracked source + locks after restore/import; refuses on any input hash mismatch), `verify --offline` (all
accepted worlds' receipts and dependencies present).

## Implementation notes (IP-07, 2026-10-02)

Code: `app/addons/world_painter/apply/` (identity, review, bake helpers, stager, transaction, locked bake, verify),
`runtime/` (`WPAcceptedWorldBinding`, `WPAcceptedWorldMount`), `editor/apply_controller.gd` + dock, `preview/frozen_snapshot.gd`
(child freeze), `cli/bake_command.gd`, `cli/verify_command.gd`. Golden vectors: `contracts/world-painter/world-v4/fixtures/generation-vectors.json`
(Python reference `scripts/world_v4_generation_vectors.py`). Where the code differs from the text above:

- **Lock owner id.** `assetstudio.lock.json` owner ids are `slug` (`^[a-z0-9][a-z0-9_.-]{0,63}$`): no `/`, 64 characters at most. The root is
  `{"owner_kind": "world_generation", "owner_id": "<world_id>.<first 27 hex of the generation directory name>"}`.
- **Roots per generation, no pruning.** Apply adds the root of the new generation and keeps the roots of every retained generation;
  rollback ensures the root of the target generation and prunes nothing (pruning stays explicit, INT-SPEC §11). Which generation is
  active is decided by `binding.tres` alone.
- **Terrain files.** Region files are written with `Terrain3DRegion.save` (float32, `save_16_bit` off) under Terrain3D's own file naming
  and the node's `data_directory` points at them. `Terrain3D` is not usable before its tree is ready (a command-line script's
  `_initialize`), so the bake never puts it in the tree; `Terrain3DData.save_directory` is therefore not used. Material and texture
  assets are separate resources (`assets.tres`, `material.tres` text; `textures/*.res`), the shader parameters are written as authored values.
- **Normalization.** The bake runs against `res://.world_painter/staging/<id>/`; after the reload check the staged prefix is replaced by the
  final generation directory in every text resource (`.tscn`, `.tres`), checked to be exactly reversible.
- **Installation receipt** (`.world_painter/receipts/<dir>.json`) is a fourth write of the same coordinator transaction, so a crash
  can never leave an installed generation without its receipt.
- **Profile.** Besides the A2 settings the profile carries `terrain_collision` (`dynamic` default, `full`, `disabled`) and
  `scatter_collision_bindings`; both change the generated bytes, so both change the generation id.
- **Missing deliveries are never fetched.** Review lists them and Apply refuses; installing them is AssetStudio's add/restore flow.
- **Records of every origin** become instances (a `SCATTER`-origin object record is still an individual object).
- **Consumer hooks (FG-03/04, 2026-10-02).** `world_painter/apply/material_mapper` (res:// script with a static
  `map_material(slot_id, material) -> Material`, same hook as the preview profile) maps object surfaces (instance
  surface overrides; the instance is marked editable so the saved scene keeps them) and scatter meshes (a shared catalog
  mesh is copied only when a surface changed). `world_painter/terrain/material` replaces the default terrain material
  (the bake saves a duplicate as `terrain/material.tres`). Both are part of the consumer profile only when set:
  `material_mapper {path, sha256 of the script}` and `terrain_material {path, sha256 of the resource, its dependencies and
  shader includes}`, so a default profile keeps its hash.
