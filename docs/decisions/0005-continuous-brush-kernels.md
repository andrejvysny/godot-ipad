# 0005 — Continuous segment brush kernels

Status: accepted.

## Context

Spec §12.1 asks for resampling brush movement at a spacing of at most `min(radius/4, 0.25 m)`,
applying coverage-max paint and time-distributed sculpting. With a 16 m brush a fast stroke yields
dozens of dabs per frame, each touching ~3 000 samples, too slow for GDScript on a tablet. The spec
also requires results that do not depend on callback rate (TE-03/TE-04).

## Decision

Each resampled piece of the stroke is treated as a continuous segment, which is the limit of the
spec's dab resampling as spacing → 0:

- **Paint:** coverage of a sample from a segment is `strength · pressure · falloff(d/r)` where `d` is
  the distance to the segment and pressure is interpolated at the closest point; per-stroke
  coverage keeps the maximum. `blend = before + (target − before) · coverage`, quantized once when
  encoding. Holding still never accumulates.
- **Sculpt:** fixed 1/60 s steps from the stroke start. Within a step, the pencil path is a segment
  of length `L` and the step's `dt` is spread uniformly along it, so each sample receives
  `rate · strength · pressure · dt · (1/L)∫ falloff(|s − p(u)|/r) du`. For the spec falloff
  `(1 − q²)²` the integral has a closed form (a degree-5 polynomial), so each sample costs O(1).
  A stationary pencil (`L → 0`) reduces to a point dab with the full `dt`.
- **Path preset:** dirt paint with pressure off, strength 1, `radius = width / 2`, and a hard-core
  falloff (1 inside 60 % of the radius) so the visible trail width matches the width setting.

## Consequences

Cost per segment is proportional to the capsule area, not to the number of dabs. Results are
identical across callback rates for the same path and timeline, not merely within tolerance. The
spec's spacing rule is still exposed (`BrushMath.resample_spacing`) for diagnostics.
