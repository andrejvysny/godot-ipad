shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx,skip_vertex_transform;

// World Painter terrain shader. Base: the shader Terrain3D 1.0.2-stable generates for
// Terrain3DMaterial (auto_shader = false, shader_override_enabled = true, empty override),
// dumped verbatim and then patched. Every change is marked `// WP:`. Patches:
//   1. Uniforms rules_rock_enabled / rules_rock_slope_deg / rules_sand_enabled /
//      rules_sand_height_m / rules_highlight (set from the world's TerrainRules).
//   2. Rule weights evaluated once per pixel in fragment() (slope from the terrain normal,
//      height from the vertex height) and passed to accumulate_material().
//   3. accumulate_material(): a control corner with the auto bit set replaces its stored base
//      id by the rule material (grass -> sand -> rock, rock wins); overlay id/blend unchanged.
//   4. material.highlight accumulates the rule weight on auto corners for the rule overlay.
//   5. Colour map is the tint map (rgb tint, a weight): default is weight 0, not
//      "white albedo, roughness 0.5", and its alpha no longer drives roughness.
//   6. Final albedo: tint mixed over the texture albedo by 0.6 * weight, keeping texture
//      detail; optional rule highlight.
//   7. Debug views: uniform debug_view (0 none, 1 control blend, 2 heightmap, 3 normals) and
//      debug_region_grid, drawn as emission over a black albedo. Terrain3D's own show_control_blend /
//      show_heightmap / show_region_grid are shader injections of the generated shader and are inert
//      under this override; TerrainAdapter.set_debug_view / set_region_grid drive these uniforms instead.
//   8. Trim (spec 13.2): removed macro variation (noise_texture, noise1/2_*, macro_variation*), per-texture detiling
//      (_texture_detile_array), depth blur (depth_blur, bias_distance) and the noise world-background
//      hooks (u/v derivative offsets). Steep-slope UV projection (enable_projection / projection_threshold)
//      is KEPT (only the detile position snapping that used its projected position was dropped). The adapter sets the Terrain3D background to NONE (nothing is
//      drawn outside the authored regions; was FLAT before 2026-10). The 4-corner control blend and the height-blend
//      weighting are unchanged; the 0.5 UV offset detiling applied at zero detile is kept.
//   9. Fixed-area texture preview (spec 11.4): preview_enabled / preview_area / preview_layer and the
//      preview_albedo_array / preview_normal_array. Inside the area the albedo RGB and the normal/
//      roughness sample come from the preview layer with the same UV and the same explicit
//      gradients as the low-tier sample, mixed by a feathered world-XZ mask. Blend weights (albedo.a
//      of the LOW-tier sample, control, overlay, auto-paint rules) are untouched.
//  10. Colour map: the redundant textureLod before the bilinear-corner path is skipped when the
//      4-corner path replaces it.
//  11. Developer-only overview experiment skips normal/roughness lookups only when they do not
//      drive painted blend weights. Preview pixels retain the full path. Default remains full.
//  12. Coarse clipmap triangles retain edge vertices with clamped height samples; strict fragment
//      bounds avoid losing authored corners when a triangle straddles the finite world edge.
//
// Upstream: Terrain3D 1.0.2-stable@0077405b, MIT license (app/addons/terrain_3d/LICENSE.txt).
//
// Texture lookups per fragment (texelFetch + texture/textureLod/textureGrad), counted from the code.
// "n" = corners with an overlay (blend > 0), "r" = rule slots sampled per auto corner (1..3):
//   (projection is ALU only and changes no counts)
//   before: fixed 5 (nearest, region_mip >= 0) or 17 (bilinear) incl. the redundant colour lookup (+1),
//           per corner 2 * (r or 1) + 2 if overlay, macro variation 2.
//           nearest: 9..15 ; bilinear (4 corners): 27..51 for r = 1..3 with/without overlays.
//   after : fixed 5 (nearest) or 16 (bilinear), macro variation 0, corners as before.
//           nearest: 7..13 ; bilinear: 24..48. Saves 2 (nearest) / 3 (bilinear) lookups per fragment.
//   preview area (opt-in, only while the preview is active and only for slots with a preview layer):
//           +2 per sampled slot per corner (preview albedo + preview normal).
//   overview experiment outside preview: saves one normal lookup per overlay corner, or
//           (r or 1) normal lookups for corners without overlays. Albedo/height lookups unchanged.

/* The terrain depends on this shader to function. Don't change most things in vertex() or 
 * terrain normal calculations in fragment(). You probably only want to customize the 
 * material calculation and PBR application in fragment().
 *
 * Uniforms that begin with _ are private and will not display in the inspector. However, 
 * you can set them via code. You are welcome to create more of your own hidden uniforms.
 *
 * This system only supports albedo, height, normal, roughness. Most textures don't need the other
 * PBR channels. Height can be used as an approximation for AO. For the rare textures do need
 * additional channels, you can add maps for that one texture. e.g. an emissive map for lava.
 *
 */

// Defined Constants
#define SKIP_PASS 0
#define VERTEX_PASS 1
#define FRAGMENT_PASS 2
#define COLOR_MAP_DEF vec4(1.0, 1.0, 1.0, 0.0) // WP: tint map default = weight 0 (was roughness 0.5)
#define DIV_255 0.003921568627450 // 1. / 255.
#define TAU_16TH -0.392699081698724 // -TAU / 16.

// Inline Functions
#define DECODE_BLEND(control) float(control >> 14u & 0xFFu) * DIV_255
#define DECODE_AUTO(control) bool(control & 0x1u)
#define DECODE_BASE(control) int(control >> 27u & 0x1Fu)
#define DECODE_OVER(control) int(control >> 22u & 0x1Fu)
#define DECODE_ANGLE(control) float(control >>10u & 0xFu) * TAU_16TH
// This math recreates the scale value directly rather than using an 8 float const array.
#define DECODE_SCALE(control) (0.9 - float(((control >>7u & 0x7u) + 3u) % 8u + 1u) * 0.1)
#define DECODE_HOLE(control) bool(control >>2u & 0x1u)

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    #define fma(a, b, c) ((a) * (b) + (c))
    #define dFdxCoarse(a) dFdx(a)
    #define dFdyCoarse(a) dFdy(a)
#endif

// Private uniforms
uniform vec3 _camera_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform uint _background_mode = 1u; // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // Layer 32
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1./_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1./region_size
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
uniform float _texture_normal_depth_array[32];
uniform float _texture_ao_strength_array[32];
uniform float _texture_roughness_mod_array[32];
uniform float _texture_uv_scale_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
#define FILTER_LINEAR
uniform highp sampler2DArray _color_maps : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform highp sampler2DArray _texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;


// Public uniforms
uniform float blend_sharpness : hint_range(0, 1) = 0.5;
uniform bool flat_terrain_normals = false;
// WP: experimental benchmark mode only; texture normals that drive paint weights remain sampled.
uniform bool terrain_overview_experiment = false;
// WP: authored sample bounds, XZ minimum then maximum; supplied from the document layout.
uniform vec4 terrain_world_bounds = vec4(-128.0, -128.0, 127.5, 127.5);

uniform bool enable_projection = true;
uniform float projection_threshold : hint_range(0.0, 0.99, 0.01) = 0.8;

uniform float mipmap_bias : hint_range(0.5, 1.5, 0.01) = 1.0;

// WP: auto-paint rules (docs/world-format.md 1.1) and rule highlight.
uniform bool rules_rock_enabled = true;
uniform float rules_rock_slope_deg = 30.0;
uniform bool rules_sand_enabled = true;
uniform float rules_sand_height_m = -0.4;
uniform bool rules_highlight = false;
// WP: debug views (0 none, 1 control blend, 2 heightmap, 3 normals) and region boundary lines.
uniform int debug_view = 0;
uniform bool debug_region_grid = false;
// WP: fixed-area texture preview. preview_area = (centre x, centre z, radius m, feather m);
// preview_layer maps material slots 0..3 to a layer of the preview arrays (-1 = low tier only).
uniform bool preview_enabled = false;
uniform vec4 preview_area = vec4(0.0, 0.0, 0.0, 1.5);
uniform ivec4 preview_layer = ivec4(-1);
uniform highp sampler2DArray preview_albedo_array : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform highp sampler2DArray preview_normal_array : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// WP: mean luminance used to keep texture detail in the tint (a texel of this luminance gets
// exactly the tint colour); highlight colour is (1.0, 0.77, 0.16) sRGB in linear.
#define TINT_MEAN_LUM 0.22
#define HIGHLIGHT_COLOR vec3(1.0, 0.554, 0.021)
// WP: material slot ids of the rule materials.
#define SLOT_GRASS 0
#define SLOT_ROCK 2
#define SLOT_SAND 3

// Varyings & Types

struct material {
	vec4 albedo_height;
	vec4 normal_rough;
	float normal_map_depth;
	float ao_strength;
	float total_weight;
	float highlight; // WP: weight-accumulated rule strength on auto corners
};

varying float v_vertex_xz_dist;
varying vec3 v_vertex;

////////////////////////
// Vertex
////////////////////////

#include "res://src/terrain/world_terrain_region.gdshaderinc"

void vertex() {
	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Camera distance to vertex on flat plane
	v_vertex_xz_dist = length(v_vertex.xz - _camera_pos.xz);

	// Geomorph vertex, set end and start for linear height interpolate
	float scale = MODEL_MATRIX[0][0];
	float vertex_lerp = smoothstep(0.55, 0.95, (v_vertex_xz_dist / scale - _mesh_size - 4.0) / (_mesh_size - 2.0));
	vec2 v_fract = fract(VERTEX.xz * 0.5) * 2.0;
	// For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
	vec2 shift = (scale < _vertex_spacing + 1e-6) ? // LOD0 or not
		// Shift from regular to symetric
		mix(v_fract, vec2(v_fract.x, -v_fract.y),
			round(fract(round(mod(v_vertex.z * _vertex_density, 4.0)) *
			round(mod(v_vertex.x * _vertex_density, 4.0)) * 0.25))
			) :
		// Symetric shift
		v_fract * round((fract(v_vertex.xz * 0.25 / scale) - 0.5) * 4.0);
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	// UV coordinates in world space. Values are 0 to _region_size within regions
	UV = v_vertex.xz * _vertex_density;

	// UV coordinates in region space + texel offset. Values are 0 to 1 within regions
	UV2 = fma(UV, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	// Discard vertices for Holes. 1 lookup
	// WP: outside vertices still support triangles crossing the world boundary. Sampling clamps,
	// not geometry; the fragment pass clips the true bounds. Missing interior regions stay absent.
	vec2 sample_start = clamp(start_pos, terrain_world_bounds.xy * _vertex_density,
		terrain_world_bounds.zw * _vertex_density);
	vec2 sample_end = clamp(end_pos, terrain_world_bounds.xy * _vertex_density,
		terrain_world_bounds.zw * _vertex_density);
	ivec3 v_region = get_index_coord(sample_start, VERTEX_PASS);
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0)).r;
	bool hole = DECODE_HOLE(control);

	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) && 
			(hole || (_background_mode == 0u && v_region.z == -1))) {
		v_vertex.x = 0. / 0.;
	} else {		
		// Set final vertex height & calculate vertex normals. 3 lookups
		ivec3 coord_a = get_index_coord(sample_start, VERTEX_PASS);
		ivec3 coord_b = get_index_coord(sample_end, VERTEX_PASS);
		float h = mix(texelFetch(_height_maps, coord_a, 0).r,texelFetch(_height_maps, coord_b, 0).r,vertex_lerp);
		v_vertex.y = h;
	}

	// Convert model space to view space w/ skip_vertex_transform render mode
	VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}

////////////////////////
// Fragment
////////////////////////

#include "res://src/terrain/world_terrain_material.gdshaderinc"

void fragment() {
	// WP: clip before region lookups, including triangles supported by outside edge vertices.
	if (any(lessThan(v_vertex.xz, terrain_world_bounds.xy)) ||
			any(greaterThan(v_vertex.xz, terrain_world_bounds.zw))) {
		discard;
	}
	// Recover UVs
	vec2 uv = UV;
	vec2 uv2 = UV2;
	
	// Lookup offsets, ID and blend weight
	vec3 region_uv = get_index_uv(uv2);
	const vec3 offsets = vec3(0, 1, 2);
	vec2 index_id = floor(uv);
	vec2 weight = fract(uv);
	vec2 invert = 1.0 - weight;
	vec4 weights = vec4(
		invert.x * weight.y, // 0
		weight.x * weight.y, // 1
		weight.x * invert.y, // 2
		invert.x * invert.y  // 3
	);

	ivec3 index[4];
	// control map lookups, used for some normal lookups as well
	index[0] = get_index_coord(index_id + offsets.xy, FRAGMENT_PASS);
	index[1] = get_index_coord(index_id + offsets.yy, FRAGMENT_PASS);
	index[2] = get_index_coord(index_id + offsets.yx, FRAGMENT_PASS);
	index[3] = get_index_coord(index_id + offsets.xx, FRAGMENT_PASS);
	
	vec3 base_ddx = dFdxCoarse(v_vertex);
	vec3 base_ddy = dFdyCoarse(v_vertex);
	// Calculate the effective mipmap for regionspace, and when less than 0,
	// skip all extra lookups required for bilinear blend.
	float region_mip = log2(max(length(base_ddx.xz), length(base_ddy.xz)) * _vertex_density);
	bool bilerp = region_mip < 0.0 && region_uv.z > -1.;

	// Terrain normals
	vec3 index_normal[4];
	float h[4];
	// Re-use index[] for the first lookups, skipping some math. 3 lookups
	h[3] = texelFetch(_height_maps, index[3], 0).r; // 0 (0,0)
	h[2] = texelFetch(_height_maps, index[2], 0).r; // 1 (1,0)
	h[0] = texelFetch(_height_maps, index[0], 0).r; // 2 (0,1)
	index_normal[3] = normalize(vec3(h[3] - h[2], _vertex_spacing, h[3] - h[0]));

	// Set flat world normal - overwritten if bilerp is true
	vec3 w_normal = index_normal[3];

	// Adjust derivatives for mipmap bias (WP: depth blur removed)
	base_ddx *= mipmap_bias;
	base_ddy *= mipmap_bias;

	// Color map. WP: the single textureLod is only needed when the 4-corner path does not replace it.
	vec4 color_map = COLOR_MAP_DEF;
	if (!bilerp) {
		color_map = region_uv.z > -1.0 ? textureLod(_color_maps, region_uv, region_mip) : COLOR_MAP_DEF;
	}

	// Branching smooth normals and manually interpolated color map - fixes cross region artifacts
	if (bilerp) {
		// 4 lookups if linear filtering, else 1 lookup.
		vec4 col_map[4];
		col_map[3] = index[3].z > -1 ? texelFetch(_color_maps, index[3], 0) : COLOR_MAP_DEF;
		#ifdef FILTER_LINEAR
		col_map[0] = index[0].z > -1 ? texelFetch(_color_maps, index[0], 0) : COLOR_MAP_DEF;
		col_map[1] = index[1].z > -1 ? texelFetch(_color_maps, index[1], 0) : COLOR_MAP_DEF;
		col_map[2] = index[2].z > -1 ? texelFetch(_color_maps, index[2], 0) : COLOR_MAP_DEF;

		color_map =
			col_map[0] * weights[0] +
			col_map[1] * weights[1] +
			col_map[2] * weights[2] +
			col_map[3] * weights[3] ;
		#else
		color_map = col_map[3];
		#endif

		// 5 lookups
		// Fetch the additional required height values for smooth normals
		h[1] = texelFetch(_height_maps, index[1], 0).r; // 3 (1,1)
		float h_4 = texelFetch(_height_maps, get_index_coord(index_id + offsets.yz, FRAGMENT_PASS), 0).r; // 4 (1,2)
		float h_5 = texelFetch(_height_maps, get_index_coord(index_id + offsets.zy, FRAGMENT_PASS), 0).r; // 5 (2,1)
		float h_6 = texelFetch(_height_maps, get_index_coord(index_id + offsets.zx, FRAGMENT_PASS), 0).r; // 6 (2,0)
		float h_7 = texelFetch(_height_maps, get_index_coord(index_id + offsets.xz, FRAGMENT_PASS), 0).r; // 7 (0,2)

		// Calculate the normal for the remaining index ids.
		index_normal[0] = normalize(vec3(h[0] - h[1], _vertex_spacing, h[0] - h_7));
		index_normal[1] = normalize(vec3(h[1] - h_5, _vertex_spacing, h[1] - h_4));
		index_normal[2] = normalize(vec3(h[2] - h_6, _vertex_spacing, h[2] - h[1]));

		// Set interpolated world normal
		w_normal =
			index_normal[0] * weights[0] +
			index_normal[1] * weights[1] +
			index_normal[2] * weights[2] +
			index_normal[3] * weights[3] ;
	}

	// Apply terrain normals
	if (flat_terrain_normals) {
		NORMAL = normalize(cross(dFdyCoarse(VERTEX),dFdxCoarse(VERTEX)));
		TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	} else {
		vec3 w_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
		vec3 w_binormal = normalize(cross(w_normal, w_tangent));
		NORMAL = mat3(VIEW_MATRIX) * w_normal;
		TANGENT = mat3(VIEW_MATRIX) * w_tangent;
		BINORMAL = mat3(VIEW_MATRIX) * w_binormal;
	}

	// Get index control data
	// 1 - 4 lookups
	uvec4 control = uvec4(floatBitsToUint(texelFetch(_control_maps, index[3], 0).r));
	if (bilerp) {
		control = uvec4(
		floatBitsToUint(texelFetch(_control_maps, index[0], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[1], 0).r),
		floatBitsToUint(texelFetch(_control_maps, index[2], 0).r),
		control[3]);
	}


	// Texture weights
	// Vectorised Deocode of all texture IDs, then swizzle to per index mapping.
	// Passed to accumulate_material to avoid repeated decoding.
	ivec4 t_id[2] = {ivec4(control >> uvec4(27u) & uvec4(0x1Fu)),
		ivec4(control >> uvec4(22u) & uvec4(0x1Fu))};
	ivec2 texture_ids[4] = ivec2[4](
		ivec2(t_id[0].x, t_id[1].x),
		ivec2(t_id[0].y, t_id[1].y),
		ivec2(t_id[0].z, t_id[1].z),
		ivec2(t_id[0].w, t_id[1].w));

	// uninterpolated weights.
	vec4 weights_id_1 = vec4(control >> uvec4(14u) & uvec4(0xFFu)) * DIV_255;
	vec4 weights_id_0 = 1.0 - weights_id_1;
	vec2 t_weights[4] = vec2[4](
				vec2(weights_id_0[0], weights_id_1[0]),
				vec2(weights_id_0[1], weights_id_1[1]),
				vec2(weights_id_0[2], weights_id_1[2]),
				vec2(weights_id_0[3], weights_id_1[3]));
	// interpolated weights
	#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
	if (bilerp) {
		t_weights = {vec2(0), vec2(0), vec2(0), vec2(0)};
		weights_id_0 *= weights;
		weights_id_1 *= weights;
		for (int i = 0; i < 4; i++) {
			vec2 w_0 = vec2(weights_id_0[i]);
			vec2 w_1 = vec2(weights_id_1[i]);
			ivec2 id_0 = texture_ids[i].xx;
			ivec2 id_1 = texture_ids[i].yy;
			t_weights[0] += fma(w_0, vec2(equal(texture_ids[0], id_0)), w_1 * vec2(equal(texture_ids[0], id_1)));
			t_weights[1] += fma(w_0, vec2(equal(texture_ids[1], id_0)), w_1 * vec2(equal(texture_ids[1], id_1)));
			t_weights[2] += fma(w_0, vec2(equal(texture_ids[2], id_0)), w_1 * vec2(equal(texture_ids[2], id_1)));
			t_weights[3] += fma(w_0, vec2(equal(texture_ids[3], id_0)), w_1 * vec2(equal(texture_ids[3], id_1)));
		}
	}
	#endif

	// WP: auto-paint rules, once per pixel. Slope from the terrain normal, height from the
	// vertex height. rule = (w_grass, w_sand, w_rock, highlight strength).
	float slope_deg = degrees(acos(clamp(w_normal.y, 0.0, 1.0)));
	float t_sand = rules_sand_enabled ? 1.0 - smoothstep(rules_sand_height_m - 0.2, rules_sand_height_m + 0.4, v_vertex.y) : 0.0;
	float t_rock = rules_rock_enabled ? smoothstep(rules_rock_slope_deg - 4.0, rules_rock_slope_deg + 4.0, slope_deg) : 0.0;
	vec4 rule = vec4((1.0 - t_sand) * (1.0 - t_rock), t_sand * (1.0 - t_rock), t_rock,
		rules_highlight ? max(t_sand, t_rock) : 0.0);

	// WP: preview mask from world XZ (no derivatives involved); full inside radius - feather.
	float pmask = 0.0;
	if (preview_enabled) {
		float pd = length(v_vertex.xz - preview_area.xy);
		pmask = 1.0 - smoothstep(preview_area.z - max(preview_area.w, 0.01), preview_area.z, pd);
	}

	// Struct to accumulate all texture data.
	material mat = material(vec4(0.0), vec4(0.0), 0., 0., 0., 0.);

	// 2 - 8 lookups per corner
	accumulate_material(base_ddx, base_ddy, weights[3], control[3], t_weights[3],
		texture_ids[3], index_normal[3], rule, pmask, mat);

	if (bilerp) {
		accumulate_material(base_ddx, base_ddy, weights[2], control[2], t_weights[2],
			texture_ids[2], index_normal[2], rule, pmask, mat);
		accumulate_material(base_ddx, base_ddy, weights[1], control[1], t_weights[1],
			texture_ids[1], index_normal[1], rule, pmask, mat);
		accumulate_material(base_ddx, base_ddy, weights[0], control[0], t_weights[0],
			texture_ids[0], index_normal[0], rule, pmask, mat);
	}

	// normalize accumulated values back to 0.0 - 1.0 range.
	float weight_inv = 1.0 / mat.total_weight;
	mat.albedo_height *= weight_inv;
	mat.normal_rough *= weight_inv;
	mat.normal_map_depth *= weight_inv;
	mat.ao_strength *= weight_inv;
	mat.highlight *= weight_inv;

	// Wetness/roughness modifier, converting 0 - 1 range to -1 to 1 range, clamped to Godot roughness values 
	// WP: colour map alpha is the tint weight, not a roughness modifier.
	float roughness = clamp(mat.normal_rough.a, 0., 1.);

	// WP: tint keeps texture detail (luminance relative to TINT_MEAN_LUM), mixed in by at most 60 %.
	vec3 albedo = mat.albedo_height.rgb;
	float albedo_lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	vec3 tinted = clamp(color_map.rgb * clamp(albedo_lum / TINT_MEAN_LUM, 0.3, 1.8), 0.0, 1.0);
	albedo = mix(albedo, tinted, 0.6 * color_map.a);
	albedo = mix(albedo, HIGHLIGHT_COLOR, 0.55 * mat.highlight);

	// WP: debug views replace the lit albedo by an emissive colour.
	vec3 emission = vec3(0.0);
	float grid_line = 0.0;
	if (debug_region_grid) {
		vec2 g = v_vertex.xz / (_region_size * _vertex_spacing);
		vec2 edge = abs(fract(g + 0.5) - 0.5);
		vec2 fw = max(fwidth(g), vec2(1e-6));
		grid_line = max(1.0 - smoothstep(0.0, 1.5 * fw.x, edge.x), 1.0 - smoothstep(0.0, 1.5 * fw.y, edge.y));
		albedo = mix(albedo, vec3(1.0, 0.15, 0.15), grid_line);
	}
	if (debug_view != 0) {
		vec3 dbg = vec3(0.0);
		if (debug_view == 1) {
			// Overlay weight as grey; auto-bit samples (rule-driven base) tinted blue.
			float blend_w = bilerp ? dot(weights_id_1, weights) : weights_id_1[3];
			float auto_w = bilerp ? dot(vec4(control & uvec4(1u)), weights) : float(control[3] & 1u);
			dbg = mix(vec3(blend_w), vec3(0.2 * blend_w, 0.5 * blend_w, 0.4 + 0.6 * blend_w), auto_w);
		} else if (debug_view == 2) {
			float t = clamp((v_vertex.y + 8.0) / 48.0, 0.0, 1.0);
			dbg = mix(vec3(0.1, 0.2, 0.6), vec3(0.2, 0.7, 0.3), smoothstep(0.0, 0.5, t));
			dbg = mix(dbg, vec3(0.95, 0.85, 0.5), smoothstep(0.5, 1.0, t));
		} else if (debug_view == 3) {
			dbg = normalize(w_normal) * 0.5 + 0.5;
		}
		emission = mix(dbg, vec3(1.0, 0.15, 0.15), grid_line);
		albedo = vec3(0.0);
	}

	// Apply PBR
	ALBEDO = albedo;
	EMISSION = emission;
	ROUGHNESS = roughness;
	SPECULAR = debug_view != 0 ? 0.0 : 1. - mat.normal_rough.a;
	// Repack final normal map value.
	NORMAL_MAP = fma(normalize(mat.normal_rough.xzy), vec3(0.5), vec3(0.5));
	NORMAL_MAP_DEPTH = mat.normal_map_depth;

	// Higher and/or facing up, less occluded.
	float ao = (1. - (mat.albedo_height.a * log(2.1 - mat.ao_strength))) * (1. - mat.normal_rough.y);
	AO = clamp(1. - ao * mat.ao_strength, mat.albedo_height.a, 1.0);
	AO_LIGHT_AFFECT = (1.0 - mat.albedo_height.a) * clamp(mat.normal_rough.y, 0., 1.);

}
