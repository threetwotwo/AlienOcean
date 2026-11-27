// Creature school 0.1.0: a creature maker export drawn in a MultiMesh school (fish/creature_school_mesh.gd). The maker's
// PBR material, and its swim wave from the glTF extras (alien_ocean.swim.wave.amplitude_envelope_BL: per station s, half
// sideways swing in BL with recoil included, phase lag in turns behind the snout), played back as the extras' rule says:
// lateral z(s) = A(s) x amp_scale x sin(phase - 2 pi lag(s)), phase advancing at f(U) (beat_law), amp_scale = A_U / A.
// INSTANCE_CUSTOM: r = swim phase (rad), g = amplitude scale (A_U / A, startle boosted), b = body bend (turning, as the
// stand-in), a = startle. Mesh frame: one body length, head toward +x, x = 0.5 - s, y up.
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
uniform float env_a[16];
uniform float env_lag[16];
uniform int env_n = 0;

void table(float s, out float a, out float lag) {
	a = env_a[0]; lag = env_lag[0];
	if (env_n <= 0) { a = 0.0; lag = s; return; }
	if (s <= env_s[0]) { return; }
	for (int i = 1; i < 16; i++) {
		if (i >= env_n) break;
		if (s <= env_s[i]) {
			float u = (s - env_s[i - 1]) / max(env_s[i] - env_s[i - 1], 1e-5);
			a = mix(env_a[i - 1], env_a[i], u); lag = mix(env_lag[i - 1], env_lag[i], u);
			return;
		}
	}
	// past the last station (tail tip): extend the last segment's slope
	int l = max(env_n - 1, 1);
	float u = (s - env_s[l - 1]) / max(env_s[l] - env_s[l - 1], 1e-5);
	a = mix(env_a[l - 1], env_a[l], u); lag = mix(env_lag[l - 1], env_lag[l], u);
}

float lateral(float s, float ph, float amp, float bend) {
	float a; float lag;
	table(s, a, lag);
	float sb = s - 0.42;
	return a * amp * sin(ph - 6.2831853 * lag) + 0.5 * bend * sb * sb;
}

void vertex() {
	float s = 0.5 - VERTEX.x;
	float ph = INSTANCE_CUSTOM.r;
	float amp = INSTANCE_CUSTOM.g * swim_on;
	float bend = INSTANCE_CUSTOM.b;
	float w = lateral(s, ph, amp, bend);
	float ds = 0.01;
	float dw = (lateral(s + ds, ph, amp, bend) - lateral(s - ds, ph, amp, bend)) / (2.0 * ds);   // dz/ds
	VERTEX.z += w;
	// rotate the normal and tangent by the local midline slope (dz/dx = -dz/ds)
	float ang = atan(-dw);
	float c = cos(ang), sn = sin(ang);
	NORMAL = normalize(vec3(NORMAL.x * c - NORMAL.z * sn, NORMAL.y, NORMAL.x * sn + NORMAL.z * c));
	TANGENT = normalize(vec3(TANGENT.x * c - TANGENT.z * sn, TANGENT.y, TANGENT.x * sn + TANGENT.z * c));
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
}
