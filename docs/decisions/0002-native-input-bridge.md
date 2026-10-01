# 0002 — Native Pencil input through a GDExtension gesture observer

Status: accepted for implementation; device validation NOT RUN.

## Context

Inspected Godot 4.7.2 source (`drivers/apple_embedded/godot_view_apple_embedded.mm`,
`display_server_apple_embedded.mm`, commit `ed1daf0b`):

- `touchesBegan` → `touch_press(tid, x*scale, y*scale, pressed, double_tap)`: coordinates are
  truncated to `int`, and no touch type, force or timestamp is forwarded.
- `touchesMoved` → `touch_drag(...)` forwards force/tilt but still no touch type.
- `touchesCancelled` → `touches_canceled(tid)` → `touch_press(tid, -1, -1, false, false)`:
  cancellation is indistinguishable from a release except by a sentinel position.

The spec requires Pencil/finger identity on BEGIN, explicit CANCEL, monotonic native timestamps and
no pressure-based guessing (spec §6.1, §6.4). None of that is available from Godot's events.

## Decision

A small GDExtension (`native/ios_input`, Objective-C++, godot-cpp 10.0.0 targeting API 4.7) adds a
passive `UIGestureRecognizer` subclass to the Godot `GDTView` inside the root controller:

- `cancelsTouchesInView = NO`, `delaysTouchesBegan/Ended = NO`, simultaneous recognition allowed,
  and the recognizer never leaves the *Possible* state, so it observes every touch without
  changing what Godot's view receives.
- Identity is `UITouch.type` read in `touchesBegan` (Pencil / Direct / other = UNKNOWN).
- Coalesced touches are emitted once each (the coalesced list already contains the primary touch).
- `touchesCancelled`, app/scene deactivation, view-metric changes, explicit cancel and queue
  overflow all produce explicit CANCEL records with a reason code.
- Records go into a bounded queue drained once per frame by `IOSNativeInputProvider`.

The app then treats this provider as the only authoritative input path on iOS: `InputSystem`
swallows every Godot `InputEventScreenTouch/Drag` and non-synthetic mouse event. Standard Godot
`Control`s are operated only by synthetic mouse events generated from Pencil-owned UI contacts
(device id 4242), which never re-enter world editing (spec §6.2).

## Alternatives rejected

- **Legacy `.gdip` iOS plugin** — needs engine headers matching the template; same UIKit technique,
  more build friction.
- **Custom engine/export template change** — would need approval (spec §2.4); unnecessary because
  public UIKit API is enough.
- **Pressure/size/count heuristics** — forbidden by the spec and unreliable.
- **Method swizzling / private API** — forbidden (spec §2.4).

## Risks (to be closed by device gate G1)

- UIKit could still route some touches differently in a future iPadOS; the diagnostics screen shows
  bridge counters and per-contact identity to detect it.
- `UITouch.timestamp` and `CACurrentMediaTime()` are expected to share a timebase; the bridge
  exposes `native_now()` so latency is computed on one clock only. Verify on device.
- If the observer cannot be attached, the app falls back to Godot touches with `UNKNOWN` identity,
  and editing is disabled. That outcome is a G1 failure, not a pass.
