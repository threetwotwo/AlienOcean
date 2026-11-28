// Sea seen from above 0.8.2 (water surface thread): the lagoon's top side on the FFT sea (look/sea_waves.gdshaderinc).
// 0.2.0 (28 Nov): the water's own colour, one model from the lagoon's sand to the open sea (Rrs x Ed where the floor
// fades; it read jet black: the lagoon's path only saw the floor).
// 0.5.0 (28 Nov): the sun's glitter sparkles (the tank's moon sparkle, run for the sun).
// 0.4.0 (28 Nov): the sun through the crests (tank v374's crest glow, its GLOW_LOBE 0.25).
// 0.3.0 (28 Nov): the unresolved waves average the Fresnel and lift the reflected ray (the far sea mirrored a grey band).
//  Normal: the drawn slope (TOP_NORMAL_HLSL, with open water v144's lean: a face seen nearly edge-on turns back up).
//  Reflection: the sky along the mirrored ray (look/sky_dome.gdshaderinc: the sky overhead) x Fresnel (n 1.333), and
//    the sun's glint: its disc widened by the facets' spread (reflection doubles a tilt: 2 S.z of angle variance),
//    energy kept (lagoonwater v12: a lobe widened to a pixel keeps its light, not its peak).
//  Through the surface: the scene under the water, shifted by the TRUE bend (HANDOVER 14 Nov item 2: Unreal moved
//    the picture by the surface tilt on the screen, blind to depth; the true shift is depth x the refracted ray's
//    lean, a few cm at 2 m), dimmed by the water along the refracted ray and plus the water's own glow along it
//    (water_physics w_glow, the underwater view's maths), x (1 - Fresnel).
// Transparent, cull_back (the eye above sees the mesh's front faces); next pass of look/sea_under.gdshader.
// Values in nits x exposure; the screen already holds exposed values.
shader_type spatial;
render_mode unshaded, cull_back, world_vertex_coords, fog_disabled, shadows_disabled, depth_draw_always;
#include "res://look/water_physics.gdshaderinc"
#include "res://look/caustics.gdshaderinc"
#include "res://look/sky_dome.gdshaderinc"
#include "res://look/sea_waves.gdshaderinc"
#include "res://look/sea_bathy.gdshaderinc"
#include "res://look/sea_floor_map.gdshaderinc"
global uniform vec3 water_sun_air;
global uniform float water_sun_lux;
#include "res://look/sea_foam_shade.gdshaderinc"   // the whitecaps' look (after the lines above: it uses them)
global uniform float water_sky_nits;   // the clear sky as a uniform dome, nits (sky lux / pi)
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
// The water's own colour, seen through the surface (28 Nov, Gary: "unify them, for seamless transitions"): the
// shallow-water reflectance model (Maritorena et al. 1994, Lee et al. 1998): what comes up through the surface is the
// floor, dimmed by the water on the way, plus the deep water's own light, Rrs x Ed, in the share the floor no longer
// covers, 1 - exp(-(Kd + Ku) H) for H m of water under this point. Over the lagoon's sand H is a few metres and the
// floor leads; past the shelf H grows and the colour runs smoothly into the open sea's (the tank v374 SEA_SHADE's
// "light coming out of the water", Rrs x Ed (1 - F) / 0.98); with no floor at all it is the open sea's colour. The
// water's Rrs is WorldRoot's water_rrs (WaterOptics.optics: the lagoon's from its own optics, the ocean's the tank's).
// water_rrs: declared in water_physics.gdshaderinc
// water_rrs_deep (the open ocean's Rrs, WaterOptics.OCEAN): declared in water_physics.gdshaderinc (the abyss under water blends to it too)
// art levers on the deep water's colour (1, 0 = physical; FftSea sets 2, 0.5): x brightness, and a share pulled toward
// a turquoise of the same blue (Abzu's lighter sea; art direction over the physical ink-navy)
// sea_open_gain / sea_open_teal: declared in water_physics.gdshaderinc (the abyss under water uses them too)
global uniform float sea_crest_sd;      // the crests' height spread, m (cascades 1-2; the tank's SeaK.x; FftSea)
global uniform float sea_sparkle;       // 1 = the sparkling glitter (0.5.0), 0 = one smooth lobe as before (FftSea, AO_SPARKLE)
global uniform float sea_crest_glow;    // art lever on the light through the crests (1 = the tank's; FftSea)
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float nq = 32.0;
uniform float sun_size = 1.0;
uniform float sea_body_wobble = 3.0;   // art lever (0.8.2): how much the waves wiggle the edges of things under the surface (1 = the waves' true share)
uniform float sea_body_veil = 2.5;     // art lever (0.8.2): how much water a body under the surface is seen through, as a multiple of the true path
uniform float sea_horizon_lift = 1.0;   // art lever: how far up the sky the rough sea's mean mirrored ray comes from (1 = as measured)
varying vec2 still;
varying vec3 wi;

void vertex() {
	vec3 cam = sea_isl(CAMERA_POSITION_WORLD);
	vec2 lp = vec2(VERTEX.x, -VERTEX.z);
	vec2 st;
	wi = sea_vertex_world(lp, cam, water_y, nq, st);
	still = st;
	VERTEX = sea_gdt(wi);
	NORMAL = vec3(0.0, 1.0, 0.0);
}

float fresnel_air(float ci) {          // unpolarised, air -> water, n 1.333
	float st2 = (1.0 - ci * ci) / 1.776889;
	float ct = sqrt(max(1.0 - st2, 0.0));
	float rs = (ci - 1.333 * ct) / (ci + 1.333 * ct);
	float rp = (1.333 * ci - ct) / (1.333 * ci + ct);
	return 0.5 * (rs * rs + rp * rp);
}

void fragment() {
	vec3 cam = sea_isl(CAMERA_POSITION_WORLD);
	vec3 sj0, sj1; vec2 sjl;
	vec3 S = sea_slope_j(wi.xy, still, wi, cam, 0.0, sj0, sj1, sjl);   // + cascades 0-1's squeeze for the foam (sea speed thread)
	vec3 V = normalize(cam - wi);                          // toward the eye (island)
	vec3 N = normalize(vec3(-S.x, -S.y, 1.0));
	// the whitecaps (tank v374 foam look): the foam map drawn as lace and streaks; its 2 cm relief tilts the normal
	SeaFoam fo = sea_foam_read_j(still, wi, cam, nq, TIME, sj0, sj1, sjl);
	N = sea_foam_bump(N, fo.foam, still);
	N = normalize(N + vec3(0.0, 0.0, 2.0 * clamp((0.05 - dot(N, V)) / 0.05, 0.0, 1.0)));   // open water v144
	float ci = clamp(dot(N, V), 1e-3, 1.0);
	// 0.3.0: the waves too small to draw still tilt the mirror (S.z, their slope variance, grows with distance): averaged
	// over them the Fresnel never reaches 1 at the horizon and the mean reflected ray comes from higher, bluer sky
	// (Bruneton, Neyret & Holzschuch 2010, meanFresnel; as a ratio to the smooth case so the near sea is unchanged)
	// 0.8.0: Bruneton's sigma is the slope spread along the view (one axis); S.z sums both axes, so half of it (the sea is
	// near isotropic). Was the sum: the horizon's mirror ran ~0.4 where it should be ~0.55 (waterline thread, 28 Nov)
	float sv = sqrt(0.5 * max(S.z, 0.0));
	float R = fresnel_air(ci) * (pow(1.0 - ci, 5.0 * exp(-2.69 * sv)) / (1.0 + 22.7 * pow(sv, 1.5))) / max(pow(1.0 - ci, 5.0), 1e-6);
	R = min(R, fresnel_air(ci));
	vec3 Rd0 = reflect(-V, N);                            // the mirror ray of the drawn facet (the sun's glint)
	vec3 Rd = normalize(Rd0 + vec3(0.0, 0.0, sea_horizon_lift * 1.414 * sv));   // the mean mirrored ray from higher sky (1.414: as before the per-axis sigma; art lever)
	vec3 refl = sky_dome_nits(sea_gdt(Rd));
	// the sun's glint
	vec3 Ls = sea_isl(normalize(water_sun_air));
	float ang = sqrt(max(2.0 * (1.0 - dot(Rd0, Ls)), 0.0));
	float sigs = 0.25 * pow(0.0046514 * sun_size, 2.0);
	float sig0sq = sigs + 2.0 * max(S.z, 1e-5);
	float sig2 = max(sig0sq, pow(1.5 * fwidth(ang), 2.0));
	float up = step(0.0, water_sun_air.y);
	vec3 sun_c = up * vec3(1.0, 0.97, 0.9) * water_sun_lux;
	vec3 g_mean = sun_c / (6.2831853 * sig2) * exp(-0.5 * ang * ang / sig2);   // the glitter's average over the facets
	// 0.5.0: the glitter sparkles (the tank v98/v129/v157/v166 moon sparkle, run for the sun by day; there Unreal's own
	// per-pixel glint sparkled): near, the facets too small to draw that tilt just right flash the sun back as sharp
	// points (35 cm cells, each its own tilt, within 1.5 deg of the sun), with the drawn waves' own sharp reflection of
	// the disc; far off, where a pixel holds many cells, the average path broken into twinkling 1 px points, its mean
	// kept. Was one smooth lobe everywhere: a blurry white sheet under the sun.
	vec2 ms_p = still / 0.35;
	vec2 ms_c = floor(ms_p);
	float ms_h1 = fract(sin(dot(ms_c, vec2(12.9898, 78.233))) * 43758.5453);
	float ms_h2 = fract(sin(dot(ms_c, vec2(39.3468, 11.135))) * 24634.6345);
	vec3 ms_n = normalize(N + vec3(ms_h1 - 0.5, ms_h2 - 0.5, 0.0) * 2.0 * max(sv, 0.02));
	float ms_hit = smoothstep(0.99965732, 0.99965732 + 0.00015, dot(reflect(-V, ms_n), Ls));   // cos 1.5 deg
	vec2 ms_fw = fwidth(ms_p);
	float ms_fr = max(ms_fw.x, ms_fw.y);                   // cells per pixel
	float ms_px = max(ms_fr, 1.0);
	float ms_far = smoothstep(0.5, 2.0, ms_fr);
	vec3 g_pts = sun_c / (PI * 6.854e-4) / (ms_px * ms_px) * ms_hit * fresnel_air(clamp(dot(ms_n, V), 1e-3, 1.0)) / max(R, 1e-3);
	float sig2s = max(sigs, pow(1.5 * fwidth(ang), 2.0));
	vec3 g_disc = sun_c / (6.2831853 * sig2s) * exp(-0.5 * ang * ang / sig2s);   // the drawn facets' own sharp sun
	vec2 tw_jx = dFdx(ms_p), tw_jy = dFdy(ms_p);
	vec2 tw_l2 = log2(max(max(abs(tw_jx), abs(tw_jy)) * 3.0, vec2(1.0)));
	float tw_l = max(tw_l2.x, tw_l2.y);
	float tw_f = tw_l - floor(tw_l);
	float tw = 0.0;
	for (int tq = 0; tq < 2; tq++) {
		vec2 tw_lv = floor(tw_l2) + float(tq);
		vec2 tw_s = exp2(tw_lv);
		vec2 tw_cc = ms_p / tw_s;
		vec2 tw_i = floor(tw_cc);
		float tw_h1 = fract(sin(dot(tw_i + tw_lv * 17.0, vec2(41.3, 289.1))) * 43758.5453);
		float tw_h2 = fract(tw_h1 * 37.71 + 0.31);
		float tw_h3 = fract(tw_h1 * 91.37 + 0.77);
		vec2 tw_h4 = fract(tw_h1 * vec2(13.17, 7.73) + 0.43);
		float tw_fp = fract(TIME / (1.0 + 2.0 * tw_h2) + tw_h3 * 7.0);
		float tw_pu = smoothstep(0.0, 0.1, tw_fp) * (1.0 - smoothstep(0.1, 0.5, tw_fp));
		vec2 tw_d = tw_i + 0.25 + 0.5 * tw_h4 - tw_cc;     // to the point, in cells
		vec2 tw_ax = tw_jx / tw_s, tw_ay = tw_jy / tw_s;
		float tw_det = tw_ax.x * tw_ay.y - tw_ax.y * tw_ay.x;
		float tw_dt = abs(tw_det) > 1e-12 ? tw_det : 1e-12;
		vec2 tw_px = vec2(tw_ay.y * tw_d.x - tw_ay.x * tw_d.y, tw_ax.x * tw_d.y - tw_ax.y * tw_d.x) / tw_dt;
		float tw_dot = clamp(1.0 - length(tw_px), 0.0, 1.0);
		float tw_nm = min(1.0 / max(1.047 * abs(tw_dt), 1e-6), 12.0);
		tw += (tq == 0 ? 1.0 - tw_f : tw_f) * step(tw_h1 * 2.0, 1.0) * tw_pu * tw_dot * tw_nm / (0.5 * 0.3);
	}
	float tw_m = mix(1.0, tw, 0.6);
	refl += mix(g_disc + g_pts, g_mean * tw_m, ms_far) * sea_sparkle + g_mean * (1.0 - sea_sparkle);
	// through the surface: the true bend
	vec3 T = refract(-V, N, 1.0 / 1.333);                 // down into the water
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vp.xyz /= vp.w;
	vec3 qg = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;   // what the straight view meets (Godot)
	vec3 q = sea_isl(qg);
	float h = clamp(wi.z - q.z, 0.0, 60.0);                // its depth under this bit of surface
	vec2 shift = (T.xy / max(-T.z, 0.05) + V.xy / max(V.z, 0.05)) * h;   // bent landing - straight landing
	// 0.7.0: two passes. The bend assumes the floor lies at the straight view's depth h; where the floor rises toward the
	// eye (looking down past a reef wall) the bent point lands on the shallow reef flat and its sand glowed cyan over
	// the deep (water surface thread, 28 Nov). The second pass bends again by the depth found there (a fixed-point step).
	vec2 tl = T.xy / max(-T.z, 0.05);                       // m along per m down
	float Hg = max(wi.z - floor_top(wi.xy), 0.0);
	for (int k = 0; k < 4; k++) Hg = mix(Hg, max(wi.z - floor_top(wi.xy + tl * Hg), 0.0), 0.7);   // damped: walls
	// 0.8.2 (Gary 28 Nov: bodies under the surface "flat and cut out", independent review): the mean bend slides the picture
	// along an upright body, so its sides stayed straight; only the waves' share of the bend moves an edge sideways. A body
	// (anything standing clear above the floor map, which leaves movers out) is drawn from the screen moved by that share
	// alone, scaled by the art lever and capped at 8 cm: a wiggle of its own outline, never a copy
	vec3 T0 = refract(-V, vec3(0.0, 0.0, 1.0), 1.0 / 1.333);
	vec2 dw = (tl - T0.xy / max(-T0.z, 0.05)) * min(h / max(V.z, 0.2), 2.0) * sea_body_wobble;
	dw *= min(1.0, 0.08 / max(length(dw), 1e-5));
	vec4 cw = PROJECTION_MATRIX * VIEW_MATRIX * vec4(sea_gdt(q + vec3(dw, 0.0)), 1.0);
	vec2 uvw = clamp(cw.xy / cw.w * 0.5 + 0.5, vec2(0.0), vec2(1.0));
	vec4 vw = INV_PROJECTION_MATRIX * vec4(uvw * 2.0 - 1.0, texture(depth_tex, uvw).r, 1.0);
	float hw = wi.z - sea_isl((INV_VIEW_MATRIX * vec4(vw.xyz / vw.w, 1.0)).xyz).z;
	// the wiggle never carries a shallower thing out over deeper water beside it (a fringe of the body on the water: the
	// ghost rule's test, 0.8.1): edges move inward only
	if (hw < 0.0 || hw < 0.5 * h - 0.1) { uvw = SCREEN_UV; hw = h; }
	float body = smoothstep(0.08, 0.30, Hg - hw);
	bool occl = false;                                      // the bent ray's sample lands on a body (it hides the floor there)
	vec2 uvb = SCREEN_UV; float hb = h;
	for (int it = 0; it < 2; it++) {
		float hs = it == 0 ? h : clamp(hb, 0.0, h);
		vec3 qb = q + vec3(shift * (hs / max(h, 1e-4)), 0.0);
		vec4 cs = PROJECTION_MATRIX * VIEW_MATRIX * vec4(sea_gdt(qb), 1.0);
		uvb = cs.xy / cs.w * 0.5 + 0.5;
		// near the screen edge (the screen may not hold the bent point) the shift is squeezed: it goes at most half way
		// to the edge along its line, so rows stay in order (a clamp smears the edge row into streaks)
		vec2 du = uvb - SCREEN_UV;
		vec2 room = mix((vec2(1.0) - SCREEN_UV) / max(du, vec2(1e-6)), -SCREEN_UV / min(du, vec2(-1e-6)), step(du, vec2(0.0)));
		uvb = SCREEN_UV + du * clamp(min(room.x, room.y) * 0.5, 0.0, 1.0);   // at most half way to the edge: a smooth squeeze
		float db = texture(depth_tex, uvb).r;
		vec4 vb = INV_PROJECTION_MATRIX * vec4(uvb * 2.0 - 1.0, db, 1.0);
		vb.xyz /= vb.w;
		hb = wi.z - sea_isl((INV_VIEW_MATRIX * vec4(vb.xyz, 1.0)).xyz).z;
		if (it == 0 && Hg - hb > 0.4) { occl = true; break; }   // 0.8.2: never bend again by a body's depth (a third patch)
		if (hb < 0.0 || hb > h - 0.5) break;                  // above the water (an edge), or the floor where it was assumed
	}
	// the bent point is above the water (an edge), or still on something far shallower than the floor it was bent for
	// (a body or rock between: sampling it there drew it twice, Gary 28 Nov "a doubling of the player body"): no shift
	// 0.8.1: and the point sampled must lie beyond this bit of surface, seen from the eye: the bent ray goes on away from
	// the eye, so it cannot meet anything nearer. In shallow water (a girl standing on a rock skirt, 0.5 m of water behind
	// her) her submerged hips, nearer than the water seen beside them, passed the depth test above and were drawn a
	// second time on that water (Gary 28 Nov playtest, "double ghosting of refraction still present")
	float kb = (hb < 0.0 || hb < 0.5 * h - 0.25) ? 0.0 : 1.0;
	if (kb > 0.0 && length(V.xy) > 0.05) {
		vec4 vs = INV_PROJECTION_MATRIX * vec4(uvb * 2.0 - 1.0, texture(depth_tex, uvb).r, 1.0);
		vec3 qs = sea_isl((INV_VIEW_MATRIX * vec4(vs.xyz / vs.w, 1.0)).xyz);   // the point the bent sample shows
		kb *= smoothstep(-0.3, -0.05, dot(qs.xy - wi.xy, -normalize(V.xy)));
	}
	if (occl) kb = 0.0;
	// 0.8.2: a body pixel is its own picture moved by the waves; elsewhere the bent sample. Where the bent sample was
	// refused (kb 0: a body hides the floor the ray lands on) the unshifted screen showed the floor 0.9 m out of register,
	// a body-shaped patch beside her (the "halo"): the landing model fills it now (wsc below), not the screen
	vec3 scene = mix(textureLod(screen_tex, uvb, 0.0).rgb, textureLod(screen_tex, uvw, 0.0).rgb, body);
	float hsc = mix(max(hb, 0.0), hw, body);               // the depth of what the screen shows there
	vec3 c = water_a + water_b;
	// 0.8.0: where the bent ray really lands, followed through the floor map (adapters/godot/sea_floor_map.gd: the floor's
	// light and top round the eye) and past it the floor beyond (sea_bathy). The screen alone cannot say: at a slant the
	// straight view runs far past the floor under this point (down a reef's slope it found the floor 300 m on and 60 m
	// down, so the slope read near black between the shallow cyan and the floor beyond: Gary 28 Nov "the dark blue area
	// between the cyans"), and near the line it shows a rock a few cm under it 3 m off, which the bent ray, diving 41-49
	// deg from the vertical, never meets (it was seen as clearly as looking down, a hard cut-out: Gary 28 Nov "a cardboard
	// effect" at the waterline). The screen's picture is kept where its depth agrees with the landing (the near floor,
	// rocks under the eye) and fades out as the view goes grazing, where it holds nothing the bent ray sees.
	// the landing's light: the screen's, where the eye sees that very spot (the drawn floor as lit, net and all), else the
	// floor map's, else the floor beyond's sand at that depth
	vec3 lw = vec3(wi.xy + tl * Hg, wi.z - Hg);
	vec4 lc = PROJECTION_MATRIX * VIEW_MATRIX * vec4(sea_gdt(lw), 1.0);
	vec2 luv = lc.xy / lc.w * 0.5 + 0.5;
	vec3 fl = vec3(-1.0);
	if (lc.w > 0.0 && all(greaterThan(luv, vec2(0.002))) && all(lessThan(luv, vec2(0.998)))) {
		float dl = texture(depth_tex, luv).r;
		vec4 vl = INV_PROJECTION_MATRIX * vec4(luv * 2.0 - 1.0, dl, 1.0);
		vec3 sl = sea_isl((INV_VIEW_MATRIX * vec4(vl.xyz / vl.w, 1.0)).xyz);
		if (dl > 1e-7 && distance(sl, lw) < 0.3 + 0.01 * distance(cam, lw)) fl = textureLod(screen_tex, luv, 0.0).rgb / max(water_exposure, 1e-12);
	}
	if (fl.x < 0.0) {                                       // the floor map's light is a 1 m average: give it the light net (0.8.2)
		fl = floor_light(lw.xy);
		if (fl.x >= 0.0) fl *= caustic_sun(sea_gdt(lw), Hg, water_sun_w, 0.05, TIME, 1.0);
	}
	if (fl.x < 0.0) fl = sea_bathy_sand(Hg);
	float Lg = min(min(Hg, 60.0) / max(-T.z, 0.05), 400.0);
	vec3 under = (fl * exp(-c * Lg) + w_glow(sea_gdt(T), 0.0, Lg)) * water_exposure;
	bool nofloor = depth <= 1e-7;                           // nothing drawn under this point (and none of the screen shows)
	// the screen is kept unless it lies well deeper than the landing (the straight view ran on past the floor the bent ray
	// meets: a reef's slope); something nearer (a rock, a body, a fish) stays where the screen has it, as the bend has
	// already placed it (0.7.0); only the slant fades it, below
	float agree = nofloor ? 0.0 : 1.0 - smoothstep(0.5, 1.5, max(hsc - Hg, 0.0) / max(3.0, 0.5 * Hg));
	float wsc = agree * smoothstep(0.10, 0.30, V.z) * max(kb, body);   // the view's slant, not the facet's (waves must not flicker it)
	if (wsc > 0.0) {
		float Lp = min(min(hsc, 60.0) / max(-T.z, 0.05), 400.0) * mix(1.0, sea_body_veil, body);
		under = mix(under, scene * exp(-c * Lp) + w_glow(sea_gdt(T), 0.0, Lp) * water_exposure, wsc);
	}
	float H = mix(Hg, hsc, wsc);
	float Ed = water_sun_lux * max(water_sun_air.y, 0.0) + PI * water_sky_nits;   // lux on the level sea
	// 0.7.0: past the reef the water is the open ocean's, not the lagoon's (an atoll's lagoon water is its own; out over
	// the drop-off the deep's royal blue takes over as the floor falls away: the deep read near-black navy from the air)
	vec3 rrs0 = mix(water_rrs, max(water_rrs, water_rrs_deep), sea_bathy_ss(20.0, 120.0, H));
	vec3 rrs = mix(rrs0, rrs0.z * vec3(0.03, 0.55, 1.0), sea_open_teal) * sea_open_gain;
	under += rrs * Ed / 0.98 * (vec3(1.0) - exp(-(water_kd + water_ku) * H)) * water_exposure;
	// 0.4.0: light through the crests (tank v374 SEA_SHADE, Gary's "subsurface scattering to catch the light from the
	// other side"): the sun shines into the back of a wave and comes out through its thin top toward you. hn: height
	// on the wind waves (cascades 1-2; 0 in the troughs, 1 on the highest crests); th: the light's path through the
	// top (m: thin at the top, longer on bigger waves). On faces turned toward you, most with the sun behind the wave;
	// inside, the light scatters toward you (water, particles, the bubbles of a breaking crest), and near the sun it
	// is also seen straight through the top (a soft lobe round the sun: the crest is a rough lens).
	float crest = 0.0;
	for (int k = 1; k <= 2; k++) crest += texture(sea_disp, vec3(still / sea_c_sel(sea_patch, k), float(k))).z;
	float hn = clamp(crest / (2.0 * max(sea_crest_sd, 0.005)), 0.0, 1.0);
	vec3 glow = vec3(0.0);
	if (hn > 0.0 && water_sun_air.y > 0.0) {
		float th = mix(2.0, 0.25, hn) * clamp(sea_crest_sd / 0.25, 0.3, 4.0);
		float vh = length(V.xy), lh = length(Ls.xy);
		float facing = vh > 1e-4 ? clamp(4.0 * dot(N.xy, V.xy) / vh, 0.0, 1.0) : 0.0;
		float behind = (vh > 1e-4 && lh > 1e-4) ? clamp(-dot(Ls.xy, V.xy) / (vh * lh), 0.0, 1.0) : 0.0;
		float gl = hn * hn * facing * (0.25 + 0.75 * behind) * (1.0 - 0.6 * clamp(Ls.z, 0.0, 1.0));
		float cw = cos(acos(clamp(dot(-Ls, V), -1.0, 1.0)) / 1.333);
		float phg = (1.0 - 0.8464) / (12.566 * pow(max(1.8464 - 1.84 * cw, 1e-4), 1.5));
		float pbu = (1.0 - 0.64) / (12.566 * pow(max(1.64 - 1.6 * cw, 1e-4), 1.5));
		vec3 bw = vec3(0.0005, 0.0019, 0.0049);               // pure water's scattering (Morel 1974), the rest is particles
		vec3 bp = max(water_b - bw, vec3(0.0));
		vec3 beta = bw * 0.0597 * (1.0 + cw * cw) + bp * phg + 2.0 * clamp(fo.fresh + 0.5 * fo.plume, 0.0, 1.0) * pbu;
		float s2 = 0.08 + 2.0 * max(S.z, 0.0);
		vec3 ds = -V - Ls;
		float lobe = 0.25 * exp(-dot(ds, ds) / (2.0 * s2)) / (6.2832 * s2);   // GLOW_LOBE
		glow = sea_crest_glow * water_sun_lux * 0.9 * exp(-c * th) * (beta * th + lobe) * gl * (1.0 - R) * (1.0 - fo.foam);
	}
	// the foam lies opaque over the water (the mirror and the view through both give way to it); the bubble cloud
	// under and behind a whitecap adds its turquoise to the water
	ALBEDO = (R * refl * water_exposure + (1.0 - R) * under) * (1.0 - fo.foam)
		+ (sea_foam_top_nits(fo, N) + sea_foam_plume_nits(fo, R) + glow) * water_exposure;
	// 0.8.1: art direction: the last half degree of sea under the horizon melts into the sky's horizon (look/sky does the
	// same past the far plane). Physically the far sea sits a little darker than the haze above it, and beyond the reef
	// the deep's own blue made that a thin dark band a few pixels high, which read as a seam (Gary 28 Nov playtest)
	float melt = sea_horizon_melt * (1.0 - smoothstep(0.0, 0.012, V.z));
	if (melt > 0.0) ALBEDO = mix(ALBEDO, sky_dome_nits(sea_gdt(normalize(vec3(-V.xy, 0.0015)))) * water_exposure, melt);
}
