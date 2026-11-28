// Sea seen from above 0.4.0 (water surface thread): the lagoon's top side on the FFT sea (look/sea_waves.gdshaderinc).
// 0.2.0 (28 Nov): the water's own colour, one model from the lagoon's sand to the open sea (Rrs x Ed where the floor
// fades; it read jet black: the lagoon's path only saw the floor).
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
global uniform vec3 water_rrs;
// art levers on the deep water's colour (1, 0 = physical; FftSea sets 2, 0.5): x brightness, and a share pulled toward
// a turquoise of the same blue (Abzu's lighter sea; art direction over the physical ink-navy)
global uniform float sea_open_gain;     // FftSea adds both
global uniform float sea_open_teal;
global uniform float sea_crest_sd;      // the crests' height spread, m (cascades 1-2; the tank's SeaK.x; FftSea)
global uniform float sea_crest_glow;    // art lever on the light through the crests (1 = the tank's; FftSea)
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float nq = 32.0;
uniform float sun_size = 1.0;
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
	vec3 S = sea_slope(wi.xy, still, wi, cam, 0.0);
	vec3 V = normalize(cam - wi);                          // toward the eye (island)
	vec3 N = normalize(vec3(-S.x, -S.y, 1.0));
	// the whitecaps (tank v374 foam look): the foam map drawn as lace and streaks; its 2 cm relief tilts the normal
	SeaFoam fo = sea_foam_read(still, wi, cam, nq, TIME);
	N = sea_foam_bump(N, fo.foam, still);
	N = normalize(N + vec3(0.0, 0.0, 2.0 * clamp((0.05 - dot(N, V)) / 0.05, 0.0, 1.0)));   // open water v144
	float ci = clamp(dot(N, V), 1e-3, 1.0);
	// 0.3.0: the waves too small to draw still tilt the mirror (S.z, their slope variance, grows with distance): averaged
	// over them the Fresnel never reaches 1 at the horizon and the mean reflected ray comes from higher, bluer sky
	// (Bruneton, Neyret & Holzschuch 2010, meanFresnel; as a ratio to the smooth case so the near sea is unchanged)
	float sv = sqrt(max(S.z, 0.0));
	float R = fresnel_air(ci) * (pow(1.0 - ci, 5.0 * exp(-2.69 * sv)) / (1.0 + 22.7 * pow(sv, 1.5))) / max(pow(1.0 - ci, 5.0), 1e-6);
	R = min(R, fresnel_air(ci));
	vec3 Rd = reflect(-V, N);
	Rd = normalize(Rd + vec3(0.0, 0.0, sv));
	vec3 refl = sky_dome_nits(sea_gdt(Rd));
	// the sun's glint
	vec3 Ls = sea_isl(normalize(water_sun_air));
	float ang = sqrt(max(2.0 * (1.0 - dot(normalize(Rd), Ls)), 0.0));
	float sig0sq = 0.25 * pow(0.0046514 * sun_size, 2.0) + 2.0 * max(S.z, 1e-5);
	float sig2 = max(sig0sq, pow(1.5 * fwidth(ang), 2.0));
	float up = step(0.0, water_sun_air.y);
	refl += up * vec3(1.0, 0.97, 0.9) * water_sun_lux / (6.2831853 * sig2) * exp(-0.5 * ang * ang / sig2);
	// through the surface: the true bend
	vec3 T = refract(-V, N, 1.0 / 1.333);                 // down into the water
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vp.xyz /= vp.w;
	vec3 qg = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;   // what the straight view meets (Godot)
	vec3 q = sea_isl(qg);
	float h = clamp(wi.z - q.z, 0.0, 60.0);                // its depth under this bit of surface
	vec2 shift = (T.xy / max(-T.z, 0.05) + V.xy / max(V.z, 0.05)) * h;   // bent landing - straight landing
	vec3 qb = q + vec3(shift, 0.0);
	vec4 cs = PROJECTION_MATRIX * VIEW_MATRIX * vec4(sea_gdt(qb), 1.0);
	vec2 uvb = cs.xy / cs.w * 0.5 + 0.5;
	// near the screen edge (the screen may not hold the bent point) the shift is squeezed: it goes at most half way
	// to the edge along its line, so rows stay in order (a clamp smears the edge row into streaks)
	vec2 du = uvb - SCREEN_UV;
	vec2 room = mix((vec2(1.0) - SCREEN_UV) / max(du, vec2(1e-6)), -SCREEN_UV / min(du, vec2(-1e-6)), step(du, vec2(0.0)));
	uvb = SCREEN_UV + du * clamp(min(room.x, room.y) * 0.5, 0.0, 1.0);   // at most half way to the edge: a smooth squeeze
	float db = texture(depth_tex, uvb).r;
	vec4 vb = INV_PROJECTION_MATRIX * vec4(uvb * 2.0 - 1.0, db, 1.0);
	vb.xyz /= vb.w;
	float hb = wi.z - sea_isl((INV_VIEW_MATRIX * vec4(vb.xyz, 1.0)).xyz).z;
	if (hb < 0.0) uvb = SCREEN_UV;                         // the bent point is above the water (an edge): no shift
	vec3 scene = textureLod(screen_tex, uvb, 0.0).rgb;
	float Lp = min(h / max(-T.z, 0.05), 400.0);
	vec3 c = water_a + water_b;
	vec3 under = scene * exp(-c * Lp) + w_glow(sea_gdt(T), 0.0, Lp) * water_exposure;
	// the deep water's own light where the floor fades (H: the floor under this point; nothing drawn there = no floor,
	// and then nothing of the screen shows through either)
	bool nofloor = depth <= 1e-7;
	float H = nofloor ? 1e4 : max(wi.z - q.z, 0.0);
	if (nofloor) under -= scene * exp(-c * Lp);
	float Ed = water_sun_lux * max(water_sun_air.y, 0.0) + PI * water_sky_nits;   // lux on the level sea
	vec3 rrs = mix(water_rrs, water_rrs.z * vec3(0.03, 0.55, 1.0), sea_open_teal) * sea_open_gain;
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
}
