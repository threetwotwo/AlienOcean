// Ported lagoon water physics (under_model.py / lagoonwater PHYS_CODE + UNDER_PHYS). Shared by every water shader.
global uniform float water_y;
global uniform float water_floor_y;
global uniform vec3 water_a;
global uniform vec3 water_b;
global uniform vec3 water_kd;
global uniform vec3 water_ku;
global uniform vec3 water_sun_w;
global uniform float water_es0;
global uniform float water_ek0;
global uniform float water_exposure;
global uniform float water_glow_k;
global uniform float water_glow_ms;  // 1 = forward scattering kept on the ray (similarity relation), 0 = all scattering lost (as ported)
global uniform vec4 water_sand;
global uniform vec3 water_amb_ref;   // the scene's ambient colour (env ambient / exposure, nits): the fill's reference (WorldRoot)
global uniform float water_fill_ao;  // 1 = the water's fill goes through Godot's ambient path (SSAO, SSIL, AO occlude it), 0 = emission
const float W_G = 0.9;

vec3 w_G(vec3 k, float L) {
	k = mix(k, k + 2e-4, step(abs(k), vec3(1e-4)));
	return (1.0 - exp(-clamp(k * L, -60.0, 60.0))) / k;
}
// in-scattered light (nits) along a ray from depth z0 (m under the surface), direction d (y up), length L
vec3 w_glow(vec3 d, float z0, float L) {
	// the haze's own loss: light scattered forward (HG g = W_G) stays on the ray, so the glow builds up to b J / (a + b (1 - g))
	// (the similarity relation), not b J / (a + b) (28 Nov: the far water read navy, the underside's mirror with it)
	vec3 c = water_a + water_b * mix(1.0, 1.0 - W_G, water_glow_ms);
	// the floor the sand's bounce comes from is never above the ray's deepest point: past the lagoon floor (open water, a drop-off)
	// a downward ray would otherwise integrate an upwelling that grows exp(+Ku) without end: the white void (test level, 28 Nov)
	float H = max(water_y - water_floor_y, z0 + max(-d.y, 0.0) * L + 0.05);
	float muw = max(water_sun_w.y, 0.05);
	vec3 Es = water_es0 * exp(-water_kd * z0) / muw;
	vec3 Ek = water_ek0 * exp(-water_ku * z0);
	vec3 EH = water_es0 * exp(-water_kd * H) + water_ek0 * exp(-water_ku * H);
	vec3 Eu = EH * water_sand.rgb * exp(-water_ku * (H - z0));
	float ct = dot(d, water_sun_w);
	float ph = (1.0 - W_G * W_G) / (4.0 * PI * pow(1.0 + W_G * W_G - 2.0 * W_G * ct, 1.5));
	float pw = 0.548 * W_G / 0.9;
	float Wd = clamp(0.5 + pw * (-d.y) / (abs(d.y) + 0.118), 0.0, 1.0);
	return water_glow_k * water_b * (Es * ph * w_G(c - water_kd * d.y, L)
		+ (Ek * w_G(c - water_ku * d.y, L) * (1.0 - Wd) + Eu * w_G(c + water_ku * d.y, L) * Wd) / PI);
}
// the floor plane seen along a downward ray that meets no geometry (past the drawn floor): the distance to it (m, or -1 when the ray
// does not go down) and its radiance in nits (sand lit by the water's light at that depth, as the drawn sand is)
float w_floor_dist(vec3 d, float z0) {
	float H = max(water_y - water_floor_y, z0 + 0.05);
	return d.y < -1e-3 ? (H - z0) / (-d.y) : -1.0;
}
vec3 w_floor_nits() {
	float H = max(water_y - water_floor_y, 0.05);
	return (water_es0 * exp(-water_kd * H) + water_ek0 * exp(-water_ku * H)) * water_sand.rgb / PI;
}
// irradiance on the flat sand (lux per band)
vec3 w_EH() {
	float H = max(water_y - water_floor_y, 0.05);
	return water_es0 * exp(-water_kd * H) + water_ek0 * exp(-water_ku * H);
}

// the water's diffuse light on a surface at depth z (m under the surface) whose normal points up by `up` (0.5 + 0.5 n.y), in nits per
// unit albedo: sky from above exp(-Ku z), the sand's bounce from below (as under_model.py); seabed_surface and ground_surface
vec3 w_fill(float z, float up) {
	float H = max(water_y - water_floor_y, 0.05);
	vec3 ek = water_ek0 * exp(-water_ku * z);
	vec3 eh = water_es0 * exp(-water_kd * H) + water_ek0 * exp(-water_ku * H);
	vec3 eu = eh * water_sand.rgb * exp(-water_ku * max(H - z, 0.0));
	return (ek * up + eu * (1.0 - up)) / PI;
}
// Godot's ambient is one colour (water_amb_ref), so the fill's own colour and depth ride in the albedo as a ratio; the direct light
// divides it back out (light()), so the sun and the net are unchanged while SSAO / SSIL / AO now occlude the fill
// Under water with SDFGI on, Godot's ambient is the water's light field at water_zref (look/sky.gdshader under_*), already w_fill(z_ref, up) for
// this normal, so only the depth's own change rides in the albedo (a ratio near 1). Root cause it stands in for: Godot's sky light
// is one field for the whole scene, with no water between it and a point deeper or shallower than z_ref.
global uniform float water_amb_sky;
global uniform float water_zref;
vec3 w_fill_ratio(float z, float up) {
	if (water_amb_sky > 0.5) return w_fill(z, up) / max(w_fill(water_zref, up), vec3(1e-9));
	return w_fill(z, up) / max(water_amb_ref, vec3(1e-9));
}
