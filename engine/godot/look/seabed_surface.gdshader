// Seabed surface 0.3.0 (engine thread). Static world pieces whose COLOR_0 is paint (floor, rocks, corals, grass).
// Lit by the ported lagoon water physics (look/water_optics.gd globals): the sun's beam loses exp(-Kd z) on its
// way down (the key light arrives pre-attenuated to water_zref; this corrects to the pixel's own depth), the
// sky's diffuse light exp(-Ku z) from above, and the sand's upwelling from below, as in under_model.py.
// Caustics modulate the sun's beam only (as the Unreal light function did), mean ~1.
shader_type spatial;
render_mode blend_mix, cull_back, diffuse_lambert, specular_disabled, ambient_light_disabled;

global uniform float water_y;
global uniform float water_floor_y;
global uniform vec3 water_kd;
global uniform vec3 water_ku;
global uniform vec3 water_sun_w;
global uniform float water_es0;
global uniform float water_ek0;
global uniform float water_zref;
global uniform vec4 water_sand;

// Better sand colour lock (SD2, Gary-approved design 14 Nov; passed in Unreal: #cbc8c2 vs lock #cdcac4): bare sand takes the
// locked colour, darker sorted sand #c8c4bb in the paint's darker patches. Floor pieces only (sand_lock 1).
uniform float sand_lock : hint_range(0.0, 1.0) = 0.0;
uniform vec3 sand_c : source_color = vec3(0.804, 0.792, 0.769);    // #cdcac4
uniform vec3 sand_d : source_color = vec3(0.784, 0.769, 0.733);    // #c8c4bb
uniform float roughness_base : hint_range(0.0, 1.0) = 0.92;
uniform float caustic_strength : hint_range(0.0, 2.0) = 1.0;
uniform float caustic_scale = 0.55;      // cells per metre
uniform float caustic_speed = 0.35;
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
	if (sand_lock > 0.0) {
		float pm = clamp(dot(COLOR.rgb, vec3(0.2126, 0.7152, 0.0722)) / 0.30, 0.0, 1.0);   // the paint's own light/dark patches
		ALBEDO = mix(COLOR.rgb, mix(sand_d, sand_c, smoothstep(0.6, 1.0, pm)), sand_lock);
	}
	ROUGHNESS = roughness_base;
	float z = max(water_y - wpos.y, 0.0);
	float H = max(water_y - water_floor_y, 0.05);
	vec3 ek = water_ek0 * exp(-water_ku * z);
	vec3 eh = water_es0 * exp(-water_kd * H) + water_ek0 * exp(-water_ku * H);
	vec3 eu = eh * water_sand.rgb * exp(-water_ku * max(H - z, 0.0));
	float up = 0.5 + 0.5 * wnorm.y;
	EMISSION = ALBEDO * (ek * up + eu * (1.0 - up)) / PI;   // nits; Godot applies the exposure
}
void light() {
	float z = max(water_y - wpos.y, 0.0);
	vec3 corr = exp(-water_kd * (z - water_zref));
	vec3 L = water_sun_w;
	vec2 p = (wpos.xz + z * L.xz / max(L.y, 0.2)) * caustic_scale;
	float t = TIME * caustic_speed;
	float c = min(cells(p, t), cells(p * 1.37 + 3.1, -t * 1.13));
	c = pow(1.0 - smoothstep(0.0, 0.55, c), 3.0);
	float caus = mix(1.0, 0.55 + 2.6 * c, caustic_strength);   // c averages ~0.17: mean stays ~1
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI * corr * caus;
}
