// Sea foam look 0.1.0 (water surface thread, 28 Nov 2026): how the whitecaps are drawn on the sea, ported from the
// Unreal open-water tank (openocean_tank v374, the assembled SEA_N_HLSL foam path and SEA_SHADE_HLSL's foam terms).
// The foam MAP is adapters/godot/fft_sea.gd's (look/sea_foam.glsl, the tank's FOAM_HLSL); this file only draws it.
//
// INCLUDE ORDER: after water_physics, sky_dome and sea_waves (it uses sea_disp / sea_deriv / sea_patch / sea_mom_*,
// sea_isl / sea_gdt, SEA_CHOP / SEA_MOD, water_a / water_b / water_kd, sky_dome_nits) and after the shader's own
// `global uniform vec3 water_sun_air; global uniform float water_sun_lux;`.
//
// What is ported (tank names in brackets; the numbers are the tank's):
//   sea_foam_read()  = SEA_N's foam path, in its order:
//     the map read at the still-water point (fm; r foam, b the break clock) and, beyond the map and over its outer
//       40 m, the fold of cascades 0-1 with a wider margin (now / nowf / dj, fitted in the tank to the map's cover);
//     the bubble cloud (plume: the map over a 2.2 m footprint) and the bright crest (v325-v331 fresh: the break
//       clock's flare, rise 0.4 s, fade 2.5 s, half from the same footprint; beyond the map the W/30 fold);
//     the small waves' squeeze thickening or thinning the foam (detail, from cascades 2-3 while they are drawn);
//     the v337 roller's white (the W/10 to W/30 fold, squared, on the rings finer than 4 m);
//     ragged edges and streaks along the wind (rag 1.7 / 0.75 m; streak 14 x 1.3 m and 29 x 3.4 m, bent by a 23 x 7 m
//       noise), old foam pulled into the streaks from 7 m/s up (sw) and dense white streaks in a storm (v31);
//     v350 foam opaque on top (old foam's cover x FOAM_AGED_OP 0.4, x the storm thinning);
//     the lace (v6): three octaves of round bubble holes on a twice-warped grid near the eye, and further out v334's
//       wind streaks (LACE_STREAKS); the thresholds are the tank's fitted polynomials LACE_T / LACE_TC with the
//       v339 soft widths (LACE_SOFT 0.04 / 0.08, at least a pixel).
//   sea_foam_bump()  = v24: the drawn foam as a 2 cm layer tilting the normal (slope capped at 0.35).
//   sea_foam_top_nits() = SEA_SHADE above: foam albedo 0.55 (old) to 0.92 (fresh), old foam tinted a fifth toward the
//     water's colour (v21), lit by the sun on the drawn normal and by the sky (the tank's lit base colour).
//   sea_foam_plume_nits() = the turquoise bubble cloud under and behind a whitecap, seen from above.
//   sea_foam_under_window() / sea_foam_under_haze() = SEA_SHADE below: daylight through the foam (old foam 0.3,
//     fresh 0.18 of the daylight, / pi) in place of the window, and the bubble cloud as a bright haze in front of the
//     surface (0.11 of the daylight half a metre down, the surface behind it dimmed by 0.6 plume).
//   FW_HLSL (v319: the map read through a 0.8 m warp and a 4-tap tent, so no edge follows the map's texels) is ON
//     (SF_WARP), and the bubble cloud and the crest's footprint are a 3 x 3 tent instead of the tank's four taps.
//     The tank ended with FW off (FOAM_VEILS False since v325) because its foam fluid (v336) carried the map with a
//     bilinear read that smoothed it; this map moves by whole texels and keeps its texel speckle, and without the
//     warp and the tent the 0.39 m lattice showed from 50 m up (shots foam_dbg/ch, 27 Nov).
//   BK_HLSL (v321 break-up pattern) is ported but OFF as the tank left it (FOAM_BREAKUP False since v325): SF_BREAKUP.
// Left out: the floats', swimmers', ripples' and breach's churn (v351, no such bodies here), the foam fluid's flow
//   map (v322 / v336), the plankton glow, v354's damping of the shortest ripples under foam (it needs cascade 3's
//   slope apart from sea_slope()'s sum), the crest's light-through bubbles term (the crest glow is not ported), the
//   cloud shadow (no cloud map here), the v340 second copy of cascade 2 in `detail` (one read: the term only thins or
//   thickens the foam a little near the eye).
// Stand-ins, because the sea has no global for them yet (say so to whoever owns fft_sea.gd):
//   the lace's slide down the wind (the tank's LaceAt.x = the drift x the sea clock) = 0.03 U x the `clock` argument
//     (pass TIME); the pattern then slides at the foam map's own drift speed, but a held sea's lace keeps sliding;
//   the roller's height gate saturate(min(0.12 Hs, 0.6) / 0.1) is taken as 1 (true for Hs over 0.83 m);
//   the water's colour for the old foam's tint is b / (a + b) instead of the tank's Rrs.
global uniform sampler2D sea_foam : filter_linear, repeat_disable;
global uniform vec4 sea_foam_org;    // centre island x, y, size m, 1 = valid
global uniform vec4 sea_foam_k;      // FoamK: the Jacobian threshold (cascades 0-1), soft width, the deep-fold step, 1
global uniform vec4 sea_wind;        // wind dir island x, y, U10 m/s, storm ramp (not used: the tank's own ramp below)

const float SF_AMOUNT = 1.0;         // Water.y FoamAmount
const float SF_S1 = 0.35;            // Detail.y FoamBubbleSize m
const float SF_ST = 2.5;             // Detail.z FoamStretch downwind
const float SF_STORM = 1.0;          // Detail.w StormFoam
const float SF_SHARP = 3.0;          // Look.w Sharpness (the tank's cascade fade)
const float SF_AGED_OP = 0.4;        // FOAM_AGED_OP
const float SF_FRESH_TAU = 2.5, SF_FRESH_RISE = 0.4;
const float SF_ROLL_DE = 4.0;        // ROLL_DE m
const bool SF_WARP = true;           // FW_HLSL (FOAM_VEILS); the tank ended with it off, see the header
const bool SF_BREAKUP = false;       // BK_HLSL (FOAM_BREAKUP)
const float SF_BK_CAP = 0.720;

struct SeaFoam {
	float foam;     // the drawn cover 0-1 (Misc.y)
	float fresh;    // the breaking crest (Misc.z)
	float aged;     // old foam (Misc2.y)
	float plume;    // the bubble cloud under it (Misc2.x)
	float storm;    // Misc2.w
	float young;    // SEA_SHADE's young = saturate(1.5 fresh + 0.5 (1 - saturate(3 aged)))
};

uint sf_hash(ivec2 c, uint seed) {       // the tank's lattice hash
	uvec2 hc = uvec2(c + 32768);
	uint h = (hc.x * 1597334677u) ^ (hc.y * 3812015801u) ^ (seed * 2654435761u);
	h = h * 747796405u + 2891336453u;
	h ^= h >> 16u;
	h *= 2246822519u;
	h ^= h >> 13u;
	h *= 3266489917u;
	h ^= h >> 16u;
	return h;
}
float sf_vn(vec2 p, uint seed) {         // value noise 0-1
	vec2 fl = floor(p);
	ivec2 i = ivec2(fl);
	vec2 f = p - fl;
	vec2 s = f * f * (3.0 - 2.0 * f);
	float a = float(sf_hash(i, seed) & 0xFFFFu) / 65535.0;
	float b = float(sf_hash(i + ivec2(1, 0), seed) & 0xFFFFu) / 65535.0;
	float c = float(sf_hash(i + ivec2(0, 1), seed) & 0xFFFFu) / 65535.0;
	float d = float(sf_hash(i + ivec2(1, 1), seed) & 0xFFFFu) / 65535.0;
	return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}
float sf_vs(vec2 p, uint seed) { return sf_vn(p, seed) * 2.0 - 1.0; }
float sf_flare(float b) {                // v327: the break clock's flare
	return clamp(1.5 * exp(-b / SF_FRESH_TAU) * (1.0 - exp(-b / SF_FRESH_RISE)) * clamp((5.8 - b) / 0.3, 0.0, 1.0), 0.0, 1.0);
}
float sf_hole(vec2 p, float rlo, float rhi) {   // v6: distance to the nearest hole centre / its radius (< 1 inside)
	vec2 fl = floor(p);
	ivec2 ip = ivec2(fl);
	vec2 f = p - fl;
	float m = 8.0;
	for (int k = 0; k < 9; k++) {
		ivec2 gc = ivec2(k % 3 - 1, k / 3 - 1);
		uint h = sf_hash(ip + gc, 0u);
		uint h2 = h * 747796405u + 2891336453u;
		h2 ^= h2 >> 16u;
		float rr = float(h2 & 0xFFFFu) / 65535.0;
		vec2 dl = vec2(gc) + 0.1 + 0.8 * vec2(float(h & 0xFFFFu), float(h >> 16u)) / 65535.0 - f;
		m = min(m, length(dl) / (rlo + (rhi - rlo) * rr * rr));
	}
	return min(m, 2.0);
}

// Xl = the pixel's island still-water point, P = its island world point, cam = island camera, nq = the mesh's quads
// per ring, clock = seconds (TIME)
// jc0, jc1, jl: cascades 0-1's squeeze sums from sea_slope_j where it read them at mip 0 (jl = 1), the same reads this
// fold takes (sea speed thread, 28 Nov); jl = 0 reads them here
SeaFoam sea_foam_read_j(vec2 Xl, vec3 P, vec3 cam, float nq, float clock, vec3 jc0, vec3 jc1, vec2 jl) {
	SeaFoam o = SeaFoam(0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
	// the pixel's footprint on the sea (m), as sea_slope() and the tank take it
	vec3 vr = P - cam;
	float vl = max(length(vr), 1e-3);
	vec3 vu = vr / vl;
	float pa = max(max(length(dFdx(vu)), length(dFdy(vu))), 1e-7);
	float mu = max(abs(vu.z), 0.02);
	float fpa = vl * pa;
	vec2 along = vu.xy * (fpa / mu);
	float fp = max(max(fpa, 0.25 * fpa / mu), 1e-5);
	if (sea_on < 0.5 || sea_foam_k.x < -5.0) return o;          // no whitecaps (the calm lagoon)
	float U = sea_wind.z;
	vec2 wd = normalize(sea_wind.xy + vec2(1e-6, 0.0));
	vec2 wp = vec2(-wd.y, wd.x);
	float storm = clamp(clamp(SF_STORM, 0.0, 2.0) * clamp((U - 15.5) / 10.9, 0.0, 1.0), 0.0, 1.0);
	o.storm = storm;
	// the map
	vec2 fu = (Xl - sea_foam_org.xy) / sea_foam_org.z + 0.5;
	float inb = sea_foam_org.w > 0.5 ? min(min(fu.x, fu.y), min(1.0 - fu.x, 1.0 - fu.y)) : 0.0;
	float edge = clamp(10.0 * inb, 0.0, 1.0);
	float fr_e = clamp(4.0 * inb, 0.0, 1.0);                    // v326: blends over the map's outer 100 m
	vec2 fw_u = fu;
	if (SF_WARP) {   // FW_HLSL v319: the map read through a warp (2.6 m and 1.1 m noise, up to 0.8 m) and a 4-tap tent
		vec2 fw_t = vec2(0.0);
		for (int q = 0; q < 4; q++) {
			float sc = q < 2 ? 2.6 : 1.1;
			float v = sf_vs(Xl / sc + vec2(3.7 + 13.1 * float(q), 11.9 - 7.3 * float(q)), uint(q + 11)) * (1.0 - smoothstep(0.4, 1.6, fp / sc));
			float w = q < 2 ? 0.55 : 0.25;
			if (q == 0 || q == 2) fw_t.x += w * v; else fw_t.y += w * v;
		}
		fw_u = fu + fw_t / sea_foam_org.z;
	}
	vec3 fm = textureLod(sea_foam, clamp(fw_u, 0.0, 1.0), 0.0).rgb;
	float fmr = fm.r;
	if (SF_WARP) {
		float e = 0.0004883;
		fmr = 0.25 * (textureLod(sea_foam, clamp(fw_u + vec2(e, e), 0.0, 1.0), 0.0).r + textureLod(sea_foam, clamp(fw_u + vec2(-e, e), 0.0, 1.0), 0.0).r
			+ textureLod(sea_foam, clamp(fw_u + vec2(e, -e), 0.0, 1.0), 0.0).r + textureLod(sea_foam, clamp(fw_u - vec2(e, e), 0.0, 1.0), 0.0).r);
	}
	// the fold of cascades 0-1 at full detail (v361 mp_a0: four taps along the view), wanted beyond the map, for the
	// roller and for the small waves' modulation; and the squeeze of cascades 2-3 while the tank draws them
	float L2 = sea_patch.z;
	float lr2 = log2(fp / (2.0 * L2 / 256.0)) - log2(SF_SHARP / 1.7);
	float w2 = 1.0 - smoothstep(4.0, 5.0, lr2);
	float J0 = 1.0, Jf = 1.0;
	if (edge < 1.0 || w2 > 0.0) {
		float jxx = 1.0, jyy = 1.0, jxy = 0.0;
		for (int c = 0; c < 2; c++) {
			float L = c == 0 ? sea_patch.x : sea_patch.y;
			// sea speed thread 28 Nov: only the taps that reach new texels of mip 0 (sea_taps; 4 wherever the view's stretch
			// spans 2 texels or more, as before)
			if ((c == 0 ? jl.x : jl.y) > 0.5) {
				vec3 jc = c == 0 ? jc0 : jc1;
				jxx += jc.x; jyy += jc.y; jxy += jc.z;
				continue;
			}
			float tr = sea_tap_r(length(along), 0.0, L);
			int nk = sea_taps(tr);
			float fk = 1.0 / float(nk);
			for (int k = 0; k < 4; k++) {
				if (k >= nk) break;
				vec3 uk = vec3((Xl + along * sea_tap_off(k, nk, tr)) / L, float(c));
				vec4 g = textureLod(sea_deriv, uk, 0.0);
				jxx += fk * g.z; jyy += fk * g.w; jxy += fk * textureLod(sea_disp, uk, 0.0).w;
			}
		}
		J0 = jxx * jyy - jxy * jxy;
		if (w2 > 0.0) {
			float v0 = SEA_CHOP * SEA_CHOP * (sea_mom_x.x + sea_mom_y.x + sea_mom_x.y + sea_mom_y.y);
			float md = clamp(1.0 + SEA_MOD * (1.0 - J0), 0.3, 2.5) * inversesqrt(1.0 + SEA_MOD * SEA_MOD * v0);
			float fxx = 1.0, fyy = 1.0, fxy = 0.0;
			for (int c = 2; c < 4; c++) {
				float L = c == 2 ? sea_patch.z : sea_patch.w;
				float lr = log2(fp / (2.0 * L / 256.0)) - log2(SF_SHARP / 1.7);
				float w = (1.0 - smoothstep(4.0, 5.0, lr)) * md;
				if (w > 0.0) {
					vec3 uk = vec3(Xl / L, float(c));
					float lod = clamp(lr, 0.0, 4.0);
					vec4 g = textureLod(sea_deriv, uk, lod);
					fxx += w * g.z; fyy += w * g.w; fxy += w * textureLod(sea_disp, uk, lod).w;
				}
			}
			Jf = fxx * fyy - fxy * fxy;
		}
	}
	float now = clamp((sea_foam_k.x - J0) / sea_foam_k.y, 0.0, 1.0);
	float dj = min(0.06 + 0.004 * max(U - 6.0, 0.0), 0.2);
	float nowf = clamp(2.5 * clamp((sea_foam_k.x + dj - J0) / (sea_foam_k.y + dj), 0.0, 1.0), 0.0, 1.0);
	float fcov = mix(nowf, fmr, edge);
	float lace_off = mod(0.03 * U * clock, 1.0e5);
	vec2 xw = vec2(dot(Xl, wd) - lace_off, dot(Xl, wp));
	// the bubble cloud under breaking water: the map over about 2 m round the point; v331: the bright crest too
	float plume = 0.0, fr_cs = 0.0;
	if (edge > 0.0) {
		// (the tank: four taps 1.1 m out. Here a 3 x 3 tent, 0.59 m (1.5 texels) apart, the same 2.2 m footprint: the
		// map here is not smoothed by the foam fluid's carry, and four taps of it drew the texel lattice)
		for (int pk = 0; pk < 9; pk++) {
			vec2 pi = vec2(float(pk % 3 - 1), float(pk / 3 - 1));
			float pw = (2.0 - abs(pi.x)) * (2.0 - abs(pi.y)) / 16.0;
			vec2 po = pi * 0.586;
			vec2 pu = fw_u + (po.x * wd + po.y * wp) / sea_foam_org.z;
			vec2 pfb = textureLod(sea_foam, clamp(pu, 0.0, 1.0), 0.0).rb;
			plume += pw * pfb.x;
			fr_cs += pw * sf_flare(pfb.y);
		}
	}
	plume = clamp(mix(max(1.5 * now, 0.6 * nowf), max(plume, 0.6 * fmr), edge) * SF_AMOUNT, 0.0, 1.0);
	// v325-v331: bright and opaque only while the crest breaks
	float fr_a = clamp((sea_foam_k.x - 1.7 * sea_foam_k.z - J0) / sea_foam_k.y, 0.0, 1.0);
	float fr_c = 0.5 * sf_flare(fm.b) + 0.5 * fr_cs;
	float fresh = mix(fr_a, fr_c, fr_e);
	float detail = clamp(0.5 + 2.5 * (1.0 - Jf), 0.0, 1.0);
	float foam = clamp(fcov * SF_AMOUNT * sea_foam_k.w * mix(1.0, 0.3 + 1.4 * detail, w2), 0.0, 1.0);
	{   // v337: the roller's thick whitewater, on the rings finer than ROLL_DE (the ring spacing under this pixel)
		float W0 = SEA_D0 * nq;
		float cheb = max(abs(Xl.x - cam.x), abs(Xl.y - cam.y));
		float l = max(0.0, ceil(log2(max(cheb, 1e-3) / W0) - 1e-3));
		float de = SEA_D0 * exp2(l) * (1.0 + clamp((cheb / (W0 * exp2(l)) - 0.70) / 0.25, 0.0, 1.0));
		float rfold = clamp((sea_foam_k.x - J0) / (sea_foam_k.y + 1.7 * sea_foam_k.z), 0.0, 1.0);
		float roll = rfold * rfold * clamp((SF_ROLL_DE - de) / 2.0, 0.0, 1.0);
		fresh = max(fresh, roll);
		foam = max(foam, roll);
	}
	// ragged edges and streaks along the wind
	float rag = 0.5, streak = 0.5;
	if (foam > 0.001) {
		vec2 xa = vec2(0.9925 * xw.x - 0.1219 * xw.y, 0.1219 * xw.x + 0.9925 * xw.y);
		vec2 xb = vec2(0.9816 * xw.x + 0.1908 * xw.y, -0.1908 * xw.x + 0.9816 * xw.y);
		float q0 = sf_vn(xw / vec2(1.7 * SF_ST, 1.7) + 5.3, 0u);
		float q1 = sf_vn(xw / vec2(0.75 * SF_ST, 0.75) + 9.1, 1u);
		float bend = (sf_vn(xw / vec2(23.0, 7.0) + 1.3, 2u) - 0.5) * 2.0;
		float q3 = sf_vn(xa / vec2(14.0, 1.3) + vec2(2.7, 2.7 + 1.3 * bend), 3u);
		float q4 = sf_vn(xb / vec2(29.0, 3.4) + vec2(4.1, 4.1 + 0.5 * bend), 4u);
		rag = 0.5 + (q0 - 0.5) * 0.8 * (1.0 - smoothstep(0.4, 1.6, fp / 1.7)) + (q1 - 0.5) * 0.5 * (1.0 - smoothstep(0.4, 1.6, fp / 0.75));
		streak = 0.5 + (q3 - 0.5) * 0.55 * (1.0 - smoothstep(0.4, 1.6, fp / 1.3)) + (q4 - 0.5) * 0.45 * (1.0 - smoothstep(0.4, 1.6, fp / 3.4));
	}
	float aged = clamp(foam - fresh, 0.0, 1.0);
	float sw = clamp((U - 7.0) / 9.0, 0.0, 1.0);
	float sk = smoothstep(mix(0.32, 0.42, storm), mix(0.70, 0.58, storm), streak);
	foam = clamp(foam - aged + aged * mix(1.0, mix(0.35, 0.1, storm) + mix(1.5, 2.2, storm) * sk, sw), 0.0, 1.0);
	foam = clamp(foam * (0.45 + 1.1 * rag), 0.0, 1.0);
	if (SF_BREAKUP && foam > 0.001) {   // BK_HLSL v321: a 1.5-22 m pattern stretched along the wind, with open channels
		vec2 bq = vec2(xw.x / 2.5, xw.y);
		vec2 bw = vec2(sf_vs(bq / 30.0 + vec2(5.1, 2.3), 21u), sf_vs(bq / 30.0 + vec2(12.8, -0.8), 22u));
		float bfb = 0.0, bws = 0.0;
		float bv1 = 0.0, bv2 = 0.0;
		for (int bo = 2; bo < 6; bo++) {
			float bsc = bo == 2 ? 22.0 : (bo == 3 ? 9.0 : (bo == 4 ? 3.6 : 1.5));
			float bnv = sf_vs((bq + 10.5 * bw) / bsc + vec2(20.5 + 7.7 * float(bo), 8.4 - 3.1 * float(bo)), uint(bo + 21));
			float ba = 1.0 - smoothstep(0.4, 1.6, fp / (0.5 * bsc));
			float bwt = bo == 2 ? 0.2 : (bo == 3 ? 0.35 : (bo == 4 ? 0.3 : 0.15));
			bfb += bwt * ba * bnv;
			bws += bwt * ba;
			if (bo == 3) bv1 = bnv * ba;
			if (bo == 4) bv2 = bnv * ba;
		}
		float bP = clamp(0.5 + 1.2 * bfb / max(bws, 1e-4), 0.0, 1.0);
		float bch = smoothstep(0.82, 0.95, 1.0 - abs(0.7 * bv1 + 0.3 * bv2));
		float bfc = min(foam, SF_BK_CAP);
		float bbr = smoothstep(1.0 - bfc - 0.1, 1.0 - bfc + 0.1, bP) * (1.0 - 0.9 * bch);
		foam = mix(foam, bbr, bws);
	}
	float op_y = clamp(1.5 * fresh + 0.5 * (1.0 - clamp(3.0 * aged, 0.0, 1.0)), 0.0, 1.0);   // v350: foam opaque on top
	foam *= mix(SF_AGED_OP, 1.0, op_y) * mix(0.35 + 0.65 * op_y, 0.7 + 0.3 * op_y, storm);
	// the lace (v6): the holes between the bubbles near the eye, v334's wind streaks further out
	float wl = 1.0 - smoothstep(0.04 * SF_S1, 0.2 * SF_S1, fp);
	float wl2 = 1.0 - smoothstep(0.16 * SF_S1, 0.8 * SF_S1, fp);
	if (foam > 0.001 && wl2 > 0.0) {
		vec2 q = vec2(xw.x / SF_ST, xw.y) / SF_S1;
		float vn0 = sf_vs(q * 0.6 + 3.1, 0u);
		float vn1 = sf_vs(q * 0.6 + 7.7, 0u);
		float vn2 = sf_vs(q * 2.3 + 1.7, 0u);
		float vn3 = sf_vs(q * 0.21 + 5.5, 0u);
		float vn4 = sf_vs(q * 0.21 + 9.9, 0u);
		float lfill = 0.5 + 0.4 * vn0 + 0.1 * vn2;
		vec2 qw = q + 0.5 * vec2(vn0, vn1) + 1.2 * vec2(vn3, vn4);
		float lace = 2.0;
		if (wl > 0.0) {
			float g = (0.8 + 0.4 * lfill) * (1.0 + 0.3 * vn2);      // and a ragged edge on every hole
			float h0 = sf_hole(qw * 0.7 + 3.3, 0.2, 0.8);
			float h1 = sf_hole(qw * 1.9 + 11.1, 0.2, 0.7);
			float h2 = sf_hole(qw * 4.4 + 23.7, 0.25, 0.6);
			lace = min(min(h0, 0.35 + 0.75 * h1), 0.6 + 0.5 * h2) * g;
		}
		float lacec = 1.0;
		if (wl < 1.0) {   // LACE_STREAKS v334: lanes about 5 m apart with 1.8 m lanes inside, 12 m long to 40 m in a storm
			float lc_al = mix(12.0, 40.0, storm);
			float n0 = sf_vs(xw / 20.0 + 17.3, 0u);
			float n1 = sf_vs(vec2(xw.x / 9.0, xw.y / 6.0) + 33.7, 0u);
			float lc_ys = xw.y + 4.0 * n0 + 1.2 * n1;
			float n2 = sf_vs(vec2(xw.x / lc_al, lc_ys / 5.0) + 71.3, 0u);
			float n3 = sf_vs(vec2(xw.x / (0.4 * lc_al), (lc_ys + 0.8 * n1) / 1.8) + 83.9, 0u);
			float n4 = sf_vs(vec2(xw.x / 15.0, xw.y / 6.0) + 29.1, 0u);
			float n5 = sf_vs(qw * 0.175 + 41.7, 0u);
			float n6 = sf_vs(vec2(0.7986 * qw.x - 0.6018 * qw.y, 0.6018 * qw.x + 0.7986 * qw.y) * 0.35 + 53.1, 0u);
			float lc_g = (0.8 + 0.4 * lfill) * (1.0 + 0.3 * vn2 * (1.0 - smoothstep(0.03, 0.08, fp)));
			lacec = (1.0 + 0.9 * (0.3 * n2 + 0.25 * n3 + 0.2 * n4 + 0.15 * n5 * (1.0 - smoothstep(0.25, 0.6, fp))
				+ 0.1 * n6 * (1.0 - smoothstep(0.12, 0.3, fp)))) * lc_g;
		}
		float c = clamp(foam + 0.35 * fresh, 0.0, 1.0);
		float t = (((0.8951 * c - 4.3314) * c + 5.1046) * c - 2.9541) * c + 1.4595;    // LACE_T
		float tc = (((0.3261 * c - 2.1570) * c + 2.7425) * c - 1.7248) * c + 1.4166;   // LACE_TC
		float lw_f = max(0.040, 3.0 * fp / SF_S1);   // v339: at least a pixel's change in the holes
		float lw_c = max(0.080, 0.2 * fp);           // and in the far streaks
		float lit = mix(smoothstep(tc - lw_c, tc + lw_c, lacec), smoothstep(t - lw_f, t + lw_f, lace), wl);
		foam = mix(foam, lit, max(wl, 0.85 * wl2));
	}
	o.foam = foam;
	o.fresh = fresh;
	o.aged = aged;
	o.young = clamp(1.5 * fresh + 0.5 * (1.0 - clamp(3.0 * aged, 0.0, 1.0)), 0.0, 1.0);
	// SEA_SHADE: the cloud thins with the old foam above it
	o.plume = plume * sqrt(mix(0.35 + 0.65 * o.young, 0.7 + 0.3 * o.young, storm));
	return o;
}

// v24: the drawn foam, lace and all, is a 2 cm layer; its gradient on the still sea tilts the normal (island, z up)
vec3 sea_foam_bump(vec3 N, float foam, vec2 Xl) {
	float fh = 0.02 * foam;
	vec2 pdx = dFdx(Xl), pdy = dFdy(Xl);
	float phx = dFdx(fh), phy = dFdy(fh);
	float pdet = pdx.x * pdy.y - pdx.y * pdy.x;
	vec2 pg = abs(pdet) > 1e-12 ? vec2(pdy.y * phx - pdx.y * phy, pdx.x * phy - pdy.x * phx) / pdet : vec2(0.0);
	float pgl = length(pg);
	pg *= min(pgl, 0.35) / max(pgl, 1e-6);
	return normalize(N - vec3(pg, 0.0) * N.z);
}

vec3 sf_sun_lux() {                      // the beam, lux on a surface facing it (0 with the sun down)
	return vec3(1.0, 0.97, 0.9) * water_sun_lux * step(0.0, water_sun_air.y);
}
vec3 sf_sky_lux() {                      // the sky's light on a level surface: five looks at the dome, cosine weighted
	vec3 e = 0.36 * sky_dome_nits(vec3(0.0, 1.0, 0.0));
	e += 0.16 * (sky_dome_nits(vec3(0.5793, 0.5736, 0.5793)) + sky_dome_nits(vec3(-0.5793, 0.5736, 0.5793))
		+ sky_dome_nits(vec3(0.5793, 0.5736, -0.5793)) + sky_dome_nits(vec3(-0.5793, 0.5736, -0.5793)));
	return PI * e;
}
vec3 sf_daylight() {                     // SEA_SHADE's Ed: sun and sky on the level sea
	return sf_sun_lux() * max(normalize(water_sun_air).y, 0.0) + sf_sky_lux();
}

// the foam seen from above, nits: add to the water's own light x (1 - foam). N = the drawn normal (island, up).
vec3 sea_foam_top_nits(SeaFoam f, vec3 N) {
	if (f.foam <= 0.0) return vec3(0.0);
	vec3 wc = water_b / max(water_a + water_b, vec3(1e-6));
	vec3 alb = vec3(f.foam * mix(0.55, 0.92, f.young));
	alb *= mix(vec3(1.0), wc / max(max(wc.r, wc.g), max(wc.b, 1e-6)), 0.2 * (1.0 - f.young));   // v21
	vec3 Ls = sea_isl(normalize(water_sun_air));
	return alb * (sf_sun_lux() * max(dot(N, Ls), 0.0) + sf_sky_lux()) / PI;
}
// the turquoise bubble cloud under and behind a whitecap, seen from above, nits (F = the surface's Fresnel mirror)
vec3 sea_foam_plume_nits(SeaFoam f, float F) {
	float pl = f.plume * (1.0 - f.foam);
	if (pl <= 0.001) return vec3(0.0);
	vec3 tp = exp(-water_a * mix(6.0, 1.5, f.young));
	return sf_daylight() * (0.08 / 1.777) * mix(0.5, 1.0, f.young) * pl * tp * (1.0 - F);
}
// seen from below: Lin = the light through the window (nits); foam lets daylight through in its place
vec3 sea_foam_under_window(SeaFoam f, vec3 Lin) {
	if (f.foam <= 0.0) return Lin;
	return Lin * (1.0 - f.foam) + f.foam * sf_daylight() * mix(0.3, 0.18, f.young) * 0.3183;   // v58
}
// seen from below: Ls = the whole surface (window + mirror, nits); the bubble cloud is a bright haze in front of it
vec3 sea_foam_under_haze(SeaFoam f, vec3 Ls) {
	if (f.plume <= 0.0) return Ls;
	return Ls * (1.0 - 0.6 * f.plume) + sf_daylight() * exp(-water_kd * 0.5) * 0.11 * f.plume;
}
SeaFoam sea_foam_read(vec2 Xl, vec3 P, vec3 cam, float nq, float clock) {
	return sea_foam_read_j(Xl, P, cam, nq, clock, vec3(0.0), vec3(0.0), vec2(0.0));
}
