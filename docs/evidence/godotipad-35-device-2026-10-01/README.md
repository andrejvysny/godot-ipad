# GODOTIPAD-35 physical-device diagnostic evidence

Device: physical iPad Air 4 (`iPad13,1`), Apple A14 GPU, Release, Mobile/Vulkan 1.2.334.
Base checkout: `47cbb912275cf7cd4adf49ab28274f1b697d5ed3`, dirty implementation tree.
These generic editor workloads do not establish acceptance of the separate fantasy-game valley.
The user explicitly chose godot-ipad-only implementation scope; external integration remains
pending by that choice. No external files were changed.

## Initial diagnostic matrix

[Raw report](initial-not-ready.json), [installed build inputs](initial-installed-identity.json).
Installed source SHA-256: `7b704d45b7f53f06b4c2ed26b8b993469f81f68264897e61085aea9ebdb9f6d3`.
PCK SHA-256: `4e3fc321945801baee3ae9368a489dde29cc6f9594bcb25b495b3c6ad7a4c14a`.

The deterministic `mixed_world_10k` workload contains 10,000 authored meaningful objects and
20,000 decorative scatter instances. Ten steps measured 30 seconds each after two seconds of
warm-up and a capped settling wait. Every row reports `settled=false`. CPU/GPU samples are
positive and available, but these timings include unfinished presentation work and are **not
steady-state calibration or a controlled three-repeat performance acceptance run**. Charging and
battery state were not recorded; thermal telemetry stayed nominal. Footprint was approximately
674–840 MiB. The restored user's authored hash, revision and history remained unchanged.

| Variant / pose | Frame p95 (ms) | GPU p95 (ms) | CPU render p95 (ms) | Last primitives |
|---|---:|---:|---:|---:|
| Old distance / overview, first | 17.1 | 10.1 | 2.0 | 612,366 |
| Old distance / focus | 22.8 | 21.1 | 1.6 | 628,384 |
| Old distance / shallow | 17.0 | 13.6 | 1.7 | 654,206 |
| Combined / overview | 17.0 | 10.8 | 1.3 | 355,424 |
| Combined / focus | 26.2 | 21.4 | 1.8 | 672,100 |
| Combined / shallow | 17.2 | 14.0 | 1.6 | 648,266 |
| Old distance / overview, repeat | 17.0 | 10.4 | 1.4 | 457,560 |

The combined focus result exceeded the 25 ms goal and was about 15% above the initial old-distance
frame p95. This warrants investigation; it is not an established steady-state regression boundary.
The baseline overview changed representation between its first and repeated row, reinforcing the
warm-up limitation. No blanket speedup or calibrated workload envelope is claimed.

The `comparison_size_only` rows are **INVALID ABLATION**: despite `hlod_enabled=false`, the old
service loop reactivated proxies. This run exposed that defect. The implementation now gates
service, activation, capture, mesh publication and pending work while HLOD is disabled, with
moving/settled and partial-capture regressions. Raw data is retained unchanged for review.

The combined overview recorded zero individual-object instances and zero HLOD submissions.
Scatter submission counts were not recorded by this older report, so its image alone is not
proof of every zero-submission invariant. New reports include scatter submissions, actual view
state/material mode, pending reasons and static-measurement readiness.

Screenshots were captured outside timed windows:

- [Old-distance overview](mixed_world_10k-comparison_old_distance-overview.png), overwritten by the
  final repeat under the existing screenshot filename scheme.
- [Combined terrain-only overview](mixed_world_10k-comparison_combined-overview.png).

The console observer timed out after the report was completed; iOS `SceneTree.quit()` did not
terminate the native process. Report collection, not observer exit status, establishes benchmark
completion. Subsequent runs use launch-and-poll collection.

## Corrected readiness smoke

[Raw report](readiness-smoke.json), [installed build inputs](readiness-installed-identity.json).
Installed source SHA-256: `d5a3ee36522857a80c350857e2bd0392cc94a5c13e9e24d592a32871c02ed4bc`.
PCK SHA-256: `e501c062dce964647d03355664547ab1e8936843e5829dfe4cfd38878e9f46bc`.
This report predates further scheduler corrections under evaluation. It is retained as diagnostic evidence,
not proof of the final working tree or current installed application.

Seven rows measured two seconds each after ten seconds of warm-up and a capped ten-second settling
wait. Two rows were `READY`: combined overview and the final old-distance overview repeat. Five were
`NOT_READY`: initial old-distance overview/focus/shallow and combined focus/shallow. These short
windows are **not performance calibration**. Every row restored the original authored hash, revision
and history. All scenario rows record generated-world SHA-256
`967deedce51b4ae19d2156ffb40d05a9dbab1d850cc78368b866009eae069b1b` and attached bench-catalog SHA-256
`4a5fe2f2c632971afea0a710749782271c142766da5396ec24f2347994e2f83c`.

Combined overview was `terrain_only`, full material, with **zero individual-object instances, zero
scatter submissions and zero HLOD proxy submissions**. Its held masked classification queues did
not falsely mark the static measurement busy. Local combined poses still reported pending object
classification: only 1,341 evaluations at the end of focus, then 3,899 cumulative at the end of
shallow, for a 10,000-object population. Baseline object queues also had real unfinished work before
measurement: 152, 576 and 293 queued batches for the first three poses. The first queue drained during
measurement; the repeated overview was ready. This establishes slow cold classification and queue
progress, not an infinite queue. Camera-generation scheduling priority corrections are under evaluation and require new
installed-build evidence. The current native matrix remains diagnostic, not performance acceptance.

Thermal state was `fair`, safety state `normal`. End-of-step footprint ranged approximately
766–778 MiB; the first start sample was approximately 741 MiB. Charging and battery state remained
unavailable. No nominal-thermal or sustained-memory acceptance claim is made.

## Final-generation core-pose diagnostic

The [raw ten-row matrix](generation-matrix.json), [compact summary](generation-matrix-summary.json)
and [installed artifact identity](installed-generation-identity.json) record the Release build with
source SHA-256 `be6c34f030721734433ed54a76220d6fe6bee173a1cae57a0e55d3d98cc35436` and PCK SHA-256
`a17218f0abc7ffb265a119de4f0567555aaf921bd556c057e9c4e8837cf1824c`. Each row used 60 seconds of
warm-up and 30 seconds of measurement. The report completed in 992.26 seconds and restored the
original authored hash, revision and history.

All rows began and ended at **serious** thermal status with safety state **warning**. These are hot-device
diagnostics, not controlled performance acceptance. Static measurement readiness is recorded separately
from the capped initial settling wait; a `settled=false` row can become ready during the later warm-up.

| Variant | Pose | Readiness at measurement start | Frame p95 (ms) | GPU p95 (ms) | Classification remaining at end |
| --- | --- | --- | ---: | ---: | ---: |
| Old distance | Overview | READY | 17.0 | 12.6 | 0 |
| Old distance | Focus | READY | 23.3 | 21.5 | 0 |
| Old distance | Shallow | READY | 17.2 | 14.8 | 0 |
| Size only | Overview | NOT_READY | 17.1 | 12.0 | 0 |
| Size only | Focus | NOT_READY | 29.0 | 22.1 | 4,908 |
| Size only | Shallow | NOT_READY | 17.1 | 15.9 | 208 |
| Combined | Overview | READY | 17.0 | 10.5 | 208, held behind the overview mask |
| Combined | Focus | NOT_READY | 23.9 | 22.0 | 0 |
| Combined | Shallow | READY | 17.1 | 15.2 | 0 |
| Old distance, repeat | Overview | READY | 16.8 | 12.4 | 0 |

End classification retry and pinned-retry counts were zero throughout. The size-only focus frame p95
exceeded the 25 ms target, but it was unfinished and thermally serious; the combined focus remained
below 25 ms but was also unfinished at measurement start. Neither establishes steady acceptance.
The report records start readiness and end classification counters, not an explicit end readiness snapshot.

Combined overview retained full terrain material and submitted zero individual objects, scatter
instances and HLOD proxies. Size-only also submitted zero HLOD proxies. However, **all variants had
zero HLOD groups, builds and proxy submissions**, including the enabled baseline. This invalidates an
active-HLOD comparison and requires investigation of overview rebind initialization before calibration.
Thermal warning does not itself restrict overview work. Cache errors and rejections remained zero.
Last render-service samples were 0.257–0.911 ms with zero last-sample overruns; these are not duration
maxima and cannot prove the hard budget gate.

Only the initial overview baseline was repeated. Three repeats per core pose, controlled thermal starts
and sustained sessions remain pending. WorldPainter process 11434 was stopped after report recovery
at 23:41:13 local time to let the device cool without render load.

## Corrected overview-grid artifact

A same-extent catalog rebind retained the previous world rectangle while clearing overview groups.
The corrected build recreates the grid and prevents an HLOD-enabled benchmark with a missing grid
from reporting ready. The [installed identity](installed-rebind-identity.json) records source SHA-256
`2360a1596e038011b6db2087067502981a1491d68507dfbd1892d6dc2330e847` and PCK SHA-256
`ccb4c46a051c3289160eb05b8b205c9960cca7d207637dbb4c7cf8db8c2f3e91`.

The planned two-second, 120-second-warm-up native smoke did **not start**. The
[launch result](rebind-smoke-launch-locked.json) records device-lock rejection. Corrected-grid native
readiness, active HLOD submissions and controlled timing remain unmeasured until a successful launch.
The older matrix above must not be attributed to this corrected artifact.

## Remaining acceptance gates

Three-repeat core-pose comparisons on the corrected build, continuous transitions, physical
editing/preview checks, 30/60-minute Release sessions and exact-valley entry-point parity remain
open until corresponding evidence is recorded. No appearance cache was adopted; its profiling
prerequisite remains unmet.
