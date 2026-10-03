# ADR 0016: Desktop preview process, local broker and iPad link (IP-06)

Status: accepted 2026-10-02. Implements INT-SPEC-1.1 §6 "Preview pairing", §10, §11 "Dedicated process" and
IP-SPEC-1.1 §6. Builds on ADR 0015 (live protocol).

## Decisions

### P1. Processes and ownership

- **Editor plugin** (`addons/world_painter/editor/`): dock with Start/Stop preview, pairing details, connection and
  revision/hash/durable/visual-ready status, missing assets, and Apply (enabled by IP-07). It is the only writer of
  project files and the only holder of AssetStudio credentials.
- **Preview child** (`addons/world_painter/preview/preview_main.tscn`): launched with the same Godot executable and
  project (`OS.create_process(OS.get_executable_path(), ["--path", <project>, <scene>, "--", "--wp-config", <file>])`).
  It owns the LAN listener (`LiveListener`), the `LiveReplica`, and the presentation. It never writes under `res://`;
  its private session root is `user://world_painter/sessions/<session_id>/` and cleanup is limited to it.
- The child is killed and its session root removed when the editor stops the preview or the editor exits; a child
  that loses the broker connection exits within 5 s.

### P2. Private configuration

The editor writes `user://world_painter/sessions/<session_id>/config.json` (owner-only permissions where supported)
holding the broker port, a one-time broker credential (32 random bytes hex), listener port/bind, `allow_insecure_lan`
and the profile scene path. Only the file path is on the command line. The child reads then deletes the file.

### P3. Broker channel

Loopback TCP (`127.0.0.1`, ephemeral port) between editor (server) and child (client); frames = u32 LE length +
UTF-8 JSON ≤ 64 KiB; first frame must authenticate with the one-time credential within 5 s. Allowlisted requests only:

| Request (child → editor) | Reply |
|---|---|
| `hello {credential}` | `hello_result {accepted}` |
| `status {listener, pairing, session, revision, authored_hash, durable_revision, visual_ready, missing[]}` | `ok` (editor displays) |
| `assets_needed {bindings: [binding rows]}` | `asset_status {binding_id: {state, files: {path: absolute cache path}, manifest_sha256, error}}` |
| `snapshot_frozen {path, revision, authored_hash, source_snapshot_hash}` (reply to editor `freeze_snapshot`, IP-07) | — |

The editor resolves `assets_needed` with the vendored AssetStudio addon (project config + device-local credentials,
exact pinned `portable_glb_v1` delivery). It only returns paths inside the AssetStudio blob cache root; the child
re-verifies file SHA-256/size against the manifest before loading and rejects any path outside that root. The iPad
never supplies paths or URLs.

### P4. Presentation and host profile

- Project setting `world_painter/preview/profile_scene` (optional PackedScene) supplies lights, environment and camera
  rig; it must contain a node in group `world_painter_mount` where the isolated `WorldPreviewRoot` is attached. Without
  a profile the child creates a neutral default light/environment; with a profile it never adds its own.
- `WorldPreviewRoot` renders `replica.document` with the extracted presentation (`TerrainAdapter`, `WorldLayers`,
  `ObjectPresenter`, runtime-tier providers) and overlays the provisional state. Placeholders use frozen bounds; an
  on-screen label shows `INCOMPLETE` while `visual_ready` is false. The camera is independent.
- Material policy: default `preserve` (library materials as baked by `RuntimeGlbLoader`). When the profile root has
  `map_material(slot_id: String, material: Material) -> Material`, the preview calls it once per (binding, slot) for
  every runtime and bundled object/scatter surface material (`WPMaterialMapper`; slot id = material name, or
  `surface_<n>`; a host may instead define `map_material_for(asset_id, slot_id, material)`, preferred when present, because
  slot ids such as `m_solid` are shared by unrelated assets); a null result keeps the original. Runtime meshes are mapped before their tiers register
  (`RuntimeBackedProvider.material_mapper`), loaded bundled meshes in `RenderAssetCache.mesh_mapper`; far/ghost boxes
  are not mapped. Implemented 2026-10-02 (FG-03).
- Terrain material: project setting `world_painter/terrain/material` (a `Terrain3DMaterial` resource, `res://`) replaces
  the World Painter terrain shader material in the preview and in the Apply bake; unset keeps the default. An invalid
  value falls back silently in the preview and fails the bake.

### P5. iPad link

`app/src/preview/` holds `PreviewLink` (drives `LivePeerSocket` + `LiveSender` + `LiveSessionBinding`), a small
settings panel (host, port, pairing token, `allow_insecure_lan` toggle with persistent warning, connect/disconnect) and
a status indicator. Host settings are device-local (`user://world_painter/preview.json`, no token stored after pairing
except the in-memory session credential). The iOS export preset sets `NSLocalNetworkUsageDescription`.

### P6. Defaults

Listener port 8666, ping 2 s, unresponsive 6 s, drop 10 s, pairing expiry 5 min, ≤ 4 unauthenticated peers, 5 s auth
deadline, one writer.

## Consequences

The preview can never modify project content; Apply (IP-07) goes through the editor plugin. A crashed child leaves
only its own session directory.
