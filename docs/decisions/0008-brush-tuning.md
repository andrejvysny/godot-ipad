# 0008 — Brush strength tuning for Apple Pencil

Status: accepted as a starting point on 2026-10-01; re-tune from on-device stroke probe data.

## Context

On iPad Air 4 the user reported that Sculpt strokes visibly did nothing, while the brush ring followed
the Pencil, and that Paint covered some places only partially. Investigation:

- The GPU upload path is correct on the Mac with Metal, Vulkan/MoltenVK, and the Mobile renderer. The
  rendered `test_gpu_texture_layers_match_document_after_partial_flush` passes on all three. No
  Terrain3D partial-update defect was found against the pinned source.
- The magnitudes were too small to see. Sculpt applied `2 m/s × strength 0.8 × pressure factor ×
  falloff × dt`, and a moving stroke spreads `dt` along its path. At the 140 m default camera distance,
  a normal Pencil stroke raised the ground by centimetres. The Mac self-test screenshot after full-strength,
  no-pressure raise strokes shows almost no relief either.
- Pressure is `force / maximumPossibleForce`. Normal writing force is a small part of the maximum, so the
  spec's linear factor `0.2 + 0.8p` stays close to its floor.
- Paint coverage per stroke is `strength × pressure factor × falloff`. Terrain3D's height blending turns
  coverage into a sharp threshold, with exponent `56 · blend_sharpness + 8` = 36 at the default 0.5.
  A light stroke's partial coverage therefore looks unpainted, or painted only where the texture
  height wins. Input Lab painting looked fine because it used pressure off and strength 1.

Spec §12.1 calls the 0.2 minimum factor "a proposed usability choice", and spec §13.1 calls 2 m/s a
"proposed default".

## Decision

Configuration (`config/poc_defaults.json`, `brush`):

| Key | Old | New | Why |
|---|---|---|---|
| `sculpt_speed_m_per_s` | 2.0 | 5.0 | Relief visible at editing distance |
| `sculpt_strength_default` | (shared 0.8) | 1.0 | Spec §13.1 rate has no strength term; strength stays a user multiplier |
| `pressure_gamma` | (linear) | 0.5 | `pressure_factor = min + (1 − min) · p^gamma`; lifts light Pencil pressure (p = 0.25 gives 0.6 instead of 0.4) |

`TerrainMaterials.BLEND_SHARPNESS = 0.15` (shader exponent ≈ 16) is applied to the Terrain3D
material. It is visual configuration only; control bytes and the saved format are unchanged.

`gamma = 1` reproduces the spec mapping exactly. Paint keeps per-stroke maximum coverage, and sculpt
keeps time-based integration and the 250 ms stall cancellation.

## Consequences

- Strokes saved before this change are unaffected. These values only change how new input maps to edits.
- The values are a starting point. The diagnostics overlay's stroke probe reports pressure range,
  pressure factor, sculpt steps, peak height change and changed control samples for the last stroke.
  "Verify GPU" checks the uploaded texture layers against the document. Re-tune from those
  device numbers, not from Mac runs, because the Mac has no pressure.
- Device evidence is still required. These settings make no iPad or Pencil claim until a physical run
  is recorded.
