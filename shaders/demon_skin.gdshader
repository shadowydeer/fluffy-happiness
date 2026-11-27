shader_type spatial;
// Charred, wet-looking hide for the skinned demon.
// The model's painted texture supplies the anatomy (ribs, skull, tendons) as a darkened,
// desaturated base; a tiling charred-bark set adds pore-level normal and roughness detail;
// molten veins and the painted ember areas (eyes, claws, chest sigil) glow with its mood.
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D paint_map : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D detail_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_roughness : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform sampler2D vein_map : source_color, filter_linear_mipmap, repeat_enable;

uniform vec3 soot_color : source_color = vec3(0.04, 0.032, 0.03);
uniform vec3 ash_color : source_color = vec3(0.27, 0.2, 0.16);
// How much of the painted hue survives the charring.
uniform float paint_keep : hint_range(0.0, 1.0) = 0.2;
uniform float detail_scale = 7.0;
uniform float normal_strength = 1.1;
uniform float wetness : hint_range(0.0, 1.0) = 0.55;
uniform vec3 rim_color : source_color = vec3(0.6, 0.1, 0.02);
uniform float rim_energy = 0.35;
uniform float rim_power = 3.2;
uniform vec3 ember_color : source_color = vec3(1.0, 0.36, 0.06);
uniform float vein_scale = 3.0;
// Veins across the chest and back, veins everywhere else, and the painted ember areas.
uniform float core_energy = 0.6;
uniform float limb_energy = 0.0;
uniform float paint_energy = 1.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
// Mesh space to chest-bone space in metres: the vein mask rides the ribcage.
uniform mat4 chest_from_model;
uniform vec3 chest_center = vec3(0.0);
uniform float chest_radius = 0.45;
// While the taser has hold of it: a thin, hard electric-cyan Fresnel edge and veins that
// crackle on and off in patches. Nothing is added to the face of the hide, so its dark
// texture, horns and features stay readable under the current.
uniform vec3 shock_color : source_color = vec3(0.1, 0.82, 1.0);
uniform float shock = 0.0;
uniform float shock_time = 0.0;
uniform float shock_rim_energy = 2.6;
uniform float shock_vein_energy = 1.7;
// Shadow lunge: the hide drinks the light for a moment.
uniform float shade : hint_range(0.0, 1.0) = 0.0;

varying vec3 chest_position;

void vertex() {
	chest_position = (chest_from_model * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 paint = texture(paint_map, UV).rgb;
	float value = dot(paint, vec3(0.299, 0.587, 0.114));
	vec2 detail_uv = UV * detail_scale;
	float grain = dot(texture(detail_albedo, detail_uv).rgb, vec3(0.333));

	// Painted ember: saturated orange or red that is also bright.
	float hot = max(paint.r - max(paint.g, paint.b) * 1.15, 0.0);
	float painted = smoothstep(0.16, 0.5, hot) * smoothstep(0.3, 0.7, paint.r);

	vec3 base = mix(soot_color, ash_color, smoothstep(0.05, 0.85, value));
	base = mix(base, base * (paint / max(value, 0.05)), paint_keep);
	base *= mix(0.55, 1.35, grain);
	ALBEDO = base * (1.0 - 0.6 * painted) * (1.0 - 0.85 * shade);

	NORMAL_MAP = texture(detail_normal, detail_uv).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	float rough = texture(detail_roughness, detail_uv).r;
	ROUGHNESS = clamp(mix(0.95, 0.28, wetness) + (rough - 0.5) * 0.5 - value * 0.15, 0.12, 1.0);
	SPECULAR = 0.55;
	METALLIC = 0.0;
	// A thin wet film, so a torch beam picks out ribs and tendons.
	CLEARCOAT = wetness * 0.4;
	CLEARCOAT_ROUGHNESS = 0.3;
	RIM = 0.22;
	RIM_TINT = 0.6;

	float chest = 1.0 - smoothstep(chest_radius * 0.55, chest_radius, distance(chest_position, chest_center));
	vec3 veins = texture(vein_map, UV * vein_scale).rgb;
	vec3 glow = veins * (chest * core_energy * (0.65 + 0.35 * pulse) + limb_energy);
	glow += ember_color * painted * paint_energy * (0.7 + 0.3 * pulse);
	float grazing = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(grazing, rim_power);
	// Crisp band at the silhouette only: zero across the faces turned toward the camera.
	float shock_edge = smoothstep(0.66, 0.9, grazing);
	// Veins flicker in cells that re-roll two dozen times a second.
	vec2 cell = floor(UV * vein_scale * 5.0);
	float roll = fract(sin(dot(cell + floor(shock_time * 24.0), vec2(12.9898, 78.233))) * 43758.5453);
	float crackle = step(0.5, roll) * smoothstep(0.3, 0.7, max(veins.r, max(veins.g, veins.b)));
	vec3 current = shock_color * shock * (shock_edge * shock_rim_energy + crackle * shock_vein_energy);
	EMISSION = (glow + rim_color * fresnel * rim_energy) * (1.0 - shade) + current;
}
