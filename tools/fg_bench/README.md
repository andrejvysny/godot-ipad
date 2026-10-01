# fantasy-game valley iPad bench

Terrain-only bench of the fantasy-game valley (no character, no game logic) as a separate iPad app
`sk.andrejvysny.fgbench`. The fantasy-game repository is never modified: `make_fg_bench.py` copies it
into the gitignored `build/fg_ipad` and adds `bench_root.gd` and `valley_bench.tscn`.

- `valley_bench.tscn`: `scenes/valley.tscn` (fantasy-game `ce478c4`) without Player, CameraRig,
  TreeOccluder and main.gd, plus a `BenchCamera`. Regenerate it if the source scene changes.
- `bench_root.gd`: scripted camera phases, JSON report, on-screen overlay, touch orbit viewer.

Build and install (commands in the `make_fg_bench.py` docstring), then:

```sh
xcrun devicectl device install app --device DEVICE_ID build/fg_ios/dd/Build/Products/Release-iphoneos/FGBench.app
xcrun devicectl device process launch --terminate-existing --device DEVICE_ID sk.andrejvysny.fgbench -- --bench
xcrun devicectl device copy from --device DEVICE_ID --domain-type appDataContainer \
  --domain-identifier sk.andrejvysny.fgbench --source Documents/bench --destination OUT_DIR
```

User args: `--bench`, `--bench-phase-s=15`, `--bench-scale=0.5`, `--bench-far=250`,
`--bench-shadows=off`, `--bench-quit` (ignored on iOS, which does not quit apps). Engine args such
as `--rendering-method` arrive as user args on iOS: pick the renderer with
`make_fg_bench.py --renderer mobile|forward_plus`. Without `--bench` the app is a touch viewer
(1 finger orbit, 2 fingers pan, pinch zoom). Results: `docs/evidence/fg-valley-ipad-2026-10-01/`.
