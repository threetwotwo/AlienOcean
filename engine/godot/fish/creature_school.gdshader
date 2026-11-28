// Creature school 0.3.0 (0.3.0, look thread: lit by look/creature_light.gdshaderinc, caustics on the fish): a creature maker export drawn in a MultiMesh school (fish/creature_school_mesh.gd). The maker's
// PBR material, and its swim wave from the glTF extras (alien_ocean.swim.wave.amplitude_envelope_BL: per station s, half
// sideways swing in BL with recoil included, phase lag in turns behind the snout), played back as the extras' rule says:
// lateral z(s) = A(s) x amp_scale x sin(phase - 2 pi lag(s)), phase advancing at f(U) (beat_law), amp_scale = A_U / A.
// r2: three tables (wave.envelopes_by_speed at env_u) blended at the fish's drawn speed U.
// INSTANCE_CUSTOM: r = swim phase (rad), g = drawn speed U (BL/s, picks the table), b = body bend (turning, as the
// stand-in), a = amplitude factor (A_U / A for a one-table export, x startle boost, x burst-and-coast glide fade). Mesh frame: one body length, head toward +x, x = 0.5 - s, y up.
// No fog here: the underwater view quad fogs every pixel along the view ray.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform float use_albedo_tex = 0.0;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float use_normal_tex = 0.0;
uniform float normal_scale = 1.0;
uniform float metallic = 0.0;
uniform float roughness = 0.6;
uniform sampler2D metallic_tex : hint_default_white, filter_linear_mipmap;
uniform sampler2D roughness_tex : hint_default_white, filter_linear_mipmap;
uniform float use_mr_tex = 0.0;
uniform float swim_on = 1.0;
uniform float env_s[16];
uniform float env_a0[16];
uniform float env_lag0[16];
uniform float env_a1[16];
uniform float env_lag1[16];
uniform float env_a2[16];
uniform float env_lag2[16];
uniform vec3 env_u = vec3(1.0, 2.0, 3.0);   // the speeds (BL/s) of the three tables
uniform int env_n = 0;
// lit by the water physics like the seabed: the sun's beam at the fish's depth with the light net, the fill's depth change, GGX specular
#include "res://look/creature_light.gdshaderinc"

// the three tables blended at U: linear between the two nearest speeds, end tables held outside (export r2 rule)
float row_a(int i, float u01, float u12, bool hi) { return hi ? mix(env_a1[i], env_a2[i], u12) : mix(env_a0[i], env_a1[i], u01); }
float row_l(int i, float u01, float u12, bool hi) { return hi ? mix(env_lag1[i], env_lag2[i], u12) : mix(env_lag0[i], env_lag1[i], u01); }

void table(float s, float U, out float a, out float lag) {
	bool hi = U > env_u.y;
	float u01 = clamp((U - env_u.x) / max(env_u.y - env_u.x, 1e-5), 0.0, 1.0);
	float u12 = clamp((U - env_u.y) / max(env_u.z - env_u.y, 1e-5), 0.0, 1.0);
	a = row_a(0, u01, u12, hi); lag = row_l(0, u01, u12, hi);
	if (env_n <= 0) { a = 0.0; lag = s; return; }
	if (s <= env_s[0]) { return; }
	for (int i = 1; i < 16; i++) {
		if (i >= env_n) break;
		if (s <= env_s[i]) {
			float u = (s - env_s[i - 1]) / max(env_s[i] - env_s[i - 1], 1e-5);
			a = mix(row_a(i - 1, u01, u12, hi), row_a(i, u01, u12, hi), u);
			lag = mix(row_l(i - 1, u01, u12, hi), row_l(i, u01, u12, hi), u);
			return;
		}
	}
	// past the last station (tail tip): extend the last segment's slope
	int l = max(env_n - 1, 1);
	float u = (s - env_s[l - 1]) / max(env_s[l] - env_s[l - 1], 1e-5);
	a = mix(row_a(l - 1, u01, u12, hi), row_a(l, u01, u12, hi), u);
	lag = mix(row_l(l - 1, u01, u12, hi), row_l(l, u01, u12, hi), u);
}

float lateral(float s, float ph, float U, float amp, float bend) {
	float a; float lag;
	table(s, U, a, lag);
	float sb = s - 0.42;
	return a * amp * sin(ph - 6.2831853 * lag) + 0.5 * bend * sb * sb;
}

void vertex() {
	float s = 0.5 - VERTEX.x;
	float ph = INSTANCE_CUSTOM.r;
	float U = INSTANCE_CUSTOM.g;
	float bend = INSTANCE_CUSTOM.b;
	float amp = INSTANCE_CUSTOM.a * swim_on;
	float w = lateral(s, ph, U, amp, bend);
	float ds = 0.01;
	float dw = (lateral(s + ds, ph, U, amp, bend) - lateral(s - ds, ph, U, amp, bend)) / (2.0 * ds);   // dz/ds
	VERTEX.z += w;
	// rotate the normal and tangent by the local midline slope (dz/dx = -dz/ds)
	float ang = atan(-dw);
	float c = cos(ang), sn = sin(ang);
	NORMAL = normalize(vec3(NORMAL.x * c - NORMAL.z * sn, NORMAL.y, NORMAL.x * sn + NORMAL.z * c));
	TANGENT = normalize(vec3(TANGENT.x * c - TANGENT.z * sn, TANGENT.y, TANGENT.x * sn + TANGENT.z * c));
	cl_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;   // the swum position (look/creature_light.gdshaderinc)
}

void fragment() {
	vec4 col = albedo;
	if (use_albedo_tex > 0.5) col *= texture(albedo_tex, UV);
	ALBEDO = col.rgb;
	float m = metallic; float r = roughness;
	if (use_mr_tex > 0.5) { m *= texture(metallic_tex, UV).b; r *= texture(roughness_tex, UV).g; }
	METALLIC = m;
	ROUGHNESS = r;
	if (use_normal_tex > 0.5) { NORMAL_MAP = texture(normal_tex, UV).rgb; NORMAL_MAP_DEPTH = normal_scale; }
	cl_fill = creature_fill(cl_wpos, (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	ALBEDO *= cl_fill;
	ALBEDO = creature_debug_albedo(ALBEDO, TIME, INV_VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE);
}
