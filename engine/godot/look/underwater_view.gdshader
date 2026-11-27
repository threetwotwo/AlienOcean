// Underwater view 0.1.0 (engine thread): the water between the eye and every pixel, from the ported lagoon
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

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
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
		vec3 glow = w_glow(d, water_y - cam.y, L);
		vec3 god = god_k > 0.5 ? god_rays(cam, d, L, FRAGCOORD.xy, god_frame) : vec3(0.0);
		if (god_k > 1.5) ALBEDO = vec3(0.5 + 0.25 * god_acc(cam, d, L, FRAGCOORD.xy, god_frame));
		else ALBEDO = max(scene * exp(-c * L) + (glow + god) * water_exposure, vec3(0.0));
	}
}
