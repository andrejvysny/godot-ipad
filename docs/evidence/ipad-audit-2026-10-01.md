# Physical iPad failure audit — 2026-10-01

## Outcome

The Input Lab runs on the tested iPad with **Mobile/Vulkan**. The user confirmed visible terrain,
finger orbit, Pencil painting, and Pencil operation of both **Toggle 100% / 50% 3D scale** and
**Checkpoint probe**. **G1 remains INCOMPLETE**: this was a failure diagnosis and basic interaction
retest, not the complete physical acceptance procedure.

Device: iPad Air 4 (`iPad13,1`), iPadOS 26.5, Apple A14 GPU; Apple Pencil 2 model supplied by the
user. Toolchain: Godot 4.7.2 official `ed1daf0bf001b61586d9930840f2f1394092c079`, Terrain3D 1.0.2
`0077405b52e353c5e5dc3a094e7ede49833ba6fe`, official iOS template, Debug device build.

## Failure and owning layer

The original screenshot showed magenta 3D output behind the Input Lab controls. Buttons appeared
frozen. The physical [Metal log](ipad-audit/metal-failure.log) repeatedly records:

```text
ERROR: timeout waiting for fence
   at: wait (drivers/metal/rendering_device_driver_metal3.cpp:54)
```

The pinned engine source waits up to 1000 ms at this fence. One recorded stack passes through
`InputSystem._push`; native events reached the application even while rendering stalled.
`Ready: ios_native_uikit` established completed scene initialization, not healthy frame delivery.
The evidence locates the observed stall in the Metal rendering path. It does not isolate the GPU
command, prove a particular Terrain3D shader defect, or establish an input-queue deadlock.

The same installed app was then launched with both:

```text
--rendering-method mobile --rendering-driver vulkan
```

The [first Vulkan log](ipad-audit/vulkan-initial.log) reports Vulkan 1.2.334, Forward Mobile,
Apple A14 GPU, and native-provider readiness, without fence timeouts. The user confirmed terrain,
orbit, and Pencil paint. Specifying both flags matters: a driver-only exploratory launch selected
Forward+ and is not the evidence supporting this decision.

The project now defaults to Vulkan on iOS. The official template already includes MoltenVK;
no custom engine/template or vendored Terrain3D modification was needed. macOS remains Metal.
The [rebuilt Vulkan log](ipad-audit/vulkan-rebuilt.log) confirms the configured driver on device.
The driver decision and primary-source context are recorded in [ADR 0006](../decisions/0006-ipad-vulkan.md).

## UI findings

Earlier Simulator testing found two independent defects, already repaired before this physical
driver comparison:

1. The native observer attached to SwiftUI's root host at scale 1. It now locates the pinned
   Godot drawable descendant, observed as `GDTViewIOS` at scale 2.
2. Input Lab omitted its panel from `UiHitTester`. Registering the panel routes Pencil contact
   ownership to UI rather than beginning a terrain operation.

After the first Vulkan run, the user still reported inactive buttons. Diagnostics were added
to distinguish native samples, routed UI actions, GUI mouse-button events, and button signals.
A newly installed Vulkan-default diagnostic build responded to the two requested Pencil buttons.
No new input injection algorithm was introduced between those observations; a separate final
button root cause was not established. Finger taps on buttons are intentionally ignored by the
input contract. The persistent panel text now states these roles.

The [runtime report](ipad-audit/runtime-ui.json) independently records a successful **Nine-point
calibration** button event, 1,877 samples, 258 synthetic events, zero native queue overflows,
an attached `GDTViewIOS` observer, IDLE contact state, and saved revision 38. Activation of the
calibration button does not prove completion or accuracy of the nine-point procedure.

## Implementation and optimization

`LabRuntimeDiagnostics` records a bounded 600-frame window using monotonic wall time. This exposes
GPU waits that capped Godot process deltas can hide. Input Lab displays a tick counter and uses
the same wall interval for its existing 250 ms active-stroke cancellation threshold.

Diagnostic labels refresh at 4 Hz instead of every frame. Input handling and the late terrain
flush remain per frame. This removes redundant string/UI work without changing input ownership,
document authoring, or terrain batching. No before/after performance gain is claimed.

Debug builds retain rotating engine logs. `--lab-diagnostics` explicitly enables a runtime report
every 2 seconds and one rendered PNG after 5 seconds. Normal launches do not perform these writes
or screenshot readback. The final refinement collects report state only when the write is due,
avoiding repeated provider queries and fingerprint-file reads between reports.

Regression coverage checks real wall-time stalls, refresh behavior after stalls, bounded history,
disabled/throttled report collection, and Pencil press/release activating the real scale button.

## Codebase assessment

The existing ownership boundaries should be retained: `WorldDocument` owns authored state;
transactions/history own reversible edits; `TerrainAdapter` projects canonical buffers; the
native provider supplies typed samples; the router arbitrates UI, tools, and camera. Storage
uses immutable snapshots and a worker. No evidence justified replacing these layers to fix the
observed GPU stall.

The audit covered startup/composition, rendering configuration, native attachment and queue
drain, coordinate mapping, UI dispatch, terrain upload batching, storage, and test coverage.
The material verification gap was physical rendering: headless host tests cannot exercise Metal,
and the Simulator uses a separate GLES preview. Healthy startup alone was an inadequate check.

Input Lab remains a feasibility scene. Full editor composition, placement, tool UI, consumer,
export flow, and sustained acceptance remain unfinished, tracked in `TODO.md`.

## Measurements and limitations

At 100% render scale, the captured Debug runtime report contains this recent 600-frame window:

| Measurement | Observed |
|---|---:|
| p50 wall frame interval | 21.166 ms |
| p95 wall frame interval | 21.909 ms |
| Maximum | 24.073 ms |
| Frames above 16.7 ms | 600 / 600 |
| Frames above 33.4 ms | 0 / 600 |
| Last terrain flush CPU duration | 0.071 ms |

This does not establish 60 fps, a sustained-session result, or GPU execution time. The
[captured frame](ipad-audit/vulkan-frame.png) shows painted terrain at 50% scale and a 16.5 ms
instantaneous interval. It was captured at a different time, so it is not a controlled scale
comparison. GPU fill cost is a hypothesis to test, not a demonstrated bottleneck.

The working log still contains `ERROR: Mouse is not supported by this display server.` at startup
and Terrain3D's `instance_reset_physics_interpolation() is deprecated.` warning. Inspection traced
the former to the pinned engine's root-window mouse-position query and the latter to a compatibility
API. The app worked despite these messages; the log is not claimed to be error-free. No fence
timeout or script error appears in the preserved working-device log.

## Validation and build identity

- `venv/bin/python scripts/dev.py test --sandbox ipad-handoff`: **325 Godot tests, 0 failures;
  102 Python tests, OK**. Full local log: `build/ipad-handoff-tests.log`.
- `bash native/ios_input/build.sh test`: **10 tests, 0 failures**, ASan/UBSan, 200 fuzz rounds.
  Local log: `build/ipad-handoff-native-tests.log`.
- Doctor: **28 OK, 1 WARN, 1 PENDING, 0 NOT_RUN, 0 FAIL**. Warning: `scons` absent from PATH
  (the build uses `uvx`). Pending: Mac consumer scene absent. These counts do not close G1.
- macOS Mobile/Metal Input Lab smoke completed without GPU errors. This is a host check only.
- Signed Debug iPad build installed and user-tested; final source exported successfully to an
  Xcode project. The last lazy-report refinement was not rebuilt/reinstalled before handoff.
- Whitespace checks pass for project-owned implementation and documentation. The initial commit
  preserves upstream Terrain3D whitespace and intentional Markdown hard breaks in the supplied
  specification; those are excluded from the scoped whitespace check.

The hardware-tested source fingerprint is
`4cf84ef645d08cf622771045ff7146ae06a9e7af6f217431e43889fe9eb8e511`; native artifacts are
`edaea5e1efa0b8b8fea872271e6f4b920e6f161fe84af4b2cee5ffc816d993b4`.
The final source adds lazy diagnostic snapshot scheduling and refreshed metadata. Tests cover
that refinement; its exact final source has no new physical result. Rebuild/install and record
the generated fingerprint before the next physical acceptance run.

Evidence integrity is recorded in [summary.json](ipad-audit/summary.json). Device data and
screenshots were copied with explicit user approval. Full app data remains ignored under
`build/ipad-failure-before/`; older raw traces remain under `build/ipad-audit-traces/`.
One earlier Vulkan trace dropped 7,531 entries, so it cannot prove complete contact lifecycles.
The earlier deployment-only report and Simulator report remain historical evidence, not the
current physical result.

## Next checks

1. Run the formal [device checklist](../device-test-checklist.md): source identity and palm,
   interruption/cancellation, both-scale calibration, complete contact lifecycle, and exact
   checkpoint/force-quit/reopen payload hashes.
2. Profile a signed Release build at 100% and 50% using identical scene/camera/strokes. Record
   frame percentiles, thermal behavior, memory, GPU timing, and upload frequency across a sustained
   session before changing terrain resolution, shadows, or native queue behavior.
3. Keep broad editor work gated on G1; do not relabel this short smoke test as full acceptance.

Unresolved questions: which GPU command fails under native Metal, and which resource limits
sustained performance? Neither blocks this working Vulkan baseline or the requested handoff.
