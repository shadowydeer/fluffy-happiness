shader_type spatial;
// Repaints the cab of the CC0 truck model.
// The model is coloured from a small palette atlas: saturated texels are body
// paint, grey / dark texels are bumper, glass, tyres and trim. Body paint is
// swapped for a weathered PBR paint set (world-space triplanar) so the cab
// matches the cargo body; everything else keeps its atlas colour under a film of road grime.
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D paint_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D paint_roughness : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform sampler2D grime : filter_linear_mipmap, repeat_enable;
uniform vec3 paint_tint : source_color = vec3(0.8);
uniform float paint_scale = 0.55;
uniform float paint_metallic = 0.25;
uniform float paint_roughness_scale = 0.75;

varying vec3 world_position;
varying vec3 world_normal;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

vec3 triplanar(sampler2D map, vec3 p, vec3 n) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= (w.x + w.y + w.z);
	return texture(map, p.zy).rgb * w.x + texture(map, p.xz).rgb * w.y + texture(map, p.xy).rgb * w.z;
}

void fragment() {
	vec3 base = texture(atlas, UV).rgb;
	float high = max(base.r, max(base.g, base.b));
	float low = min(base.r, min(base.g, base.b));
	float saturation = (high - low) / max(high, 0.001);
	float painted = smoothstep(0.22, 0.4, saturation) * smoothstep(0.1, 0.25, high);

	vec3 n = normalize(world_normal);
	vec3 paint = triplanar(paint_albedo, world_position * paint_scale, n) * paint_tint;
	float paint_rough = triplanar(paint_roughness, world_position * paint_scale, n).r * paint_roughness_scale;
	float dirt = triplanar(grime, world_position * 0.3, n).r;
	// Grime gathers low on the body.
	float splash = smoothstep(1.3, 0.2, world_position.y);
	vec3 trim = base * mix(0.5, 1.0, dirt) * mix(1.0, 0.7, splash);

	// Near-black texels are glazing and tyres: glossy for the glass, the tyres read the same in the dark.
	float glossy = 1.0 - smoothstep(0.04, 0.14, high);
	ALBEDO = mix(trim, paint * mix(1.0, 0.8, splash), painted);
	ROUGHNESS = mix(mix(0.7, 0.14, glossy), paint_rough, painted);
	METALLIC = paint_metallic * painted;
	SPECULAR = 0.5;
}
