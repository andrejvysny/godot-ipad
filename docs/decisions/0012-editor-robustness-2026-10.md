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

## No stall cancellation (GODOTIPAD-1)

### Context

Large strokes were cancelled with "Stroke cancelled: frame stall over 250 ms" (spec §745). Sculpt
work runs in fixed 1/60 s steps and `SculptStroke` caught up on every missed step each frame. HOST
measurement (Mac, one timeline piece per step): raise 2.2 ms, flatten 4.5 ms, noise 8.7 ms, smooth
12.3 ms per step at 16 m radius; each Pencil sample in a step adds another kernel call. Once a step
costs more than its 16.7 ms on the device, every frame owes more steps than the last, frame time
grows without bound and the 250 ms check fires. The cancel was the symptom, the catch-up the cause.

### Decision

- Slow frames never cancel a stroke. The session-level and stroke-level 250 ms checks and
  `brush.stall_cancel_s` are removed. App deactivation still cancels and rolls back.
- A backlog of up to 4 steps is processed step by step, so normal frame-rate variation stays
  exact (TE-04 cadence tests unchanged). A larger backlog is applied as 2 grid-aligned intervals;
  contiguous timeline pieces inside them are joined into straight pieces of at most half the
  brush radius. Total sculpted time is preserved (stationary raise within 0.1 mm); a moving dense
  stroke advanced at 4 fps stays within ~1.2 cm of the exact result (HOST test).
- Smooth and flatten weights are already bounded (`minf(1, …)`, `1 - exp(-…)`), so long merged
  intervals cannot overshoot.

### Consequences

- Work per frame is bounded by the brush footprint, not by how far behind the stroke is; a heavy
  brush on a slow device lowers the frame rate instead of failing the stroke.
- Per-step kernel cost (GDScript) is still high for noise/smooth at large radii; reducing it is a
  separate performance item, measured on the device first.
