# World schema 4 binary formats and identifiers (DRAFT)

Source of truth: INT-SPEC-1.1 §9.2 and §10.5. Little-endian throughout. `str` = u32 byte length + UTF-8.

## scatter.bin version 2

```text
"WPSC"                      4 ASCII bytes
u32 version = 2
u32 binding_count
binding_count × str binding_id      # sorted byte-wise, unique, each referenced by >= 1 instance
u32 instance_count                  # <= 100000 (schema 4 limit)
instance_count × 20 bytes:
  u16 binding_index                 # < binding_count
  u16 flags                         # bit 0 = tilt to terrain normal; other bits 0
  f32 x, f32 z                      # finite, inside the layout's bilinear extent
  f32 yaw_rad                       # finite, |yaw| <= 3.1416
  f32 scale                         # finite, inside the binding's effective scale_range
```

- Every referenced binding has effective `policy.scatter_allowed = true`.
- Instance order is document order and is preserved exactly. No trailing bytes.
- Empty file: `"WPSC"`, 2, 0, 0 (16 bytes).
- File size ≤ 4 MiB.

## WPST scatter preview tile version 1 (live preview only)

Never stored in a world generation.

```text
"WPST"                      4 ASCII bytes
u32 version = 1
u32 binding_count
binding_count × str binding_id      # sorted, unique
u32 instance_count                  # <= 16384
instance_count × 20-byte records as in scatter.bin v2 (binding_index into this file's table)
```

All instance X/Z lie inside the tile's world rectangle. A tile is 64×64 samples, which is 32 m × 32 m at 0.5 m spacing. Its X range is half-open `[x0, x0 + 32)`, and the Z range is the same.

## binding_id

```text
binding_id = "b" + lowercase_hex(SHA256("WPBIND1\n" + canonical_v1_bytes(binding_without_binding_id)))[0:32]
```

- `canonical_v1_bytes` is exactly AssetStudio `assetstudio_core.canonical_v1.canonical_bytes`: reject floats, non-string keys and non-JSON types, then Python `json.dumps(sort_keys=True, separators=(",",":"), ensure_ascii=False, allow_nan=False)` as UTF-8. Escapes: `\"`, `\\`, `\n`, `\r`, `\t`, `\b`, `\f`, other code points below U+0020 as lowercase `\u00xx`; `/`, U+007F, U+2028 and all other non-ASCII are not escaped.
- The binding object is hashed with every field except `binding_id`, including `provider` and `policy`.
- Validators recompute the ID and reject a mismatch.
- Identical selections therefore share one ID on every peer. Any change to version, delivery or policy produces a new ID.
