# Device test checklist: World Editor v2 (iPad Air + Apple Pencil)

Companion to `docs/device-test-checklist.md` (setup, gate G1, transfer procedure and the evidence
template there apply). Behaviour contract: `docs/editor-v2.md`; decision: ADR 0009.

Every item below is **NOT RUN** until performed on the physical iPad. Desktop, simulator and
self-test (`dev.py selftest`, synthetic input) results never satisfy these items (spec §20.6).
Record each result under `docs/evidence/device/<test-id>.md` with a video, screenshot or trace
path. Results for PoC+ features (flatten, noise/smooth, scatter, paths, tint, rules) are reported
separately from Core results.

## 1. Modes, popover, chip (UI)

| ID | Steps | Pass condition | Result |
|---|---|---|---|
| V2-UI-01 | Tap each mode tile (Sculpt, Paint, Place); tap the active tile again | Popover opens on the dominant-hand side, lists that mode's tools, closes on the second tap; each mode remembers its last tool | NOT RUN |
| V2-UI-02 | Open the popover, then draw on the terrain with the Pencil | Popover and world menu close when the Pencil touches the world; stroke is not lost | NOT RUN |
| V2-UI-03 | Tap the active-tool chip; use **Invert** on Raise, Paint, Scatter, Fill | Chip label and colour show the invert state; stroke follows it; switching tool clears invert | NOT RUN |
| V2-UI-04 | Finger-touch every button, scrub field, swatch and Library tile | Nothing reacts to fingers; Pencil operates all of them | NOT RUN |
| V2-UI-05 | Toggle Left-handed layout (world menu) | Rail and popover mirror to the right, Library to the left; diagnostics stay clear of the Library | NOT RUN |
| V2-UI-06 | Trigger a long toast (e.g. export result) and open diagnostics | Toast wraps inside the free span, never overlaps the rail, popover or Library; diagnostics panel stays above the chip and scrolls | NOT RUN |
| V2-UI-07 | World menu status after an edit and after waiting | Shows "Saving revision N" then "Saved · revision N" | NOT RUN |

## 2. Sculpt tools

| ID | Steps | Pass condition | Result |
|---|---|---|---|
| V2-SC-01 | Raise, then Invert (Lower), at 3 sizes | Terrain follows the Pencil; one undo per stroke; no stall | NOT RUN |
| V2-SC-02 | Flatten with "stroke start" target, then **Pick** a height and flatten elsewhere | Terrain moves toward the target; toast "Target height N m"; object FOLLOW_TERRAIN placements regrounded | NOT RUN |
| V2-SC-03 | Noise, then Invert (Smooth), same area | Surface roughens, then relaxes; no seam at region borders | NOT RUN |
| V2-SC-04 | Each brush alpha (soft, hard, cloud, ring, splat, streak) with Circle, Stamp, Pattern on Raise | Footprint matches the popover preview; Stamp follows stroke direction; Pattern tiles in world space | NOT RUN |
| V2-SC-05 | Pressure switch on/off | Strength varies with force when on; constant when off | NOT RUN |

## 3. Paint tools and rules

| ID | Steps | Pass condition | Result |
|---|---|---|---|
| V2-PA-01 | Paint each material (Grass, Dirt, Rock, Sand); then Invert (Erase) | Material replaces the layer under the brush; Erase reveals the rule layer | NOT RUN |
| V2-PA-02 | Spray, then Invert | Soft broken blend; no accumulation when holding still | NOT RUN |
| V2-PA-03 | Tint (Dry, Lush, Autumn), then Remove | Colour variation over textures with texture detail kept; Remove fades it | NOT RUN |
| V2-PA-04 | Pick on dirt, rock, and a rule-driven area | Selected swatch matches; toast "Picked <Layer>"; tool returns to Paint | NOT RUN |
| V2-PA-05 | Scrub **Rock above** and **Sand below** | Slopes and low ground repaint live; releasing is one history action | NOT RUN |
| V2-PA-06 | Toggle rock and sand rules; **Highlight rule areas** | Toggle is one undoable action; highlight is view-only and does not change saved data | NOT RUN |
| V2-PA-07 | Diagnostics Blend / Height / Normals / Region grid views | Each view renders (no magenta) and toggles back to the lit terrain | NOT RUN |

## 4. Place tools

| ID | Steps | Pass condition | Result |
|---|---|---|---|
| V2-PL-01 | Drag a Library tile onto the terrain; tap a tile to arm and tap the terrain | Ghost label follows; placement lands where lifted; object selected | NOT RUN |
| V2-PL-02 | Select an object; use inspector Yaw, Scale, Duplicate, Delete | Each edit is one undo step; inspector avoids other objects | NOT RUN |
| V2-PL-03 | Scatter with the meadow set, then forest, then a quick mix of ticked assets | Instances appear within the slope range; "Keep clear of placed objects" respected | NOT RUN |
| V2-PL-04 | Erase, and Scatter with Invert, over scattered and manual objects | Only scatter instances are removed; manual objects untouched | NOT RUN |
| V2-PL-05 | Fill a closed loop; Invert (Clear) a loop | Dashed loop preview while drawing; fill/clear applies on lift; one undo each | NOT RUN |
| V2-PL-06 | Draw a path; drag a control point; delete it from the popover | Path flattens terrain on draw (one action); handle drag edits the curve only; handles stay at least about 22 pt across at any zoom | NOT RUN |
| V2-PL-07 | Edit a set in the Library (set editor), save a quick mix as a set | Set editor opaque, scrubs work with Pencil, Save selects the set as the source | NOT RUN |
| V2-PL-08 | Scatter, Fill, Path strokes, then Undo and Redo repeatedly | State returns exactly each time (compare saved hash) | NOT RUN |

## 5. Persistence

| ID | Steps | Pass condition | Result |
|---|---|---|---|
| V2-IO-01 | Make scatter, path, rule and tint edits, wait for Saved, force-quit, relaunch | All data restored; authored hash identical | NOT RUN |
| V2-IO-02 | Export and open in the Mac consumer | Scatter, paths, tint and rules render as in the editor | NOT RUN |

## 6. Performance probes to capture

Record frame time from Diagnostics (Frame p50/p95 and brush p95) with the active driver shown.
All NOT RUN.

| ID | Probe | Method | Capture | Result |
|---|---|---|---|---|
| V2-PF-01 | Cloud alpha stroke, radius 8 m | Paint (or Raise) with shape cloud, size 8 m, a 10 s continuous stroke | Frame p50/p95, brush p95, any stroke stall cancel | NOT RUN |
| V2-PF-02 | 20000-instance scatter rebuild | Fill/scatter until the instance limit (20000), then undo/redo and a large sculpt under the scatter | Rebuild ms (scatter stats `last_rebuild_ms`), frame p95 during rebuild | NOT RUN |
| V2-PF-03 | Rule scrub | Drag **Rock above** back and forth for 10 s on Gentle Hills | Frame p50/p95 while scrubbing; hitches on release (commit) | NOT RUN |
| V2-PF-04 | 15-minute mixed session | Alternate every tool; watch memory in Xcode | Peak memory, history evictions, no crash | NOT RUN |
