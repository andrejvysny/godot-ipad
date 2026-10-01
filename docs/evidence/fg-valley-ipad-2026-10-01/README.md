# fantasy-game valley on iPad Air 4 — DEVICE benchmark (2026-10-01)

Evidence class: **DEVICE** — physical iPad Air 4 (iPad13,1), iOS 26.5, Godot 4.7.2 Release export,
Vulkan (MoltenVK), native 2360×1640 unless scaled. Analysis: Plane GODOTIPAD page
"Benchmark — fantasy-game valley on iPad Air 4 (2026-10-01)". Harness: `tools/fg_bench/`.

Content: fantasy-game `ce478c4`, `scenes/valley.tscn` reduced to terrain, water/falls, forest, props,
grass, ground cover, mist, particles and lighting/atmosphere — **no character, no game logic**
(player, camera rig, tree occluder and main.gd removed and excluded from the pack).

Camera phases (15 s each after a 10 s warm-up, FOV 50°): `ground_walk` (1.8 m eye height walking
from the spawn), `low_orbit_30m`, `editor_view_140m` (100 m out / 100 m up), `overview_whole_valley`
(450 m out / 550 m up). Values are p50 per phase; full percentiles in the JSON files.
With far 250 m the overview camera sits beyond the far plane: those overview numbers are invalid.

| Config | File | ground_walk | low_orbit_30m | editor_view_140m | overview_whole_valley |
|---|---|---|---|---|---|
| forward_plus, scale 1.0, far 1500 | `valley-forward_plus-s1.00-far1500-1790883004.json` | 5.9 fps · GPU 183 (p95 197) ms · CPU 4.5 ms · 848 draws · 2.68 M prims | 7.4 fps · GPU 136 (p95 147) ms · CPU 2.8 ms · 476 draws · 1.59 M prims | 8.1 fps · GPU 121 (p95 130) ms · CPU 2.6 ms · 356 draws · 1.37 M prims | 2.2 fps · GPU 465 (p95 488) ms · CPU 8.9 ms · 2282 draws · 6.92 M prims |
| mobile, scale 0.5, far 1500 | `valley-mobile-s0.50-far1500-1790882610.json` | 12.5 fps · GPU 93 (p95 100) ms · CPU 1.9 ms · 857 draws · 2.66 M prims | 16.0 fps · GPU 63 (p95 69) ms · CPU 1.2 ms · 495 draws · 1.57 M prims | 18.2 fps · GPU 54 (p95 59) ms · CPU 1.1 ms · 396 draws · 1.37 M prims | 3.9 fps · GPU 260 (p95 264) ms · CPU 4.7 ms · 2282 draws · 6.92 M prims |
| mobile, scale 0.5, far 250 | `valley-mobile-s0.50-far250-1790882469.json` | 19.6 fps · GPU 51 (p95 55) ms · CPU 0.9 ms · 344 draws · 1.07 M prims | 16.8 fps · GPU 60 (p95 65) ms · CPU 0.9 ms · 368 draws · 1.18 M prims | 18.1 fps · GPU 54 (p95 58) ms · CPU 0.9 ms · 307 draws · 1.10 M prims | 59.7 fps · GPU 9 (p95 9) ms · CPU 0.5 ms · 9 draws · 0.00 M prims |
| mobile, scale 1.0, far 1500 | `valley-mobile-s1.00-far1500-1790881927.json` | 9.8 fps · GPU 117 (p95 128) ms · CPU 3.6 ms · 857 draws · 2.66 M prims | 11.4 fps · GPU 87 (p95 96) ms · CPU 2.2 ms · 497 draws · 1.58 M prims | 12.3 fps · GPU 80 (p95 86) ms · CPU 2.1 ms · 396 draws · 1.37 M prims | 3.0 fps · GPU 342 (p95 347) ms · CPU 6.7 ms · 2282 draws · 6.92 M prims |
| mobile, scale 1.0, far 1500, sun shadows off | `valley-mobile-s1.00-far1500-noshadow-1790882773.json` | 10.4 fps · GPU 111 (p95 120) ms · CPU 3.1 ms · 828 draws · 2.42 M prims | 12.6 fps · GPU 80 (p95 87) ms · CPU 1.8 ms · 445 draws · 1.26 M prims | 13.4 fps · GPU 73 (p95 79) ms · CPU 1.8 ms · 385 draws · 1.24 M prims | 3.2 fps · GPU 321 (p95 325) ms · CPU 7.0 ms · 2282 draws · 6.92 M prims |
| mobile, scale 1.0, far 250 | `valley-mobile-s1.00-far250-1790882358.json` | 17.3 fps · GPU 59 (p95 65) ms · CPU 1.0 ms · 344 draws · 1.07 M prims | 13.8 fps · GPU 74 (p95 81) ms · CPU 1.0 ms · 368 draws · 1.19 M prims | 12.2 fps · GPU 82 (p95 86) ms · CPU 0.9 ms · 307 draws · 1.10 M prims | 59.5 fps · GPU 8 (p95 12) ms · CPU 0.4 ms · 9 draws · 0.00 M prims |

Findings: GPU-bound everywhere (CPU 1–9 ms); quarter pixel count cuts GPU only 25–35 %, sun
shadows off 5–9 %; draw distance 1500→250 m halves the eye-height cost; Forward+ is 1.4–1.6×
slower than Mobile; one ~8 s first frame (pipeline compile). Not run: thermal/sustained runs and
per-feature ablations. The first report (`…-1790881927`) came from an earlier harness revision
without `user_args`/`sun_shadows` fields; its configuration is Mobile, scale 1.0, far 1500 m.
