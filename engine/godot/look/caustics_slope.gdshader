// Caustic map, pass 1 of 3 (engine thread) 0.2.0: the waves' slope over the 2.56 m tile in the mip one depth reads
// (v98 CAUS_SLOPE_HLSL + CAUS_DOWN_HLSL: RT_LW_CausS1..3, 2 / 4 / 8 cm texels). Drawn by adapters/godot/caustics_map.gd.
// With the FFT sea running (sea_on, adapters/godot/fft_sea.gd) the slopes are the sea's own, as in v98: cascade 2
// (sea_patch.z = 2.56 m = this tile, uv the same island xy / patch) plus `fine` x cascade 3 (sea_patch.w = 0.32 m, 8
// repeats over the tile), each read from the wrap-averaged mip whose texel is this pass's texel (cascade 2 mips 1 / 2 / 3,
// cascade 3 mips 4 / 5 / 6), at texel centres. v98 averaged 16 taps of cascade 3 into 1 cm texels and then halved;
// the sea's mip chain is that mean exactly. Without the sea (sea_on 0), or with from_sea 0: the 32 waves of
// look/caustic_waves.gdshaderinc, each already averaged over the texel (CAUS_B).
// The tile only repeats cleanly while sea_patch.z equals CAUS_TILE and sea_patch.w divides it.
shader_type canvas_item;
render_mode blend_disabled, unshaded;
#include "res://look/caustic_waves.gdshaderinc"
global uniform vec4 water_caus_k;
global uniform sampler2DArray sea_deriv : filter_linear_mipmap, repeat_enable;   // rg = the height's slope (dDz/dx, dDz/dy)
global uniform vec4 sea_patch;
global uniform float sea_on;
uniform int level = 0;
uniform float from_sea = 1.0;      // 0 = the 32 waves even while the sea runs (checks)
uniform float fine = 1.0;          // v89 Fine.x: x the finest cascade (0 leaves it out)
void fragment() {
	vec2 X = UV * CAUS_TILE;
	vec2 g = vec2(0.0);
	if (sea_on > 0.5 && from_sea > 0.5) {
		float texel = CAUS_TILE / (128.0 / exp2(float(level)));
		g = textureLod(sea_deriv, vec3(X / sea_patch.z, 2.0), log2(texel * 256.0 / sea_patch.z)).rg;
		if (fine > 0.0) g += fine * textureLod(sea_deriv, vec3(X / sea_patch.w, 3.0), log2(texel * 256.0 / sea_patch.w)).rg;
	} else {
		float tt = (water_caus_k.y >= 0.0 ? water_caus_k.y : TIME) / CAUS_LOOP;
		int o = level * CAUS_N;
		for (int i = 0; i < CAUS_N; i++) {
			vec4 w = CAUS_K[i];
			g += CAUS_B[o + i] * cos(dot(w.xy, X) + w.z - 6.2831853 * fract(w.w * tt));
		}
	}
	COLOR = vec4(g, 0.0, 1.0);
}
