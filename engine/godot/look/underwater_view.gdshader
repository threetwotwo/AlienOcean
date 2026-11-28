// Underwater view 0.4.0 (0.4.0, look thread: the open ocean's abyss, Unreal M_OO_Abyss DEEP, where no floor lies under the ray; 0.3.0: the floor plane past the drawn floor; the glow's floor never above the ray) (engine thread): the water between the eye and every pixel, from the ported lagoon
// physics (under_model.py glow(), lagoonwater PHYS_CODE): scene x exp(-c L) + in-scattered glow, per band.
// Glow = b ( Es HG(cos) G(c - Kd dz, L) + (Ek G(c - Ku dz, L) Wk + Eu G(c + Ku dz, L) Wd) / pi ) x GlowK.
// Drawn as a full-screen quad after the opaque pass. Only when the eye is under the water (above: later step).
// 0.2.0: + the god rays (look/god_rays.gdshaderinc, lagoonwater v98's): the light net's map summed along the view
// ray, added to the haze as Unreal's look did (now = scene x T + glow + God, never under 0). god_k 0 = off.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;

#include "res://look/water_physics.gdshaderinc"
#include "res://look/caustics.gdshaderinc"
#include "res://look/god_rays.gdshaderinc"
#include "res://look/sea_bathy.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
global uniform sampler2D water_floor_height : filter_linear;   // adapters/godot/sea_floor_map.gd: alpha 0 = nothing there
global uniform vec4 water_floor_org;                           // centre x, centre z, size m, 1 = valid
uniform float max_path = 400.0;
uniform float god_k = 1.0;      // Unreal GodK: 1 = the god rays, 0 = off (WorldRoot.god_rays); 2 = show the sum, 0.5 + 0.25 x metres (checks)
uniform float god_frame = 0.0;  // the frame count mod 8 when TAA averages the jitter, else 0 (WorldRoot)

void vertex() { POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0); }

void fragment() {
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 scene = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	if (cam.y >= water_y) { ALBEDO = scene; }
	else {
		float depth = texture(depth_tex, SCREEN_UV).r;
		vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
		vp.xyz /= vp.w;
		float L = min(length(vp.xyz), max_path);
		vec3 d = normalize((INV_VIEW_MATRIX * vec4(vp.xyz, 0.0)).xyz);
		vec3 c = water_a + water_b;
		float z0 = water_y - cam.y;
		float ocean = sea_bathy_ss(20.0, 120.0, sea_bathy_depth(cam.xz));   // past the reef: the open ocean's water (as sea_top)
		vec3 glow;
		if (depth <= 1e-7) {
			// no geometry on this ray (depth at the far plane: reversed z 0). Is there a floor under it? Not when the eye is below
			// the lagoon floor (down a reef wall), nor where the floor map round the eye holds nothing (open water past the drawn
			// floor); outside the map the lagoon's floor plane is assumed, as the surface's mirror does (sea_under floor_top).
			float fd = w_floor_dist(d, z0);
			vec2 probe = cam.xz + d.xz * (fd > 0.0 ? fd : 20.0);
			bool has_floor = z0 < water_y - water_floor_y - 0.05;
			vec2 fuv = (probe - water_floor_org.xy) / water_floor_org.z + 0.5;
			if (has_floor && water_floor_org.w > 0.5 && all(greaterThan(fuv, vec2(0.0))) && all(lessThan(fuv, vec2(1.0))))
				has_floor = textureLod(water_floor_height, fuv, 0.0).a > 0.5;
			if (has_floor && fd > 0.0) {
				// the lagoon floor goes on past the drawn floor: the ray ends on sand lit as the drawn sand is (the white void fix)
				L = min(fd, L); scene = w_floor_nits() * water_exposure; glow = w_glow(d, z0, L);
			} else if (!has_floor) {
				// the abyss: endless water, its own light field (Unreal M_OO_Abyss DEEP), nothing behind it
				scene = vec3(0.0); glow = w_deep_o(d, z0, 1e4, ocean);
			} else glow = w_glow(d, z0, L);
		} else {
			// a ray that ends below the lagoon floor (down a reef wall, a fore-reef slope 50-150 m down) sees mostly water column, not
			// the lagoon's sand bounce: blend to the deep light field over the first 10 m past the floor, so it matches the open-water
			// ray beside it (water surface thread's drop-off views, 28 Nov: these read near black on w_glow alone)
			float zend = z0 + max(-d.y, 0.0) * L;
			float kd = clamp((zend - (water_y - water_floor_y)) / 10.0, 0.0, 1.0);
			glow = w_glow(d, z0, L);
			if (kd > 0.0) glow = mix(glow, w_deep_o(d, z0, L, ocean), kd);
		}
		vec3 god = god_k > 0.5 ? god_rays(cam, d, L, FRAGCOORD.xy, god_frame) : vec3(0.0);
		if (god_k > 1.5) ALBEDO = vec3(0.5 + 0.25 * god_acc(cam, d, L, FRAGCOORD.xy, god_frame));
		else ALBEDO = max(scene * exp(-c * L) + (glow + god) * water_exposure, vec3(0.0));
	}
}
