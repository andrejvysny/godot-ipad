# 0004 — Terrain picking on canonical data

Status: accepted.

## Context

Spec §11.3 suggests starting with Terrain3D's CPU `get_intersection(..., gpu_mode=false)` and
validating its accuracy. The pinned 1.0.2 source (`terrain_3d.cpp`, `get_intersection`) shows:

- a fixed 1-metre step along the ray, 4000 steps, no refinement — up to ~1 m error along the
  ray, much more horizontally at grazing angles;
- when looking straight down, a missing height (hole/no region) is replaced by `y = 0`, which the
  spec forbids ("never substitute world origin for no-hit");
- it depends on Terrain3D's internal camera/viewport state.

## Decision

`TerrainPicker` raymarches the canonical `WorldDocument` heights (0.25 m steps inside the world
bounding box, then bisection) with the same bilinear interpolation as Terrain3D's `get_height`, and
returns a typed `TerrainHit` with explicit `no_hit`, `outside`, `grazing` and `invalid_ray` results.
Picking always reads the current canonical data, never stale collision or GPU readback.

An integration test measures Terrain3D's `get_intersection` against the picker on identical rays
and logs the error, so the reason for this decision stays evidenced.

## Consequences

Picking is exact to the heightfield's interpolation and independent of rendering. Cost is a few
hundred bilinear samples per pick in GDScript; timing is reported by the picker tests and the
diagnostics overlay. A C++ kernel is only added if device profiling shows a bottleneck (spec §4.2).

## Host measurements (2026-09-30)

The analytic 25-ray fixture compared pinned Terrain3D CPU intersections against canonical picking:
45 degrees: mean 0.5674 m, worst 0.9622 m; 30 degrees: mean 0.3734 m, worst 0.9633 m;
70 degrees: mean 0.3988 m, worst 0.9881 m. Vertical rays inside agreed; outside Terrain3D
substituted y=0 while canonical picking returned no position. Host evidence does not establish
device cost or visual feedback latency.

Hole cells now return NAN before interpolation, matching the pinned `get_height` hole check.
Control ownership uses floor-based coordinates, including negative coordinates and region seams.
Reading a surface does not modify either payload buffer. Ray refinement rejects brackets that
cross an absent surface.
