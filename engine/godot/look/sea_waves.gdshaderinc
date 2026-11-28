// Sea waves 0.2.0 (water surface thread; 0.2.0 sea speed thread: taps along the view only where needed): reading the FFT sea (adapters/godot/fft_sea.gd) for the sea mesh and its
// shading. Ported from lagoonwater v98:
//   sea_vertex_world()  = LW_VS_HLSL: nested square rings round the camera (snap 0.25 m), each vertex moved by every
//                         cascade its spacing can carry (fade from 4 to 8 vertices per shortest wave), morph between
//                         rings, the planet's curvature (R 200 km).
//   sea_slope()         = FFT_SLOPE_HLSL: the drawn slope at a pixel (4 taps along the view, each cascade faded out
//                         by the pixel's footprint with its un-drawn slope variance kept as roughness; the short swell's
//                         ripples steeper on the long waves' crests (RipplesOnSwell 2); the 2.56 m and 0.32 m tiles
//                         broken by three turned copies (caus_tb_*: the same blend the light net uses).
//   Changes for Godot: the cascades are mipmapped (wrap-averaged), so each read takes the mip of the pixel's footprint
//   across the view instead of v98's single level (LESSONS water, tank v361); v98's 4-tap box on the 250 m cascade
//   is that mip. Gusts (v94 x1) and the ripple texture (LAB_RIPPLES 0) are off, as saved. No foam (the lagoon's
//   whitecap share is 0 at 2 m/s).
// Frames: island (x east, y north, z up) = Godot (x, -z, y). Textures read uv = island xy / patch.
global uniform sampler2DArray sea_disp : filter_linear_mipmap, repeat_enable;
global uniform sampler2DArray sea_deriv : filter_linear_mipmap, repeat_enable;
global uniform vec4 sea_patch;
global uniform vec4 sea_ring_hi;
global uniform vec4 sea_mom_x;
global uniform vec4 sea_mom_y;
global uniform vec4 sea_mom_r;
global uniform float sea_on;
const float SEA_D0 = 0.0625;        // v98 GEO: finest ring spacing m
const float SEA_SNAP = 0.25;        // camera snap m
const float SEA_CURVE_M = 2.0e5;    // v6: the open water's planet radius
const float SEA_CHOP = 1.0;
const float SEA_MOD = 2.0;          // the tank's RipplesOnSwell
const float SEA_SHARP = 1.0;        // v96: the true value for 4 taps
const float SEA_TAP1 = 1.0;         // 0.2.0: 1 tap under this many mip texels of stretch along the view
const float SEA_TAP2 = 2.0;         // 0.2.0: 2 taps under this many, else 4 (sea_taps)

vec3 sea_isl(vec3 g) { return vec3(g.x, -g.z, g.y); }
vec3 sea_gdt(vec3 i) { return vec3(i.x, i.z, -i.y); }

float sea_c_sel(vec4 v, int c) { return c == 0 ? v.x : (c == 1 ? v.y : (c == 2 ? v.z : v.w)); }

// sideways push and height (island m) of the cascades a ring of spacing de can carry, at still-water point X
vec3 sea_disp_at(vec2 X, float de) {
	vec3 D = vec3(0.0);
	for (int c = 0; c < 4; c++) {
		float L = sea_c_sel(sea_patch, c);
		float lmin = L / sea_c_sel(sea_ring_hi, c);
		float w = c == 0 ? 1.0 : clamp((lmin / de - 4.0) / 4.0, 0.0, 1.0);
		if (w > 0.0) {
			float lod = max(log2(max(de, 1e-5) * 256.0 / L), 0.0);
			D += w * textureLod(sea_disp, vec3(X / L, float(c)), lod).xyz;
		}
	}
	return D;
}

// the sea mesh vertex: lp = the mesh vertex (island xy, rings centred at 0), cam = island camera, surf = still level.
// Returns the world point (island) and writes the still-water point.
vec3 sea_vertex_world(vec2 lp, vec3 cam, float surf, float nq, out vec2 still) {
	float W0 = SEA_D0 * nq;
	float cheb = max(abs(lp.x), abs(lp.y));
	float l = max(0.0, ceil(log2(max(cheb, 1e-3) / W0) - 1e-3));
	float dl = SEA_D0 * exp2(l);
	float m = clamp((cheb / (W0 * exp2(l)) - 0.70) / 0.25, 0.0, 1.0);
	vec2 idx = round(lp / dl);
	vec2 odd = idx - 2.0 * floor(idx * 0.5);
	vec2 C = round(cam.xy / SEA_SNAP) * SEA_SNAP;
	vec2 X = C + idx * dl;
	float de = dl * (1.0 + m);
	vec3 D = vec3(0.0);
	if (sea_on > 0.5) {
		D = sea_disp_at(X, de);
		if (m > 0.0 && odd.x + odd.y > 0.5) {
			vec3 Dc = vec3(0.0);
			for (int t = 1; t < 5; t++) {
				vec2 sg = vec2(float((t - 1) & 1) * 2.0 - 1.0, float((t - 1) >> 1) * 2.0 - 1.0);
				Dc += 0.25 * sea_disp_at(X + sg * odd * dl, de);
			}
			D = mix(D, Dc, m);
		}
	}
	still = X;
	vec3 world = vec3(X + D.xy, surf + D.z);
	vec2 cv = world.xy - cam.xy;
	world.z -= dot(cv, cv) / (2.0 * SEA_CURVE_M);
	return world;
}

// 0.2.0 (sea speed thread, 28 Nov): how many of the 4 taps along the view a cascade needs. The taps stand in for the
// footprint's stretch along the view (the mip already covers it across). Where that stretch is under two texels of the
// mip being read, 4 taps read the same texels again: then 2 taps (under 2 texels) or 1 (under 1). 4 taps stay wherever
// the stretch is 2 texels or more, so the grazing sea is drawn exactly as before. along = the stretch (m), fpa = the
// footprint across the view (m): the read's mip texel is max(fpa, L / 256).
int sea_taps(float along, float fpa, float L) {
	float r = along / max(fpa, L / 256.0);
	return r < SEA_TAP1 ? 1 : (r < SEA_TAP2 ? 2 : 4);
}

// the drawn slope at a pixel: (dh/dx, dh/dy) island, and the slope variance the pixel does not draw.
// x = the pixel's island xy, Xl = its still-water point, cam = island camera, P = island pixel point.
vec3 sea_slope(vec2 x, vec2 Xl, vec3 P, vec3 cam, float fine3) {
	if (sea_on < 0.5) return vec3(0.0, 0.0, 0.0047);
	vec3 vr = P - cam;
	float vl = max(length(vr), 1e-3);
	vec3 vu = vr / vl;
	float pa = max(max(length(dFdx(vu)), length(dFdy(vu))), 1e-7);
	float mu = max(abs(vu.z), 0.02);
	float fpa = vl * pa;                                  // m across the view
	vec2 alongv = vu.xy * (fpa / mu);
	float alongl = length(alongv);
	float fp = max(max(fpa, 0.25 * fpa / mu), 1e-5);
	vec3 tbw = caus_tb_weights(x);
	float sx = 0.0, sy = 0.0, dxx = 0.0, dyy = 0.0, dxy = 0.0, vxx = 0.0, vyy = 0.0;
	float j0xx = 1.0, j0yy = 1.0, j0xy = 0.0;
	float md = 1.0;
	for (int c = 0; c < 4; c++) {
		float L = sea_c_sel(sea_patch, c);
		float tx = L / sea_c_sel(sea_ring_hi, c) * 0.125 * SEA_SHARP;
		float w = 1.0 - smoothstep(tx, 4.0 * tx, fp);
		if (c == 2) {
			float J0m = j0xx * j0yy - j0xy * j0xy;
			float v0 = SEA_CHOP * SEA_CHOP * (sea_mom_x.x + sea_mom_y.x + sea_mom_x.y + sea_mom_y.y);
			md = clamp(1.0 + SEA_MOD * (1.0 - J0m), 0.3, 2.5) * inversesqrt(1.0 + SEA_MOD * SEA_MOD * v0);
		}
		float gm = c >= 2 ? md * (c == 3 ? clamp(fine3, 0.0, 1.0) : 1.0) : 1.0;
		float lod = max(log2(max(fpa, 1e-5) * 256.0 / L), 0.0);
		int nk = sea_taps(alongl, fpa, L);
		float fk = 1.0 / float(nk);
		vec3 a = vec3(0.0), b = vec3(0.0);
		if (w > 0.0 || c < 2) {
			for (int v = 0; v < 3; v++) {
				float wv = (c < 2) ? (v == 0 ? 1.0 : 0.0) : tbw[v];
				if (wv > 0.001) {
					vec2 rc = v == 0 ? vec2(1.0, 0.0) : (v == 1 ? vec2(0.8, 0.6) : vec2(0.28, 0.96));
					vec3 av = vec3(0.0), bv = vec3(0.0);
					for (int k = 0; k < 4; k++) {
						if (k >= nk) break;
						vec2 xk = Xl + alongv * ((float(k) + 0.5) * fk - 0.5);
						vec2 xv = (c < 2 || v == 0) ? xk : (v == 1 ? caus_tb_x1(xk) : caus_tb_x2(xk));
						vec3 uk = vec3(xv / L, float(c));
						vec4 g4 = textureLod(sea_deriv, uk, lod);
						float dxy_ = textureLod(sea_disp, uk, lod).w;
						av += fk * g4.xyz;
						bv += fk * vec3(g4.w, dxy_, 0.0);
					}
					if (c >= 2 && v > 0) {
						// each copy's slope and squeeze turned back into the world (g' = R^T g, J' = R^T J R)
						vec2 gv = vec2(rc.x * av.x + rc.y * av.y, -rc.y * av.x + rc.x * av.y);
						float jxx = av.z, jyy = bv.x, jxy = bv.y;
						float cc = rc.x * rc.x, ss = rc.y * rc.y, cs2 = rc.x * rc.y;
						float nxx = cc * jxx + 2.0 * cs2 * jxy + ss * jyy;
						float nyy = ss * jxx - 2.0 * cs2 * jxy + cc * jyy;
						float nxy = (cc - ss) * jxy + cs2 * (jyy - jxx);
						av = vec3(gv, nxx);
						bv = vec3(nyy, nxy, bv.z);
					}
					a += wv * av;
					b += wv * bv;
				}
			}
		}
		a *= gm; b *= gm;
		sx += w * a.x; sy += w * a.y;
		dxx += w * a.z; dyy += w * b.x; dxy += w * b.y;
		float un = (1.0 - w * w) * gm * gm;
		vxx += un * sea_c_sel(sea_mom_x, c);
		vyy += un * sea_c_sel(sea_mom_y, c);
		if (c < 2) { j0xx += a.z; j0yy += b.x; j0xy += b.y; }
	}
	vxx += sea_mom_r.x * md * md;
	vyy += sea_mom_r.y * md * md;
	vec3 nn = vec3(dxy * sy - sx * (1.0 + dyy), sx * dxy - (1.0 + dxx) * sy, (1.0 + dxx) * (1.0 + dyy) - dxy * dxy);
	nn.z = max(nn.z, 0.05 * length(nn.xy) + 1e-4);
	vec2 g = -nn.xy / nn.z;            // the slope of the surface as drawn (the crests' squeeze in it)
	return vec3(g, vxx + vyy);
}
