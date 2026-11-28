// Sea floor map, read (water surface thread, 28 Nov 2026): what lies under the sea round the eye, from
// adapters/godot/sea_floor_map.gd (radiance in nits and top height, seen from above). Shared by the surface's underside
// (look/sea_under.gdshader: the mirror's floor) and its top (look/sea_top.gdshader: the floor a grazing view sees through
// the water). Include after sea_bathy.gdshaderinc. (look/underwater_view declares water_floor_height itself.)
global uniform sampler2D water_floor_albedo : filter_linear;
global uniform sampler2D water_floor_height : filter_linear;
global uniform vec4 water_floor_org;   // centre x, centre z (Godot), size m, 1 = valid (adapters/godot/sea_floor_map.gd)

vec2 floor_uv(vec2 xy) {             // island xy -> the floor map (screen right = Godot +x, up = Godot -z)
	return vec2(xy.x - water_floor_org.x, -xy.y - water_floor_org.y) / water_floor_org.z + 0.5;
}
float floor_top(vec2 xy) {            // island z of the floor's top (the still floor outside the map)
	vec2 uv = floor_uv(xy);
	float far_y = water_y - sea_bathy_depth(vec2(xy.x, -xy.y));   // past the map: the floor beyond (sea_bathy)
	if (water_floor_org.w < 0.5) return far_y;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return far_y;
	vec4 h = textureLod(water_floor_height, uv, 0.0);
	return h.a > 0.5 ? h.r / max(h.g, 1e-4) : far_y;
}
vec3 floor_light(vec2 xy) {          // the floor's radiance seen from above (nits), or -1 where the map has nothing
	if (water_floor_org.w < 0.5) return vec3(-1.0);
	vec2 uv = floor_uv(xy);
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return vec3(-1.0);
	// FloorNet (v75-v76, Style: the net's lines and the sand's grain are grain in the ceiling): the mirror reads the floor
	// averaged over about 1 m (a 3 x 3 tent of 2-texel steps), so rocks, grass and sand read as forms, not noise
	vec3 sum = vec3(0.0); float wsum = 0.0;
	float st = 2.0 / 512.0;
	for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
		float w = (2.0 - abs(float(i))) * (2.0 - abs(float(j)));
		vec4 a = textureLod(water_floor_albedo, uv + vec2(float(i), float(j)) * st, 0.0);
		if (a.a > 0.5) { sum += w * a.rgb; wsum += w; }
	}
	return wsum > 4.0 ? sum / wsum : vec3(-1.0);
}

