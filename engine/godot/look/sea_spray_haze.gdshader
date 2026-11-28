// Sea spray haze 0.1.0 (water surface thread, 28 Nov 2026): the low haze of spray over a storm sea. New here: the
// open-water tank had none (its spray was sprites only, and switched off since v66). The Beaufort scale's words are
// the target: force 10 "visibility affected", force 12 "the air is filled with foam and spray, visibility very
// seriously affected".
// What it is: a layer of fine spray whose density falls with height over the still sea, sigma exp(-z / H) (sigma and
// H from adapters/godot/sea_spray.gd: the wind and Hs), streaked along the wind where the view meets the sea near
// the eye. One screen quad drawn after the sea's top side and before the spray's sprites; each pixel works out the
// spray along its view ray in closed form, from the eye to the still sea's plane (or to whatever opaque thing the
// depth picture holds nearer, or 6 km of air for a ray over the horizon), and lays the haze over the picture by
// that much. Lit like the foam (look/sea_foam_shade.gdshaderinc sf_daylight: the beam on a level face plus the
// sky's five looks, albedo 0.8 / pi) with the sprites' forward glow toward the sun.
// Cost: one blended screen pass, per pixel one depth read, four exp and (within 400 m) eight hashes; the light is
// worked out at the quad's four corners. It is not drawn at all under about 15 m/s of wind (the node is hidden),
// nor while the eye is under the water (the quad is folded off the screen).
// Not right: the ray ends at the still sea's plane, not at the wave it meets, so a near crest gets the haze of the
// trough behind it; the sprites are drawn over the haze, so a far plume is not softened by it.
// Frames: island (x east, y north, z up) = Godot (x, -z, y). Values in nits x exposure.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled, blend_mix;
#include "res://look/sky_dome.gdshaderinc"
global uniform sampler2DArray sea_disp : filter_linear_mipmap, repeat_enable;
global uniform vec4 sea_patch;
global uniform vec4 sea_wind;
global uniform float sea_on;
global uniform float water_y;
global uniform vec3 water_sun_air;
global uniform float water_sun_lux;
global uniform float water_exposure;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec4 haze = vec4(0.0, 6.0, 8.0, 30.0);   // extinction at the still level 1/m, scale height m, Hs m, wind m/s
uniform float clock = 0.0;                       // the sea's clock s (the streaks ride the wind)
uniform float glow_share = 0.25;                 // the forward glow's share of the beam (as the sprites')
const float REACH_M = 6000.0;
varying flat vec3 e_day;
varying flat float eye_z;

// the water's height under island point x (look/sea_spray.gdshader kit_surface)
float kit_surface(vec2 x) {
	if (sea_on < 0.5) return 0.0;
	vec2 sx = x;
	vec3 sd = vec3(0.0);
	for (int it = 0; it < 2; it++) {
		sd = vec3(0.0);
		for (int c = 0; c < 3; c++) {
			float L = c == 0 ? sea_patch.x : (c == 1 ? sea_patch.y : sea_patch.z);
			sd += textureLod(sea_disp, vec3(sx / L, float(c)), 0.0).xyz;
		}
		sx = x - sd.xy;
	}
	return sd.z;
}

float hash2(vec2 p) {
	uvec2 q = uvec2(ivec2(floor(p)) + 32768);
	uint h = (q.x * 1597334677u) ^ (q.y * 3812015801u);
	h = h * 747796405u + 2891336453u;
	h ^= h >> 16u;
	h *= 2246822519u;
	h ^= h >> 13u;
	return float(h & 0xFFFFu) / 65535.0;
}
float vnoise(vec2 p) {
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(p), hash2(p + vec2(1.0, 0.0)), f.x), mix(hash2(p + vec2(0.0, 1.0)), hash2(p + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	vec3 camg = CAMERA_POSITION_WORLD;
	vec3 cam = vec3(camg.x, -camg.z, camg.y - water_y);
	float up = cam.z > 0.0 ? 1.0 : 0.0;
	if (abs(cam.z) < 1.2 * haze.z + 1.0) up = cam.z > kit_surface(cam.xy) ? 1.0 : 0.0;
	eye_z = cam.z;
	vec3 e = 0.36 * sky_dome_nits(vec3(0.0, 1.0, 0.0));
	e += 0.16 * (sky_dome_nits(vec3(0.5793, 0.5736, 0.5793)) + sky_dome_nits(vec3(-0.5793, 0.5736, 0.5793))
		+ sky_dome_nits(vec3(0.5793, 0.5736, -0.5793)) + sky_dome_nits(vec3(-0.5793, 0.5736, -0.5793)));
	e_day = vec3(1.0, 0.97, 0.9) * water_sun_lux * max(normalize(water_sun_air).y, 0.0) + PI * e;
	// nothing above the water is drawn while the eye is under it: the quad goes off the screen
	POSITION = up > 0.5 && haze.x > 0.0 ? vec4(VERTEX.xy * 2.0, 1.0, 1.0) : vec4(2.0, 2.0, 2.0, 1.0);
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, max(depth, 1e-6), 1.0);
	vp.xyz /= vp.w;
	vec3 dg = normalize((INV_VIEW_MATRIX * vec4(vp.xyz, 0.0)).xyz);
	vec3 d = vec3(dg.x, -dg.z, dg.y);                       // island
	float z0 = max(eye_z, 0.0);
	float H = max(haze.y, 0.5);
	float L = min(length(vp.xyz), REACH_M);
	float hit = 0.0;
	if (d.z < -1e-4 && z0 / -d.z < L) {
		L = z0 / -d.z;
		hit = 1.0;
	}
	// the spray along the ray: sigma exp(-(z0 + d.z s) / H) summed over s = 0..L
	float k = d.z * L / H;
	float f = abs(k) < 1e-3 ? 1.0 - 0.5 * k : (1.0 - exp(-k)) / k;
	float tau = haze.x * exp(-z0 / H) * L * f;
	// streaks of thicker spray along the wind, riding it, where the view meets the sea near the eye
	if (hit > 0.5 && L < 400.0) {
		vec2 x = CAMERA_POSITION_WORLD.xz * vec2(1.0, -1.0) + d.xy * L;
		vec2 wd = sea_wind.xy;
		vec2 q = vec2(dot(x, wd) - 0.6 * haze.w * clock, dot(x, vec2(-wd.y, wd.x)));
		float n = 0.65 * vnoise(q / vec2(90.0, 11.0)) + 0.35 * vnoise(q / vec2(37.0, 4.3) + 17.0);
		tau *= mix(1.0, 0.45 + 1.1 * n, 1.0 - smoothstep(150.0, 400.0, L));
	}
	vec3 Ld = normalize(water_sun_air);
	vec3 Es = vec3(1.0, 0.97, 0.9) * water_sun_lux * step(0.0, water_sun_air.y) * glow_share;
	float cs = dot(Ld, dg);
	float ph = (1.0 - 0.36) / (12.566 * pow(max(1.36 - 1.2 * cs, 1e-4), 1.5));
	ALBEDO = (e_day * (0.8 * 0.3183) + Es * min(ph, 1.0) * 0.6) * water_exposure;
	ALPHA = 1.0 - exp(-tau);
}
