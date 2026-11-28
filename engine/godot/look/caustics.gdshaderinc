// The light net on the sand 0.2.0 (engine thread), ported from the Unreal lagoon (lagoonwater v98: CAUS_SLOPE_HLSL,
// CAUS_HLSL, CAUS_BLUR_HLSL, FFT_NET_HLSL, tb_weights / tb_x and the light function's strength line).
// Sunlight comes straight down through the waves and is bent by (1 - 1/1.333) x the slope where it enters, so the ray
// from x lands at X = x + h g(x), h = 0.24981 x depth. Three steps back find the x that lands on X; the bundle's area
// there is det(I + h H) and the light on X is 1 / area, never narrower than CAUS_EPS and never brighter than CAUS_CAP.
// The sun's tilt only slides the net (the entry point).
// Two readers of the same waves (look/caustic_waves.gdshaderinc), picked by the global water_caus_k.x:
//   1 = the map, as v98: adapters/godot/caustics_map.gd draws the net once a frame into water_caus_map (512 px over
//       the 2.56 m tile, r g b = 0.8, 2, 5 m deep); a lit point reads it at its sunlight's entry point.
//       Its slopes are the FFT sea's while that runs (look/caustics_slope.gdshader), else the 32 waves.
//   0 = per pixel, for checks and wherever no map is drawn: the same maths on the 32 waves' sum at every lit point
//       (about 1000 sin/cos a copy).
// Both lay v98's three turned copies of the tile over each other (tile break), so the 2.56 m repeat does not show.
// Frame: the island's (x east, y north), metres. Godot (x, y, z) -> island (x, -z).
#include "res://look/caustic_waves.gdshaderinc"
global uniform sampler2D water_caus_map : repeat_enable, filter_linear;
global uniform vec4 water_caus_k;      // x: 1 = read the map, 0 = per pixel; y: the net's time in s when >= 0 (stills, checks), else TIME; z: 1 = net off
const float CAUS_S = 0.90;             // live Unreal strength: CausticStrength 0.70 + CausticPerStop 0.10 x ExposureBias 2.0
const float CAUS_HEADROOM = 2.0;       // live Unreal CausticHeadroom: the light function's ceiling, x plain sun
const float CAUS_MASK_M = 0.30;        // the light function fades in over the first 30 cm under the still surface
const float CAUS_TB_CELL = 7.0;        // v98 TB_CELL_M: the tile-break patches, m
// Past the deepest map layer the net is not held at that layer's contrast for ever (a 30 m slope used to get the 5 m net at full
// strength): the light spread over the sun's disc and the unresolved short waves (key frame v7c's lens spread, p50 1.1 deg) blurs
// the net's cells (about 25 cm at 5 m) once depth x spread passes their size, so its swing falls as 1 / sqrt(1 + (dz / L)^2),
// L = cell / spread = 0.25 / 0.0192 = 13 m: 0.7 at 18 m, 0.45 at 30 m, 0.25 at 60 m (Gary 28 Nov: clear in the shallow lagoon,
// a natural fade toward open water, not noisy).
const float CAUS_FADE_M = 13.0;

// ---- v98's tile break: three copies of the tile (turned 0, 36.9, 73.7 deg and shifted), weighted by patches of 7 m
float caus_tb_w(vec2 x, float v) {
	vec2 q = x / CAUS_TB_CELL + vec2(13.7, 7.9) * v;
	vec2 i = floor(q); vec2 f = q - i;
	f = f * f * (3.0 - 2.0 * f);
	vec2 a = vec2(127.1, 311.7);
	vec4 h = fract(sin(vec4(dot(i, a), dot(i + vec2(1.0, 0.0), a), dot(i + vec2(0.0, 1.0), a), dot(i + vec2(1.0, 1.0), a))) * 43758.5453);
	return smoothstep(0.25, 0.75, mix(mix(h.x, h.y, f.x), mix(h.z, h.w, f.x), f.y)) + 0.05;
}
vec3 caus_tb_weights(vec2 x) {
	vec3 w = vec3(caus_tb_w(x, 0.0), caus_tb_w(x, 1.0), caus_tb_w(x, 2.0));
	return w * inversesqrt(dot(w, w));
}
vec2 caus_tb_x1(vec2 x) { return vec2(0.8 * x.x - 0.6 * x.y + 37.31, 0.6 * x.x + 0.8 * x.y + 11.87); }
vec2 caus_tb_x2(vec2 x) { return vec2(0.28 * x.x - 0.96 * x.y + 5.17, 0.96 * x.x + 0.28 * x.y + 23.93); }

// ---- the per-pixel reader
// the x whose ray lands on X (x = X - h g(x), from the guess x)
vec2 caus_back(int o, vec2 X, vec2 x, int steps, float tt) {
	for (int n = 0; n < steps; n++) {
		vec2 s = vec2(0.0);
		for (int i = 0; i < CAUS_N; i++) {
			vec4 w = CAUS_K[i];
			s += CAUS_G[o + i] * cos(dot(w.xy, x) + w.z - 6.2831853 * fract(w.w * tt));
		}
		x = X - s;
	}
	return x;
}
// the light of the bundle that entered at x, x plain sun
float caus_focus(int o, vec2 x, float tt) {
	vec3 h = vec3(0.0);
	for (int i = 0; i < CAUS_N; i++) {
		vec4 w = CAUS_K[i];
		h += CAUS_H[o + i] * sin(dot(w.xy, x) + w.z - 6.2831853 * fract(w.w * tt));
	}
	float det = (1.0 + h.x) * (1.0 + h.y) - h.z * h.z;
	return min(inversesqrt(det * det + CAUS_EPS * CAUS_EPS), CAUS_CAP);
}
// one depth at X: the focus, softened over the sun's disc at that depth (the map: 8 ring taps and the centre; here 4
// and the centre, each ring tap starting from the centre's answer) and over the pixel (the map's reader: 4 taps at
// min(0.35 x pixel, 4 cm) once a pixel covers more than 1 cm; here the same radius widens the one ring)
float caus_level(int level, vec2 X, float pixel_m, float tt) {
	int o = level * CAUS_N;
	vec2 x = caus_back(o, X, X, 3, tt);
	float acc = caus_focus(o, x, tt);
	float rs = 0.7 * CAUS_SUN_RAD * CAUS_DEPTHS[level];
	float tx = CAUS_TILE / CAUS_PX;
	float rp = pixel_m > 2.0 * tx ? min(0.35 * pixel_m, 8.0 * tx) : 0.0;
	float r = sqrt(rs * rs + rp * rp);
	for (int k = 0; k < 4; k++) {
		float an = 1.5707963 * (float(k) + 0.5);
		vec2 Xk = X + r * vec2(cos(an), sin(an));
		acc += caus_focus(o, caus_back(o, Xk, Xk + (x - X), 2, tt), tt);
	}
	return acc / 5.0;
}
vec3 caus_pixel_at(vec2 X, int lo, float f, float pixel_m, float tt) {
	vec3 s = vec3(1.0);
	if (lo == 0) { if (f < 0.999) s.r = caus_level(0, X, pixel_m, tt); if (f > 0.001) s.g = caus_level(1, X, pixel_m, tt); }
	else { if (f < 0.999) s.g = caus_level(1, X, pixel_m, tt); if (f > 0.001) s.b = caus_level(2, X, pixel_m, tt); }
	return s;
}
// ---- the map's reader (v98 FFT_NET_HLSL): four taps over the pixel once it covers more than two texels
vec3 caus_map_at(vec2 X, float pixel_m) {
	float tx = CAUS_TILE / CAUS_PX;
	vec2 uv = X / CAUS_TILE;
	if (pixel_m > 2.0 * tx) {
		float r = min(0.35 * pixel_m, 8.0 * tx) / CAUS_TILE;
		return 0.25 * (textureLod(water_caus_map, uv + vec2(r, 0.3 * r), 0.0).rgb + textureLod(water_caus_map, uv + vec2(-0.3 * r, r), 0.0).rgb
			+ textureLod(water_caus_map, uv + vec2(-r, -0.3 * r), 0.0).rgb + textureLod(water_caus_map, uv + vec2(0.3 * r, -r), 0.0).rgb);
	}
	return textureLod(water_caus_map, uv, 0.0).rgb;
}
float caus_time(float time_s) { return (water_caus_k.y >= 0.0 ? water_caus_k.y : time_s) / CAUS_LOOP; }

// The net at a lit point (v98 FFT_NET_HLSL): wpos Godot world m, depth m under the still surface, sun_w the refracted
// sun (toward the sun, Godot frame), pixel_m the pixel's size on the ground. Returns x plain sun, mean ~1.
float caustic_net(vec3 wpos, float depth, vec3 sun_w, float pixel_m, float time_s) {
	if (depth <= 0.0 || water_caus_k.z > 0.5) return 1.0;
	vec2 e = wpos.xz + sun_w.xz * (depth / max(sun_w.y, 0.2));   // where this point's sunlight came through the surface
	vec2 X = vec2(e.x, -e.y);
	float nw = clamp(log2(max(depth, 1e-3) / CAUS_D0) / CAUS_DSTEP, 0.0, 2.0);
	vec3 tb = caus_tb_weights(X);
	vec3 s = vec3(1.0);
	if (water_caus_k.x > 0.5) {
		if (tb.x > 0.001) s += tb.x * (caus_map_at(X, pixel_m) - 1.0);
		if (tb.y > 0.001) s += tb.y * (caus_map_at(caus_tb_x1(X), pixel_m) - 1.0);
		if (tb.z > 0.001) s += tb.z * (caus_map_at(caus_tb_x2(X), pixel_m) - 1.0);
	} else {
		float tt = caus_time(time_s);
		int lo = nw < 1.0 ? 0 : 1;
		float f = nw - float(lo);
		if (tb.x > 0.001) s += tb.x * (caus_pixel_at(X, lo, f, pixel_m, tt) - 1.0);
		if (tb.y > 0.001) s += tb.y * (caus_pixel_at(caus_tb_x1(X), lo, f, pixel_m, tt) - 1.0);
		if (tb.z > 0.001) s += tb.z * (caus_pixel_at(caus_tb_x2(X), lo, f, pixel_m, tt) - 1.0);
	}
	s = max(s, vec3(0.0));
	float c = nw < 1.0 ? mix(s.r, s.g, nw) : mix(s.g, s.b, nw - 1.0);
	float dz = max(depth - CAUS_DEPTHS[2], 0.0) / CAUS_FADE_M;
	return mix(1.0, c, clamp(depth / CAUS_D0, 0.0, 1.0) * inversesqrt(1.0 + dz * dz));
}
// The sun's light function (Unreal M_LW_LF_Caustics): S = (CausticStrength + CausticPerStop x ExposureBias) x NetK,
// under water only, never over the headroom. net_k 1 = the saved Unreal picture.
float caustic_sun(vec3 wpos, float depth, vec3 sun_w, float pixel_m, float time_s, float net_k) {
	float s = CAUS_S * max(net_k, 0.0) * clamp(depth / CAUS_MASK_M, 0.0, 1.0);
	if (s <= 0.0) return 1.0;
	return clamp(1.0 + s * (caustic_net(wpos, depth, sun_w, pixel_m, time_s) - 1.0), 0.0, CAUS_HEADROOM);
}
