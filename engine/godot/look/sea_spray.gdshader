// Sea spray 0.1.0 (water surface thread, 28 Nov 2026): the open-water tank's spray and spume (the sprite kit's
// M_OO_Spray), ported from openocean_tank_v374.py as it was last assembled:
//   vertex()   = KIT_CELL + SPRAY_VS_BODY (v374 lines 9127-9230) with KIT_SURFACE inlined: every quad of the sprite
//                mesh (adapters/godot/sea_spray.gd: 64 x 64 cells x 8 slots) is worked out from its world cell
//                (1.5 m), its slot and the time; nothing is simulated or stored. Slots 0-5 are clusters of drops
//                thrown off breaking crests from 3 m/s of wind, slots 6-7 wisps of spume blown downwind from 9 m/s.
//                A slot is launched when the sea breaks at its fixed spawn point (the foam map's break clock, .b,
//                read at one texel) and flies its whole arc inside its 10 s epoch (v9), with linear air drag in
//                closed form, its height kept over the water under it now.
//   fragment() = SPRAY_PS_BODY_TEX (lines 11153-11302; the tank drew the spume from T_OO_Spume whenever the picture
//                was there, and it was: SPRAY_PS_NOISE was the fallback and is not ported): six soft round drops of
//                1-3 mm in a mottled veil with a ragged edge; the spume one of sixteen puff pictures whose thin parts
//                erode with age. Light = LIGHT_STANDIN_HLSL (v10/v25): a matte cloud in the foam's light (a quarter
//                of the sun's beam, steady, plus the sky) with a forward glow capped at 0.3 / sr (drops) or 1 / sr
//                x 0.6 (spume).
//   Kept as they were: the rates (BRK_RATE 0.55 / 1.75), the epoch (BRK_EPOCH 10 s), MIST_A 0.05, the fade near the
//   lens (1-3 m), no cluster wider than about 2.5 degrees (spume 3-4.5), never thinner than a pixel (grown and
//   dimmed by its area), the streak cap 1.8 x, nothing drawn while the eye is under the water.
//   Changes for Godot:
//   - Unreal's Depth Fade (SPUME_FADE_CM 150) read the scene's depth behind the sprite. Here the sea seen from above
//     is a transparent pass, so the depth picture does not hold it: the fade is worked out from the pixel's height
//     over the water under its sprite, along the view (the same number over flat water). The depth test against the
//     sea still hides spray behind a crest.
//   - A pixel's angle (Kit.z) comes from the projection, not from a script.
//   - The sun's colour (SunCol) is white: the sun script here gives the beam's lux only.
//   Left out: SPLASH_VS_BODY and SPR_STEP_HLSL (the test floats' splashes: v59 sprites, v64 GPU particles),
//   SPRAYP_* and CROWN_* (the whale breach's drops and sheets, v180), the bubbles under the foam (M_OO_Bubbles, gone
//   from the tank at v35) and the night's plankton sparks (NIGHT_PC_HLSL, only in the breach's materials).
//   NOTE: in v374 itself every kit actor was hidden (kit_on False since v66, "remove sprays"; SPRAY_LIVE False since
//   v186): this is the last wind spray the tank had (v39's, lit as v10/v34), not something v374 showed.
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
global uniform float water_sky_nits;
global uniform float water_exposure;
uniform sampler2D spume : filter_linear_mipmap, repeat_disable;   // T_OO_Spume: 4 x 4 puffs, R = density
uniform vec4 kit = vec4(0.0, 0.016667, 0.0, 0.0);    // the tank's Kit: the sea's clock s, frame time s
uniform vec4 sea_k = vec4(0.35, 1.8, 3.0, 8.0);      // the tank's SeaK: -, Hs m, breaking speed m/s, wind m/s
uniform vec4 spray = vec4(1.0, 1.0, 1.0, 1.0);       // the tank's Spray: amount, -, sprite size, -
uniform float sun_share = 0.25;                      // LIGHT_STANDIN: the foam's share of the beam
const float KCELL = 1.5;          // SPRAY_CELL m
const float EPOCH = 10.0;         // BRK_EPOCH s
const float KRD = 0.55;           // BRK_RATE drops
const float KRM = 1.75;           // BRK_RATE spume
const float MIST_A = 0.05;
const float FOAM_N = 1024.0;
const float FADE_M = 1.5;         // SPUME_FADE_CM
const float SEA_CURVE_M = 2.0e5;
varying vec4 info;                // corner xy, cover (- for spume), -
varying vec4 aux;                 // height over the water m, distance m, the drops' radius in corner units, age / life
varying flat float seed;          // the tank's Info.w
varying float hgt;                // this corner's height over the water under the sprite, m
varying flat vec3 e_sky;          // the sky's light, lux, in its colour

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
	vec2 cell = floor(cam.xy / KCELL) + home;
	vec3 world = vec3(cell * KCELL, 0.0);                        // folded onto a point unless drawn
	info = vec4(corner, 0.0, 0.0);
	aux = vec4(0.0);
	seed = 0.0;
	hgt = 0.0;
	e_sky = vec3(0.0);
	uvec2 hc = uvec2(ivec2(cell) + 65536);
	float U = sea_k.w;
	vec2 wd = sea_wind.xy;

	float camUp = cam.z > 0.0 ? 1.0 : 0.0;
	if (abs(cam.z) < 1.2 * sea_k.y + 1.0) camUp = cam.z > kit_surface(cam.xy) ? 1.0 : 0.0;
	float mist = slot > 5.5 ? 1.0 : 0.0;
	// v9: v8's share of slots in use, scaled so about as much spray shows at a time as in v8 (each puff now shows its
	// whole flight): drops x 0.55 up to 8 m/s, rising to x1 at 20 m/s; spume x 1.75 (its long flights often miss their epoch)
	float rate = spray.x * (mist > 0.5 ? KRM * clamp((U - 9.0) / 10.0, 0.0, 1.0)
		: mix(KRD, 1.0, clamp((U - 8.0) / 12.0, 0.0, 1.0)) * clamp((U - 3.0) / 8.0, 0.0, 1.0));
	uint h0 = pcg((hc.x * 1597334677u) ^ (hc.y * 3812015801u) ^ (uint(slot) * 2798796415u));
	float T = mist > 0.5 ? 2.0 + 2.0 * float(h0 & 0xFFFFu) / 65535.0 : 1.0 + 1.2 * float(h0 & 0xFFFFu) / 65535.0;
	uint hA = pcg(h0 + 1013904223u);
	uint hB = pcg(hA + 1013904223u);
	vec4 r0 = r4(hA, hB);
	// v9: the slot's spawn point, its share of the slots in use and its launch delay are its own for good; its flight
	// is drawn from its epoch (10 s, its own phase), which the whole flight must fit inside
	vec2 P0 = (cell + r0.xy) * KCELL;
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
	vec2 fu = (P0 - sea_foam_org.xy) / sea_foam_org.z + 0.5;
	if (camUp > 0.5 && sea_on > 0.5 && sea_foam_org.w > 0.5 && r0.z < rate && fu.x > 0.0 && fu.y > 0.0 && fu.x < 1.0 && fu.y < 1.0) {
		// v9: thrown when the sea breaks at its spawn point: its age is the break clock there (one texel, never a
		// blend of two clocks) less its delay
		float age = textureLod(sea_foam, (floor(fu * FOAM_N) + 0.5) / FOAM_N, 0.0).b - 0.15 * r0.w;
		float tb = kit.x - age;
		if (age > 0.0 && age < life && tb >= te && tb + life <= te + EPOCH) {
			vec2 wn = vec2(-wd.y, wd.x);
			float tau = mist > 0.5 ? 0.005 : mix(0.15, 0.7, r2.x);
			vec3 va = vec3(wd * 0.7 * U, -9.81 * tau);
			float up = mist > 0.5 ? 0.3 : mix(0.8, 3.5, r2.y) * clamp(0.3 + U / 12.0, 0.0, 1.0);
			vec3 v0 = vec3(wd * sea_k.z * mix(0.6, 1.1, r2.z) + wn * (r2.w - 0.5) * 2.0, up);
			float e = 1.0 - exp(-age / tau);
			vec3 p = vec3(P0, 0.0) + va * age + (v0 - va) * (tau * e);
			vec3 vel = va + (v0 - va) * (1.0 - e);
			// its height over the water under it now (it rides over the crest it came off; spume rises in the wind)
			float hz = (mist > 0.5 ? 0.1 + 0.15 * age : 0.05 + 0.25 * r3.x) + p.z;     // v34: spume stays low
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
				float R = (mist > 0.5 ? mix(0.25, 0.7, sqrt(age / life)) * mix(0.7, 1.3, r3.y) : mix(0.08, 0.25, r3.y)) * spray.z;   // v39: smaller
				float a = (mist > 0.5 ? MIST_A : 0.9) * clamp(age / 0.08, 0.0, 1.0) * clamp((life - age) / (0.35 * life), 0.0, 1.0);
				// v9: drops fade as they sink over their own size
				a *= mist > 0.5 ? clamp(hz / 0.3, 0.0, 1.0) : clamp(hz / max(R, 0.03), 0.0, 1.0);
				a *= 1.0 - smoothstep(0.7, 0.95, length(c3.xy - cam.xy) / (32.0 * KCELL));
				// nothing right by the lens (v3: a cluster a hand's width away filled the frame, sharp, like glass), and
				// no cluster covering more than about 3 degrees of the view (v6)
				a *= smoothstep(1.0, 3.0, dist);
				a *= mist > 0.5 ? 1.0 - smoothstep(0.03, 0.08, R / dist) : 1.0 - smoothstep(0.02, 0.05, R / dist);
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
						sx = R * mix(1.0, 2.5, clamp((vl - 0.2) / 0.5, 0.0, 1.0));     // v39: drawn out along the wind
					}
				}
				world = c3 + corner.x * sx * rx + corner.y * R * (mist > 0.5 ? 0.6 : 1.0) * ry;   // v34: thin wisps
				info = vec4(corner, mist > 0.5 ? -a : a, 0.0);
				seed = r3.z;
				// the drops' own radius (1-3 mm) in the quad's corner units
				aux = vec4(hz, dist, mix(0.001, 0.003, r3.w) / R, clamp(age / life, 0.0, 1.0));     // v10: .w its age / life
				hgt = world.z - zs;
				// LIGHT_STANDIN: the sky overhead, as light on a level face, in its own colour
				vec3 sky_up = sky_dome_nits(vec3(0.0, 1.0, 0.0));
				float lu = dot(sky_up, vec3(0.2126, 0.7152, 0.0722));
				float sky_lux = PI * water_sky_nits;
				float Ek = clamp(PI * lu, 0.25 * sky_lux, 4.0 * sky_lux);
				e_sky = (lu > 1e-9 ? sky_up / lu : vec3(1.0)) * Ek;
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
	vec3 Es = vec3(sun_share * water_sun_lux);                  // v25: the stand-in (a quarter of the beam), steady
	float cs = dot(Ld, w);
	float gg = info.z < 0.0 ? 0.6 : 0.75;
	float ph = (1.0 - gg * gg) / (12.566 * pow(max(1.0 + gg * gg - 2.0 * gg * cs, 1e-4), 1.5));
	float lf = aux.w;
	float px = max(max(length(dFdx(uv)), length(dFdy(uv))), 1e-4);
	float r = length(uv);
	float cov = 0.0;
	if (info.z < 0.0) {
		// v39: one of sixteen puff pictures (T_OO_Spume: 4 x 4 tiles, R = density, 0 at the tile's edge), picked and
		// flipped by the slot's seed; its thin parts erode as it ages, so it breaks up into shreds as it flies
		float sd = fract(seed * 16.0);
		float ti = floor(seed * 16.0);
		vec2 tuv = vec2(sd < 0.5 ? uv.x : -uv.x, uv.y) * 0.5 + 0.5;
		vec2 auv = (vec2(mod(ti, 4.0), floor(ti / 4.0)) + clamp(tuv, 0.0, 1.0)) * 0.25;
		float tex = textureLod(spume, auv, log2(max(px * 128.0, 1.0))).r;   // its mip from the quad's size on screen
		float er = 0.1 + 0.55 * lf;
		cov = tex * clamp((tex - er) / max(1.0 - er, 0.05), 0.0, 1.0) * 1.3;
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
		// and the drops too fine to see one by one round them: a mottled puff with a ragged edge (v6; v3-v5's smooth
		// veil was a see-through pane, and stretched it read as glass)
		vec2 nq = uv * 2.2 + seed * 53.0;
		vec2 inq = floor(nq);
		vec2 fnq = nq - inq;
		vec2 snq = fnq * fnq * (3.0 - 2.0 * fnq);
		vec4 nv = vec4(0.0);
		vec4 nw = vec4(0.0);
		for (int kq = 0; kq < 4; kq++) {
			uvec2 qc = uvec2(ivec2(inq) + ivec2(kq & 1, kq >> 1) + 32768);
			uint hq = (qc.x * 1597334677u) ^ (qc.y * 3812015801u);
			hq = hq * 747796405u + 2891336453u;
			hq ^= hq >> 16u;
			hq *= 2246822519u;
			hq ^= hq >> 13u;
			nv[kq] = float(hq & 0xFFFFu) / 65535.0;
			nw[kq] = float(hq >> 16u) / 65535.0;
		}
		float n1 = mix(mix(nv.x, nv.y, snq.x), mix(nv.z, nv.w, snq.x), snq.y);
		float n2 = mix(mix(nw.x, nw.y, snq.x), mix(nw.z, nw.w, snq.x), snq.y);
		float rb = r * (0.75 + 0.5 * n1);
		cov += 0.32 * (1.0 - smoothstep(0.3, 1.0, rb)) * (0.35 + 0.65 * n2) * (1.0 - 0.6 * lf);     // v10: thins with age
	}
	// v10: lit like the foam it comes off (a matte cloud in the foam's light), with a forward glow capped at 0.3 / sr;
	// thick parts with the sun behind them a little greyer (the cloud shades itself)
	float shade = 1.0 - 0.18 * clamp(1.5 * cov, 0.0, 1.0) * clamp(0.5 - 0.5 * cs, 0.0, 1.0);
	// v34: the spume is a thin cloud of fine spray: half as matte as the foam, and the sun's forward glow up to
	// 1 / sr x 0.6; the drops as v10
	vec3 Ed = Es * max(Ld.y, 0.0) + e_sky;
	vec3 C = info.z < 0.0 ? (Ed * (0.5 * 0.3183) + Es * min(ph, 1.0) * 0.6) * shade
		: (Ed * (0.9 * 0.3183) + Es * min(ph, 0.3)) * shade;
	// Unreal's Depth Fade (150 cm of scene depth behind the pixel), from the pixel's height over the water under its
	// sprite along the view (see the header)
	float fade = clamp(hgt / (max(abs(w.y), 0.05) * FADE_M), 0.0, 1.0);
	ALBEDO = C * water_exposure;
	ALPHA = a * clamp(cov, 0.0, 1.0) * fade;
}
