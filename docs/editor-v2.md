# Editor v2 behaviour spec

Implementation contract for ADR 0009. Visual source: `docs/design/world-editor-v2.dc.html`
(claude.ai design "World Editor v2"; its `terrain-engine.js` is summarised in §4–§8). The
design is a 2D mock: where it works in screen pixels, this spec gives world metres
(design scale: 8 px = 1 m). Format: `docs/world-format.md` schema 2. Input ownership:
`docs/input-contract.md` (unchanged unless stated).

## 1. Modes and tools

| Mode | Tool id | Label | Icon (`res://addons/terrain_3d/icons/`) | Invert label | Brush |
|---|---|---|---|---|---|
| sculpt | `raise` | Raise | height_add.svg | Lower | yes |
| sculpt | `flatten` | Flatten | height_flat.svg | — | yes |
| sculpt | `noise` | Noise | height_mul.svg | Smooth | yes |
| paint | `paint` | Paint | texture_paint.svg | Erase | yes |
| paint | `spray` | Spray | texture_spray.svg | Erase | yes |
| paint | `tint` | Tint | color_paint.svg | Remove | yes |
| paint | `pick` | Pick | picker_checked.svg | — | no |
| place | `select` | Select | picker_checked.svg | — | no |
| place | `scatter` | Scatter | multimesh.svg | Erase | yes |
| place | `erase` | Erase | holes.svg | — | yes |
| place | `fill` | Fill | layers.svg | Clear | no (lasso) |
| place | `path` | Path | navigation.svg | — | no (stroke) |

Mode icons: Sculpt height_add.svg, Paint texture_paint.svg, Place multimesh.svg. Each mode
remembers its tool (defaults: raise, paint, scatter). Start-up: mode paint, tool paint.

Hints (popover footer):
raise "Draw to raise. Invert to lower." · flatten "Pulls terrain toward the target height. Pick
samples it from the terrain." · noise "Roughens the surface. Inverted, it smooths." · paint
"Replaces the layer under the brush. Inverted, it erases manual paint and reveals the rule
layer." · spray "Builds up a soft, broken blend." · tint "Colour variation on top of the
textures." · pick "Tap the terrain to pick its texture layer." · select "Drag from the Library
to place one item. Tap an object to select it, drag to move." · scatter "Paints instances from
the active set, within its slope range." · erase "Removes scattered instances under the brush."
· fill "Draw a closed loop to fill it. Inverted, it clears the loop." · path "Draw freehand. On
lift it becomes a spline; drag its points to edit."

Brush-mode hints: circle "Alpha centred on the Pencil tip." · stamp "Alpha rotates to follow
the stroke direction." · pattern "Alpha tiles in world space; the stroke reveals it."

## 2. ToolController v2 API

`ToolController` keeps its operation protocol (`begin/move/resume/pause/advance/end/cancel`,
`error`, one operation at a time, commits through ToolContext) and Library drops.

- `const MODES := ["sculpt", "paint", "place"]`, `const TOOLS_BY_MODE` per §1, `INVERT_LABELS`.
- `mode() -> String`, `set_mode(mode) -> String`; `tool_of(mode) -> String`;
  `active_tool() -> String` (tool id of the current mode); `set_tool(tool_id) -> String`
  (switches mode too). Errors: unknown id, busy. Changing mode or tool clears invert, cancels
  height picking and hides the ghost. Signal `tool_changed(tool_id)`.
- `inverted() -> bool`, `set_inverted(on) -> String` (no-op false for tools without invert);
  signal `settings_changed("invert")`.
- Settings namespaces (`settings(ns)`, `set_setting(ns, key, value)`, validated/clamped):
  - `sculpt`: `radius` (config sculpt min/max/default), `strength` (0.05–1, default
    `sculpt_strength_default`)
  - `paint`: `radius` (config paint), `strength` (default `strength_default`), `layer` int 0–3
    (default 1 dirt), `tint` int 0–2 (default 0)
  - `place`: `radius` (1–20 m, default 7), `strength` = flow (0.05–1, default 0.7)
  - `brush` (shared by every brush tool): `shape` (soft|hard|cloud|ring|splat|streak, default
    soft), `alpha_mode` (circle|stamp|pattern, default circle), `pressure_enabled` (default true)
  - `flatten`: `target` float, NAN = "stroke start" (default NAN)
  - `path`: `width` (1–6 m, default 2.4)
  - `scatter`: `source` String `"set:<id>"` or `"mix"` (default `set:forest`), `avoid_objects`
    bool (default true)
  - `select`: snap via existing `snap_enabled()/set_snap_enabled()`
- `arm_asset(asset_id) -> String`, `armed_asset() -> String`, `disarm()`: the next tool_begin
  on the world, in any mode, starts a PlaceOperation for that asset (drag to position, lift to
  place) instead of the tool; afterwards mode place, tool select, new object selected.
- `begin_height_pick() -> String`, `is_picking_height() -> bool`: the next tap samples the
  terrain height into `flatten.target` (message "Target height 12.3 m").
- Scatter source: `scatter_config() -> Dictionary` (resolved set or quick mix; §6),
  `set_quick_mix(asset_ids: PackedStringArray)`, `quick_mix() -> PackedStringArray`.
- Object edits for the inspector: existing `nudge("yaw"|"scale", delta)`, `delete_selected()`,
  new `duplicate_selected() -> String` (copy offset +3.0 m X, +1.5 m Z, regrounded per its
  grounding mode, new id, selected; label "Duplicate <name>").
- Paths: `selected_path_id()`, `select_path(id)`, `delete_selected_path() -> String`.

`stroke_state()` returns "Sculpting", "Painting", "Scattering", "Erasing", "Filling",
"Drawing path", "Editing path", "Placing", "Moving", "Editing object", "Idle".

History labels: raise "Raise terrain" / "Lower terrain"; flatten "Flatten terrain"; noise
"Roughen terrain" / "Smooth terrain"; paint "Paint <Layer>" / "Erase paint"; spray "Spray
<Layer>" / "Erase spray"; tint "Tint <Tint>" / "Remove tint"; scatter "Scatter <Set> (N)" /
"Erase scatter (N)"; erase "Erase scatter (N)"; fill "Fill <Set> (N)" / "Clear area (N)"; path
"Draw path", "Edit path", "Delete path"; rules "Toggle rule", "Edit auto-paint rule"; objects
"Place <Name>", "Move <Name>", "Rotate <Name>", "Scale <Name>", "Duplicate <Name>", "Delete
<Name>". N = instances added/removed. Strokes that change nothing push no history.

## 3. Brush alphas

Normalised offset `(u, v) = (p - c) / r` from dab centre `c`, radius `r`:

| Shape | Weight |
|---|---|
| soft | existing `BrushMath.falloff(q)` (q = √(u²+v²)) |
| hard | q ≥ 1: 0; q < 0.82: 1; else (1 − q) / 0.18 |
| cloud | q ≥ 1: 0; else (1 − q²) · clamp(noise(3u + 7, 3v + 3) · 1.6 − 0.3, 0, 1) |
| ring | q ≥ 1: 0; else exp(−((q − 0.66) / 0.16)²) |
| splat | max over blobs (x, y, s) of exp(−((u − x)² + (v − y)²) / s²); blobs (0,0,.38) (.5,.3,.26) (−.45,.4,.24) (−.3,−.5,.28) (.42,−.45,.22); 0 for q ≥ 1 |
| streak | e = u² + (v / 0.32)²; e ≥ 1: 0; else (1 − e)(0.6 + 0.4 (u + 1) / 2) |

`noise` is 2D value noise with smoothstep interpolation of a hash lattice (deterministic,
`fract(sin(x·127.1 + y·311.7)·43758.5453)`), identical in every use.

Modes: **circle** weight(u, v). **stamp** rotate (u, v) by −angle, angle = stroke direction
(atan2 of the last segment in XZ; kept when the segment is shorter than 1 mm). **pattern**
tile t = max(1.5 m, 0.7 r); (u', v') = (fract(x / t)·2 − 1, fract(z / t)·2 − 1) from the world
sample position; weight = shape(u', v') · (1 − smoothstep(0.75, 1, q)).

`soft` + `circle` keeps the existing continuous kernels bit-for-bit. Every other combination
uses discrete dabs along the segment, spacing ≤ 0.15 r, coverage = max over dabs (paint
family), and amount split evenly over dabs (sculpt family, so total mass per segment matches
the continuous kernel's).

## 4. Paint family (control map + tint map)

Per stroke, coverage `c` per sample is the maximum over the stroke of
`strength × pressure_factor × alpha` (existing PaintStrokeState pattern: start-of-stroke maps,
pure function of coverage; holding still never accumulates).

Control state: auto A, base B, overlay O, blend b = blend_u8 / 255. Painting layer L:
1. O == L: b' = b + (1 − b)·c.
2. else b == 0: O' = L, b' = c.
3. else !A and B == L: b' = b·(1 − c).
4. else (a third material; ADR 0012): the target mix (1 − c)·old + c·L needs three slots, so keep
   the two heaviest. Strong S = O if b ≥ 0.5 else B; w_S = (1 − c)·max(b, 1 − b),
   w_W = (1 − c)·min(b, 1 − b). If c < w_W the sample is unchanged. Otherwise the weaker material is
   replaced by L: if S = O then A' = false, B' = O; O' = L; b' = c / (c + w_S). At the threshold
   L takes exactly the weaker material's share, so the swap never jumps in weight.

Erase: A: b' = b·(1 − c). !A: c ≤ 0.5: b' = b·(1 − 2c); c > 0.5: A' = true, O' = B,
b' = 2(1 − c).

Blend quantised with `round(b·255)`; base id when A is set is preserved; bits outside
`PAINT_OWNED_MASK` preserved. These are pure functions in `ControlCodec` with unit tests.

Spray: coverage multiplied by 0.35 · m, m = 1 if hash(gx, gz, stroke_seed) > 0.5 else 0.2
(per-sample, per-stroke deterministic). Erase spray: coverage · 0.35.

Tint (tint map, preset colours Dry (200,180,84), Lush (38,108,40), Autumn (192,110,48)): start
colour (rgb, a). If a == 0 or rgb == tint: rgb' = tint, a' = a + (255 − a)·c. Else c ≤ 0.5:
a' = a·(1 − 2c) (rgb kept); c > 0.5: rgb' = tint, a' = 255·(2c − 1). Remove: a' = a·(1 − c).
Round to bytes.

Pick (tap): visible layer at the hit = O if b ≥ 0.5, else B if !A, else the rule material
(`TerrainRules.material_at(doc, x, z)`: CPU mirror of the shader rule using
`doc.sample_height` and the slope of `doc.sample_normal`). Sets `paint.layer`, switches to tool
`paint`, message "Picked <Layer>", no history.

## 5. Sculpt family

Time-based, reusing SculptStroke fixed steps and pressure.
- raise/lower: existing (`sculpt_speed_m_per_s`).
- flatten: per step `h += (T − h)·(1 − exp(−k·s·pf·w·dt))`, k = 4 /s, s strength, w alpha
  weight. T = `flatten.target`, or the surface height at the stroke's first valid hit when NAN.
- noise: `h += (noise(gx·0.35, gz·0.35) − 0.5)·2·rate·s·pf·w·dt`, rate 1.5 m/s (deterministic
  in world space; repeated passes roughen further).
- smooth: per step, each sample moves toward the mean of its 4 neighbours (read from a
  pre-step snapshot, neighbours across region seams included, missing neighbours skipped):
  `h += (avg − h)·min(1, 6·s·pf·w·dt)`.

All keep heights within [−32, 64], capture before write, and reground FOLLOW_TERRAIN objects
in the changed rect (existing `_reground_followers`). Pick height: §2.

## 6. Scatter

Sets (`ScatterSetStore`, `user://scatter_sets.json`, defaults when missing/corrupt):

| id | name | items (asset, weight) | density /m² | spacing m | slope ° | align |
|---|---|---|---|---|---|---|
| forest | Spruce forest | spruce 6, fern 3, boulder 1 | 0.6 | 1.4 | 0–35 | no |
| meadow | Meadow | grass tuft 7, wildflowers 2, pebbles 1 | 3.0 | 0.35 | 0–25 | yes |
| scree | Rocky scree | pebbles 5, boulder 2 | 1.4 | 0.5 | 12–70 | yes |

Set fields: `id`, `name`, `items` [{asset_id, weight 0.5–10}], `density` 0.1–5, `spacing`
0.2–4, `slope_min`/`slope_max` 0–90 (min ≤ max), `align` bool. Quick mix: items = ticked assets
weight 1, density 1.2, spacing 0.8, slope 0–45, align true, name "Quick mix". Only
`scatter_allowed` assets can be ticked or added.

Candidate test (`try_add`): slope at (x, z) within [slope_min, slope_max] (no sample → reject);
pick asset by weight; min distance = max(spacing, 0.8·footprint) to existing instances
(spatial hash, 2 m cells); with avoid on, reject within (object footprint + 0.5·min distance)
of any manual object; scale uniform in the asset's [scale_min, scale_max]; yaw uniform
[−π, π); flags bit 0 = set.align. Seeded RNG per operation (`RandomNumberGenerator`, seed from
the operation id hash; tests inject a seed).

- Scatter brush: dabs every 0.5 r along the stroke; per dab `tries = max(1, round(density ·
  π r² · 0.05 · flow · pf))`; candidate uniform in the disc, kept with probability = alpha weight.
- Erase brush / inverted scatter: per dab remove each instance with probability
  `alpha · flow · 0.7` (scatter instances only; manual objects are never touched).
- Fill: the stroke's terrain hits form a polygon in XZ (≥ 3 points, closed implicitly); live
  preview is a draped dashed loop. On lift: `tries = min(6000, round(density · bbox_area · 0.6))`
  uniform candidates in the bounding box, inside the polygon, then try_add. Clear (inverted):
  remove instances inside the polygon.
- One transaction per operation (`capture_scatter`); empty source → message "The scatter source
  is empty. Pick a set or tick assets." and no operation.
- Renderer (`ScatterRenderer`): MultiMeshInstance3D per (32 m cell, asset); instance Y =
  bilinear surface height (skip on no sample); align → basis tilted to the terrain normal; scale;
  scatter mesh from the catalog. Rebuild only cells touched by scatter changes or by height
  changes (changed rect) — not every frame. Limit 20000 instances.

## 7. Paths

- Draw (tool path, stroke not starting on a handle): collect terrain hits ≥ 0.25 m apart; live
  preview = draped ribbon of the current width. On lift: if < 2 points or length < 1 m, nothing.
  Otherwise resample to control points every 4 m (keep first and last), new PathRecord
  (width = `path.width`), and flatten along the raw stroke: every second raw point a flatten
  dab, radius 0.75·width + 0.5 m, strength 0.9, target = surface height at that point when the
  dab is applied, soft circle. Path record + heights + regrounded objects = one action "Draw
  path". The new path is selected.
- Select: tap within width/2 + 0.5 m of a path's curve selects it (tool path).
- Edit: tool path, contact beginning within 1.5 m (XZ) of a control point of the selected path
  drags that point (XZ follows the terrain hit); one action "Edit path". Heights unchanged.
- Delete: popover action "Delete selected path" → "Delete path".
- Renderer (`PathRenderer`): per path a ribbon along the Catmull-Rom curve sampled every 0.5 m,
  vertices at ±width/2, Y = surface height + 0.06 m, colour #a37650 with a darker 0.25 m edge
  rgba(50,34,18,.35); re-drape paths whose bounds intersect a height change. In tool path the
  selected path shows a white dashed centreline and control-point handles (white dots with an
  accent outline).

## 8. Objects

- Library drag-to-place unchanged (ADR 0007), plus tap a tile = arm (message "Tap the terrain
  to place <Name>"; Esc or tapping the tile again disarms). Release over a panel: "Released over
  a panel. Nothing placed."
- Ghost label (screen-space, beside the ghost): "Lift to place <Name>" (accent) or "Too close to
  <Name>" (#ff6b52) when the footprint overlaps a manual object (distance < 0.8·(r_a + r_b)) or
  "Over a panel · lift to cancel" (#ff9a88). Sub line: "Slope 12° · yaw 30°". Q/E (Mac) rotate
  the ghost ±15°. Too-close is a warning only; placement is still allowed.
- Inspector (Place mode, Select tool, an object selected, no world operation active): header
  name + first 8 chars of the id; rows Yaw (−/+ 15°, "30°") and Scale (−/+ 0.1, clamped to the
  asset range, "1.4×"); buttons Duplicate and Delete. Placement rules of ADR 0007 still apply
  (hidden during world operations, avoids other objects' screen points).
- Snap toggle "Snap move to 0.5 m" (existing snap).

## 9. Interface

Frame reference 1180 × 820 pt (iPad Air 4). Tokens: panel rgba(18,22,26,.86) (+.94/.95 for
menus/popover), border rgba(255,255,255,.08), accent #f2bf33, accent tint rgba(242,191,51,.16),
text #e8ecef, secondary #aab3bb, muted #8a949d, tool text #c9d0d6, danger #ff9a88, saved
#6fd08c, surface rgba(255,255,255,.05/.07). Every interactive panel registers with UiHitTester;
hints and toasts do not. No Unicode symbol glyphs in text (iPad font): icons only.

- **World pill** top-left (10, 10): save dot + world name + chevron icon; opens the world menu
  (240 wide, below): status text ("Saved · revision N" / "Saving revision N" / failure),
  "Open template: Flat", "Open template: Gentle Hills" (existing confirmation), "New 1 km world
  (flat)", "New 1 km world (hills)" (same confirmation; the current world is saved first, undo
  history is cleared; hills is a deterministic gentle relief, flat is height 0), "Save checkpoint
  now", "Reset camera", plus existing Diagnostics and Left-handed layout switches. Reset camera
  (and every world replacement) frames a 1 km world whole: the zoom range, pan clamp and far plane
  follow the world layout, the legacy world keeps its 140 m start and 350 m maximum distance.
  Placing or duplicating beyond the schema's object limit (2,000 legacy, 50,000 for 1 km) is
  refused with "Object limit reached (N)."; the scatter limit message shows its schema's number.
- **History** top-centre: Undo and Redo tiles 52 × 38 (icon + 9 pt caption), 40 % opacity when
  unavailable. After undo/redo a toast "Undid <label>" / "Redid <label>"; nothing to undo →
  "Nothing to undo".
- **Actions** top-right: Export (toast with the result), Library toggle (active = light fill
  #e8ecef, dark text).
- **Mode rail** left (10, 62): three 52 × 52 tiles (20 pt icon + 9.5 pt label). Tapping the
  active mode toggles the popover; another mode switches and opens it.
- **Tool popover** (76, 62), 272 wide, max 700 tall, scrolls: header "<MODE> TOOLS" + "closes
  when you draw"; 5-column tool grid (50 tall tiles); then, per tool (§1): texture swatches
  (Grass, Dirt, Rock, Sand — paint, spray, pick) or tint swatches (Dry, Lush, Autumn — tint);
  flatten target row ("Target height" + "stroke start" | "12.3 m" + Pick button); scatter
  source card (scatter, fill: kicker "SCATTER SET" / "QUICK MIX · N ASSETS", "<name> · density
  D", weight bar, Change → opens Library on the matching tab, Edit set / Save as set → set
  editor); scrubs Size and Strength (Flow in place mode) for brush tools, Width for path;
  brush alpha section (6 shape tiles with alpha previews, Circle/Stamp/Pattern segmented, mode
  hint; caption "Brush alpha · shared by all tools"); switches ("Pressure → strength" / "Pressure
  → flow" for brush tools except erase; "Keep clear of placed objects" for scatter and fill;
  "Snap move to 0.5 m" for select); actions ("Delete selected path"); in paint mode the
  auto-paint rules section (autoshader.svg + "Auto-paint rules" + "live, under manual paint";
  rows: switch + colour square + scrub "Rock above" 10–60° step 1 and "Sand below" −3.0–3.0 m
  step 0.1; "Highlight rule areas" switch, view-only); hint. A Pencil contact on the world
  closes the popover and the world menu; pick tools reopen it after the tap.
- **Active-tool chip** bottom-centre: icon + label (accent; danger colour when inverted) + sub
  (brush: "[<set> · ]7.0 m · 50%"; path "width 2.4 m"; fill "<set>" / "clear loop"; pick "tap
  terrain"; select "drag from Library"). Tap toggles the popover. Invertible tools add an
  Invert button (swap icon + invert label; active = danger tint).
- **Hints** bottom-left, 10 pt, white with shadow, not interactive: touch "1 finger orbit · 2
  fingers pan / zoom", "Pencil edits · Invert on the chip", "Library: drag to place"; Mac
  development input: "Click edits · right-drag orbit · middle-drag pan · wheel zoom", "D inverts
  · [ ] brush size · Q/E rotate ghost", "Esc cancels".
- **Library** right (top 62, bottom 10, width 240): segmented tabs Objects / Scatter sets.
  Objects: 2-column tiles (thumbnail, name, category), tick circle top-right (30 pt hit target,
  scatter_allowed assets only), armed ring; tile drag = drop, tap = arm; ticked → "Scatter N as
  quick mix" + clear button. Sets: cards (name, Edit, thumbnails, weight bar, "density D ·
  spacing S m · slope A–B°"), selected ring, "+ New set". Collapsible via the Library toggle;
  mirrored when left-handed.
  **AssetStudio libraries (IP-04)**: with a server set up, source chips (Bundled + one per granted
  library) sit above the grid, plus a search field, category chips, connectivity text and a "Load
  more" button (pages of 60). A remote tile shows its readiness: Remote, Downloading n %, Ready,
  Failed (reason) or Over budget, loader disclosures (e.g. "1 blended material(s) became cutout"),
  and Download / Cancel / Retry. Only a Ready tile can be dragged or armed; a download never starts
  a placement or changes the tool. A drop keeps the Pencil contract: one successful drop = one
  record = one history action; cancel, release over UI, world switch, backgrounding or provider
  loss leave no object. The third tab "Server" holds the device-local connection (URL, server id,
  token field that never shows the token, cleartext-LAN switch with a persistent warning). A newer
  exact version of a bound asset is only a badge ("Update available" on the tile and the inspector);
  "Review update" lists the descriptor differences (anchor, bounds, limits, slots, collision),
  requires an explicit choice for a placed scale or height offset outside the new limits (never a
  clamp), and applies one history action; undo needs no download. Declining records that version.
- **Set editor** full-screen overlay: Cancel · name field · Delete set · Save set; left: asset
  rows (thumbnail, name, colour, Weight scrub 0.5–10 step 0.5, remove), add chips for
  scatter_allowed assets not in the set, scrubs Density, Min spacing, Slope from, Slope to,
  Align switch; right: "PREVIEW · 50 × 35 M FLAT PATCH" + Re-roll, a top-down 2D preview drawn
  with thumbnails, "N instances in preview". Save requires ≥ 1 item ("Add at least one asset").
  Saving selects the set as the scatter source.
- **Toast** bottom-centre above the chip, 2.2 s; errors in danger colour. **Editing-disabled
  banner** keeps its current behaviour.
- **Keys (Mac development input)**: D invert, [ / ] size −/+ 1 m, Q/E rotate ghost, Esc closes
  popover/menu, disarms, cancels.

Asset colours (weight bars): lodge #c08a5a, spruce #3d8a4a, boulder #9a958c, grass tuft
#8fc050, fern #2f6b26, wildflowers #e9c84a, pebbles #c7c2b8.

### 9.1 Render profiles and visibility aids

Rendering configuration: `config/rendering_profiles.json` (synced copy under `app/config/`, validated by
`RenderConfig`; an invalid file falls back to built-in safe Performance defaults and posts an error).
Spec: `docs/rendering-performance-spec.md` §4, §15.4.

- **Performance indicator** top bar, immediately left of the action pill, 38 pt tall: "<Profile> · <fps> fps"
  ("—" until frames are measured; " -> <Profile>" appended while a switch is pending). The text turns
  danger-coloured when fps < 0.9 × the profile target. It is a warning only; nothing changes automatically.
  Tapping it opens the **performance menu** (250 wide, right-aligned below it): radio rows Performance /
  Balanced / Detailed, the "Hide vegetation" switch and "Target N fps · 3D P%". Both panels register with
  UiHitTester and close on Esc or when an operation starts.
- **Profiles** are explicit user choices; the app always starts in Performance and persists nothing. A
  request during a stroke or object edit is deferred: toast "<Profile> applies after the current edit", the
  row shows "(after edit)", and it is applied once when the operation commits or cancels. A profile sets the
  3D resolution scale (bilinear, MSAA/TAA off), mesh LOD threshold and Engine.max_fps. Nothing casts
  shadows in any profile; the light is fixed and the environment has no post effects.
- **Hide vegetation** is presentation only: trees, shrubs and ground cover (not pebbles) are hidden in the
  view. The document, history and selection are untouched, and the toggle is not saved.
