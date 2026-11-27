// Caustic map, pass 3 of 3 (engine thread): v98 CAUS_BLUR_HLSL as it was. The sun is a disc, so each depth's net is
// softened over depth x the sun's radius: 8 taps on a ring at 0.7 of it and the centre.
// Drawn by adapters/godot/caustics_map.gd; the result is the global water_caus_map.
shader_type canvas_item;
render_mode blend_disabled, unshaded;
#include "res://look/caustic_waves.gdshaderinc"
uniform sampler2D src : repeat_enable, filter_linear;
void fragment() {
	vec3 r = vec3(CAUS_DEPTHS[0], CAUS_DEPTHS[1], CAUS_DEPTHS[2]) * CAUS_SUN_RAD / CAUS_TILE;   // the sun's radius from each depth, in tiles
	vec3 acc = textureLod(src, UV, 0.0).rgb;
	for (int k = 0; k < 8; k++) {
		float an = 0.7853982 * (float(k) + 0.5);
		vec2 u = 0.7 * vec2(cos(an), sin(an));
		acc.r += textureLod(src, UV + u * r.r, 0.0).r;
		acc.g += textureLod(src, UV + u * r.g, 0.0).g;
		acc.b += textureLod(src, UV + u * r.b, 0.0).b;
	}
	COLOR = vec4(acc / 9.0, 1.0);
}
