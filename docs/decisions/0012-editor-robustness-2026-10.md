# 0012 — Silent undo eviction, finite world edge, no stall cancellation

Status: accepted 2026-10-01 (user decisions on Plane GODOTIPAD-1, -4, -5). Amends spec §908 (undo
limit message) and spec §745 (stall cancellation). Device results stay NOT RUN until measured.

## Undo history (GODOTIPAD-5)

### Context

`CommandHistory` was already a rolling deque: it evicts the oldest entries by action count and by
payload bytes, always keeps the newest entry, and a new action drops the redo branch. One Pencil
stroke is one entry. Spec §908 asked the editor to *show* that the undo limit was reached, so
`EditorSession.commit` posted "Undo limit reached" on every commit once 20 actions existed. Users
read the repeated toast as a failure.

### Decision

- Eviction is silent. The diagnostics overlay shows entries, MiB, eviction count and the oldest and
  newest labels instead.
- Limits: 100 actions, 256 MiB (`config/poc_defaults.json` `history`). Memory is the main bound;
  iPad Air 4 has 4 GB. A single entry larger than the budget is kept and evicts everything older.
- `EditTransaction.max_payload_bytes` (64 MiB per edit) stays a separate hard cap that refuses one
  oversized edit; it is a memory-safety guard, not an undo limit.

## World edge (GODOTIPAD-4)

### Context

`TerrainAdapter` set `Terrain3DMaterial.world_background = FLAT`, so Terrain3D drew an endless flat
grass plane outside the authored regions. Picking already returned no hit there, so painting or
placing on that plane silently did nothing.

### Decision

`world_background = NONE`. The project shader already honours `_background_mode == 0` (vertices
and fragments outside regions are discarded), so the sky shows past the edge. Collision stays
disabled. A rendered test checks the sky outside the legacy world.
