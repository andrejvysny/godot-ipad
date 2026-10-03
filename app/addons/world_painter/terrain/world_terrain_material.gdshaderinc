// App-owned material sampling; globals remain in world_terrain.gdshader.
// Base: Terrain3D 1.0.2-stable@0077405b, MIT (app/addons/terrain_3d/LICENSE.txt).
vec2 rotate_vec2(const vec2 v, const vec2 cs) {
	return vec2(fma(cs.x, v.x,  cs.y * v.y), fma(cs.x, v.y, -cs.y * v.x));
}

// WP: samples one material slot (control rotation only; detiling removed). The low-tier sample
// decides the blend height (alb.a); inside the preview area its RGB and normal/roughness are mixed
// toward the preview layer using the same UV and gradients (explicit, so the area-dependent branch
// cannot break derivatives).
void sample_slot(const int id, const vec2 i_uv, const vec4 i_dd, const vec2 c_cs_angle, const mat2 p_align, const float pmask,
			const bool sample_normal, out vec4 alb, out vec4 nrm) {
	float id_scale = _texture_uv_scale_array[id];
	vec4 id_dd = i_dd * id_scale;
	vec2 id_uv = fma(i_uv, vec2(id_scale), vec2(-0.5));
	id_dd.xy = rotate_vec2(id_dd.xy, c_cs_angle);
	id_dd.zw = rotate_vec2(id_dd.zw, c_cs_angle);
	alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
	nrm = vec4(0.5, 0.5, 1.0, 1.0);
	if (sample_normal) {
		nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw);
	}
	if (pmask > 0.0 && id < 4 && preview_layer[id] >= 0) {
		vec3 puv = vec3(id_uv, float(preview_layer[id]));
		vec4 p_alb = textureGrad(preview_albedo_array, puv, id_dd.xy, id_dd.zw);
		vec4 p_nrm = textureGrad(preview_normal_array, puv, id_dd.xy, id_dd.zw);
		alb.rgb = mix(alb.rgb, p_alb.rgb, pmask);
		nrm = mix(nrm, p_nrm, pmask);
	}
	alb.rgb *= _texture_color_array[id].rgb;
	nrm.a = clamp(nrm.a + _texture_roughness_mod_array[id], 0., 1.);
	nrm.xyz = fma(nrm.xzy, vec3(2.0), vec3(-1.0));
	nrm.xz = rotate_vec2(nrm.xz, c_cs_angle) * p_align;
}

// 2-4 lookups per corner (+2 per previewed slot inside the preview area)
void accumulate_material(const vec3 base_ddx, const vec3 base_ddy, const float weight,
			const uint control, const vec2 texture_weight, const ivec2 texture_id, const vec3 i_normal,
			const vec4 rule, const float pmask, inout material mat) { // WP: rule = (w_grass, w_sand, w_rock, highlight)

	// Projection on steep slopes; the preview samples with the same projected UVs and gradients.
	vec2 i_uv = v_vertex.xz;
	vec4 i_dd = vec4(base_ddx.xz, base_ddy.xz);
	mat2 p_align = mat2(1.);
	if (i_normal.y <= projection_threshold && enable_projection) {
		p_align = mat2(vec2(i_normal.z, -i_normal.x), vec2(i_normal.x, i_normal.z));
		vec2 xz = round(normalize(-i_normal.xz) * 1.3065629648763765);
		xz *= abs(xz.x) + abs(xz.y) > 1.5 ? 0.7071067811865475 : 1.0;
		xz = vec2(-xz.y, xz.x);
		i_uv = vec2(dot(v_vertex.xz, xz), -v_vertex.y);
		i_dd.xy = vec2(dot(base_ddx.xz, xz), -base_ddx.y);
		i_dd.zw = vec2(dot(base_ddy.xz, xz), -base_ddy.y);
	}

	// Control map scale
	float control_scale = DECODE_SCALE(control);
	i_dd *= control_scale;
	i_uv *= control_scale;

	// Control map rotation.
	float c_angle = DECODE_ANGLE(control);
	vec2 c_cs_angle = vec2(cos(c_angle), sin(c_angle));
	i_uv = rotate_vec2(i_uv, c_cs_angle);

	// Blend adjustment of Higher ID from Lower ID normal map in world space.
	float world_normal = 1.;
	vec3 T = normalize(base_ddx), B = -normalize(base_ddy);
	// mat3 multiply, reduced to 2x fma and 1x mult.
	#define FAST_WORLD_NORMAL(n) fma(T, vec3(n.x), fma(B, vec3(n.z), i_normal * vec3(n.y)))

	float blend = DECODE_BLEND(control); // only used for branching.
	float sharpness = fma(56., blend_sharpness, 8.);


	// 1st Texture Asset ID
	// WP: auto corners use the per-pixel rule material instead of the stored base id.
	bool is_auto = DECODE_AUTO(control);
	// WP: the base normal changes overlay blend weight, so it cannot be replaced there.
	bool has_overlay = blend > 0.0 && (texture_id[1] != texture_id[0] || is_auto);
	bool lighting_normals = !terrain_overview_experiment || pmask > 0.0;
	bool base_normals = lighting_normals || has_overlay;
	if (blend < 1.0
			) {
		int id = texture_id[0];
		float id_w = texture_weight[0];
		vec4 alb = vec4(0.0);
		vec4 nrm = vec4(0.0);
		float id_depth = 0.0;
		float id_ao = 0.0;
		if (is_auto) {
			// WP: weights are zero for unused rule slots; skip their lookups.
			if (rule.x > 0.0) {
				vec4 a; vec4 n;
				sample_slot(SLOT_GRASS, i_uv, i_dd, c_cs_angle, p_align, pmask, base_normals, a, n);
				alb += a * rule.x; nrm += n * rule.x;
				id_depth += _texture_normal_depth_array[SLOT_GRASS] * rule.x;
				id_ao += _texture_ao_strength_array[SLOT_GRASS] * rule.x;
			}
			if (rule.y > 0.0) {
				vec4 a; vec4 n;
				sample_slot(SLOT_SAND, i_uv, i_dd, c_cs_angle, p_align, pmask, base_normals, a, n);
				alb += a * rule.y; nrm += n * rule.y;
				id_depth += _texture_normal_depth_array[SLOT_SAND] * rule.y;
				id_ao += _texture_ao_strength_array[SLOT_SAND] * rule.y;
			}
			if (rule.z > 0.0) {
				vec4 a; vec4 n;
				sample_slot(SLOT_ROCK, i_uv, i_dd, c_cs_angle, p_align, pmask, base_normals, a, n);
				alb += a * rule.z; nrm += n * rule.z;
				id_depth += _texture_normal_depth_array[SLOT_ROCK] * rule.z;
				id_ao += _texture_ao_strength_array[SLOT_ROCK] * rule.z;
			}
		} else {
			sample_slot(id, i_uv, i_dd, c_cs_angle, p_align, pmask, base_normals, alb, nrm);
			id_depth = _texture_normal_depth_array[id];
			id_ao = _texture_ao_strength_array[id];
		}

		world_normal = FAST_WORLD_NORMAL(nrm).y;

		float id_weight = exp2(sharpness * log2(weight + id_w + alb.a)) * weight;
		mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
		mat.normal_rough = fma(nrm, vec4(id_weight), mat.normal_rough);
		mat.normal_map_depth = fma(id_depth, id_weight, mat.normal_map_depth);
		mat.ao_strength = fma(id_ao, id_weight, mat.ao_strength);
		mat.total_weight += id_weight;
		if (is_auto) {
			mat.highlight += rule.w * id_weight;
		}
	}

	// 2nd Texture Asset ID
	if (has_overlay) { // WP: overlay always applies over the rule material
		int id = texture_id[1];
		float id_w = texture_weight[1];
		vec4 alb; vec4 nrm;
		sample_slot(id, i_uv, i_dd, c_cs_angle, p_align, pmask, lighting_normals, alb, nrm);

		float id_weight = exp2(sharpness * log2(weight + id_w + alb.a * clamp(world_normal, 0., 1.))) * weight;
		mat.albedo_height = fma(alb, vec4(id_weight), mat.albedo_height);
		mat.normal_rough = fma(nrm, vec4(id_weight), mat.normal_rough);
		mat.normal_map_depth = fma(_texture_normal_depth_array[id], id_weight, mat.normal_map_depth);
		mat.ao_strength = fma(_texture_ao_strength_array[id], id_weight, mat.ao_strength);
		mat.total_weight += id_weight;
	}
}
