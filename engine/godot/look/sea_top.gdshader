// Sea seen from above 0.1.0 (water surface thread): the lagoon's top side on the FFT sea (look/sea_waves.gdshaderinc).
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
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
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
	N = normalize(N + vec3(0.0, 0.0, 2.0 * clamp((0.05 - dot(N, V)) / 0.05, 0.0, 1.0)));   // open water v144
	float ci = clamp(dot(N, V), 1e-3, 1.0);
	float R = fresnel_air(ci);
	vec3 Rd = reflect(-V, N);
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
	ALBEDO = R * refl * water_exposure + (1.0 - R) * under;
}
