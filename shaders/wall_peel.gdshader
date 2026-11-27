shader_type spatial;
// Aged wallpaper that peels away to damaged plaster.
// World-space planar mapping (same convention as StandardMaterial3D triplanar),
// so every wall segment lines up with its neighbours without authored UVs.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D paper_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D paper_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D paper_roughness : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform sampler2D under_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D under_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D under_roughness : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform sampler2D peel_mask : filter_linear_mipmap, repeat_enable;

uniform vec3 paper_tint : source_color = vec3(1.0);
uniform vec3 under_tint : source_color = vec3(1.0);
uniform float paper_scale = 0.5;
uniform float under_scale = 0.4;
uniform float mask_scale = 0.09;
// Share of the wall where the paper has come away.
uniform float peel_amount : hint_range(0.0, 1.0) = 0.22;
// Strength of damp stains and water streaks.
uniform float damp : hint_range(0.0, 1.0) = 0.6;
uniform float floor_height = 0.45;
uniform float wall_height = 3.4;
uniform float normal_strength = 1.0;
// Pulls the paper toward its tint, for sets whose own pattern is too loud.
uniform float paper_flatten : hint_range(0.0, 1.0) = 0.4;

varying vec3 world_position;
varying vec3 axis_weight;

void vertex() {
	TANGENT = vec3(0.0, 0.0, -1.0) * abs(NORMAL.x);
	TANGENT += vec3(1.0, 0.0, 0.0) * abs(NORMAL.y);
	TANGENT += vec3(1.0, 0.0, 0.0) * abs(NORMAL.z);
	TANGENT = normalize(TANGENT);
	BINORMAL = vec3(0.0, 1.0, 0.0) * abs(NORMAL.x);
	BINORMAL += vec3(0.0, 0.0, -1.0) * abs(NORMAL.y);
	BINORMAL += vec3(0.0, 1.0, 0.0) * abs(NORMAL.z);
	BINORMAL = normalize(BINORMAL);
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	axis_weight = abs(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	// Pick the projection plane from the dominant axis (walls are axis aligned).
	vec3 flipped = world_position * vec3(1.0, -1.0, 1.0);
	float use_x = step(max(axis_weight.y, axis_weight.z), axis_weight.x);
	float use_y = (1.0 - use_x) * step(axis_weight.z, axis_weight.y);
	vec2 plane = mix(flipped.xy, flipped.zy * vec2(-1.0, 1.0), use_x);
	plane = mix(plane, flipped.xz, use_y);

	float height = clamp((world_position.y - floor_height) / wall_height, 0.0, 1.0);
	float blotch = texture(peel_mask, plane * mask_scale).r;
	float detail = texture(peel_mask, plane * mask_scale * 4.3 + vec2(0.37, 0.11)).r;
	float streak = texture(peel_mask, plane * vec2(1.9, 0.07) + vec2(0.5, 0.0)).r;

	// Paper lets go first under the ceiling and along the skirting.
	float bias = peel_amount + damp * (smoothstep(0.72, 1.0, height) * 0.22 + smoothstep(0.16, 0.0, height) * 0.12);
	float field = blotch * 0.72 + detail * 0.28;
	float edge = 1.0 - bias * 0.62;
	float peeled = smoothstep(edge - 0.015, edge + 0.015, field);
	float curl = smoothstep(edge - 0.07, edge - 0.01, field) * (1.0 - peeled);

	vec3 paper = texture(paper_albedo, plane * paper_scale).rgb * paper_tint;
	float stain = smoothstep(0.35, 0.8, streak) * smoothstep(0.25, 1.0, height) + smoothstep(0.55, 0.9, blotch) * 0.6;
	paper = mix(paper, paper_tint * 0.62, paper_flatten);
	paper *= mix(1.0, 0.45, clamp(stain, 0.0, 1.0) * damp);
	paper *= 1.0 - curl * 0.55;
	vec3 under = texture(under_albedo, plane * under_scale).rgb * under_tint;

	ALBEDO = mix(paper, under, peeled);
	ROUGHNESS = mix(texture(paper_roughness, plane * paper_scale).r, texture(under_roughness, plane * under_scale).r, peeled);
	SPECULAR = 0.3;
	NORMAL_MAP = mix(texture(paper_normal, plane * paper_scale).rgb, texture(under_normal, plane * under_scale).rgb, peeled);
	NORMAL_MAP_DEPTH = normal_strength;
}
