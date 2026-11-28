// Bubbles 0.1.0 (bubbles thread, 28 Nov 2026): air bubbles under water, the look of the Unreal-era bubbles v4
// (M_SL_Bubble in seeplab v4; numpy twin /mnt/project-files/bubbles/tools/look_v4/optics.py bubble_optics_T, shapes.py)
// drawn for Thalassa's bubble sources (adapters/godot/bubbles.gd). One quad per bubble (a MultiMesh slot), turned to face
// the eye and sized to the bubble; each pixel traces its own ray through the bubble:
//  - shape: an ellipsoid {x : |x Tm| = 1}: Moore's flattening chi = 1 + 9/64 We from the rise speed (capped 2.5), the
//    let-go ring (15 %, Lamb n = 2, Lamb damping), the wobble of bubbles over 2 mm (up to 20 % as Eo passes 4) with the
//    n = 2, m = 2 equator ellipse, all averaged over a 1/60 s exposure (a pearl's 100 Hz ring fades to a shimmer, big
//    bubbles wobble visibly); the axis tilts with the wake's zigzag. Bubbles resting under the surface or a ceiling flatten.
//  - light: the exact front hit, Fresnel water -> air with total internal reflection (the silver rim beyond ~0.75 r),
//    the ray refracted through the air lens and out the back (two refractions, the world seen through it upside down),
//    each ray's end lit by the water's own light field (look/water_physics.gdshaderinc w_glow, the sand under it, Snell's
//    window of sky above with the deep's mirror outside it, the refracted sun as a lobe) at the bubble's depth.
//  - small bubbles (under 1.5 px): the light averaged over the disc (4 golden-angle rays) and spread over a soft footprint
//    whose total equals the bubble's true area: no twinkle as it shrinks below a pixel (v4's baked disc did the same).
//  - the water between the eye and the bubble: x exp(-c d) + the glow along it (as underwater_view), so a bubble sits in
//    the fog exactly as the scene behind it does; alpha = coverage, drawn after the underwater view (render_priority 2).
// Motion: core/m34_bubbles/bubble_motion.gd, mirrored here line for line (base, eddy, wake, grown); per-slot record:
//   MODEL_MATRIX[3] p0, [0] v0, [1] drift at birth, [2] (t0, a0 m, cap_y); INSTANCE_CUSTOM (t_cap, t_end, w, tau)
//   COLOR (seed, kind 0 surface / 1 ceiling, -, -). now / drift_now: adapters/godot/bubbles.gd every drawn frame.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

#include "res://look/water_physics.gdshaderinc"

uniform float now = 0.0;           // s since the bubbles' epoch, at render time (interpolated between physics ticks)
uniform vec3 drift_now = vec3(0.0);// m: the water's displacement since start (current + swell orbit), as motes
uniform float bright_k = 1.0;      // art lever, 1 = physical
uniform float near_fade_m = 0.12;  // bubbles closer than this fade out (the lens is inside the head in first person)

const float NW = 1.333;
const float COS_C = 0.6614;        // Snell's window edge (48.6 deg from straight up)
const float NU = 1.05e-6;
const float POP_S = 0.04;          // s: a bubble's pop (swells 30 % and is gone)
const float CHI_MAX = 2.5;
const float WOB_MIN_MM = 2.0;
const float WOB_A = 0.2;
const float RING_A = 0.15;
const float EXPO = 1.0 / 60.0;
const float TILT = 0.2094;

varying flat vec3 v_c;
varying flat float v_A;
varying flat vec3 v_T0;
varying flat vec3 v_T1;
varying flat vec3 v_T2;
varying flat float v_rpx;
varying flat float v_alpha;
varying flat vec3 v_tr;
varying flat vec3 v_glow;
varying flat float v_z;
varying flat float v_sig;
varying flat vec3 v_ax;
varying flat float v_dchi;
varying vec3 v_wp;

// ---- motion (bubble_motion.gd) ----
vec3 eddy(vec3 p0, float w, float t) {
	vec3 d = vec3(0.0);
	float gold = PI * (3.0 - sqrt(5.0));
	float us[4]; vec3 ks[4]; vec3 es[4];
	float s2 = 0.0;
	for (int i = 0; i < 4; i++) {
		float kmag = TAU / 0.3 * pow(1.7, float(i));
		float th = acos(1.0 - 2.0 * ((float(i) + 0.5) / 4.0));
		float ph = float(i) * gold + 3.0;
		vec3 kh = vec3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph));
		ks[i] = kh * kmag; es[i] = normalize(cross(kh, vec3(0.3, 0.81, 0.5)));
		us[i] = pow(kmag, -1.0 / 3.0); s2 += us[i] * us[i];
	}
	float kk = 0.01 / sqrt(0.5 * s2);
	float pp[4] = float[](1.3, 4.1, 2.2, 5.9);
	for (int i = 0; i < 4; i++) {
		float u = us[i] * kk;
		float wi = u * length(ks[i]);
		float om = ks[i].y * w - wi;
		float ph0 = dot(ks[i], p0) + pp[i];
		float x = 0.5 * om * t;
		float sinc = abs(x) < 1e-4 ? 1.0 : sin(x) / x;
		d += es[i] * u * t * cos(ph0 + x) * sinc;
	}
	return d;
}
vec3 wake(float a, float w, float t, float ph, bool spiral, float tau) {
	float re = w * 2.0 * a / NU;
	if (re <= 275.0) return vec3(0.0);
	float al = TILT * sqrt(clamp((re - 275.0) / 125.0, 0.0, 1.0));
	float fz = 0.087 * w / (2.0 * a);
	float amp = w * tan(al) / (TAU * fz) * (1.0 - exp(-t / tau));
	vec2 dz = vec2(cos(1.7 * ph), sin(1.7 * ph)); vec2 dq = vec2(-dz.y, dz.x);
	float u = clamp((t - 0.5) / 1.0, 0.0, 1.0);
	float sp = spiral ? u * u * (3.0 - 2.0 * u) : 0.0;
	float x = TAU * fz * t + ph;
	vec2 o = amp * (sin(x) * dz - sp * cos(x) * dq);
	return vec3(o.x, 0.0, o.y);
}
// the wake's path tilt (the bubble's axis leans with its zigzag), as shapes.py
vec2 wake_tilt(float a, float w, float t, float ph, bool spiral) {
	float re = w * 2.0 * a / NU;
	if (re <= 275.0) return vec2(0.0);
	float al = TILT * sqrt(clamp((re - 275.0) / 125.0, 0.0, 1.0));
	float fz = 0.087 * w / (2.0 * a);
	vec2 dz = vec2(cos(1.7 * ph), sin(1.7 * ph)); vec2 dq = vec2(-dz.y, dz.x);
	float u = clamp((t - 0.5) / 1.0, 0.0, 1.0);
	float sp = spiral ? u * u * (3.0 - 2.0 * u) : 0.0;
	float x = TAU * fz * t + ph;
	return tan(al) * (cos(x) * dz + sp * sin(x) * dq);
}
float grown(float a0, float z0, float z) { return a0 * pow((10.3 + max(z0, 0.0)) / (10.3 + max(z, 0.0)), 1.0 / 3.0); }

// ---- optics (look_v4/optics.py) ----
float fresnel(float ci, float eta) {
	ci = clamp(ci, 0.0, 1.0);
	float s2 = eta * eta * (1.0 - ci * ci);
	if (s2 >= 1.0) return 1.0;
	float ct = sqrt(1.0 - s2);
	float rs = (eta * ci - ct) / (eta * ci + ct + 1e-12);
	float rp = (eta * ct - ci) / (eta * ct + ci + 1e-12);
	return 0.5 * (rs * rs + rp * rp);
}
// the water's light seen along d from depth z (nits): haze along the ray + what ends it (sky window / deep mirror above,
// the sand below) + the refracted sun as a lobe of width sig
vec3 bub_env(vec3 d, float z, float sig) {
	vec3 c = water_a + water_b;
	vec3 L;
	if (d.y > 1e-3) {
		float s = min(z / d.y, 400.0);
		float win = clamp((d.y - COS_C) / 0.012 + 0.5, 0.0, 1.0);
		vec3 sky = vec3(water_ek0 / (PI * 0.5628));
		vec3 mir = w_glow(vec3(d.x, -d.y, d.z), 0.02, 400.0);
		L = w_glow(d, z, s) + exp(-c * s) * mix(mir, sky, win);
		float muw = max(water_sun_w.y, 0.05);
		vec3 Es = water_es0 * exp(-water_kd * z) / muw;
		float ang = acos(clamp(dot(d, water_sun_w), -1.0, 1.0));
		L += Es * exp(-ang * ang / (2.0 * sig * sig)) / (TAU * sig * sig);
	} else if (d.y < -1e-3) {
		float fd = w_floor_dist(d, z);
		fd = fd < 0.0 ? 400.0 : min(fd, 400.0);
		L = w_glow(d, z, fd) + exp(-c * fd) * w_floor_nits();
	} else {
		L = w_glow(d, z, 400.0);
	}
	return L;
}
// ray / ellipsoid {x : |T x| = 1} (x in units of the equatorial radius, centre at 0): the near hit's ray parameter s, and
// the hit's impact radius rn in the ellipsoid's own unit-sphere space (1 = the silhouette, for the edge's coverage)
float near_s(mat3 T, vec3 o, vec3 v, out float rn) {
	vec3 vy = T * v; float vl = length(vy); vec3 vyh = vy / vl;
	vec3 oy = T * o;
	vec3 imp = oy - dot(oy, vyh) * vyh;
	rn = length(imp);
	return (-dot(oy, vyh) - sqrt(1.0 - min(rn * rn, 0.9999))) / vl;
}
float far_s(mat3 T, vec3 x, vec3 d) {
	vec3 a3 = T * d, b3 = T * x;
	float a = dot(a3, a3), b = dot(b3, a3), c = dot(b3, b3) - 1.0;
	return (-b + sqrt(max(b * b - a * c, 0.0))) / a;
}
// a bubble = two half ellipsoids sharing the equator: the dome Tt above it, the flatter base Tb below (Tb = Tt for small
// bubbles; big ones are spherical caps, a rounded top over a flat, wobbling base). Returns the light along v from o
// (both in equatorial radii), rn = the near hit's impact radius (coverage)
vec3 optics(vec3 o, vec3 v, mat3 Tt, mat3 Tb, vec3 ax, float z, float sig, out float rn) {
	float rnt;
	float s = near_s(Tt, o, v, rnt);
	mat3 T = Tt; rn = rnt;
	if (dot(o + s * v, ax) < 0.0) { s = near_s(Tb, o, v, rn); T = Tb; }
	vec3 x1 = o + s * v;
	vec3 N = normalize(T * (T * x1));
	float ci = -dot(v, N);
	float F1 = fresnel(ci, NW);
	vec3 R = v + 2.0 * ci * N;
	vec3 Lr = bub_env(R, z, sig);
	vec3 t1 = refract(v, N, NW);
	if (F1 >= 1.0 || dot(t1, t1) < 1e-6) return Lr;
	float s2 = far_s(Tt, x1, t1);
	mat3 T2 = Tt;
	if (dot(x1 + s2 * t1, ax) < 0.0) { s2 = far_s(Tb, x1, t1); T2 = Tb; }
	vec3 N2 = normalize(T2 * (T2 * (x1 + s2 * t1)));
	float F2 = fresnel(dot(t1, N2), 1.0 / NW);
	vec3 t2 = refract(t1, -N2, 1.0 / NW);
	vec3 Lt = bub_env(normalize(t2), z, sig);
	return F1 * Lr + (1.0 - F1) * (1.0 - F2) * Lt;
}

void vertex() {
	vec3 p0 = MODEL_MATRIX[3].xyz;
	vec3 v0 = MODEL_MATRIX[0].xyz;
	vec3 D0 = MODEL_MATRIX[1].xyz;
	float t0 = MODEL_MATRIX[2].x, a0 = MODEL_MATRIX[2].y, cap_y = MODEL_MATRIX[2].z;
	float t_cap = INSTANCE_CUSTOM.x, t_end = INSTANCE_CUSTOM.y, w = INSTANCE_CUSTOM.z, tau = INSTANCE_CUSTOM.w;
	float seed = COLOR.x; float kind = COLOR.y;
	float t = now - t0;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	v_alpha = 0.0;
	v_ax = vec3(0.0, 1.0, 0.0); v_dchi = 0.0;
	POSITION = vec4(0.0, 0.0, 2.0, 1.0);          // dead / hidden slot: a point outside the view
	if (a0 > 0.0 && t >= 0.0 && t < t_end + POP_S && cam.y < water_y) {
		float tc = t;
		float ph = seed * TAU;
		bool spiral = fract(seed * 7.31) < 0.5;
		float z0 = water_y - p0.y;
		float a_cap = grown(a0, z0, water_y - cap_y);
		vec3 up = vec3(0.0, w, 0.0);
		vec3 c = p0 + up * tc + (v0 - up) * (tau * (1.0 - exp(-tc / tau)));
		c += eddy(p0, w, tc);
		float y_max = cap_y - a_cap;
		float q = y_max - c.y;
		float wk = smoothstep(0.0, 4.0 * a_cap, q);    // the wake dies as it comes to rest
		c += wake(a0, w, tc, ph, spiral, tau) * wk;
		float xq = q / a_cap;                         // soft landing (BubbleMotion.soft_cap)
		c.y = y_max - a_cap * (max(xq, 0.0) + log(1.0 + exp(-abs(xq))));
		c += drift_now - D0;                         // it rides the water (current, swell orbit), as the motes
		float z = max(water_y - c.y, 0.0);
		float a = grown(a0, z0, z);
		// shape (shapes.py): Moore's flattening, the let-go ring, the wobble over 2 mm, the axis tilting with the wake
		float om2 = sqrt(0.876 / (1023.0 * a * a * a));
		float xb = 0.5 * om2 * EXPO;
		float bl = abs(sin(xb) / xb);
		float bo = 1023.0 * 9.81 * a * a / 0.073;
		float we = 1023.0 * w * w * 2.0 * a / 0.073;
		// Moore (small We) and, for big bubbles, Wellek's contaminated-water fit E = 1 / (1 + 0.163 Eo^0.757), whichever is rounder
		float eo = 1023.0 * 9.81 * 4.0 * a * a / 0.073;
		float chi = min(min(1.0 + 0.140625 * we, 1.0 + 0.163 * pow(eo, 0.757)), CHI_MAX);
		chi = 1.0 + (chi - 1.0) * (1.0 - exp(-tc / tau));
		chi *= 1.0 + RING_A * exp(-tc / (a * a / (5.0 * NU))) * bl * cos(om2 * tc);
		vec2 ee = vec2(0.0);
		if (a * 1000.0 > WOB_MIN_MM) {
			float fz = 0.087 * w / (2.0 * a);
			float wa = WOB_A * clamp((4.0 * bo - 1.0) / 3.0, 0.0, 1.0) * bl * (0.6 + 0.4 * sin(TAU * fz * t + 3.0 * ph));
			chi *= 1.0 + wa * sin(om2 * t + ph);
			float x2 = 1.13 * om2 * t + 2.0 * ph;
			ee = 0.8 * wa * vec2(cos(x2), sin(x2));
		}
		vec2 tl = wake_tilt(a0, w, tc, ph, spiral) * wk;
		float rest = 1.0 - smoothstep(0.0, 2.0 * a_cap, q);   // resting under its cap: pressed flat against it
		chi = mix(chi, kind > 0.5 ? 1.9 : 1.5, rest);
		float pop = clamp((t - t_end) / POP_S, 0.0, 1.0);
		a *= 1.0 + 0.3 * pop;
		vec3 ax = normalize(vec3(tl.x, 1.0, tl.y));
		vec3 e1 = normalize(cross(ax, vec3(0.0, 0.0, 1.0)) + vec3(1e-4, 0.0, 0.0));
		vec3 e2 = cross(ax, e1);
		mat3 Tm = mat3(1.0) + (chi - 1.0) * outerProduct(ax, ax)
			+ ee.x * (outerProduct(e1, e1) - outerProduct(e2, e2)) + ee.y * (outerProduct(e1, e2) + outerProduct(e2, e1));
		// big bubbles are spherical caps: a rounder dome over a flatter base (same volume kept by the mean flattening)
		float cap_k = smoothstep(4.0, 9.0, a * 1000.0);
		float chi_t = 1.0 + (chi - 1.0) * (1.0 - 0.45 * cap_k);
		float chi_b = 1.0 + (chi - 1.0) * (1.0 + 0.9 * cap_k);
		Tm += (chi_t - chi) * outerProduct(ax, ax);
		v_ax = ax; v_dchi = chi_b - chi_t;
		float A = a * pow(chi, 1.0 / 3.0);
		float kq = max(1.0, 1.0 / min(chi_t, chi)) * (1.0 + length(ee));
		// the quad: square to the eye's line to the bubble, wide enough for the silhouette (+ the cone's growth up close)
		vec3 to = c - cam;
		float dist = length(to);
		vec3 f = to / max(dist, 1e-5);
		float pix = 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);
		float rpx = A / (max(dist, 1e-4) * pix);
		float R = A * kq * 1.08;
		R *= dist / sqrt(max(dist * dist - R * R, 1e-6));
		float rq = max(R, 2.4 * pix * dist);          // at least 2.4 px across the footprint
		vec3 rt = normalize(cross(f, abs(f.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 uq = cross(rt, f);
		vec3 wp = c + (rt * VERTEX.x + uq * VERTEX.y) * 2.0 * rq;
		float zc = max(water_y - cam.y, 0.0);
		vec3 cw = water_a + water_b;
		v_tr = exp(-cw * dist);
		v_glow = w_glow(f, zc, dist);
		v_c = c; v_A = A; v_T0 = Tm[0]; v_T1 = Tm[1]; v_T2 = Tm[2];
		v_rpx = rpx; v_z = z; v_wp = wp;
		v_sig = clamp(2.0 / max(rpx, 1e-3), 0.0524, 0.35);
		float born = clamp(t / 0.03, 0.0, 1.0);
		v_alpha = born * (1.0 - pop) * smoothstep(0.5 * near_fade_m, near_fade_m, dist) * (1.0 - smoothstep(30.0, 45.0, dist));
		if (v_alpha > 0.0) POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
	}
}

void fragment() {
	if (v_alpha <= 0.0) discard;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 v = normalize(v_wp - cam);
	mat3 Tt = mat3(v_T0, v_T1, v_T2);
	mat3 Tb = Tt + v_dchi * outerProduct(v_ax, v_ax);
	vec3 o = (cam - v_c) / v_A;
	vec3 L; float cov; float rn;
	if (v_rpx >= 1.5) {
		L = optics(o, v, Tt, Tb, v_ax, v_z, v_sig, rn);
		cov = clamp((1.0 - rn) * v_rpx + 0.5, 0.0, 1.0);
		if (cov <= 0.0) discard;
	} else {
		// under 1.5 px: the disc's mean light (4 parallel rays across it), spread over a soft footprint holding the
		// bubble's true area (no twinkle as it shrinks below a pixel)
		vec3 vc = normalize(v_c - cam);
		vec3 oc = (cam - v_c) / v_A;
		vec3 e1 = normalize(cross(vc, abs(vc.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 e2 = cross(vc, e1);
		L = vec3(0.0);
		float sc = 1.0 / max(v_T1.y, 1.0);             // the flattened disc's vertical reach
		for (int k = 0; k < 4; k++) {
			float fk = float(k) + 0.5;
			float rho = 0.95 * sqrt(fk / 4.0);
			float an = fk * 2.39996;
			float rk;
			L += optics(oc + rho * (cos(an) * e1 + sin(an) * e2 * sc), vc, Tt, Tb, v_ax, v_z, v_sig, rk);
		}
		L *= 0.25;
		vec3 ow = cam + dot(v_c - cam, v) * v - v_c;     // this pixel's ray's miss distance from the centre
		float rpx = length(ow) / v_A * v_rpx;
		float sg = 0.7;
		cov = min(v_rpx * v_rpx / (2.0 * sg * sg) * exp(-rpx * rpx / (2.0 * sg * sg)), 1.0);
		if (cov < 1e-3) discard;
	}
	ALBEDO = max((L * bright_k * v_tr + v_glow) * water_exposure, vec3(0.0));
	ALPHA = cov * v_alpha;
}
