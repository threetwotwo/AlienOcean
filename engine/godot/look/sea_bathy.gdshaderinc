// Sea floor beyond what is drawn 0.2.0 (water surface thread, 28 Nov 2026). Gary: "lagoon shot still looks off. needs
// a transition from lagoon to open water?" Past the drawn floor (the streamed cells, the test level's tiles) the sea
// used to read as open ocean right away (no floor = 10 km deep), so the lagoon ended at a hard edge. Now the floor
// beyond goes on as the lagoon's sand out to the reef, then falls away down the fore reef to the open ocean, and the
// water's colour follows it: turquoise over the sand, through blue, to the deep sea's own colour at the horizon.
// 0.2.0: the shape is core/world/bathymetry.gd's (lagoon, back reef, reef flat, the wall, the fore-reef slope, the
// deep), which the drop-off's drawn seabed (adapters/godot/reef_terrain.gd) is built from too. The far floor is the drawn floor's mean (water_floor_mean),
// or the drawn sand's colour (water_far_sand) before the first capture.
// Globals (WorldRoot.apply): water_bathy (lagoon centre x, z Godot, its radius to the reef flat m, sector 0's angle rad; radius 0 = no
// reef: the lagoon goes on for ever), water_ocean_depth (m), water_far_sand (linear albedo).
global uniform vec4 water_bathy;
global uniform float water_ocean_depth;
global uniform vec3 water_far_sand;
global uniform vec4 water_floor_mean;   // the drawn floor's mean radiance in the floor map (nits; w 1 = valid; SeaFloorMap)

// core/world/bathymetry.gd depth(), wall_m(), pass_w(), line for line (0.3.0: the stress-test sectors; keep the two the same)
float sea_bathy_ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float sea_bathy_wall_m(float th) {      // the sector's wall run (m): 86, 60, 30, 10 deg, 45 deg + the pass; water_bathy.w = sector 0's angle
	const float WM[5] = float[5](3.0, 25.0, 75.0, 245.0, 43.0);
	float a = mod((th - water_bathy.w) / 6.2831853 * 5.0, 5.0);
	int k = int(floor(a)) % 5;
	float w = sea_bathy_ss(0.3, 0.7, a - floor(a));
	return exp(mix(log(WM[k]), log(WM[(k + 1) % 5]), w));
}
float sea_bathy_pass_w(float th, float R) {
	const float PASS_W = 25.0;
	float m = water_bathy.w + 6.2831853 * 4.0 / 5.0;
	float dth = abs(mod(th - m + 3.14159265, 6.2831853) - 3.14159265);
	return 1.0 - sea_bathy_ss(PASS_W * 0.5, PASS_W * 0.5 + 8.0, dth * R);
}
float sea_bathy_depth(vec2 xz) {        // m under the still surface, the floor beyond the drawn floor (Godot x, z)
	const float BACK_M = 30.0, REEF_FLAT_D = 1.2, FLAT_M = 25.0, WALL_D = 30.0, SLOPE_D = 150.0, PASS_D = 6.0;
	const float SLOPE_M = 220.0, DEEP_M = 900.0, SPUR_M = 14.0, SPUR_OUT = 4.0, SPUR_D = 2.5;
	float H0 = max(water_y - water_floor_y, 0.5);
	float R = water_bathy.z;
	if (R <= 0.0) return H0;
	vec2 d = xz - water_bathy.xy;
	float r = length(d);
	float th = atan(d.y, d.x);
	float rr = R * (1.0 + 0.06 * sin(3.0 * th + 0.7) + 0.03 * sin(8.0 * th + 2.1));
	float n = round(6.2831853 * R / SPUR_M);
	float g = 0.5 + 0.5 * sin(n * th + 1.8 * sin(5.0 * th) + 0.9 * sin(13.0 * th));
	float s = r - rr;
	float wm = sea_bathy_wall_m(th);
	float pw = sea_bathy_pass_w(th, R);
	float fd = mix(REEF_FLAT_D, PASS_D, pw);
	g *= 1.0 - pw;
	float crest = FLAT_M + SPUR_OUT * g;
	float h = H0 + (fd - H0) * sea_bathy_ss(-BACK_M, 0.0, s);
	if (s > crest) {
		float u = s - crest;
		h = fd + (WALL_D - fd) * sea_bathy_ss(0.0, wm, u);
		float sm = SLOPE_M + 2.0 * wm;
		h += (SLOPE_D - WALL_D) * sea_bathy_ss(wm * 0.6, wm + sm, u);
		float w = clamp((u - wm - sm) / DEEP_M, 0.0, 1.0);
		if (w > 0.0) h = SLOPE_D * pow(max(water_ocean_depth, SLOPE_D) / SLOPE_D, w * w * (3.0 - 2.0 * w));
		h += SPUR_D * (1.0 - g) * sea_bathy_ss(0.0, 4.0, u) * (1.0 - sea_bathy_ss(wm, wm + 60.0, u)) * (1.0 - pw);
	}
	return h;
}
// the still far floor's radiance seen from just above it (nits): sun and sky through the water to depth H (no net: the
// net averages to its mean). Where the floor map has the drawn floor, its mean radiance carried from the lagoon's depth
// to H, so the drawn floor and the floor beyond meet without a seam; else the sand's albedo / pi.
vec3 sea_bathy_sand(float H) {
	vec3 Eh = water_es0 * exp(-water_kd * H) + water_ek0 * exp(-water_ku * H);
	if (water_floor_mean.w > 0.5) {
		float H0 = max(water_y - water_floor_y, 0.5);
		vec3 E0 = water_es0 * exp(-water_kd * H0) + water_ek0 * exp(-water_ku * H0);
		return water_floor_mean.rgb * Eh / max(E0, vec3(1e-6));
	}
	return Eh * water_far_sand / PI;
}
