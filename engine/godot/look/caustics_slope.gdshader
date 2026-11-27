// Caustic map, pass 1 of 3 (engine thread): the waves' slope over the 2.56 m tile in the mip one depth reads
// (v98 CAUS_SLOPE_HLSL + CAUS_DOWN_HLSL: RT_LW_CausS1..3, 2 / 4 / 8 cm texels). v98 averaged its FFT's 1 cm texels;
// here each wave is written already averaged over the texel (CAUS_B). Drawn by adapters/godot/caustics_map.gd.
shader_type canvas_item;
render_mode blend_disabled, unshaded;
#include "res://look/caustic_waves.gdshaderinc"
global uniform vec4 water_caus_k;
uniform int level = 0;
void fragment() {
	vec2 X = UV * CAUS_TILE;
	float tt = (water_caus_k.y >= 0.0 ? water_caus_k.y : TIME) / CAUS_LOOP;
	int o = level * CAUS_N;
	vec2 g = vec2(0.0);
	for (int i = 0; i < CAUS_N; i++) {
		vec4 w = CAUS_K[i];
		g += CAUS_B[o + i] * cos(dot(w.xy, X) + w.z - 6.2831853 * fract(w.w * tt));
	}
	COLOR = vec4(g, 0.0, 1.0);
}
