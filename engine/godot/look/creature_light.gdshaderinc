// Creature light 0.1.0 (look thread, 28 Nov 2026; blind critique r1 row 6/7: "fish not in the light field", no caustics on fish):
// creatures lit by the same water physics as the seabed. The sun's beam is corrected to the creature's own depth and carries the
// light net (look/sun_under.gdshaderinc), so a fish swimming over sunlit sand wears the same moving net the sand does; the water's
// fill rides in the albedo as the seabed's does (w_fill_ratio: Godot's ambient / SDFGI is the field at z_ref, this adds the depth's
// own change) and the direct light divides it back out.
// Godot's built-in light is replaced (a light() function), so this also draws the PBR specular: GGX with Smith visibility and
// Schlick Fresnel, f0 = mix(0.04, albedo, metallic), x the light's specular amount, as Godot's own light does.
// Use: include after your uniforms; in fragment(), after ALBEDO / METALLIC / ROUGHNESS are set, call
//   cl_wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz; cl_fill = creature_fill(cl_wpos, (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
//   ALBEDO *= cl_fill;
#include "res://look/water_physics.gdshaderinc"
#include "res://look/caustics.gdshaderinc"
#include "res://look/sun_under.gdshaderinc"
uniform float caustic_strength : hint_range(0.0, 3.0) = 1.0;   // NetK, as the seabed's (1 = the Unreal picture)
varying vec3 cl_wpos;
varying vec3 cl_fill;
vec3 creature_fill(vec3 wpos, vec3 wnormal) {
	if (water_fill_ao < 0.5 || wpos.y >= water_y) return vec3(1.0);
	return w_fill_ratio(max(water_y - wpos.y, 0.0), 0.5 + 0.5 * normalize(wnormal).y);
}
void light() {
	vec3 k = vec3(1.0);
	if (LIGHT_IS_DIRECTIONAL && cl_wpos.y < water_y)
		k = sun_under(cl_wpos, sun_under_pixel_m(cl_wpos, INV_VIEW_MATRIX, PROJECTION_MATRIX, VIEWPORT_SIZE), TIME, caustic_strength);
	vec3 cl_alb = ALBEDO / max(cl_fill, vec3(1e-6));
	float nl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	vec3 li = ATTENUATION * LIGHT_COLOR * k;
	DIFFUSE_LIGHT += nl * li / PI / max(cl_fill, vec3(1e-6));
	if (nl > 0.0) {
		vec3 h = normalize(LIGHT + VIEW);
		float nv = clamp(dot(NORMAL, VIEW), 1e-4, 1.0);
		float nh = clamp(dot(NORMAL, h), 0.0, 1.0);
		float lh = clamp(dot(LIGHT, h), 0.0, 1.0);
		float a = max(ROUGHNESS * ROUGHNESS, 2e-3);
		float a2 = a * a;
		float dd = nh * nh * (a2 - 1.0) + 1.0;
		float D = a2 / (PI * dd * dd);
		float V = 0.5 / max(nl * sqrt(nv * nv * (1.0 - a2) + a2) + nv * sqrt(nl * nl * (1.0 - a2) + a2), 1e-5);
		vec3 f0 = mix(vec3(0.04), cl_alb, METALLIC);
		vec3 F = f0 + (1.0 - f0) * pow(1.0 - lh, 5.0);
		SPECULAR_LIGHT += D * V * F * nl * li * SPECULAR_AMOUNT;
	}
}
