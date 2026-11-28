// The girl's body (stand-in ceramic mannequin): lit by the same ported lagoon water physics as the seabed
// (look/seabed_surface.gdshader). Under water the sun's beam loses exp(-Kd z) to the pixel's own depth and carries the light net,
// and the sky's fill comes through the water from above and the sand's bounce from below. Before this she was a plain
// StandardMaterial3D and read bright cream at 1-3 m with no water tint (Gary's Mac run, 28 Nov, test-level T1.1 gap 9).
// Used only where WorldRoot has registered the water_* globals; the tests' plain worlds keep the standard material.
shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_lambert, specular_schlick_ggx;

#include "res://look/water_physics.gdshaderinc"
#include "res://look/caustics.gdshaderinc"

uniform float roughness_base : hint_range(0.0, 1.0) = 0.6;
uniform float caustic_strength : hint_range(0.0, 3.0) = 1.0;
varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = roughness_base;
	float z = max(water_y - wpos.y, 0.0);
	float up = 0.5 + 0.5 * wnorm.y;
	if (water_fill_ao > 0.5) {
		ALBEDO *= w_fill_ratio(z, up);
	} else {
		EMISSION = ALBEDO * w_fill(z, up);
		AO = 0.0;
	}
}
void light() {
	float z = max(water_y - wpos.y, 0.0);
	vec3 corr = exp(-water_kd * (z - water_zref));
	float px = length(wpos - INV_VIEW_MATRIX[3].xyz) * 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);
	float caus = caustic_sun(wpos, water_y - wpos.y, water_sun_w, px, TIME, caustic_strength);
	vec3 fr = vec3(1.0);
	if (water_fill_ao > 0.5) fr = w_fill_ratio(z, 0.5 + 0.5 * normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz).y);
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI * corr * caus / fr;
}
