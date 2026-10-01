# Render asset derivatives (schema 1)

Contract for prepared mobile representations of catalog assets (spec
`docs/rendering-performance-spec.md` §6, §12). Shared by the runtime (`app/src/rendering/`), the
offline preparation tool (`app/devtools/prepare_render_assets.gd`) and the Python validator
(`scripts/validate_render_assets.py`). Render derivatives are derived state: they never enter a
world file or an authored hash, and changing them never changes the logical catalog hash.

## 1. Registries

| Registry | Index | Logical catalog |
|---|---|---|
| Editor | `res://assets/render_assets/index.json` | `res://assets/catalog.json` (`poc_nature`) |
| Benchmark | `res://assets/bench/render_assets/index.json` | `res://assets/bench/catalog.json` (`bench_nature`) |

The benchmark catalog is a separate logical catalog (same strict format, `AssetCatalog.load_from`)
so benchmark-only assets never change the editor catalog hash that every world references.

### 1.1 index.json

```json
{
  "format": "world-painter-render-assets",
  "schema_version": 1,
  "catalog_id": "poc_nature",
  "catalog_version": 2,
  "prepared_for": {"godot": "4.7.2", "renderer": "mobile", "texture_formats": ["etc2_astc", "s3tc_bptc"]},
  "assets": [
    {"asset_id": "nature.tree.spruce_a", "asset_version": 1,
     "descriptor": "spruce_a/descriptor.json", "descriptor_sha256": "<64 hex>"}
  ]
}
```

- Exactly these keys (index and entries). `assets` sorted by `asset_id` byte-wise, unique ids.
- `catalog_id`/`catalog_version` must equal the logical catalog the registry is used with;
  otherwise every asset is `NOT_READY` (reason `catalog_mismatch`).
- `descriptor` is a relative path (§4 path rules) from the index directory; `descriptor_sha256`
  is the sha256 of the descriptor file bytes.
- Catalog assets without an index entry are `NOT_READY` (reason `no_derivative`).

## 2. descriptor.json

```json
{
  "format": "world-painter-render-asset",
  "schema_version": 1,
  "asset_id": "nature.tree.spruce_a",
  "asset_version": 1,
  "source_content_hash": "<64 hex>",
  "derivative_hash": "<64 hex>",
  "category": "tree",
  "vegetation": true,
  "decorative": false,
  "anchor_local_m": [0.0, 0.0, 0.0],
  "bounds_min_m": [-1.4, 0.0, -1.4],
  "bounds_max_m": [1.4, 7.0, 1.4],
  "footprint_radius_m": 1.4,
  "representations": {
    "selected": {"mesh": "mesh_selected", "triangles": 1536, "surfaces": 2,
                 "aabb_min_m": [-1.4, 0.0, -1.4], "aabb_max_m": [1.4, 7.0, 1.4]},
    "near": {"alias": "selected"},
    "mid": {"alias": "selected"},
    "far": {"mesh": "mesh_far", "triangles": 44, "surfaces": 2,
            "aabb_min_m": [-1.4, 0.0, -1.4], "aabb_max_m": [1.4, 7.0, 1.4]},
    "ghost": {"alias": "far"}
  },
  "overview": {"kind": "canopy", "shape": "cone", "base_y_m": 1.4, "height_m": 5.6,
               "radius_m": 1.4, "color": [0.13, 0.34, 0.18]},
  "materials": {
    "bark": {"dependency": "mat_bark", "alpha_mode": "opaque", "texture": null},
    "needles": {"dependency": "mat_needles", "alpha_mode": "opaque", "texture": null}
  },
  "textures": {},
  "dependencies": [
    {"key": "mat_bark", "type": "material", "path": "bark.tres", "bytes": 312,
     "sha256": "<64 hex>", "gpu_bytes": 0, "staging_bytes": 0}
  ],
  "provenance": "Prepared from res://assets/models/spruce_a.tscn by prepare_render_assets.gd",
  "license": "CC0-1.0"
}
```

Field rules (exact key sets at every level; unknown or missing keys fail):

| Field | Rule |
|---|---|
| `format`, `schema_version` | `"world-painter-render-asset"`, `1`; other versions fail with an explicit unsupported-version error |
| `asset_id`, `asset_version` | Must exist in the logical catalog with that version |
| `source_content_hash` | §3.1; must match the loaded catalog's asset (stale derivative → `NOT_READY`, reason `source_changed`) |
| `derivative_hash` | §3.2; recomputed and compared |
| `category` | `tree`, `shrub`, `rock`, `structure`, `ground_cover`, `prop` |
| `vegetation` | bool; drives "Hide vegetation" |
| `decorative` | bool; only `true` assets placed through the scatter layer may be density-thinned. Manual object records are never thinned |
| `anchor_local_m`, `bounds_min_m`, `bounds_max_m`, `footprint_radius_m` | Finite; equal to the catalog `placement_anchor_local`, `bounds_min/max`, `footprint_radius_m` within 1e-6 (logical semantics stay the catalog's) |
| `representations` | Exactly the roles `selected`, `near`, `mid`, `far`, `ghost`. Each is either `{"alias": <role>}` or a mesh entry. Aliases resolve to a mesh entry in at most 2 steps without cycles |
| mesh entry | `mesh` = key of a `type: "mesh"` dependency; `triangles` (int ≥ 1), `surfaces` (int 1–8) as measured by the tool; `aabb_min_m`/`aabb_max_m` finite, min < max: render bounds in asset space (used for batch culling bounds) |
| `overview` | `kind`: `canopy` (vegetation crowns), `solid` (rocks, structures), `none` (not drawn in grouped overviews, e.g. ground cover); `shape`: `cone`, `ellipsoid`, `box`; `base_y_m`, `height_m` (> 0), `radius_m` (> 0) in asset space; `color` 3 floats in [0, 1] (linear) |
| `materials` | Map material key → `{dependency, alpha_mode, texture}`; `alpha_mode` `opaque` or `cutout`; `texture` null or a key of `textures`. Every material dependency must be listed here |
| `textures` | Map texture key → `{"low": tier, "preview": tier or null}`; tier = `{"dependency": key, "width": w, "height": h, "mipmaps": true}`; w, h powers of two; low ≤ 512, preview ≤ 2048 |
| `dependencies` | Array sorted by `key`, unique keys and paths. `type` ∈ `mesh`, `material`, `texture`; `path` relative to the descriptor directory (§4); `bytes` (1 … 64 MiB) and `sha256` of the repository file; `gpu_bytes`, `staging_bytes` = estimates (§5) |
| `provenance`, `license` | Non-empty strings |

Representation targets (content targets, not enforced): selected trees 8,000–20,000 triangles,
near 2,000–5,000, mid 500–2,000, far 200–800, ghost < 500. Simple assets alias roles instead of
adding geometry.

## 3. Hashes

### 3.1 source_content_hash

`sha256` of: `"WPRA-SOURCE-V1\n"`, `str asset_id`, `u32 asset_version`, 32 raw bytes
sha256(preview_scene file bytes), `u8 has_scatter_mesh`, then (if 1) 32 raw bytes
sha256(scatter_mesh file bytes). (`str` = u32 byte length + UTF-8, integers little-endian.)

### 3.2 derivative_hash

`sha256` of: `"WPRA-DERIVATIVE-V1\n"`, `str asset_id`, `u32 asset_version`, 32 raw bytes
`source_content_hash`, `str category`, `u8 vegetation`, `u8 decorative`, then for each role in the
order selected, near, mid, far, ghost: `str role`, `u8 is_alias`, `str alias-or-mesh-key`,
`u32 triangles` (0 for aliases), `u32 surfaces` (0 for aliases); then `u32 dependency_count` and per
dependency in array order: `str key`, `str type`, `str path`, `u64 bytes`, 32 raw bytes sha256;
then `u32 material_count` and per material key sorted byte-wise: `str key`, `str dependency`,
`str alpha_mode`, `str texture` ("" for null); then `u32 texture_count` and per texture key sorted:
`str key`, `str low dependency`, `u32 low width`, `u32 low height`, `str preview dependency`
("" for null), `u32 preview width`, `u32 preview height` (0 for null). Floats are deliberately
excluded (Godot's JSON parser is not correctly rounded); they are validated by tolerance instead.

## 4. Files and safety

- Paths: relative, `/` separators, no `..`, no backslash, no absolute or `res://`/`user://`
  prefixes, no leading `/`; resolved inside the descriptor's directory. Allowed extensions:
  `.tres` (meshes: `ArrayMesh`; materials: `StandardMaterial3D`) and `.png` (textures, imported).
- Mesh `.tres`: `ArrayMesh`, triangles only, no blend shapes, no skin; surface materials reference
  the asset's material `.tres` files (ext_resource). Parts are baked to asset space (§6).
- Material `.tres`: `StandardMaterial3D` only; `transparency` DISABLED (`opaque`) or
  ALPHA_SCISSOR (`cutout`); no `next_pass`, no ShaderMaterial, no emission/refraction/subsurface/
  clearcoat/anisotropy/heightmap/detail; cull back or disabled.
- Textures: PNG imported as VRAM-compressed with mipmaps (`compress/mode=2`, `mipmaps/generate=true`,
  `compress/normal_map=2` (disabled)), colour textures sRGB, masks linear. The importer produces
  ETC2/ASTC for iOS. Cutout masks are stored as distance-field-like soft alpha so the 0.5 scissor
  contour survives box-filtered mips (§6).
- The runtime never loads `PackedScene` from a registry and never loads a catalog `preview_scene`
  for rendering; a missing/invalid derivative makes the asset `NOT_READY`.
- Runtime validation (GDScript): index + descriptor schema, catalog identity, source hash, path
  rules, `ResourceLoader.exists`, sha256 of `.tres` and `.json` files (exported verbatim), resource
  class/whitelist after load, texture size/mipmaps after load. Offline validation (Python) also
  hashes `.png` files and checks `.png.import` parameters.

## 5. Cost estimates

`gpu_bytes`: meshes = vertex bytes + index bytes as written by the tool from the actual arrays
(positions 12, normals 4 (octahedral), tangents 4, UV 8, colour 4 per vertex when present; indices
2 or 4); textures = sum over the mip chain of `width × height × bpp / 8` with bpp 8 for
ETC2-RGBA/ASTC-4×4 (worst case of the target formats); materials 0. `staging_bytes`: textures = the
level-0 RGBA8 decode size (`w × h × 4`) the loader may hold transiently, meshes = `gpu_bytes`.

## 6. Preparation tool (summary)

`godot --headless --path app --script res://devtools/prepare_render_assets.gd -- <manifest.json>`
(wrapped by `python3 scripts/dev.py prepare-render-assets <manifest>`):

1. Reads source scenes through `SceneState` (no instantiation, no scripts run). Allowed node types:
   `Node3D`, `MeshInstance3D`; scripts, lights, cameras, physics bodies, collision shapes,
   AnimationPlayers, particles, skeletons and any other node are **stripped and reported**; skinned
   meshes and blend shapes are rejected.
2. Bakes every mesh part with its complete transform relative to the asset root (normals by the
   inverse transpose, tangent handedness and triangle winding flipped for mirrored transforms);
   singular or non-finite transforms are rejected. Surfaces with the same material are merged.
   The logical anchor is kept; tiers are never recentred.
3. Tiers come from artist/prepared inputs (a tier scene per role or an alias); the tool does not
   decimate.
4. Writes meshes/materials/textures, measures triangles/surfaces/bounds/bytes, writes the
   descriptor and index and a machine-readable report (`build/render_prep/<catalog>-report.json`)
   including stripped nodes and cutout mip coverage (fraction of texels ≥ 0.5 per mip relative to
   mip 0; mips ≥ 32 px must keep ≥ 0.8).

## 7. Preparing render assets

```
python3 scripts/dev.py prepare-render-assets [--catalog poc|bench|all] [--check]
```

Runs `generate_bench_assets.gd` (bench only), `prepare_render_assets.gd` per manifest, `godot --import`
and a second tool pass with `--require-import` that verifies every texture loads imported with
mipmaps at its declared size. All Godot runs have hard timeouts and stdin=/dev/null. `--check` repeats
the pipeline in `build/render_prep_check/` and fails on any byte difference with the committed outputs.

| Catalog | Manifest | Output |
|---|---|---|
| `poc_nature` (editor) | `app/devtools/render_prep/poc_nature.json` | `app/assets/render_assets/` |
| `bench_nature` | `app/devtools/render_prep/bench_nature.json` | `app/assets/bench/render_assets/` |

The benchmark logical catalog `app/assets/bench/catalog.json` (with its source scenes and the grass scatter
mesh under `app/assets/bench/models/`) is generated by `app/devtools/generate_bench_assets.gd`. Its tier
scenes and texture PNGs are tool inputs written to the ignored `build/render_prep_inputs/bench_nature/<asset>/`
(manifest paths are project-relative, `../build/...`). `bench.tree.heavy_unprepared` is in the bench
catalog but has no registry entry (`NOT_READY` fixture).

Manifest keys: `catalog_dir`, `output_dir`, `report` (project-relative,
`../build/render_prep/<catalog>-report.json`) and per asset `asset_id`, `category`, `vegetation`,
`decorative`, `tiers` (each role is `{"scene": path}`, `{"source": true}` = the catalog preview scene, or
`{"alias": role}`), `textures` (`{key: {"low": png, "preview": png|null}}`), `overview`, and optional
`provenance`/`license`. A material whose `resource_name` equals a texture key is bound to that texture's
LOW png; other materials are keyed by `resource_name` or `m_<8 hex of the whitelisted property hash>`.
The source scene's root transform is ignored (the root is the asset frame).
