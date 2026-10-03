# Authored content hash V4

Source of truth: INT-SPEC-1.1 §9.3. The stream is the schema 3 stream (`docs/world-format.md` §11.4) with two substitutions. The catalog identity is replaced by the lock hash, and `asset_id`/`asset_version` are replaced by `binding_id`.

`authored_content_hash = lowercase_hex(SHA256(stream))`.

Encoding rules:
- Integers are little-endian.
- `str` is a u32 byte length followed by UTF-8 bytes.
- `f64` is an IEEE-754 double, little-endian, with `-0.0` written as `+0.0`.
- `u8` booleans are 0 or 1.

```text
"WPOC-AUTHORED-V4\n"
u32 schema_version = 4
32 raw bytes SHA256(asset_locks.json stored bytes)
f64 sample_spacing_m, u32 region_samples
i32 min_region_x, i32 min_region_z, u32 region_count_x, u32 region_count_z
u8 rock_enabled, i32 rock_slope_deg, u8 sand_enabled, i32 sand_height_dm
u32 region_count
per region in canonical Z-then-X order:
  i32 x, i32 z
  32 raw bytes SHA256(height file)
  32 raw bytes SHA256(control file)
  32 raw bytes SHA256(color file)
32 raw bytes SHA256(scatter.bin), 32 raw bytes SHA256(paths.bin)
u32 object_count
per object sorted by object_id:
  str object_id, str binding_id
  f64 position[3], f64 rotation_xyzw[4], f64 uniform_scale
  str grounding, f64 height_offset_m, str origin
  str scatter_operation_id ("" when null)
```

Excluded:
- `world_id`
- `document_revision`
- timestamps
- `created_with`
- session and stream state
- camera
- library display metadata

Required vectors (IP-02):

| Vector | Content |
|---|---|
| `km1_flat_empty` | `km1` layout, all height 0.0, control `0x00000001`, tint `FF FF FF 00`, default rules, empty lock, no objects, empty `scatter.bin` v2 and `paths.bin` |
| `legacy_flat_empty` | Same content on the legacy 2×2 layout. Allowed in schema 4. |
| `one_bundled_object`, `one_remote_object` | One object per provider |
| `two_versions` | Two bindings of the same asset at different versions |
| `remote_scatter` | Scatter instances using an assetstudio binding |
| `non_ascii_ids` | Non-ASCII asset and library identifiers inside the lock |
| `holes` | Control hole bits set |
| `migrate_v2`, `migrate_v3` | Source and destination pairs with expected hashes |
