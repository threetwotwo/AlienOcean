// Seabed surface 0.4.0 (engine thread). Static world pieces whose COLOR_0 is paint (floor, rocks, corals, grass).
// Lit by the ported lagoon water physics (water_* globals from adapters/godot/world_root.gd): the sun's beam loses exp(-Kd z) on its
// way down (the key light arrives pre-attenuated to water_zref; this corrects to the pixel's own depth), the
// sky's diffuse light exp(-Ku z) from above, and the sand's upwelling from below, as in under_model.py.
// The light net (look/caustics.gdshaderinc, ported from Unreal lagoonwater v98) modulates the sun's beam only, as the
// Unreal light function did: mean ~1, strength by depth, slid by the refracted sun.
shader_type spatial;
render_mode blend_mix, cull_back, diffuse_lambert, specular_disabled, ambient_light_disabled;

global uniform float water_y;
global uniform float water_floor_y;
global uniform vec3 water_kd;
global uniform vec3 water_ku;
global uniform vec3 water_sun_w;
global uniform float water_es0;
global uniform float water_ek0;
global uniform float water_zref;
global uniform vec4 water_sand;
#include "res://look/caustics.gdshaderinc"

// Better sand colour lock (SD2, Gary-approved design 14 Nov; passed in Unreal: #cbc8c2 vs lock #cdcac4): bare sand takes the
// locked colour, darker sorted sand #c8c4bb in the paint's darker patches. Floor pieces only (sand_lock 1).
uniform float sand_lock : hint_range(0.0, 1.0) = 0.0;
uniform vec3 sand_c : source_color = vec3(0.804, 0.792, 0.769);    // #cdcac4
uniform vec3 sand_d : source_color = vec3(0.784, 0.769, 0.733);    // #c8c4bb
uniform float roughness_base : hint_range(0.0, 1.0) = 0.92;
uniform float caustic_strength : hint_range(0.0, 3.0) = 1.0;   // Unreal's NetK: x the saved net strength (1 = the Unreal picture)
varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	ALBEDO = COLOR.rgb;
	if (sand_lock > 0.0) {
		float pm = clamp(dot(COLOR.rgb, vec3(0.2126, 0.7152, 0.0722)) / 0.30, 0.0, 1.0);   // the paint's own light/dark patches
		ALBEDO = mix(COLOR.rgb, mix(sand_d, sand_c, smoothstep(0.6, 1.0, pm)), sand_lock);
	}
	ROUGHNESS = roughness_base;
	float z = max(water_y - wpos.y, 0.0);
	float H = max(water_y - water_floor_y, 0.05);
	vec3 ek = water_ek0 * exp(-water_ku * z);
	vec3 eh = water_es0 * exp(-water_kd * H) + water_ek0 * exp(-water_ku * H);
	vec3 eu = eh * water_sand.rgb * exp(-water_ku * max(H - z, 0.0));
	float up = 0.5 + 0.5 * wnorm.y;
	EMISSION = ALBEDO * (ek * up + eu * (1.0 - up)) / PI;   // nits; Godot applies the exposure
}
void light() {
	float z = max(water_y - wpos.y, 0.0);
	vec3 corr = exp(-water_kd * (z - water_zref));
	// the light net (look/caustics.gdshaderinc, Unreal lagoonwater v98): on the sun's beam only, by depth and the refracted sun
	float px = length(wpos - INV_VIEW_MATRIX[3].xyz) * 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);
	float caus = caustic_sun(wpos, water_y - wpos.y, water_sun_w, px, TIME, caustic_strength);
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI * corr * caus;
}
