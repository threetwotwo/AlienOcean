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
global uniform vec4 water_sand;
const float W_G = 0.9;

vec3 w_G(vec3 k, float L) {
	k = mix(k, k + 2e-4, step(abs(k), vec3(1e-4)));
	return (1.0 - exp(-clamp(k * L, -60.0, 60.0))) / k;
}
// in-scattered light (nits) along a ray from depth z0 (m under the surface), direction d (y up), length L
vec3 w_glow(vec3 d, float z0, float L) {
	vec3 c = water_a + water_b;
	float H = max(water_y - water_floor_y, z0 + 0.05);
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
// irradiance on the flat sand (lux per band)
vec3 w_EH() {
	float H = max(water_y - water_floor_y, 0.05);
	return water_es0 * exp(-water_kd * H) + water_ek0 * exp(-water_ku * H);
}
