// Marine snow 0.2.0 (look thread, 28 Nov 2026): PORTED from the Unreal lagoon's marine snow (ocean_v34.py MOTES_PP_HLSL,
// MoteVariety 2 = v19's lean walk; v16's shapes after the imaging surveys; v20/v21 settings: MoteDensity 20 /m3, MoteSize 6 mm,
// MoteFocus 2 m, ShaftForward 0.8; Gary 28 Nov "check thalassa and ue5 marine snow work"). Replaces 0.1.0's billboards.
// Each pixel walks its view ray through the first 2.5 m of water in 25 cm cells; a cell holds at most one mote (where, what and
// whether it is there come from hashes of the cell). Kinds and shares (motes over 0.6 mm): floc 32%, mucus thread 24%, diatom
// chain 8%, larvacean-house flake 12%, comet 10%, coil 8%, spined star 6%; smaller ones are specks, 15% of them dense brown
// pellets. Sizes: a power law 0.15 mm .. MoteSize / 2, plus 1 in 30 large aggregates of 2-6 mm. Each sinks at its kind's speed
// (pellets 1-2 mm/s, mucus barely, a few gas-holding mucus pieces rise), turns slowly, is swirled by small eddies, and the snow
// is thicker in some patches than others (veils that pass like clouds). Every piece is a soft blob whose width already includes
// the lens blur (focus MoteFocus) and the pixel, so it blurs off focus as a camera would. Hidden behind geometry (depth).
// Godot changes: y up, metres. The light is Unreal's: WaterColour x MoteBrightness x phase x 2 x coverage x the light net x
// exp(-a (depth + t) - c t); WaterColour (Unreal's haze colour) is this world's water glow seen level at the eye's depth
// (w_glow over 50 m). A physical version (albedo 0.5 x the beam and fill) was tried first: the snow vanished against the sand
// (40 pixels in the key frame view), as Unreal v15's did before Gary asked for snow you watch "like clouds" (v16).
// snow_k = MoteBrightness / 2.1 (1 = Unreal v20's 2.1, Gary's "Trim to 2.1").
// The cloud's drift (current + the swell's orbit at the eye's depth) comes from adapters/godot/motes.gd as `drift`, as the
// Unreal plugin pushed Drift. Drawn as a full-screen quad after the underwater view (render_priority 1), additive.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;

#include "res://look/water_physics.gdshaderinc"
#include "res://look/caustics.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float density = 20.0;      // MoteDensity: motes per m3 (v21: a third of v16's 60, look contract rule 9)
uniform float size_mm = 6.0;       // MoteSize: the largest ordinary mote, mm (half of it is the largest lobe)
uniform float focus_m = 2.0;       // MoteFocus: the lens's focus distance, m
uniform float snow_k = 1.0;        // art lever: x Unreal's MoteBrightness 2.1
uniform float fwd_g = 0.8;         // ShaftForward: the forward lobe's HG g
uniform vec3 drift = vec3(0.0);    // m: the water's displacement since start (current + swell orbit), from Motes
uniform float reach_m = 2.5;       // the walk's length

void vertex() { POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0); }

vec4 hash44(vec4 p) {               // Hoskins, as Unreal's
	p = fract(p * vec4(0.1031, 0.1030, 0.0973, 0.1099));
	p += dot(p, p.wzxy + 33.33);
	return fract((p.xxyz + p.yzzw) * p.zywx);
}
vec3 rotv(vec3 v, vec3 ax, float c, float s) { return v * c + cross(ax, v) * s + ax * dot(ax, v) * (1.0 - c); }

void fragment() {
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 col = vec3(0.0);
	if (cam.y < water_y && density > 0.0) {
		float depth = texture(depth_tex, SCREEN_UV).r;
		vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		vp.xyz /= vp.w;
		float len = length(vp.xyz);
		vec3 dir = normalize((INV_VIEW_MATRIX * vec4(vp.xyz, 0.0)).xyz);
		float pix = 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);   // radians per pixel
		float tmax = min(len, reach_m);
		vec3 o = cam - drift;                                   // the eye in the water's own frame
		const float C = 0.25;                                   // m per cell
		float occ = clamp(density * C * C * C, 0.0, 1.0);       // chance a cell holds a mote
		vec3 q = o / C;
		vec3 cell = floor(q);
		vec3 st = vec3(dir.x >= 0.0 ? 1.0 : -1.0, dir.y >= 0.0 ? 1.0 : -1.0, dir.z >= 0.0 ? 1.0 : -1.0);
		vec3 inv = 1.0 / max(abs(dir), vec3(1e-5));
		vec3 tn = (cell + 0.5 + 0.5 * st - q) * st * inv;
		float tcell = tmax / C;
		float t = TIME;
		float F = max(focus_m, 0.2);
		float smax = 0.5 * clamp(size_mm, 0.6, 20.0) * 0.001;
		// drifts: thicker in some patches than others, slowly changing (once per pixel, 1 m along its ray)
		vec3 pm = o + dir;
		float pn = sin(dot(pm, vec3(0.9, 1.7, 0.31)) + 0.21 * t) + sin(dot(pm, vec3(-0.6, 0.4, 1.3)) - 0.17 * t)
			+ 0.6 * sin(dot(pm, vec3(1.9, 0.8, -1.1)) + 0.13 * t);
		float occL = occ * clamp(0.25 + 0.42 * (pn + 1.9), 0.15, 1.75);
		// Unreal: brighter looking toward the sun (forward scattering), phase = min(0.3 + 0.7 HG, 4)
		float g = clamp(fwd_g, 0.0, 0.95); float ct = dot(water_sun_w, dir);
		float hg = (1.0 - g * g) / pow(max(1.0 + g * g - 2.0 * g * ct, 1e-4), 1.5);
		float phase = min(0.3 + 0.7 * hg, 4.0);
		vec3 lvl = normalize(vec3(dir.x, 0.0, dir.z) + vec3(1e-4, 0.0, 0.0));
		vec3 watercol = w_glow(lvl, water_y - cam.y, 50.0);       // Unreal's WaterColour: the water's own glow, seen level
		vec3 cwat = water_a + water_b;
		vec3 acc = vec3(0.0);
		float tc0 = 0.0;
		for (int i = 0; i < 40; i++) {
			if (tc0 > tcell) break;
			vec4 h4 = hash44(cell.xyzx);
			if (h4.w < occL) {
				vec4 h2 = hash44(cell.xyzx + 71.37);
				float u = min(h4.w / occL, 0.999);
				float smin = 0.00015;
				float big = step(h2.x, 0.035);
				float s = 0.5 * smin / sqrt(1.0 - u * (1.0 - (smin / smax) * (smin / smax)));
				s = mix(s, 0.0018 + 0.0045 * h2.y * h2.y, big);
				float pick = h2.z;
				float typ = pick < 0.15 ? 8.0 : 7.0;
				if (s > 0.0006) typ = pick < 0.32 ? 0.0 : pick < 0.56 ? 1.0 : pick < 0.64 ? 2.0 : pick < 0.76 ? 3.0 : pick < 0.86 ? 4.0 : pick < 0.94 ? 5.0 : 6.0;
				float ext = s * (typ < 0.5 ? 5.6 : typ < 1.5 ? 8.8 : typ < 2.5 ? 7.6 : typ < 3.5 ? 4.8 : typ < 4.5 ? 7.0 : typ < 5.5 ? 2.1 : typ < 6.5 ? 2.5 : typ < 7.5 ? 4.2 : 3.8);
				float r1 = fract(h2.w * 7.31 + h2.y * 3.17);
				float vs = typ < 0.5 ? (0.4 + 0.6 * r1) : typ < 1.5 ? (0.02 + 0.08 * r1) : typ < 2.5 ? (0.3 + 0.3 * r1) : typ < 3.5 ? (0.05 + 0.15 * r1)
					: typ < 4.5 ? (0.2 + 0.3 * r1) : typ < 5.5 ? 0.05 : typ < 6.5 ? 0.3 : typ < 7.5 ? (0.05 + 0.25 * r1) : (1.0 + 1.0 * r1);
				vs *= 0.001;
				if (((typ > 0.5 && typ < 1.5) || (typ > 2.5 && typ < 4.5)) && r1 < 0.08) vs = -0.0002 - 0.0002 * r1 / 0.08;
				float mg = min(0.45, (0.02 + ext + 0.01) / C);
				float fz = fract(h4.z + t * vs / ((1.0 - 2.0 * mg) * C));
				float life = smoothstep(0.0, 0.08, fz) * smoothstep(1.0, 0.92, fz);
				// y is up here (Unreal's z): it sinks down through its cell
				vec3 sp = (cell + vec3(mg + (1.0 - 2.0 * mg) * h4.x, mg + (1.0 - 2.0 * mg) * (1.0 - fz), mg + (1.0 - 2.0 * mg) * h4.y)) * C;
				vec3 rel = sp - o;
				float tq = dot(rel, dir);
				float tqc = max(tq, 0.05);
				float blur = 0.004 * abs(1.0 - tqc / F), px = 0.7 * pix * tqc;
				float sb2 = blur * blur + px * px;
				float RBm = 0.0347 + ext + 2.5 * sqrt(sb2);
				if (life > 0.0 && dot(rel, rel) - tq * tq < RBm * RBm) {
					vec3 swirl = vec3(sin(dot(sp, vec3(9.1, -2.2, 4.3)) + 0.55 * t), 0.7 * sin(dot(sp, vec3(2.9, 7.7, -5.1)) + 0.61 * t + 2.1),
						sin(dot(sp, vec3(-3.7, 3.1, 8.6)) + 0.43 * t + 1.3));
					vec3 wob = 0.013 * swirl + 0.007 * sin(t * (0.21 + 0.25 * h4.yzx) + 6.2832 * h4.zxy);
					rel = sp + wob - o;
					float tc = dot(rel, dir);
					vec3 wp = cam + rel;                              // where it is in the world
					float zd = water_y - wp.y;                        // its depth
					float RT = ext + 2.5 * sqrt(sb2);
					if (tc > 0.05 && tc < tmax && zd > 0.02 && dot(rel, rel) - tc * tc < RT * RT) {
						float fade = clamp((tc - 0.05) / 0.1, 0.0, 1.0) * clamp((tmax - tc) / 0.5, 0.0, 1.0);
						// its shape: up to 10 soft pieces laid out from its hashes, turning slowly about its own axis
						vec3 ax = normalize(h2.yzw - 0.5 + 1e-3);
						float om = (0.12 + 0.5 * h2.x) / (1.0 + s * 300.0);
						float ang = h4.x * 6.2832 + (t * om + 0.8 * sin(t * om * 0.7 + h4.y * 6.28) + 0.4 * sin(t * (0.21 + 0.2 * h2.w) + h4.z * 6.28)) * (h2.y < 0.5 ? -1.0 : 1.0);
						float rc = cos(ang), rs = sin(ang);
						vec3 pos = vec3(0.0);
						vec3 dw = normalize(h2.zwx - 0.5 + 1e-3);
						vec3 bend = normalize(h4.yzw - 0.5 + 1e-3);
						float sum = 0.0, strands = 0.0;
						int K = typ < 0.5 ? 8 : typ < 1.5 ? 10 : typ < 2.5 ? 7 : typ < 3.5 ? 1 : typ < 4.5 ? 8 : typ < 5.5 ? 10 : typ < 6.5 ? 10 : 1;
						float kw = typ < 0.5 ? 1.0 : typ < 1.5 ? 1.5 : typ < 2.5 ? 1.1 : typ < 3.5 ? 0.7 : typ < 4.5 ? 1.0 : typ < 5.5 ? 1.4 : typ < 6.5 ? 1.3 : typ < 7.5 ? 1.0 : 0.5;
						float fK = float(K);
						for (int j = 0; j < 10; j++) {
							if (j >= K) break;
							float fj = float(j);
							vec4 hj = hash44(vec4(h4.xyz * 97.0 + fj * 13.7, fj + h4.w * 31.0));
							vec3 rj = hj.xyz * 2.0 - 1.0;
							vec3 la = pos, lb = pos;
							float r = s, seg = 0.0, rag = 0.0, wj = 1.0;
							vec3 xa = vec3(0.0), xb = vec3(0.0);
							float xr = 0.0, xseg = 0.0, xrag = 0.0, xw = 0.0;
							if (typ < 0.5) {            // floc: lumps clumped together, branching, ragged, in a faint veil
								if (hj.w < 0.3) pos *= 0.35;
								dw = normalize(dw * 0.4 + rj); pos += dw * s * (0.45 + 0.5 * hj.w);
								pos *= min(1.0, 2.6 * s / max(length(pos), 1e-6));
								la = pos; lb = pos;
								r = s * (0.3 + 0.45 * hj.y * hj.y + 0.2 * hj.w); rag = 0.6; wj = 0.7 + 0.6 * hj.z;
								if (j == 0) { xr = s * 2.0; xw = 0.12; }
							} else if (typ < 1.5) {     // strand: a thin curling thread of mucus with the odd knot
								la = pos; bend = normalize(bend + 0.45 * rj); dw = normalize(dw + 0.24 * cross(dw, bend)); pos += dw * s * 0.8; lb = pos;
								r = s * 0.11 * (0.55 + 0.9 * sin(3.1416 * (fj + 0.5) / fK)) * (0.7 + 0.6 * hj.w); seg = 1.0; wj = 0.6 + 0.8 * hj.z;
								if (hj.w > 0.85) { xa = lb; xb = lb; xr = r * 2.6; xrag = 0.4; xw = 0.8; }
							} else if (typ < 2.5) {     // chain: beads on a gently curving line (a diatom chain)
								dw = normalize(dw * 5.0 + rj); pos += dw * s * 0.85 * (0.85 + 0.3 * hj.w); la = pos; lb = pos;
								r = s * 0.3 * (0.85 + 0.3 * hj.y); rag = 0.08;
								if (j > 0) { xa = la - dw * s * 0.85; xb = la; xr = r * 0.22; xseg = 1.0; xw = 0.3; }
							} else if (typ < 3.5) {     // flake: a thin translucent sheet, a bright line edge-on
								r = s * 1.6;
							} else if (typ < 4.5) {     // comet: a lump trailing a curving, fading tail
								if (j == 0) { r = s * 0.65; rag = 0.45; }
								else {
									la = pos; bend = normalize(bend + 0.3 * rj); pos += normalize(dw + 0.25 * bend) * s * 0.85; dw = normalize(dw + 0.25 * bend); lb = pos;
									r = s * 0.36 * (1.0 - fj / fK); seg = 1.0; wj = 1.0 - fj / fK;
								}
							} else if (typ < 5.5) {     // coil: a coiled thread, wound unevenly
								float rh = s * 1.2 * (1.0 - 0.035 * fj), rh2 = s * 1.2 * (1.0 - 0.035 * (fj + 1.0));
								float pa0 = fj * 0.42, pa1 = pa0 + 0.42;
								la = vec3(rh * cos(pa0), rh * sin(pa0), s * (0.12 * fj - 0.6)); lb = vec3(rh2 * cos(pa1), rh2 * sin(pa1), s * (0.12 * fj - 0.48));
								r = s * 0.1 * (0.7 + 0.5 * hj.y); seg = 1.0;
							} else if (typ < 6.5) {     // star: fine spines around a small core (a radiolarian)
								if (j == 0) { r = s * 0.38; rag = 0.3; }
								else { la = vec3(0.0); lb = normalize(rj + 1e-3) * s * (1.0 + 1.2 * hj.w); r = s * 0.06 * (0.7 + 0.6 * hj.y); seg = 1.0; wj = 0.7 + 0.5 * hj.z; }
							} else if (typ < 7.5) {     // speck: a single grain, round or a short rod
								la = -dw * s * hj.w * 1.2; lb = dw * s * hj.w * 1.2; seg = step(0.5, hj.w); r = s;
							} else {                    // pellet: a small dense rod (a faecal pellet)
								la = -dw * s * (1.0 + hj.w); lb = dw * s * (1.0 + hj.w); r = s * 0.7; seg = 1.0;
							}
							if (typ > 2.5 && typ < 3.5) {
								vec3 n0 = normalize(h2.xyz - 0.5 + 1e-3);
								vec3 nv = rotv(n0, ax, rc, rs);
								vec3 FA = rel + rotv(la, ax, rc, rs);
								vec3 pa = FA - dot(FA, dir) * dir;
								float cs = abs(dot(nv, dir));
								vec3 e1 = normalize(cross(nv, dir) + 1e-5), e2 = cross(dir, e1);
								float th = 0.06 * r;
								float fs1 = r * r + sb2, fs2 = r * r * cs * cs + th * th + sb2;
								float fx = dot(pa, e1), fy = dot(pa, e2);
								float fq = fx * fx / fs1 + fy * fy / fs2;
								fq *= 1.0 + 0.18 * (sin(fx * 4.1 / r + hj.x * 6.28) + sin(fy * 3.3 / max(sqrt(fs2), 1e-5) + hj.y * 6.28));
								float rimv = 1.0 + 0.6 * smoothstep(0.4, 1.0, fq);
								sum += kw * 0.8 * (r * sqrt(r * r * cs * cs + th * th)) / sqrt(fs1 * fs2) * exp(-fq) * rimv;
							} else {
								for (int pp = 0; pp < 2; pp++) {
									if (pp == 1 && xw <= 0.0) break;
									vec3 qa = pp == 0 ? la : xa, qb = pp == 0 ? lb : xb;
									float pr = pp == 0 ? r : xr, pseg = pp == 0 ? seg : xseg, prag = pp == 0 ? rag : xrag;
									vec3 A = rel + rotv(qa, ax, rc, rs);
									vec3 B = rel + rotv(qb, ax, rc, rs);
									vec3 pa = A - dot(A, dir) * dir;
									vec3 ab = (B - dot(B, dir) * dir) - pa;
									float tt = clamp(-dot(pa, ab) / max(dot(ab, ab), 1e-14), 0.0, 1.0);
									vec3 dv = pa + ab * tt;
									float d2 = dot(dv, dv);
									float re = pr;
									if (prag > 0.0) {
										vec3 dn = dv / sqrt(d2 + 0.01 * pr * pr);
										vec3 g1 = normalize(hj.xyz - 0.5 + 1e-3), g2 = normalize(hj.yzw - 0.5 + 1e-3), g3 = normalize(hj.wxy - 0.5 + 1e-3);
										float rn = sin(dot(dn, g1) * (2.0 + 2.0 * hj.w) + hj.x * 6.28) + sin(dot(dn, g2) * (3.3 + 2.0 * hj.x) + hj.y * 6.28)
											+ sin(dot(dn, g3) * (5.1 + 2.0 * hj.y) + hj.z * 6.28) + 0.6 * sin(sqrt(d2) / pr * (4.0 + 3.0 * hj.z) + hj.w * 6.28);
										re = pr * (1.0 + prag * 0.28 * rn);
									}
									float amp = mix(pr * pr / (pr * pr + sb2), pr / sqrt(pr * pr + sb2), pseg);
									float pv = amp * exp(-d2 / (re * re + sb2));
									if (pp == 1) sum += kw * xw * pv;
									else if (seg > 0.5 && typ < 5.5) strands = max(strands, kw * wj * pv);
									else sum += kw * wj * pv;
								}
							}
						}
						sum += strands;
						float hc = h2.w;
						vec3 tint = typ > 7.5 ? vec3(0.8, 0.62, 0.45) : hc < 0.6 ? vec3(1.0) : hc < 0.82 ? vec3(0.86, 1.0, 0.78) : hc < 0.93 ? vec3(1.0, 0.88, 0.7) : vec3(0.92, 0.95, 1.0);
						// Unreal: twinkling as it crosses the light net; sunlight down to it, then on to the lens
						float caus = caustic_net(wp, zd, water_sun_w, px, t);
						vec3 lit = exp(-water_a * (zd + tc) - cwat * tc);
						acc += 2.0 * sum * fade * life * caus * lit * tint;
					}
				}
			}
			if (tn.x < tn.y && tn.x < tn.z) { cell.x += st.x; tc0 = tn.x; tn.x += inv.x; }
			else if (tn.y < tn.z)           { cell.y += st.y; tc0 = tn.y; tn.y += inv.y; }
			else                            { cell.z += st.z; tc0 = tn.z; tn.z += inv.z; }
		}
		col = watercol * 2.1 * snow_k * phase * acc * water_exposure;
	}
	ALBEDO = col;
	ALPHA = 1.0;
}
