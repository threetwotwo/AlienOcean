// Seabed surface 0.1.0 (engine thread). For static world pieces whose COLOR_0 is paint (lagoon floor, rocks, corals, grass).
// Adds sun caustics in world space (two drifting cell layers, min-combined, sharpened) where the sun reaches the surface.
// Depth colour and distance murk come from the volumetric fog, not from here.
shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

uniform float roughness_base : hint_range(0.0, 1.0) = 0.92;
uniform float caustic_strength : hint_range(0.0, 4.0) = 1.4;
uniform float caustic_scale = 0.55;      // cells per metre
uniform float caustic_speed = 0.35;
uniform vec3 sun_dir_world = vec3(0.3, -0.9, 0.2);
varying vec3 wpos;
varying vec3 wnorm;

vec2 hash2(vec2 p) { p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3))); return fract(sin(p) * 43758.5453); }
float cells(vec2 p, float t) {
	vec2 i = floor(p), f = fract(p); float d = 8.0;
	for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
		vec2 g = vec2(float(x), float(y)); vec2 o = hash2(i + g);
		o = 0.5 + 0.5 * sin(t + 6.2831 * o);
		d = min(d, length(g + o - f));
	}
	return d;
}
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = roughness_base;
	// caustics: project along the sun direction onto the horizontal plane
	vec3 L = normalize(-sun_dir_world);
	vec2 p = (wpos.xz - wpos.y * L.xz / max(L.y, 0.2)) * caustic_scale;
	float t = TIME * caustic_speed;
	float c = min(cells(p, t), cells(p * 1.37 + 3.1, -t * 1.13));
	c = pow(1.0 - smoothstep(0.0, 0.55, c), 3.0);
	float facing = clamp(dot(wnorm, L), 0.0, 1.0);
	EMISSION = COLOR.rgb * c * caustic_strength * facing * 0.6;
}
