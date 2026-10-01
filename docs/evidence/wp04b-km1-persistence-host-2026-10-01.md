# WP04b: km1 persistence frame cost — HOST measurements, not device evidence

Machine: development Mac (Apple Silicon), Godot 4.7.2 headless, desktop timers. No iPad or Pencil
measurement was made; device gates stay NOT RUN. Numbers vary a few percent between runs.

World: km1 layout (64 regions, schema 3, 48 MiB of terrain), hills terrain, `nature.rock.boulder_a`
objects spread over the extent. "Main thread" = `WorldStorage.request_checkpoint` (snapshot only; the
worker writes). Spec: `docs/rendering-performance-spec.md` §16.6.

## Snapshot (main thread) before and after

| Objects | Before (full snapshot every time) | After, first snapshot (cold cache) | After, warm (one object edited) |
|---:|---:|---:|---:|
| 0 | 124 ms | 2.0 ms | 1.2 ms |
| 10,000 | 260-270 ms | 152 ms | 0.7-1.0 ms |
| 50,000 | 790-840 ms | 770-815 ms | 1.2-1.8 ms avg, 2.7-4.0 ms worst |

Before, at 50,000 objects: `objects.json` encode 465-485 ms + authored hash 317-320 ms (about 120 ms
of it SHA-256 over the 48 MiB of terrain, the rest per-object canonical encoding). Region byte
copies (`height_bytes`/`control_bytes`/`color_bytes`, 192 maps) cost 0.6 ms in total, so they were
not changed (packed-array conversions are copy-on-write).

What changed: `ObjectChunkCache` keeps per-object `objects.json` entry bytes and canonical-hash bytes in
sorted id order and re-encodes only the objects the document's put/remove journal reports as changed;
the worker assembles `objects.json`, the payload digests and the authored hash from those plain chunks
(`WorldCodec.finalize_snapshot`). The cold first snapshot still encodes every object once;
`WorldStorage.warm_snapshot_cache()` does that when a recovered world is opened, so the first edit does
not pay it. Snapshot bytes and hash are identical to the full encoding
(`tests/unit/test_object_chunk_cache.gd`: fixtures, random edit sequences, undo, redo, replaced
documents, two caches on one document).

A km1 snapshot with 20,000 scatter instances and no objects costs 5.8-6.1 ms (`ScatterLayer.encode`
alone 3.5-3.7 ms, a per-instance script loop); not optimised.

## World open (read, validate)

| Objects | `WorldValidator.validate` | `read_generation` total |
|---:|---:|---:|
| 0 | 221 ms | 462 ms |
| 10,000 | 272 ms | 786 ms |
| 50,000 | 462 ms | 2,123 ms |

`read_generation` at 50,000 objects: payload load and hashes 234 ms, layer decode 1,145 ms (JSON parse
and `ObjectRecord.from_dict`), authored hash 319 ms, validation 450 ms. The validator is far below
1.5 s, so its sample loops were left as they are; the per-object decode dominates and is a follow-up.

## Other measurements

- `TerrainAdapter.initialize` of a km1 document (64 regions): about 165 ms headless.
- New hills world (`SessionWorldOps.new_layout_world`, bicubic upsample of a 17 x 17 grid): about 55 ms.
- 50,000-object round trip (`tests/integration/test_world_04_km1_50k.gd`): `checkpoint_now` 3.5 s,
  `recover_latest_valid` 2.4 s, whole test about 23 s.
