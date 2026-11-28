// Seabed surface 0.4.0 (engine thread). Static world pieces whose COLOR_0 is paint (floor, rocks, corals, grass).
// Lit by the ported lagoon water physics (water_* globals from adapters/godot/world_root.gd): the sun's beam loses exp(-Kd z) on its
// way down (the key light arrives pre-attenuated to water_zref; this corrects to the pixel's own depth), the
// sky's diffuse light exp(-Ku z) from above, and the sand's upwelling from below, as in under_model.py.
// The light net (look/caustics.gdshaderinc, ported from Unreal lagoonwater v98) modulates the sun's beam only, as the
// Unreal light function did: mean ~1, strength by depth, slid by the refracted sun.
shader_type spatial;
render_mode blend_mix, cull_back, diffuse_lambert, specular_disabled;

#include "res://look/water_physics.gdshaderinc"
#include "res://look/caustics.gdshaderinc"
#include "res://look/sun_under.gdshaderinc"

// Better sand colour lock (SD2, Gary-approved design 14 Nov; passed in Unreal: #cbc8c2 vs lock #cdcac4): bare sand takes the
// locked colour, darker sorted sand #c8c4bb in the paint's darker patches. Floor pieces only (sand_lock 1).
uniform float sand_lock : hint_range(0.0, 1.0) = 0.0;
uniform vec3 sand_c : source_color = vec3(0.941, 0.882, 0.753);    // #f0e1c0 (key frame sand, Gary card 28 Nov; was #cdcac4)
uniform vec3 sand_d : source_color = vec3(0.890, 0.800, 0.635);    // #e3cca2 (was #c8c4bb)
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
	float up = 0.5 + 0.5 * wnorm.y;
	if (water_fill_ao > 0.5) {   // the fill through Godot's ambient (occluded by SSAO / SSIL / AO); light() divides the ratio back out
		ALBEDO *= w_fill_ratio(z, up);
	} else {
		EMISSION = ALBEDO * w_fill(z, up);   // nits; Godot applies the exposure
		AO = 0.0;                  // no Godot ambient on top
	}
}
void light() {
	float z = max(water_y - wpos.y, 0.0);
	// the sun's beam at this depth, with the light net (look/sun_under.gdshaderinc, one copy with the creatures)
	vec3 sun_k = sun_under(wpos, sun_under_pixel_m(wpos, INV_VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE), TIME, caustic_strength);
	vec3 fr = vec3(1.0);
	if (water_fill_ao > 0.5) fr = w_fill_ratio(z, 0.5 + 0.5 * normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz).y);   // ALBEDO carries the fill ratio: take it back out
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI * sun_k / fr;
}
