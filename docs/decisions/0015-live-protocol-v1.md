# ADR 0015: Live world protocol v1 implementation (IP-05, IP-06)

Status: accepted 2026-10-02. Implements INT-SPEC-1.1 §10 and IP-SPEC-1.1 §5–§6. Contract files:
`contracts/world-painter/live-v1/`.

## Decisions

### L1. Layering

All protocol code lives in `app/addons/world_painter/live/` and is transport-independent `RefCounted` logic, except
two thin transport nodes. Nothing in `live/` imports `res://src/`.

| File | Role |
|---|---|
| `live_ids.gd` | 128-bit random hex ids (session, stream, message, transfer, operation) |
| `live_envelope.gd` | Build/parse text messages; size caps (8 KiB pre-auth, 64 KiB after); strict per-type payload keys |
| `live_blob_framer.gd` | Split a blob into `WPB1` binary frames (256 KiB payload) |
| `live_blob_receiver.gd` | Disk-backed staging of one transfer under the session root; incremental SHA-256; duplicate/conflict/order checks |
| `authored_hash_cache.gd` | Incremental authored hash V4: per-region map digests invalidated by changed regions; object chunks via `ObjectChunkCache` |
| `world_delta.gd` | Build commit deltas from a `WorldChange`, build preview deltas from a provisional sample, parse/validate delta ZIPs |
| `delta_apply.gd` | Apply a validated delta to a document in place with a rollback journal |
| `preview_sampler.gd` | Provisional sampling of the open `EditTransaction`: dirty tiles, objects, scatter tiles, coalescing |
| `live_sender.gd` | Sender session state: stream epochs, revision chain, bounded spool, snapshot scheduling, preview throttle |
| `live_replica.gd` | Receiver state: committed document + provisional overlay, ACKs, resync decisions |
| `live_peer_socket.gd` | WebSocket client node (sender) |
| `live_listener.gd` | TCPServer + WebSocketPeer node (receiver): pairing, auth deadline, single writer, caps on pre-auth peers |

### L2. Authentication and transport

- Pairing token: 32 random bytes hex (64 chars), single use, 5-minute expiry, shown in the receiver UI; it is sent
  only inside the first `hello` text message (never in a URL). After success the receiver returns a random
  in-memory `session_credential` (32 bytes hex) valid until the preview stops; `hello` with that credential resumes.
- Unauthenticated peer: must send a valid `hello` within 5 s; ≤ 8 KiB per message; at most 4 pending peers; binary
  frames before authentication close the peer. A second writer is rejected (`error` code `writer_busy`) until the
  first session is closed.
- Transport v1 is WebSocket cleartext on the LAN, enabled only when **both** peers set `allow_insecure_lan`; both
  UIs show a persistent warning. TLS is a declared capability (`tls`) that v1 builds do not offer; this gap is
  recorded as NOT RUN in acceptance. Default port 8666.

### L3. Messages

Envelope per `envelope.schema.json`. `hello` payload: `{"role": "sender"|"receiver", "protocol_versions": [1],
"auth": {"pairing_token"|"session_credential": hex}, "app": str, "capabilities": [str]}`; `hello_result`:
`{"accepted": bool, "session_credential": hex, "limits": {...}, "receiver": {"profile": str}}`. `resume`:
`{"world_id", "stream_id", "revision", "authored_hash"}` from the sender; `resume_result`: `{"mode": "continue"|
"snapshot", "revision", "authored_hash"}`. ACKs carry `{"world_id","stream_id","revision","authored_hash",
"visual_ready": bool}`. `preview_cancel`: `{"operation_id"}`. Unknown types or keys close the session with `error`.

### L4. Streams and revisions

- `stream_id` is new for: a new world, opening another world, migration, recovery that lowers the revision, and any
  full resynchronization. `document_revision` increases by exactly one per commit/undo/redo/binding update.
- The sender keeps the committed chain since the last acknowledged snapshot in a bounded spool (≤ 128 operations,
  ≤ 128 MiB; disk-backed under `user://live/spool/`). Overflow or a gap schedules a fresh snapshot on a new stream.
- Snapshot capture waits for a stable committed point (no open operation), freezes plain values on the main thread,
  and serializes the `.worldpoc` v4 on the storage worker pattern.

### L5. Commit deltas

From `WorldChange` (forward = after values, undo = before values):

- Tiles: per changed region map, compare before/after per 64×64 tile; emit the changed tiles' absolute bytes.
- Objects: upserts for non-null target records, deletes for null.
- Whole files when touched: `scatter_file` (scatter.bin v2), `paths_file`, `terrain_rules`; `asset_lock_file` when
  the referenced lock bytes differ from the previously sent revision.
- `target_authored_hash` from `authored_hash_cache.gd`; the receiver recomputes it after applying.

The receiver applies in place with a rollback journal (before values of every touched tile, object, file) and
rolls back on any mismatch, which is equivalent to scratch-then-swap without copying 64 regions per commit.

### L6. Preview deltas

- `preview_sampler.gd` runs at most 15 Hz while an operation is open. Candidate tiles are those inside regions the
  open transaction captured; a tile is sent when its current bytes differ from the bytes last sent for this
  operation (initially the committed base). Objects captured by the transaction are sent as absolute records.
  Scatter preview tiles (`WPST`) are rebuilt at most 4 Hz and only for tiles inside the operation's affected bounds.
- Coalescing: one pending value per key (tile, object, scatter tile); a newer sample overwrites the pending value.
- The receiver overlays the highest `preview_seq` per key on top of its committed view. Commit of the same
  operation, cancel, timeout (10 s without preview traffic), stream change or reconnect clears the overlay.

### L7. Visual readiness

The replica reports `visual_ready = false` while any referenced binding is unavailable; placeholders use frozen
bounds (ADR 0014 D10). Apply stays disabled until all required desktop deliveries are ready.

## Consequences

- iPad Pencil input never waits for the network: sampling and serialization costs are bounded per frame; heavy
  work (snapshot ZIP, hashing large files) runs on a worker with frozen plain values.
- TLS is a known v1 gap for LAN development use only.

## Amendment (IP-05 implementation, 2026-10-02)

- Delta archive members: `delta.json`, `tiles/r_<x>_<z>.t<tx>_<tz>.<map_kind>`, `scatter/r_<x>_<z>.t<tx>_<tz>.wpst`,
  `files/{asset_locks.json,scatter.bin,paths.bin}` (the schema's `safe_member` forbids a dotted first segment).
  Godot's `ZIPPacker` writes `tiles/`, `scatter/`, `files/` directory entries; readers tolerate exactly those.
- Payload shapes are frozen in `live-v1/envelope.schema.json` `$defs`.
- The authored-hash cache is pull-based (owner invalidates; `hash_of(doc)` recomputes stale parts). The first full hash
  at stream start runs on the main thread (~115 ms host, km1); later commits are incremental (~1.6 ms host).
- Commit delta build/apply run on the main thread over changed tiles only; snapshots are built off-thread.
- Previews start only after the snapshot is acknowledged.
