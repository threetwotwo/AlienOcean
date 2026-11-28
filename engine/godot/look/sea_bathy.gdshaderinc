// Sea floor beyond what is drawn 0.1.0 (water surface thread, 28 Nov 2026). Gary: "lagoon shot still looks off. needs
// a transition from lagoon to open water?" Past the drawn floor (the streamed cells, the test level's tiles) the sea
// used to read as open ocean right away (no floor = 10 km deep), so the lagoon ended at a hard edge. Now the floor
// beyond goes on as the lagoon's sand out to the reef, then falls away down the fore reef to the open ocean, and the
// water's colour follows it: turquoise over the sand, through blue, to the deep sea's own colour at the horizon.
// Depth along the fore reef is interpolated in log depth, so the colour change (mostly between 4 and 40 m) is spread
// over the slope instead of happening at its first metres. The far floor is the drawn floor's mean (water_floor_mean),
// or the drawn sand's colour (water_far_sand) before the first capture.
// Globals (WorldRoot.apply): water_bathy (lagoon centre x, z Godot, its radius to the reef m, the fore reef's width m;
// radius 0 = no edge: the lagoon goes on for ever), water_ocean_depth (m), water_far_sand (linear albedo).
global uniform vec4 water_bathy;
global uniform float water_ocean_depth;
global uniform vec3 water_far_sand;
global uniform vec4 water_floor_mean;   // the drawn floor's mean radiance in the floor map (nits; w 1 = valid; SeaFloorMap)

float sea_bathy_depth(vec2 xz) {        // m under the still surface, the floor beyond the drawn floor (Godot x, z)
	float H0 = max(water_y - water_floor_y, 0.5);
	if (water_bathy.z <= 0.0) return H0;
	float r = length(xz - water_bathy.xy);
	float t = smoothstep(water_bathy.z, water_bathy.z + max(water_bathy.w, 1.0), r);
	return H0 * pow(max(water_ocean_depth, H0) / H0, t);
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
