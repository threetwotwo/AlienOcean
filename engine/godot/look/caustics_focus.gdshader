// Caustic map, pass 2 of 3 (engine thread): v98 CAUS_HLSL as it was. For each point of the tile and each depth
// (r g b = 0.8, 2, 5 m): three steps back to where the ray came in, the bundle's area there from the slopes beside it
// (read over CAUS_E x depth), light = 1 / area. Drawn by adapters/godot/caustics_map.gd.
shader_type canvas_item;
render_mode blend_disabled, unshaded;
#include "res://look/caustic_waves.gdshaderinc"
uniform sampler2D s1 : repeat_enable, filter_linear;
uniform sampler2D s2 : repeat_enable, filter_linear;
uniform sampler2D s3 : repeat_enable, filter_linear;
float focus(sampler2D s, vec2 uv, float depth) {
	float h = CAUS_BEND * depth;
	float e = CAUS_E * depth / CAUS_TILE;
	vec2 u = uv;
	for (int n = 0; n < 3; n++) u = uv - (h / CAUS_TILE) * textureLod(s, u, 0.0).rg;
	vec2 gxp = textureLod(s, u + vec2(e, 0.0), 0.0).rg;
	vec2 gxm = textureLod(s, u - vec2(e, 0.0), 0.0).rg;
	vec2 gyp = textureLod(s, u + vec2(0.0, e), 0.0).rg;
	vec2 gym = textureLod(s, u - vec2(0.0, e), 0.0).rg;
	float k = h / (2.0 * e * CAUS_TILE);
	float a = 1.0 + k * (gxp.x - gxm.x);
	float d = 1.0 + k * (gyp.y - gym.y);
	float b = 0.5 * k * ((gxp.y - gxm.y) + (gyp.x - gym.x));
	float det = a * d - b * b;
	return min(inversesqrt(det * det + CAUS_EPS * CAUS_EPS), CAUS_CAP);
}
void fragment() {
	COLOR = vec4(focus(s1, UV, CAUS_DEPTHS[0]), focus(s2, UV, CAUS_DEPTHS[1]), focus(s3, UV, CAUS_DEPTHS[2]), 1.0);
}
