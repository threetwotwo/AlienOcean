// Sea spray 0.2.0 (water surface thread, 28 Nov 2026): the open sea's wind spray, made to show and to read as its
// Beaufort force. 0.1.0 was a faithful port of the open-water tank's last wind spray (the sprite kit's M_OO_Spray,
// openocean_tank_v374.py: KIT_CELL + SPRAY_VS_BODY lines 9127-9230, SPRAY_PS_BODY_TEX lines 11153-11302, v39's spray
// lit as v10/v34), and it could not be seen: held shots with it on and off differed by 0 pixels at forces 6, 9 and
// 12. The tank itself had switched its spray off (kit_on False since v66, SPRAY_LIVE False since v186), so there is
// no later tank tuning to keep, and this version tunes it by eye against the Beaufort scale's own words (6 "some
// spray", 8 "edges of crests break into spindrift", 10-12 "air filled with foam and spray").
//   Kept from the tank: the launch logic whole (KIT_CELL: every quad of the sprite mesh is worked out from its world
//   cell, its slot and the time, nothing simulated or stored; a slot is thrown when the sea breaks at its fixed spawn
//   point, the foam map's break clock .b read at one texel, and flies its whole arc inside its 10 s epoch (v9) with
//   linear air drag in closed form, its height kept over the water under it now), the rates (BRK_RATE 0.55 / 1.75),
//   the drops' and wisps' flights, the fade near the lens, never thinner than a pixel (grown and dimmed by its
//   area), the streak cap 1.8 x, the puff pictures and their erosion with age, the six soft drops in a mottled veil,
//   nothing drawn while the eye is under the water.
//   Changed from the tank, and why:
//   - A third kind of sprite, the PLUME (slots 6-11): a streak of fine spray 0.5-5 m long torn off a breaking crest
//     and carried downwind at 0.6 U, rising as it goes, on cells of 4 m, so it reaches 128 m from the eye (the foam
//     map is 400 m). The tank's sprites all lived within 48 m, and from an eye 2 m + Hs over a sea whose waves are
//     100-300 m long that is the bottom edge of the picture. From 8 m/s, full at 17 m/s; bigger and denser with the
//     wind (B6 small thin puffs, B8 streaks of spindrift, B10-12 a layer of flying spray).
//   - The light is the foam's (look/sea_foam_shade.gdshaderinc sea_foam_top_nits: the full beam on a level face plus
//     the sky's five looks, albedo 0.9 / pi), not a quarter of the beam (LIGHT_STANDIN sun_share 0.25): spray a
//     quarter as bright as the foam under it showed as nothing over white water and as grey over blue. The forward
//     glow keeps the tank's strength (a quarter of the beam x the capped phase).
//   - The wisps of spume (slots 4-5): alpha MIST_A 0.05 -> 0.2-0.4 with the wind. The drop clusters (slots 0-3):
//     0.15-0.45 m (v39: 0.08-0.25), drops 2-6 mm (1-3), the veil 0.5 (0.32): at 960 x 540 a 2 mm drop 10 m off is a
//     170th of a pixel's area.
//   Changes for Godot (as 0.1.0): Unreal's Depth Fade read the scene's depth behind the sprite; the sea seen from
//   above is a transparent pass here, so the fade is worked out from the pixel's height over the water under its
//   sprite, along the view. A pixel's angle (Kit.z) comes from the projection. The sun's colour is the foam's.
//   Left out (as 0.1.0): SPLASH_VS_BODY, SPR_STEP_HLSL, SPRAYP_*, CROWN_*, M_OO_Bubbles, NIGHT_PC_HLSL.
//   The low haze of spray over a storm sea is look/sea_spray_haze.gdshader (a screen pass, analytic).
// Cost: 64 x 64 x 12 quads (196,608 vertices), each one hash chain and up to four foam map reads; a thrown one six reads of
//   the displacement and the sky's five looks more. Blended quads, most a few pixels; the plumes overdraw.
// Frames: island (x east, y north, z up) = Godot (x, -z, y). Values in nits x exposure.
shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform, depth_draw_never, fog_disabled, shadows_disabled, blend_mix;
#include "res://look/sky_dome.gdshaderinc"
global uniform sampler2DArray sea_disp : filter_linear_mipmap, repeat_enable;
global uniform sampler2D sea_foam : filter_nearest, repeat_disable;
global uniform vec4 sea_foam_org;
global uniform vec4 sea_patch;
global uniform vec4 sea_wind;
global uniform float sea_on;
global uniform float water_y;
global uniform vec3 water_sun_air;
global uniform float water_sun_lux;
global uniform float water_exposure;
uniform sampler2D spume : filter_linear_mipmap, repeat_disable;   // T_OO_Spume: 4 x 4 puffs, R = density
uniform vec4 kit = vec4(0.0, 0.016667, 0.0, 0.0);    // the tank's Kit: the sea's clock s, frame time s
uniform vec4 sea_k = vec4(0.35, 1.8, 3.0, 8.0);      // the tank's SeaK: -, Hs m, breaking speed m/s, wind m/s
uniform vec4 spray = vec4(1.0, 1.0, 1.0, 1.0);       // the tank's Spray: amount, -, sprite size, -
uniform float glow_share = 0.25;                     // the forward glow's share of the beam (the tank's LIGHT_STANDIN)
const float KCELL = 1.5;          // SPRAY_CELL m (drops and wisps)
const float KCELL_FAR = 4.0;      // the plumes' cell m: 64 cells reach 128 m
const float EPOCH = 10.0;         // BRK_EPOCH s
const float KRD = 0.55;           // BRK_RATE drops
const float KRM = 1.75;           // BRK_RATE spume
const float FOAM_N = 1024.0;
const float FADE_M = 1.5;         // SPUME_FADE_CM
const float SEA_CURVE_M = 2.0e5;
varying vec4 info;                // corner xy, cover (- for the puff pictures: spume and plumes), 1 = a plume
varying vec4 aux;                 // height over the water m, distance m, the drops' radius in corner units, age / life
varying flat float seed;          // the tank's Info.w
varying float hgt;                // this corner's height over the water under the sprite, m
varying flat vec3 e_day;          // the foam's light: the beam on a level face plus the sky, lux

uint pcg(uint h) {
	h = h * 747796405u + 2891336453u;
	h ^= h >> 16u;
	h *= 2246822519u;
	h ^= h >> 13u;
	h *= 3266489917u;
	h ^= h >> 16u;
	return h;
}

vec4 r4(uint a, uint b) {
	return vec4(float(a & 0xFFFFu), float(a >> 16u), float(b & 0xFFFFu), float(b >> 16u)) / 65535.0;
}

// KIT_SURFACE: the water's height (m over the still level) under island point x: two steps back through the
// sideways push of cascades 0-2
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

void vertex() {
	// KIT_CELL: what this vertex is, from where it is in the mesh
	vec3 lp = vec3(VERTEX.x, -VERTEX.z, VERTEX.y);
	vec2 home = round(lp.xy);
	vec2 corner = sign(lp.xy - home);
	float slot = round(lp.z * 10.0);
	vec3 camg = CAMERA_POSITION_WORLD;
	vec3 cam = vec3(camg.x, -camg.z, camg.y - water_y);          // island, z over the still level
	// the kinds: slots 0-3 clusters of drops, 4-5 wisps of spume, 6-11 plumes of fine spray (on bigger cells)
	float mist = slot > 3.5 ? 1.0 : 0.0;       // drawn from the puff pictures
	float plume = slot > 5.5 ? 1.0 : 0.0;
	float KC = plume > 0.5 ? KCELL_FAR : KCELL;
	vec2 cell = floor(cam.xy / KC) + home;
	vec3 world = vec3(cell * KC, 0.0);                        // folded onto a point unless drawn
	info = vec4(corner, 0.0, 0.0);
	aux = vec4(0.0);
	seed = 0.0;
	hgt = 0.0;
	e_day = vec3(0.0);
	uvec2 hc = uvec2(ivec2(cell) + 65536);
	float U = sea_k.w;
	vec2 wd = sea_wind.xy;

	float camUp = cam.z > 0.0 ? 1.0 : 0.0;
	if (abs(cam.z) < 1.2 * sea_k.y + 1.0) camUp = cam.z > kit_surface(cam.xy) ? 1.0 : 0.0;
	float sf = clamp((U - 8.0) / 14.0, 0.0, 1.0);   // how hard it blows: 0.3 at force 6, 0.8 at 8, 1 from 9.5
	// v9: v8's share of slots in use, scaled so about as much spray shows at a time as in v8 (each puff now shows its
	// whole flight): drops x 0.55 up to 8 m/s, rising to x1 at 20 m/s; spume x 1.75 (its long flights often miss their epoch)
	float rate = spray.x * (plume > 0.5 ? KRM * clamp((U - 8.0) / 9.0, 0.0, 1.0) : mist > 0.5 ? KRM * clamp((U - 9.0) / 10.0, 0.0, 1.0)
		: mix(KRD, 1.0, clamp((U - 8.0) / 12.0, 0.0, 1.0)) * clamp((U - 3.0) / 8.0, 0.0, 1.0));
	uint h0 = pcg((hc.x * 1597334677u) ^ (hc.y * 3812015801u) ^ (uint(slot) * 2798796415u));
	float T = plume > 0.5 ? 2.5 + 2.5 * float(h0 & 0xFFFFu) / 65535.0 : mist > 0.5 ? 2.0 + 2.0 * float(h0 & 0xFFFFu) / 65535.0 : 1.0 + 1.2 * float(h0 & 0xFFFFu) / 65535.0;
	uint hA = pcg(h0 + 1013904223u);
	uint hB = pcg(hA + 1013904223u);
	vec4 r0 = r4(hA, hB);
	// v9: the slot's spawn point, its share of the slots in use and its launch delay are its own for good; its flight
	// is drawn from its epoch (10 s, its own phase), which the whole flight must fit inside
	vec2 P0 = (cell + r0.xy) * KC;
	vec2 P1 = (cell + fract(r0.xy + vec2(0.5, 0.31))) * KC;
	vec2 P2 = (cell + fract(r0.yx + vec2(0.27, 0.77))) * KC;
	vec2 P3 = (cell + fract(r0.yx + vec2(0.73, 0.19))) * KC;
	float ph = float(h0 >> 16u) / 65535.0;
	float ep = floor(kit.x / EPOCH + ph);
	float te = (ep - ph) * EPOCH;
	uint h1 = pcg(h0 ^ (uint(ep) * 2654435761u));
	uint h2 = pcg(h1 + 1013904223u);
	uint h3 = pcg(h2 + 1013904223u);
	uint h4 = pcg(h3 + 1013904223u);
	uint h5 = pcg(h4 + 1013904223u);
	uint h6 = pcg(h5 + 1013904223u);
	vec4 r1 = r4(h1, h2);
	vec4 r2 = r4(h3, h4);
	vec4 r3 = r4(h5, h6);

	float life = T * (mist > 0.5 ? 0.7 + 0.3 * r1.w : 0.45 + 0.5 * r1.w);
	// 0.2.0: a slot has four spawn points in its cell, not one, and is thrown from the first of them (in a fixed
	// order) where the sea broke less than its life ago: four times the spray off the same breaking sea for the
	// same mesh (at force 6 the sea breaks on a third of a percent of its face each second)
	if (camUp > 0.5 && sea_on > 0.5 && sea_foam_org.w > 0.5 && r0.z < rate) {
		float age = -1.0;
		for (int k = 0; k < 4; k++) {
			vec2 Pk = k == 0 ? P0 : (k == 1 ? P1 : (k == 2 ? P2 : P3));
			vec2 fu = (Pk - sea_foam_org.xy) / sea_foam_org.z + 0.5;
			if (fu.x > 0.0 && fu.y > 0.0 && fu.x < 1.0 && fu.y < 1.0) {
				// v9: thrown when the sea breaks at its spawn point: its age is the break clock there (one texel, never
				// a blend of two clocks) less its delay
				float ak = textureLod(sea_foam, (floor(fu * FOAM_N) + 0.5) / FOAM_N, 0.0).b - 0.15 * r0.w;
				if (ak > 0.0 && ak < life) {
					age = ak;
					P0 = Pk;
					break;
				}
			}
		}
		float tb = kit.x - age;
		if (age > 0.0 && age < life && tb >= te && tb + life <= te + EPOCH) {
			vec2 wn = vec2(-wd.y, wd.x);
			// the plume: fine spray picked up by the wind in 0.4 s and carried at 0.6 U, lofted by the gusts
			float tau = plume > 0.5 ? 0.4 : mist > 0.5 ? 0.005 : mix(0.15, 0.7, r2.x);
			vec3 va = plume > 0.5 ? vec3(wd * 0.6 * U, mix(0.1, 0.4, r2.x) * (0.5 + U / 20.0)) : vec3(wd * 0.7 * U, -9.81 * tau);
			float up = plume > 0.5 ? 0.5 : mist > 0.5 ? 0.3 : mix(0.8, 3.5, r2.y) * clamp(0.3 + U / 12.0, 0.0, 1.0);
			vec3 v0 = vec3(wd * sea_k.z * mix(0.6, 1.1, r2.z) + wn * (r2.w - 0.5) * 2.0, up);
			float e = 1.0 - exp(-age / tau);
			vec3 p = vec3(P0, 0.0) + va * age + (v0 - va) * (tau * e);
			vec3 vel = va + (v0 - va) * (1.0 - e);
			// its height over the water under it now (it rides over the crest it came off; spume rises in the wind)
			float hz = (plume > 0.5 ? 0.2 : mist > 0.5 ? 0.1 + 0.15 * age : 0.05 + 0.25 * r3.x) + p.z;     // v34: spume stays low
			if (hz > 0.0) {
				vec2 cv = p.xy - cam.xy;
				float zs = kit_surface(p.xy) - dot(cv, cv) / (2.0 * SEA_CURVE_M);
				vec3 c3 = vec3(p.xy, zs + hz);
				vec3 kw = c3 - cam;
				float dist = max(length(kw), 0.01);
				kw = normalize(kw);
				vec3 rx = cross(vec3(0.0, 0.0, 1.0), kw);
				rx = dot(rx, rx) > 1e-6 ? normalize(rx) : vec3(1.0, 0.0, 0.0);
				vec3 ry = cross(kw, rx);
				float R = (plume > 0.5 ? mix(0.4, 1.3, sqrt(age / life)) * mix(0.7, 1.4, r3.y) * mix(0.6, 1.5, sf)
					: mist > 0.5 ? mix(0.25, 0.7, sqrt(age / life)) * mix(0.7, 1.3, r3.y) : mix(0.15, 0.45, r3.y)) * spray.z;
				float a = (plume > 0.5 ? mix(0.4, 0.55, sf) : mist > 0.5 ? mix(0.2, 0.4, sf) : 0.9)
					* clamp(age / (plume > 0.5 ? 0.25 : 0.08), 0.0, 1.0) * clamp((life - age) / ((plume > 0.5 ? 0.5 : 0.35) * life), 0.0, 1.0);
				// v9: drops fade as they sink over their own size
				a *= mist > 0.5 ? clamp(hz / 0.3, 0.0, 1.0) : clamp(hz / max(R, 0.03), 0.0, 1.0);
				a *= 1.0 - smoothstep(0.7, 0.95, length(c3.xy - cam.xy) / (32.0 * KC));
				// nothing right by the lens (v3: a cluster a hand's width away filled the frame, sharp, like glass), and
				// no cluster covering more than about 3 degrees of the view (v6)
				// (a plume goes before it is a fifth of the view long)
				a *= plume > 0.5 ? smoothstep(2.0, 8.0, dist) : smoothstep(1.0, 3.0, dist);
				a *= plume > 0.5 ? 1.0 - smoothstep(0.04, 0.1, R / dist)
					: mist > 0.5 ? 1.0 - smoothstep(0.03, 0.08, R / dist) : 1.0 - smoothstep(0.02, 0.05, R / dist);
				float pix = 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);   // a pixel's angle, rad (Kit.z)
				float Rm = pix * dist * 1.2;
				if (R < Rm) {
					a *= (R / Rm) * (R / Rm);
					R = Rm;
				}
				float sx = R;
				if (mist < 0.5) {
					vec3 vp = vel - kw * dot(vel, kw);
					float vl = length(vp);
					if (vl > 0.05) {
						rx = vp / vl;
						ry = cross(kw, rx);
						// drawn out along its motion over one frame: at most 1.8 x its size (v6), and dimmer by how far
						sx = min(R + 0.5 * vl * kit.y, 1.8 * R);
						a *= R / sx;
					}
				} else {
					vec3 wv = vec3(wd, 0.0);
					vec3 vp = wv - kw * dot(wv, kw);
					float vl = length(vp);
					if (vl > 0.2) {
						rx = vp / vl;
						ry = cross(kw, rx);
						sx = R * mix(1.0, plume > 0.5 ? 4.0 : 2.5, clamp((vl - 0.2) / 0.5, 0.0, 1.0));     // v39: drawn out along the wind
					}
				}
				world = c3 + corner.x * sx * rx + corner.y * R * (plume > 0.5 ? 0.45 : mist > 0.5 ? 0.6 : 1.0) * ry;   // v34: thin wisps
				info = vec4(corner, mist > 0.5 ? -a : a, plume);
				seed = r3.z;
				// the drops' own radius (1-3 mm) in the quad's corner units
				aux = vec4(hz, dist, mix(0.002, 0.006, r3.w) / R, clamp(age / life, 0.0, 1.0));     // v10: .w its age / life
				hgt = world.z - zs;
				// the foam's light (sea_foam_shade.gdshaderinc sf_daylight): the beam on a level face plus the sky's
				// light on it, five looks at the dome, cosine weighted
				vec3 e = 0.36 * sky_dome_nits(vec3(0.0, 1.0, 0.0));
				e += 0.16 * (sky_dome_nits(vec3(0.5793, 0.5736, 0.5793)) + sky_dome_nits(vec3(-0.5793, 0.5736, 0.5793))
					+ sky_dome_nits(vec3(0.5793, 0.5736, -0.5793)) + sky_dome_nits(vec3(-0.5793, 0.5736, -0.5793)));
				e_day = vec3(1.0, 0.97, 0.9) * water_sun_lux * max(normalize(water_sun_air).y, 0.0) + PI * e;
			}
		}
	}
	vec3 wg = vec3(world.x, world.z + water_y, -world.y);
	VERTEX = (VIEW_MATRIX * vec4(wg, 1.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	vec2 uv = info.xy;
	float a = abs(info.z);
	if (a < 1e-4) discard;
	vec3 w = -(INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz;          // from the eye to the pixel (Godot)
	vec3 Ld = normalize(water_sun_air);
	vec3 Es = vec3(1.0, 0.97, 0.9) * water_sun_lux * step(0.0, water_sun_air.y) * glow_share;   // the glow's beam
	float cs = dot(Ld, w);
	float gg = info.z < 0.0 ? 0.6 : 0.75;
	float ph = (1.0 - gg * gg) / (12.566 * pow(max(1.0 + gg * gg - 2.0 * gg * cs, 1e-4), 1.5));
	float lf = aux.w;
	float px = max(max(length(dFdx(uv)), length(dFdy(uv))), 1e-4);
	float cov = 0.0;
	// v39: one of sixteen puff pictures (T_OO_Spume: 4 x 4 tiles, R = density, 0 at the tile's edge), picked and
	// flipped by the slot's seed; its thin parts erode as it ages, so it breaks up into shreds as it flies
	float sd = fract(seed * 16.0);
	float ti = floor(seed * 16.0);
	vec2 tuv = vec2(sd < 0.5 ? uv.x : -uv.x, uv.y) * 0.5 + 0.5;
	vec2 auv = (vec2(mod(ti, 4.0), floor(ti / 4.0)) + clamp(tuv, 0.0, 1.0)) * 0.25;
	float tex = textureLod(spume, auv, log2(max(px * 128.0, 1.0))).r;   // its mip from the quad's size on screen
	float er = (info.w > 0.5 ? 0.25 : 0.1) + 0.55 * lf;     // the plumes start as shreds
	float puff = tex * clamp((tex - er) / max(1.0 - er, 0.05), 0.0, 1.0) * 1.3;
	if (info.z < 0.0) {
		cov = puff;
	} else {
		uint h = uint(seed * 65535.0) * 747796405u + 2891336453u;
		for (int k = 0; k < 6; k++) {
			h ^= h >> 16u;
			h *= 2246822519u;
			h ^= h >> 13u;
			h *= 3266489917u;
			h ^= h >> 16u;
			vec2 c = (vec2(float(h & 0xFFu), float((h >> 8u) & 0xFFu)) / 255.0 * 2.0 - 1.0) * 0.6;
			float rd = aux.z * mix(0.5, 1.5, float(h >> 24u) / 255.0);
			// a soft round dot (a drop is a tiny lens: bright in the middle, no hard rim; v3's hard discs read as
			// glass), never thinner than a pixel (grown and dimmed by its area)
			float re = max(rd, 0.8 * px);
			float dd = length(uv - c) / re;
			cov += exp(-1.5 * dd * dd) * (rd / re) * (rd / re);
			h = h * 747796405u + 2891336453u;
		}
		// and the drops too fine to see one by one round them. 0.2.0: the veil is the cluster's own puff picture (the
		// tank's v6 veil was a round mottled patch, and at 0.5 it read as a soft disc, like bokeh)
		cov += 0.5 * puff;
	}
	// v10: lit like the foam it comes off (a matte cloud in the foam's light: 0.2.0 the foam's own light, see the
	// header), with a forward glow capped at 0.3 / sr (drops) or 1 / sr x 0.6 (spume, v34); thick parts with the sun
	// behind them a little greyer (the cloud shades itself)
	float shade = 1.0 - 0.18 * clamp(1.5 * cov, 0.0, 1.0) * clamp(0.5 - 0.5 * cs, 0.0, 1.0);
	vec3 C = (e_day * (0.9 * 0.3183) + Es * (info.z < 0.0 ? min(ph, 1.0) * 0.6 : min(ph, 0.3))) * shade;
	// Unreal's Depth Fade (150 cm of scene depth behind the pixel), from the pixel's height over the water under its
	// sprite along the view (see the header)
	float fade = clamp(hgt / (max(abs(w.y), 0.05) * FADE_M), 0.0, 1.0);
	ALBEDO = C * water_exposure;
	ALPHA = a * clamp(cov, 0.0, 1.0) * fade;
}
