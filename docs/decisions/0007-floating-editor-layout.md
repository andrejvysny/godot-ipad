# 0007 — Floating editor layout and Library drag-to-place

Status: accepted for the Core PoC editor (2026-10-01). Layout still needs physical validation on
the iPad with the Pencil and a resting palm (spec §9 calls its layout "proposed defaults to
validate physically").

## Context

The first editor build followed the spec §9 proposal literally: a full-height left rail of text
buttons, a context panel beside it, a top status row, and a bottom asset strip. On the iPad Air 4
(1180×820 pt) those panels covered roughly 30 % of the view. Several states were encoded only in
caption text ("▶ Select", "Pressure: ON"), and the device font did not render the ▶ glyph at all.
Undo and Redo did not show which action they would affect. Placing an asset needed two separate
steps, and nothing showed where the object would land before the Pencil touched the terrain.

The project's claude.ai design ("World Editor", proposal 1a) replaces this with floating panels.

## Decision

- **Top bar (three pills).** The world menu shows the world name and the save state as a dot
  plus text, so the state never depends on colour alone. The menu opens templates (with the
  existing confirmation), saves a checkpoint, and toggles the diagnostics overlay and a
  left-handed layout. Undo and Redo show the label of the next action. A contextual Cancel
  appears only while an operation is active (spec §16.2). Reset view and Export sit on the right.
- **Tool dock.** Five icon tiles with text labels; the active tool is highlighted. No glyphs.
- **Context bar** beside the dock. It holds the settings for the active tool: material or
  direction as a segmented control, Size/Strength/Width as relative-drag scrub fields, Pressure
  and Snap switches, and a hint. While an operation runs, the hint shows the stroke state.
- **Library** on the right (mirrored when left-handed) can collapse to a 56 pt strip. Its
  category chips are generated from the catalog. It has **no search field**, because spec §9
  forbids requiring a keyboard and the Core catalog has only three assets.
- **Object inspector** anchored next to the selected object. Each value has steppers and a
  stacked scrub field, so one continuous drag is still one history action. Grounding uses a
  segmented control, with Focus and Delete below it. The inspector is hidden while a world
  operation is active. If it followed a dragged object, the router would treat it as interface
  under the world-owned Pencil and pause the move. It also does not reposition while a Pencil
  holds any control.
- **Non-blocking overlays.** The gesture hints with the input-provider badge, toasts, the
  editing-disabled banner, and the drop hint are not registered with `UiHitTester`. A Pencil
  over them edits the world.

## Library drag-to-place

A Pencil drag that starts on a Library tile places the asset when it is lifted over terrain.
The previous two-step flow is unchanged: tap a tile, then touch the terrain (spec §14.1).
Ownership follows the input contract. The contact began over interface, so the tile owns it until
it ends. The tile forwards positions to `ToolController.begin_drop/update_drop/finish_drop`,
which drive the same `PlaceOperation`: the presenter ghost, terrain-only picking, snap, and one
transaction on a valid release. A release over any registered panel, or with no valid terrain
hit, places nothing. `ui_cancelled` and `cancel_active` roll the drop back. The controller ignores
router tool actions while a drop is open. This is not a terrain stroke started from a control
(spec §7.2), because the control owns the contact and only a placement can result.

## Consequences

- The right-side Library leaves less of the lower-right viewport clear than spec §9 proposes.
  It can collapse, and the layout can be mirrored. Physical palm testing decides whether this
  holds.
- UI tests address controls through component accessors instead of captions.
- On iOS, all icons are SVG textures (Terrain3D MIT tool icons plus icons authored in this repo).
