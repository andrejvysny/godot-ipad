# WPNativeInput — iOS Pencil/finger input bridge

GDExtension (Obj-C++, godot-cpp `10.0.0-stable` @ `507ed9d8`, `api_version` 4.7) that gives the
World Painter PoC typed Apple Pencil / finger contacts on iPad. GDScript side:
`app/src/input/ios_native_input_provider.gd` (`IOSNativeInputProvider`). Spec: §2.3, §2.4, §6,
§7.3, WP01, IN-01/04/09/10/11.

**Status: builds and loads on macOS (inert). iOS behaviour is untested on hardware — every
device result below is NOT RUN until gate G1.**

## Why the bridge exists

Godot 4.7.2 (`4.7.2-stable`, `ed1daf0b`) delivers iOS touches through `GDTView`:

- `drivers/apple_embedded/godot_view_apple_embedded.mm:356-393` — `touchesBegan/Moved/Ended/
  Cancelled` call `DisplayServerAppleEmbedded::touch_press/touch_drag/touches_canceled` with only
  a slot index, a position, and (drag only) `force / maximumPossibleForce` and tilt. `touch.type`
  is never read, so a Pencil contact cannot be told from a finger — at BEGIN or ever.
- `drivers/apple_embedded/display_server_apple_embedded.mm:272-293` — `touch_press(int p_idx, int
  p_x, int p_y, …)` / `touch_drag(…, int p_x, int p_y, …)` take `int` coordinates: the float
  point × `contentScaleFactor` value is truncated to whole pixels. No `UITouch.timestamp` is
  forwarded; events get no native time at all.
- `display_server_apple_embedded.mm:304-306` — `touches_canceled(idx)` is
  `touch_press(idx, -1, -1, false, false)`: a native cancel arrives as an ordinary release at
  (-1, -1), indistinguishable from a completed stroke (spec §6.4 forbids exactly this).
- Coalesced touches (`coalescedTouchesForTouch:`) are never read, so 240 Hz Pencil samples are lost.

## Architecture

```
UIKit touch delivery ──► GDTView (Godot's own InputEventScreenTouch/Drag, unchanged)
        │
        └─► WPTouchObserver (UIGestureRecognizer on the key window's GDTView, passive)
               │ touch_began/moved/ended/cancelled, reset, lifecycle notifications
               ▼
            TouchRecordQueue (pure C++, std::mutex, bounded)      src/touch_record_queue.*
               │ drain() → flat float64 records
               ▼
            IOSPlatformBridge / HostPlatformBridge                src/platform_bridge_*.{mm,cpp}
               ▼
            WPNativeInput (godot::Object, engine singleton)      src/wp_native_input.*
               ▼
            IOSNativeInputProvider.drain_samples() → Array[PointerSample]
```

- **Observer.** `WPTouchObserver : UIGestureRecognizer <UIGestureRecognizerDelegate>` with
  `cancelsTouchesInView = NO`, `delaysTouchesBegan = NO`, `delaysTouchesEnded = NO`,
  `requiresExclusiveTouchType = NO`; its delegate allows simultaneous recognition and every touch.
  It never leaves `UIGestureRecognizerStatePossible`, so it keeps receiving every touch and never
  cancels, delays, or blocks delivery to Godot's view. `delaysTouchesEnded = NO` matters: with the
  default `YES` a never-failing recognizer would hold Godot's `touchesEnded` back indefinitely.
- **Attach target.** The `GDTView` descendant of `rootViewController.view` in the key window of the foreground
  `UIWindowScene` (found by iterating `UIApplication.sharedApplication.connectedScenes`). A
  foreground-*inactive* scene is accepted when no active one exists, because Godot's first frames
  (where `_ready` runs) can precede the launch scene's activation. The view is held weakly.
  Godot 4.7.2 wraps `GDTView` in a SwiftUI hosting controller. Simulator inspection found the
  wrapper's content scale was 1 while the Godot drawable's scale was 2; matching bounds do not
  establish matching scale. The bridge recursively finds the pinned engine's public Objective-C
  class with `NSClassFromString("GDTView")`, and refuses attachment if absent. Diagnostics record
  the observed class; physical IN-12 calibration must still confirm mapping within 2 points.
- **Identity.** Decided once at `touchesBegan` from `UITouch.type` only: `UITouchTypePencil` →
  PENCIL, `UITouchTypeDirect` → FINGER, anything else (indirect, indirectPointer) → UNKNOWN. Never
  from pressure, size, index, or contact count. Later records reuse the stored identity.
- **Samples.** `touchesMoved` emits every element of `[event coalescedTouchesForTouch:touch]`
  exactly once — the array already ends with the primary touch's own sample, so the primary touch
  is not emitted separately; all but the last element carry the coalesced flag. If the array is
  nil/empty the primary touch is emitted. `touchesBegan/Ended/Cancelled` use the primary touch.
- **Single instance.** The class is registered abstract; only the singleton created at
  `MODULE_INITIALIZATION_LEVEL_SCENE` exists, so there is never a second observer (IN-04).
- **Godot's own touch events still flow.** The observer does not suppress `GDTView`'s
  `InputEventScreenTouch/Drag`; while `IOSNativeInputProvider` is authoritative the input system
  must ignore them (spec §6.2, IN-04). `pointing/emulate_mouse_from_touch=false` is set in
  `project.godot`.

## Record layout

`drain()` returns a `PackedFloat64Array` of records, `get_record_stride()` = 14 values each, in
arrival order (timestamp order per contact):

| # | field | meaning |
|---|---|---|
| 0 | source | 0 UNKNOWN, 1 PENCIL, 2 FINGER |
| 1 | pointer_id | session counter assigned at BEGIN (starts at 1), stable for the contact's lifetime |
| 2 | phase | 0 BEGIN, 1 MOVE, 2 END, 3 CANCEL |
| 3 | timestamp | `UITouch.timestamp` seconds (synthesized CANCELs: `CACurrentMediaTime()`) |
| 4, 5 | x, y | `locationInView:` of the observed view, UIKit **points**, full double precision |
| 6 | pressure_valid | 1 only when `type == UITouchTypePencil` and `maximumPossibleForce > 0` |
| 7 | pressure | `force / maximumPossibleForce` clamped to [0, 1]; 0 when invalid |
| 8 | tilt_valid | 1 for Pencil samples only |
| 9, 10 | tilt_x, tilt_y | `azimuthUnitVectorInView:` × `cos(altitudeAngle)` (Godot `touch_drag` convention) |
| 11 | flags | bit0 coalesced intermediate, bit1 predicted (never set), bit2 force estimated |
| 12 | sequence | monotonic per session (starts at 1; gaps possible after overflow) |
| 13 | cancel_reason | 0 none, 1 native `touchesCancelled`, 2 app resign active / scene deactivate, 3 queue overflow, 4 explicit `cancel_all`, 5 view metrics changed / observer reset or detached with live contacts |

GDScript maps reasons to `native_cancel`, `app_deactivated`, `queue_overflow`, `explicit`,
`view_changed` (an unknown code decodes as `unknown`, an undecodable phase as a CANCEL with
`invalid_phase`). `view_changed`, `unknown` and `invalid_phase` are not in
`InputRouter.CANCEL_REASONS`; they reach tools as sample reasons, which the input contract passes
through (docs/input-contract.md §5). Code 5 is deliberately not called `mapping_changed`: it also
covers an observer reset, `stop()`, a lost view and a stale touch key. The input system's own
`mapping_changed` cancel usually comes first on a real metrics change, because it compares
`get_view_metrics()` before draining. Consumers must read the stride from `get_record_stride()`; a
decoder accepts a wider stride and ignores trailing fields.

## Cancellation and queue rules

Invariant: every contact whose BEGIN reached the consumer receives exactly one terminal record
(END or CANCEL). A contact cancelled by the bridge becomes *ignored*: it produces no further
records, and its later UIKit end/cancel only removes it from tracking.

- Native `touchesCancelled` → CANCEL(1). Never converted to END.
- `UIApplicationWillResignActiveNotification`, and `UISceneWillDeactivateNotification` for the
  observed view's scene → CANCEL(2) for all live contacts, which are then ignored until they end.
- `cancel_all(reason)` → CANCEL(reason) for all live contacts (codes outside 1…5 become 4).
  `IOSNativeInputProvider.cancel_all()` always sends 4.
- Each `drain()` and `get_view_metrics()` compares the observed view's `bounds.size` and
  `contentScaleFactor` with the last values; a change increments `metrics_generation` and cancels
  live contacts with reason 5. Each successful `start()` also increments the generation.
- `-reset` with contacts still tracked (UIKit stops delivering them after a reset), `stop()`, and
  loss of the observed view all cancel live contacts with reason 5. View loss also makes
  `is_active()` false (the provider then emits `provider_failed("bridge inactive")`).
- A `touchesBegan` for a touch object that is still tracked closes the stale contact with
  CANCEL(5) before the new contact starts.
- Queue: 4096 records for BEGIN/MOVE/END plus 64 records of headroom usable only by CANCEL. On
  overflow the undelivered queue is discarded and `overflow_count` increments, but no terminal
  record is lost: queued CANCELs are kept verbatim, queued ENDs and live contacts become
  CANCEL(3), every tracked contact is ignored, and contacts whose BEGIN was itself still queued
  (never seen by the consumer) vanish whole. A touch whose `touchesBegan` triggers the overflow is
  ignored as well, with no records at all, until it lifts. Every touch down at the moment of
  overflow must be lifted before it counts again.
- The provider emits `provider_failed("queue overflow")` when `overflow_count` grows, before it
  returns that drain's samples. `InputSystem` reacts with `cancel_all("queue_overflow")`, and the
  provider forwards that as `cancel_all(4)`. The bridge then has no live contact the consumer knows
  about, because the overflow already cancelled or ignored them all. The one exception is a touch
  that *began after* the overflow and before this drain. Its BEGIN is in the batch being returned,
  so that stroke starts and is then cancelled with reason `explicit` on the next drain. The pairing
  stays correct (one terminal per BEGIN); only the reason is `explicit` rather than
  `queue_overflow`.
- A drained buffer that is not a whole number of records is fatal to
  `IOSNativeInputProvider`. The dropped values may have held an END that the bridge will never
  repeat, so the provider stops the bridge and closes every contact it delivered with its own
  CANCEL (`provider_failed`, at the contact's last position). It then emits
  `provider_failed("malformed native records: …")` and stays unavailable.
- The queue is guarded by a `std::mutex`. UIKit callbacks and Godot's main loop both run on the
  iOS main thread; the lock only makes that assumption non-fatal.

## Clocks

- `UITouch.timestamp` and `CACurrentMediaTime()` share one timebase: seconds of
  `mach_absolute_time` since boot, excluding sleep. `native_now()` returns `CACurrentMediaTime()`,
  so `native_now() - record.timestamp` is a valid event age.
- Godot's `Time.get_ticks_usec()` counts from engine start on a different origin. It is a separate
  clock: never subtract a native timestamp from Godot ticks (spec §18.3). Latency figures must
  subtract same-clock values only, or report the two timestamps side by side.

## Coordinates

Positions are UIKit points in the observed view's space, as doubles (sub-point precision kept;
`PointerSample.position_raw` stores them as `Vector2`). Godot itself multiplies by
`contentScaleFactor` to get its pixel positions (`godot_view_apple_embedded.mm:361`, scale set at
`:127` to `UIScreen.mainScreen.scale`). The bridge never scales; `CoordinateMapper` converts points
to viewport coordinates exactly once using `get_view_metrics()` (`view_size_points`,
`content_scale`, `safe_area` in points, `metrics_generation`).

## Public API only

Only documented UIKit/QuartzCore API is used: `UIGestureRecognizer` subclassing via
`UIGestureRecognizerSubclass.h`, `UIGestureRecognizerDelegate`, `UIEvent.coalescedTouchesForTouch:`,
`UITouch` properties, `UIApplication.connectedScenes`, `UIWindowScene.keyWindow`,
`NSNotificationCenter`, `CACurrentMediaTime`. No method swizzling, no private selectors, no
Objective-C runtime reflection, no Godot internals (spec §2.4). The only coupling to Godot's view
hierarchy is the documented UIKit rule that recognizers on an ancestor view see touches delivered to
its descendants.

## Build

Requirements: macOS with Xcode (tested with Xcode 26.6, iOS SDK 26.5), `git`, `uv`/`uvx` (SCons is
run as `uvx --from scons==4.9.1 scons`), network access for the first godot-cpp clone.

```bash
native/ios_input/build.sh          # all: host queue test, then macOS + iOS
native/ios_input/build.sh test     # host C++ test of the contact/overflow queue only (ASan + UBSan)
native/ios_input/build.sh macos    # inert host framework only (editor/tests)
native/ios_input/build.sh ios      # device + simulator xcframeworks only
GODOT_CPP_URL=/path/to/godot-cpp native/ios_input/build.sh   # alternate clone source
```

`build.sh` clones godot-cpp `10.0.0-stable` into `native/ios_input/godot-cpp/` (ignored) and fails
unless `git rev-parse HEAD` is `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`; an existing checkout is
reused only if it is at that commit with no local modifications. `build_profile.json` limits the
godot-cpp bindings to `Engine`, `OS` and `SceneTree` plus the classes godot-cpp always needs. The
full engine API made the simulator archives up to 93 MB each, close to GitHub's 100 MB per-file
limit. With the profile, each godot-cpp archive is 1.7 to 3.8 MB. `build.sh` records the
profile's hash in `build/` and deletes `godot-cpp/gen` and `godot-cpp/bin` whenever the profile
changes, because stale headers there would hide a class missing from the profile. If new code
includes another engine class, add it to the profile. Outputs in
`app/addons/wp_native_input/bin/`:

| artifact | contents |
|---|---|
| `libwp_native_input.macos.template_{debug,release}.framework` | universal (arm64 + x86_64) dylib, macOS ≥ 11.0, inert |
| `libwp_native_input.ios.template_{debug,release}.xcframework` | static libs: `ios-arm64` (device) + `ios-arm64_x86_64-simulator`, iOS ≥ 17.0 |
| `libgodot-cpp.ios.template_{debug,release}.xcframework` | matching godot-cpp static libs (a `[dependencies]` entry) |

Object files, static libraries and `.sconsign.dblite` stay under `native/ios_input/`. The iOS
export links the static xcframework and registers `wp_native_input_init` by name. The library needs
`UIKit`, `Foundation` and `QuartzCore`, which Godot's iOS app already links.

## Tests

- `native/ios_input/tests/test_touch_record_queue.cpp`, run by `build.sh test` and first in
  `build.sh all`. It is a host C++ test of `TouchRecordQueue`, the overflow, cancel, stale-key and
  forget policy behind "never silently drop END/CANCEL". It checks against a consumer model plus
  a seeded fuzz that must hit overflows.
- `app/tests/unit/test_native_record_decode.gd` — decoding of hand-built records (sources, phases,
  pressure, tilt, flags, cancel reasons, malformed layouts) and the provider's health signals
  through a fake bridge.
- `app/tests/integration/test_native_bridge_host.gd` — on macOS: the extension loads, the class is
  abstract, the singleton exists and every call is inert; plus the provider end to end through
  `InputSystem` with a fake bridge (a malformed buffer leaves the router idle).
- Run: `python3 scripts/godot_test.py --sandbox <name> --filter native`. None of these exercise
  UIKit; the device steps below are the only evidence for iOS behaviour.

## Platform telemetry (WPPlatformTelemetry)

Optional, spec `docs/rendering-performance-spec.md` §18.2. A separate `godot::RefCounted` class registered in the same
extension (`src/wp_platform_telemetry.*`, `src/platform_telemetry*.{h,mm}`). It has no singleton and shares no state,
thread or `NSNotificationCenter` observer with `WPNativeInput`, `TouchRecordQueue` or the Pencil/touch path; the input
queue ordering and contracts are untouched. Create it with `WPPlatformTelemetry.new()`; GDScript wrapper:
`app/src/rendering/render_platform_telemetry.gd` (`RenderPlatformTelemetry`).

| method | result |
|---|---|
| `is_available() -> bool` | true when the Apple implementation is linked (iOS and macOS host) |
| `thermal_state() -> int` | `NSProcessInfo.thermalState`: 0 nominal, 1 fair, 2 serious, 3 critical; -1 unavailable/unknown |
| `footprint_bytes() -> int` | `task_info(TASK_VM_INFO).phys_footprint`; -1 on failure (never 0 for unavailable) |
| `consume_memory_warnings() -> int` | iOS: `UIApplicationDidReceiveMemoryWarningNotification` count since the previous call; macOS: 0 |
| `source() -> String` | `ios_native` or `macos_native` |

- The memory-warning observer is registered on the first `consume_memory_warnings()` call (earlier warnings are not
  counted) and removed in the destructor. The token is an ARC-owned `id`; the notification block holds only a
  `shared_ptr<std::atomic<int64_t>>`, so a block in flight never touches freed memory. Counting is thread-safe.
- Public API only (Foundation, mach `task_info`, UIKit notification name). Calls are cheap and allocation-free apart from
  the return value; sample at low frequency from the main thread.
- Builds without the class (no extension, or any non-Apple platform) are handled by `RenderPlatformTelemetry`, which
  reports `thermal = "unavailable"`, `thermal_level = -1`, `footprint_mib = null`, `source = "unavailable"` and supports
  injected test events (`inject_thermal`, `inject_memory_warning`, `clear_injection`; source `"injected"`).
- Tests: `app/tests/unit/test_render_platform_telemetry.gd`. Device behaviour (real thermal transitions, memory
  warnings) is NOT RUN until measured on an iPad.

## Limitations

- Untested on hardware until gate G1. Nothing here proves Pencil identity, pressure, coalescing or
  cancellation on a real iPad.
- The iOS Simulator only produces `UITouchTypeDirect` touches (mouse clicks); Pencil identity,
  pressure and tilt cannot be exercised there. Simulator input is not equivalent to Pencil input.
- Terrain3D 1.0.2 ships no simulator slice (`libterrain.ios.*.dylib` is device arm64 only), so a
  simulator build can only run scenes that do not instantiate Terrain3D.
- Predicted touches are not collected (flag bit1 is reserved and never set).
- `touchesEstimatedPropertiesUpdated:` is not handled; bit2 only marks force as estimated.
- If UIKit ever resets the recognizer before delivering `touchesEnded`, a normal stroke would end
  with CANCEL(5) instead of END — safe (rollback), but must be checked in IN-01/IN-09 below.

## Device test steps (G1)

Prerequisites: signed iOS debug export on the iPad, input lab scene showing the provider name
(`ios_native_uikit`), per-contact source/phase/pointer_id/cancel_reason, pressure, and
`WPNativeInput.get_diagnostics()`; bounded trace capture enabled. Record results in the §20.6
format with the iPad model, iPadOS version and Pencil model. Before starting, confirm
`observer_attached = true` and `attach_status = attached`, and note `observed_view_class`.
`start()` may run while the launch scene is still foreground-inactive; the status then reads
`attached_scene_inactive` until the first `drain()`/`get_diagnostics()` after the scene
activates, when it becomes `attached`. If it still reads `attached_scene_inactive` while the app is
in the foreground and touches arrive, record that as a failure.

**IN-01 — source identity from BEGIN, no pressure heuristic**
1. Tap once with the Pencil without moving. Expect one BEGIN and one END, both `PENCIL`, same
   `pointer_id`; the BEGIN already shows PENCIL.
2. Tap once with a finger. Expect BEGIN/END `FINGER`.
3. Draw a slow Pencil stroke, then a finger drag. Every record of each contact keeps the identity
   shown at BEGIN.
4. Pencil stroke with the lightest possible touch (pressure near 0): still PENCIL at BEGIN.
5. Pencil stroke: MOVE records include coalesced samples (flag bit0) with increasing timestamps and
   exactly one non-coalesced sample per `touchesMoved` event; no two records share a timestamp and
   position for one contact.
6. Every normal stroke ends with END, never CANCEL(5). PASS only if all hold for 10 repetitions.

**IN-04 — one physical action, one logical action**
1. With the native provider authoritative, perform a Pencil tap on an empty terrain point and a
   Pencil stroke.
2. Expect exactly one BEGIN and one terminal record per contact from the bridge, and exactly one
   logical tool action (one history entry). Godot's own `InputEventScreenTouch/Drag` for the same
   contacts must be visible in the trace as ignored, never as a second action.
3. Confirm `ClassDB.can_instantiate("WPNativeInput") == false` and a single observer
   (`records_emitted` grows by the expected count only).

**IN-09 — native CANCEL or app deactivation**
1. Start a Pencil stroke on the terrain and, still touching, swipe down Notification Center with
   a finger from the top edge. Expect CANCEL `app_deactivated` (or `native_cancel` if UIKit cancels
   first) for the Pencil contact, the operation fully rolled back, and `active_contacts = 0` after
   the Pencil lifts.
2. Repeat with the app switcher gesture (swipe up and hold) and with the Home indicator.
3. Start a stroke and trigger a system alert (e.g. low-power or a scheduled notification).
4. After returning to the app, a new Pencil stroke begins with a new `pointer_id` and works.
   PASS only if no stroke is committed and no contact stays active in any case.

**IN-10 — queue overflow / mapping generation change**
1. Overflow: use an input-lab debug action that pauses `drain_samples()`, then draw continuously
   with the Pencil until `queued_records` would pass 4096 (about 17 s of coalesced Pencil input at
   240 Hz; add fingers to go faster), then resume draining. Expect `overflow_count` +1, a visible
   `provider_failed("queue overflow")` diagnostic, CANCEL `queue_overflow` for the active stroke,
   no half-applied terrain change, and no further records for that contact until it is lifted.
2. Mapping change: during a Pencil stroke, rotate the device (if orientation is unlocked) or
   trigger a view size/scale change (e.g. Stage Manager resize where available). Expect
   `metrics_generation` +1, CANCEL `view_changed`, rollback, and the next stroke mapped correctly.
3. Resume normal drawing: new contacts start cleanly with new `pointer_id`s.

Related: **IN-11** (no valid pressure) — paint with the Pencil while pressure is disabled in the
UI, and check a finger contact's records show `pressure_valid = 0`; brushes must run at the UI
strength. `pressure_valid = 0` never means zero strength.
