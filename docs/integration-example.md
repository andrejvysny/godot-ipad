# Integration example: loading a `.worldpoc` in another Godot 4.7 project

Status: example only. Production integration with the user's game is NOT claimed (spec §17.6).

**Superseded for consumers:** install the published archives instead of copying files — see
[`integration-consumer.md`](integration-consumer.md). This page remains as a description of the loader internals.
The reference consumer is `app/scenes/mac_consumer.tscn`; the loader is `app/src/consumer/world_loader.gd`.

## What to copy

- `app/src/consumer/world_loader.gd`
- `app/addons/world_painter/core/document/` and `app/addons/world_painter/core/storage/` (document, validator, canonical encoder, codec, ZIP inspector, package)
- the trusted catalog (`catalog.json`, loaded by `AssetCatalog.load_from()`) and every model it references
- `app/addons/terrain_3d/` (only if you render the terrain; macOS/iOS binaries only)
- `app/addons/world_painter/terrain/terrain_adapter.gd` and its helpers for terrain; `app/addons/world_painter/presentation/objects/object_presenter.gd` for objects

## Rules

- Load through `WorldLoader.load_world`. It validates package structure, hashes, schema and catalog
  identity (id, version, sha256). A world is never partially loaded: you get a document or an error string.
- Asset IDs are mapped only through the trusted catalog (`catalog.get_asset(id)`); never load a path named by the file.
- Objects are placed as stored. Do not re-snap them to terrain.
- Node transform = `ObjectRecord.node_transform(asset.anchor_local)`.

## Snippet

```gdscript
extends Node3D

func _ready() -> void:
	var loaded := AssetCatalog.load_from()
	if loaded[1] != "":
		push_warning(loaded[1])
		return
	var catalog: AssetCatalog = loaded[0]
	var result := WorldLoader.load_world("/path/to/world.worldpoc", catalog)
	if result[1] != "":
		push_warning("world rejected: " + result[1])
		return
	var doc: WorldDocument = result[0]
	for id in doc.sorted_object_ids():
		var record := doc.get_object(id)
		var asset := catalog.get_asset(record.asset_id)
		var node := catalog.instantiate_preview(record.asset_id)
		node.transform = record.node_transform(asset.anchor_local)
		add_child(node)
	var terrain := TerrainAdapter.new()
	terrain.set_camera(get_viewport().get_camera_3d())
	add_child(terrain)
	terrain.initialize(doc)
```

## Headless check

`python3 scripts/dev.py open-consumer --verify-only WORLD` prints one `WORLDPOC_REPORT <json>` line
(world id, revision, authored hash, catalog, object ids, per-region height/control SHA-256, grounding
mismatches) and exits 0 on success, 1 on any validation failure.
