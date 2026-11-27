shader_type spatial;
// Small billboarded candle flame: teardrop shape, hot core, lazy flicker.
// The quad is expected to be 1 x 1 with its origin at the bottom centre.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec3 core_color : source_color = vec3(1.0, 0.93, 0.70);
uniform vec3 outer_color : source_color = vec3(1.0, 0.45, 0.08);
uniform float intensity = 3.0;
uniform float flicker_speed = 7.0;

varying float seed;

void vertex() {
	// One random phase per flame, taken from where it stands.
	vec3 origin = MODEL_MATRIX[3].xyz;
	seed = fract(sin(dot(origin, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	float sway = sin(TIME * flicker_speed * 0.6 + seed * 31.0) * 0.5 + sin(TIME * flicker_speed * 1.7 + seed * 17.0) * 0.5;
	// Cylindrical billboard: face the camera but stay upright.
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	vec3 to_camera = normalize((INV_VIEW_MATRIX[3].xyz - origin) * vec3(1.0, 0.0, 1.0) + vec3(0.0, 0.0, 0.0001));
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), to_camera));
	vec3 local = VERTEX;
	// The tip leans with the draught, the base stays on the wick.
	local.x += sway * 0.012 * (1.0 - UV.y);
	local.y *= 1.0 + 0.08 * sin(TIME * flicker_speed * 2.3 + seed * 9.0);
	vec3 world = origin + right * local.x * scale.x + vec3(0.0, 1.0, 0.0) * local.y * scale.y;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
}

void fragment() {
	vec2 p = vec2(UV.x - 0.5, 1.0 - UV.y);
	// Teardrop: wide near the wick, pinched at the tip.
	float width = mix(0.30, 0.02, pow(p.y, 0.8)) * smoothstep(0.0, 0.14, p.y + 0.03);
	float body = 1.0 - smoothstep(width * 0.55, width, abs(p.x));
	body *= smoothstep(1.0, 0.82, p.y);
	float core = (1.0 - smoothstep(0.0, width * 0.6, abs(p.x))) * smoothstep(0.75, 0.1, p.y);
	float pulse = 0.85 + 0.15 * sin(TIME * flicker_speed * 1.3 + seed * 23.0);
	vec3 color = mix(outer_color, core_color, core);
	// Cool blue base, like a real wick.
	color = mix(color, vec3(0.25, 0.4, 1.0), smoothstep(0.12, 0.0, p.y) * 0.6);
	ALBEDO = color * intensity * pulse;
	ALPHA = clamp(body, 0.0, 1.0);
}
