// Motes 0.1.0 (look thread, 28 Nov 2026; blind critique r1 row 6: "no shafts or motes"): marine snow, the particles that hang in
// every real water column and show the water as a volume (Blue Planet 2's sunlit reefs are full of them).
// Each instance is one particle at a fixed seed position inside a box around the eye (wrapped, so the box follows the eye and
// a particle never pops in front of it), sinking and drifting slowly. Real sizes: 0.5 mm .. 4 mm (power law, Alldredge & Silver
// 1988: marine snow is > 0.5 mm). A particle smaller than a pixel is drawn one pixel wide with its coverage as alpha, so its
// light on the screen is its real light, not a sparkle the size of a pixel.
// Lit by the water physics: the sun's beam at its depth (with the light net: a mote in a shaft line is bright, one in the gaps is
// dim), the water's fill from above and below, a 50/50 mix of a Lambertian sphere and a translucent forward lobe (HG g 0.6);
// albedo MOTE_ALB. Seen through the water: x exp(-c d) to the eye. Drawn after the underwater view (render_priority 1),
// additive, exposed as the view quad is (x water_exposure). Under water only.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

#include "res://look/water_physics.gdshaderinc"
#include "res://look/caustics.gdshaderinc"

uniform float box_m = 6.0;            // the box around the eye, m (particles beyond ~0.4 x box fade out)
uniform float mote_alb = 0.5;         // the particles' albedo (detritus aggregates, pale)
uniform float near_m = 0.12;          // closer than this they fade (they would fill the lens)
uniform vec3 drift = vec3(0.004, -0.0015, 0.002);   // m/s: a slow current and settling (marine snow sinks 1-3 mm/s .. 100 m/day)
varying vec4 v_col;

float hash(float n) { return fract(sin(n) * 43758.5453); }

void vertex() {
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	// the instance's seed: INSTANCE_CUSTOM.xyz in 0..1 (box), w = size seed
	vec3 seed = INSTANCE_CUSTOM.xyz;
	float id = float(INSTANCE_ID);
	vec3 wob = 0.01 * vec3(sin(TIME * 0.31 + id), sin(TIME * 0.23 + id * 1.7), sin(TIME * 0.27 + id * 2.3));
	vec3 p = seed * box_m + drift * TIME + wob;
	p = cam + (fract((p - cam) / box_m + 0.5) - 0.5) * box_m;   // wrapped into the box around the eye
	float size = 0.0005 * pow(max(INSTANCE_CUSTOM.w, 0.0156), -0.5);   // 0.5 mm .. 4 mm, a power law (most small)
	vec3 to = p - cam;
	float dist = length(to);
	float px = dist * 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);   // one pixel at that distance, m
	float drawn = max(size, 1.5 * px);
	float cover = (size * size) / (drawn * drawn);
	// billboard
	vec3 right = INV_VIEW_MATRIX[0].xyz, up = INV_VIEW_MATRIX[1].xyz;
	vec3 w = p + (VERTEX.x * right + VERTEX.y * up) * drawn;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(w, 1.0);
	// light (nits) at the particle, toward the eye
	float z = water_y - p.y;
	vec3 d = to / max(dist, 1e-4);
	vec3 col = vec3(0.0);
	if (z > 0.0 && cam.y < water_y) {
		float muw = max(water_sun_w.y, 0.05);
		float caus = caustic_net(p, z, water_sun_w, px, TIME);
		vec3 es = water_es0 * exp(-water_kd * z) / muw * caus;     // the beam, across it
		float H = max(water_y - water_floor_y, z + 0.05);
		vec3 ek = water_ek0 * exp(-water_ku * z);
		vec3 eu = (water_es0 * exp(-water_kd * H) + water_ek0 * exp(-water_ku * H)) * water_sand.rgb * exp(-water_ku * (H - z));
		float ca = clamp(dot(water_sun_w, -d), -1.0, 1.0);           // phase angle (sun, particle, eye)
		float al = acos(ca);
		float lam = 8.0 / (3.0 * PI) * (sin(al) + (PI - al) * ca) / (4.0 * PI);
		float g = 0.6; float ct = dot(water_sun_w, d);
		float hg = (1.0 - g * g) / (4.0 * PI * pow(1.0 + g * g - 2.0 * g * ct, 1.5));
		// a particle's radiance = albedo x irradiance x phase (1/sr); the fill, about uniform over each hemisphere, gives (Ek + Eu) / 2 pi
		col = mote_alb * (es * (0.5 * lam + 0.5 * hg) + (ek + eu) / (2.0 * PI));
		col *= exp(-(water_a + water_b) * dist) * water_exposure;
	}
	float fade = smoothstep(near_m, near_m * 2.0, dist) * (1.0 - smoothstep(0.3 * box_m, 0.45 * box_m, dist));
	v_col = vec4(col, cover * fade);
}
void fragment() {
	float r = length(UV - 0.5) * 2.0;
	float disc = 1.0 - smoothstep(0.6, 1.0, r);
	ALBEDO = v_col.rgb * v_col.a * disc * 1.47;   // 1.47 = (pi / 4) / the soft disc's mean over the quad (0.534): the total is the particle's disc
	ALPHA = 1.0;
}
