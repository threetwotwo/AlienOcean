// Underwater view 0.1.0 (engine thread): the water between the eye and every pixel, from the ported lagoon
// physics (under_model.py glow(), lagoonwater PHYS_CODE): scene x exp(-c L) + in-scattered glow, per band.
// Glow = b ( Es HG(cos) G(c - Kd dz, L) + (Ek G(c - Ku dz, L) Wk + Eu G(c + Ku dz, L) Wd) / pi ) x GlowK.
// Drawn as a full-screen quad after the opaque pass. Only when the eye is under the water (above: later step).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;

#include "res://look/water_physics.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float max_path = 400.0;

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
		ALBEDO = scene * exp(-c * L) + glow * water_exposure;
	}
}
