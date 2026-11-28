// The sun under water at a lit point 0.1.0 (look thread, 28 Nov 2026): one copy for every surface the sun lights under water
// (seabed, ground, creatures). The key light arrives pre-attenuated to water_zref (WorldRoot); this corrects its beam to the point's
// own depth (exp(-Kd (z - z_ref))) and lays the light net on it (look/caustics.gdshaderinc, Unreal lagoonwater v98: mean ~1, by
// depth, slid by the refracted sun). Needs water_physics.gdshaderinc and caustics.gdshaderinc included first.
// the size of a screen pixel on a surface at wpos, m (the net's reader widens its taps over it)
float sun_under_pixel_m(vec3 wpos, mat4 inv_view, mat4 proj, vec2 viewport) {
	return length(wpos - inv_view[3].xyz) * 2.0 / (abs(proj[1][1]) * viewport.y);
}
vec3 sun_under(vec3 wpos, float pixel_m, float time_s, float net_k) {
	float z = max(water_y - wpos.y, 0.0);
	vec3 corr = exp(-water_kd * (z - water_zref));
	return corr * caustic_sun(wpos, water_y - wpos.y, water_sun_w, pixel_m, time_s, net_k);
}
