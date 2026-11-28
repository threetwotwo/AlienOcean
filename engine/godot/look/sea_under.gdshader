// Sea seen from below 0.3.2 (water surface thread; 0.2.0 engine thread's stand-in): the ported lagoon underside,
// lagoonwater v98 WINDOW_HLSL with its saved settings (UnderPhys 1, SunPhys 1, SkyFree 1, Fringe 0, SunTrue 0,
// Mirror 1, FloorNet 8 = the net as its mean in the mirror), on the FFT sea (look/sea_waves.gdshaderinc).
//  Snell's window: the share of the pixel's wave facets inside the critical angle (their slope spread + the pixel),
//    Fresnel through their mean, the sky along the refracted ray x n^2 (radiance entering the water).
//  The sun through the facets: its disc in water widened by the facets' spread (energy kept).
//  Outside the window (total internal reflection) the mirror: the water's own glow along the reflected ray + the
//    floor where that ray lands (lit by sun and sky through the water, then the path back): ported PHYS_CODE / v67.
// Opaque (cull_front: the mesh's back faces are what the eye sees from below), so look/underwater_view.gdshader adds
// the eye's own water path to the surface as to everything else. Values in nits x exposure.
// The mirror's floor comes from adapters/godot/sea_floor_map.gd (colour and top height under the eye, from above).
// 0.3.1 (27 Nov, storm stress test): past the critical angle the refracted ray is held at the grazing ray instead of
// snapping to straight up (v98 did the same snap; on calm water it never showed, on storm waves it drew hard blobs).
shader_type spatial;
render_mode unshaded, cull_front, world_vertex_coords, fog_disabled, shadows_disabled;
#include "res://look/water_physics.gdshaderinc"
#include "res://look/caustics.gdshaderinc"
#include "res://look/sky_dome.gdshaderinc"
#include "res://look/sea_waves.gdshaderinc"
#include "res://look/sea_bathy.gdshaderinc"
global uniform vec3 water_sun_air;      // toward the key body in air (Godot y-up)
global uniform float water_sun_lux;     // its beam, lux on a surface facing it
#include "res://look/sea_foam_shade.gdshaderinc"   // the whitecaps' look (after the lines above: it uses them)
uniform float nq = 32.0;                // quads per ring (the mesh's)
uniform float fine3 = 1.0;              // v89: the finest cascade, underside only
uniform float sun_size = 1.0;           // x the real sun's disc (0.533 deg)
uniform float mirror_k = 1.0;
#include "res://look/sea_floor_map.gdshaderinc"
#include "res://look/hot_probe.gdshaderinc"
varying vec2 still;
varying vec3 wi;                        // island world point

void vertex() {
	vec3 cam = sea_isl(CAMERA_POSITION_WORLD);
	vec2 lp = vec2(VERTEX.x, -VERTEX.z);
	vec2 st;
	wi = sea_vertex_world(lp, cam, water_y, nq, st);
	still = st;
	VERTEX = sea_gdt(wi);
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	vec3 cam = sea_isl(CAMERA_POSITION_WORLD);
	vec3 S = sea_slope(wi.xy, still, wi, cam, fine3);
	vec3 I = normalize(wi - cam);                          // eye -> surface, upward (island)
	vec3 Ls = sea_isl(normalize(water_sun_air));
	vec3 Nm = normalize(vec3(S.x, S.y, -1.0));            // the mean wave normal, down at the diver
	float cim = clamp(dot(I, -Nm), 0.0, 1.0);
	float fm = fwidth(1.0 - 1.7689 * (1.0 - cim * cim)) + 1e-5;
	vec3 acc = vec3(0.0);
	// v24: the sun's size in water
	float cz_s = max(Ls.z, 0.05);
	float sz_s = sqrt(clamp(1.0 - cz_s * cz_s, 0.0, 1.0)) / 1.33;
	float Rw_s = 0.0046514 * sun_size * 1.33 * sqrt(clamp(1.0 - sz_s * sz_s, 0.0, 1.0)) / cz_s;
	// v71: one evaluation at the mean normal for the facets (0.496 a^2 of slope spread per axis); m = distance to the
	// critical angle (m > 0 inside the window)
	float lenN = sqrt(S.x * S.x + S.y * S.y + 1.0);
	float m0 = 1.0 - 1.7689 * (1.0 - cim * cim);
	vec2 gm = 3.5378 * cim * (-I.xy - cim * S.xy / lenN) / lenN;
	float sg = sqrt(0.496 * max(S.z, 0.0) * dot(gm, gm) + 0.0833 * fm * fm) + 1e-6;
	float cov = 1.0 / (1.0 + exp(-clamp(1.702 * m0 / sg, -30.0, 30.0)));
	float mp = clamp(0.5 * (m0 + sqrt(m0 * m0 + 0.6366 * sg * sg)) / max(cov, 1e-4), 0.0, 1.0);
	float cie = sqrt(clamp(1.0 - (1.0 - mp) / 1.7689, 0.0, 1.0));
	float ctp = sqrt(mp);
	float rs = (1.33 * cie - ctp) / (1.33 * cie + ctp + 1e-6);
	float rp = (1.33 * ctp - cie) / (1.33 * ctp + cie + 1e-6);
	float tr = clamp(1.0 - 0.5 * (rs * rs + rp * rp), 0.0, 1.0) * cov;
	// the refracted ray; past the critical angle at the mean normal it stays at the grazing ray (refract with k held at
	// 0) instead of jumping to straight up: on storm waves the jump drew hard posterised blobs at the window's edge
	// (critique 27 Nov). Inside the window this is refract() exactly; the window's own edge is still cov's.
	float cni = dot(Nm, I);
	vec3 Tn = normalize(1.33 * I - (1.33 * cni + sqrt(max(1.0 - 1.7689 * (1.0 - cni * cni), 0.0))) * Nm);
	float tok = 1.0;
	// the sky along the refracted ray, x n^2 (v92 SkyFree 1: the sky's own brightness)
	acc += tr * sky_dome_nits(sea_gdt(Tn)) * 1.776889;
	{   // v24: the sun through the facets, its disc widened by the facets' spread
		float ang_i = sqrt(max(2.0 * (1.0 - dot(Tn, Ls)), 0.0));
		float bl_i = max(max(sqrt(0.014 * max(S.z, 0.004)), 1.5 * fwidth(ang_i)), 2e-3);
		float sp_i = 0.33 / max(Tn.z, 0.15);
		float s2_i = 0.25 * Rw_s * Rw_s + bl_i * bl_i + 0.496 * max(S.z, 0.0) * sp_i * sp_i;
		float up = step(0.0, water_sun_air.y);
		acc += up * tok * tr * vec3(1.0, 0.97, 0.9) * (1.7689 * water_sun_lux / (6.2831853 * s2_i)) * exp(-0.5 * ang_i * ang_i / s2_i);
	}
	// the whitecaps from below (tank v374): foam lets dull daylight through in place of the window's sky and sun
	SeaFoam fo = sea_foam_read(still, wi, cam, nq, TIME);
	acc = sea_foam_under_window(fo, acc);
	// the mirror (v67 UnderPhys): the water's glow along the reflected ray + the floor where it lands. v73 (S-B): where the
	// ray really lands, marched over the floor map (6 steps, then the crossing interpolated), within 30 m and where the
	// mirror counts (R > 0.06); its colour from the map. Outside the map: the still floor (v67's site depth).
	vec3 Rr = reflect(I, Nm);
	float H = max(sea_bathy_depth(vec2(wi.x, -wi.y)) + wi.z - water_y, 0.05);   // the floor beyond under this point
	float down = max(-Rr.z, 0.02);
	float uL = min(H / down, 400.0);
	vec3 f_lit = sea_bathy_sand(H);                       // the still sand's radiance (v67; FloorNet 8: the net as its mean)
	float R = 1.0 - tr;
	if (water_floor_org.w > 0.5 && uL < 30.0 && R > 0.06) {
		float f_fd = clamp((30.0 - uL) / 12.0, 0.0, 1.0) * clamp((R - 0.06) / 0.06, 0.0, 1.0);
		float f_tm = min((H + 1.0) / down, 30.0);
		float f_tp = 0.0;
		float f_gp = wi.z - floor_top(wi.xy);
		float f_th = f_tm;
		float f_hit = 0.0;
		for (int fi = 1; fi <= 6; fi++) {
			float f_t = f_tm * float(fi) / 6.0;
			vec3 f_q = wi + Rr * f_t;
			float f_g = f_q.z - floor_top(f_q.xy);
			if (f_hit < 0.5 && f_g <= 0.0) { f_th = mix(f_tp, f_t, clamp(f_gp / max(f_gp - f_g, 1e-3), 0.0, 1.0)); f_hit = 1.0; }
			if (f_hit < 0.5) { f_tp = f_t; f_gp = f_g; }
		}
		vec3 f_h = wi + Rr * f_th;
		vec3 fl = floor_light(f_h.xy);
		if (fl.x >= 0.0) f_lit = mix(f_lit, fl, f_fd);
		uL = mix(uL, f_th, f_fd);
	}
	vec3 c = water_a + water_b;
	vec3 rg = sea_gdt(normalize(Rr));
	vec3 glow = w_glow(rg, 0.0, uL);
	vec3 u_mir = glow + f_lit * exp(-c * uL);
	acc += (1.0 - tr) * mirror_k * u_mir;
	acc = sea_foam_under_haze(fo, acc);                     // the bubble cloud under breaking water: a bright haze
	ALBEDO = hot_probe_paint(acc * water_exposure, vec3(1.0, 0.0, 0.0));   // stress-shot switch (look/hot_probe), off in play
	if (hot_probe <= 0.0) ALBEDO = min(ALBEDO, vec3(30000.0));
}
