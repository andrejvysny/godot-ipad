# 0006 — Use Mobile/Vulkan on the tested iPad

Status: accepted for the Input Lab on iPad Air 4 / iPadOS 26.5. Full G1 remains incomplete.

## Evidence

The signed Godot 4.7.2 / Terrain3D 1.0.2 app launched with Mobile/Metal but displayed magenta
3D output and stalled. The physical-device log repeatedly reports:

```text
ERROR: timeout waiting for fence
   at: wait (drivers/metal/rendering_device_driver_metal3.cpp:54)
```

The pinned engine's fence wait uses a 1000 ms timeout. The log also contains a stack through
`InputSystem._push`, so native input was reaching the application despite the rendering stalls.
The exact GPU command that failed has not been isolated; this evidence does not prove a
specific Terrain3D shader defect or justify modifying the engine.

The same installed app, launched with `--rendering-method mobile --rendering-driver vulkan`,
reported Vulkan 1.2.334 on Apple A14 GPU, reached readiness, and stopped logging fence timeouts.
The user confirmed visible terrain, finger orbit, and Pencil painting. After reinstalling the
Vulkan-default diagnostic build, the user confirmed that Pencil operates the scale and checkpoint
buttons. A captured device frame and runtime counters independently confirm rendering and UI activity.

## Decision

Set `rendering/rendering_device/driver.ios="vulkan"`, retaining the Mobile rendering method.
The official export template already includes MoltenVK. macOS retains Metal. No custom engine,
export template, native bridge, or vendored Terrain3D change is needed.

This is an explicit tested-driver choice, permitted by specification §2.3, rather than an
automatic fallback. Any future return to native Metal requires the same physical scene to
render, update terrain, accept input, and run without GPU errors.

## Validation limits

The successful short device session does not establish sustained performance, palm rejection,
interruption handling, calibration at both scales, or exact save/reopen across devices. Host
headless tests and the Simulator's separate GLES preview cannot close those gates.

See [the audit](../evidence/ipad-audit-2026-10-01.md) for logs, measurements, and remaining work.
Terrain3D's [platform documentation](https://terrain3d.readthedocs.io/en/stable/docs/platforms.html)
describes Mobile/Vulkan support and does not certify this release's Metal support. Godot
[issue 119436](https://github.com/godotengine/godot/issues/119436) describes similar Metal fence
stalls on macOS; it is related context, not proof of the exact cause on this iPad.
