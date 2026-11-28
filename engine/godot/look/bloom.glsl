#version 450
// Bloom 0.1.0 (bloom thread, 28 Nov 2026): the key frame's camera veiling glare (papers/process/art_bible/style_level/
// keyframe/v7/develop_v7.py, bloom 1, threshold 3.0 before exposure 0.6 = 4.5 exposed units) on the GPU.
// The light above the threshold (per channel, in exposed scene units where 0.18 is middle grey) is taken off its pixel
// and spread by a power-law PSF built from five gaussians (sigma 1.5/4/12/36/90 px at 960 wide, weights .45/.25/.17/.09/.04),
// so the glare keeps energy. Run by adapters/godot/agx_effect.gd before the AgX tone curve, which adds the result.
// Passes (push constant mode): 0 prefilter (scene buffer -> excess per texel, 4x4 tent to half size), 1 downsample (13 taps),
// 2 separable gaussian (dir in pc). The excess per pixel is capped (d.z, BloomMax): a sub-pixel glint that aliases in and
// out before the temporal upscaler would otherwise pulse a large halo; the light above the cap stays on its pixel, so energy
// is still kept. (Stands in for running the glare after the temporal resolve, which Godot's compositor can't reach in HDR.)
// Everything addresses in normalised uv, so odd level sizes resample instead of shifting.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D dst;
layout(set = 0, binding = 1) uniform sampler2D src;
layout(push_constant, std430) uniform PC {
	vec4 a;   // mode, sigma (src px), radius (taps), threshold (exposed units)
	vec4 b;   // scale (buffer -> exposed), depth gain rgb
	vec4 c;   // dir x, dir y (prefilter: IsoK, unused), dst w, dst h
	vec4 d;   // src w, src h, excess cap (exposed units), IsoFloor (lone texel's most, exposed units)
} pc;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

vec3 tap(vec2 uv) { return texture(src, uv).rgb; }

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	vec2 dsz = pc.c.zw;
	if (p.x >= int(dsz.x) || p.y >= int(dsz.y)) return;
	vec2 uv = (vec2(p) + 0.5) / dsz;
	vec2 t = 1.0 / pc.d.xy;
	vec3 o;
	if (pc.a.x < 0.5) {
		// prefilter: each source texel's light above the threshold first, then a 4x4 tent (1 3 3 1) to half size; thresholding
		// filtered samples instead would lose the energy at every bright edge. A lone hot texel (a sub-pixel sun glint that
		// aliases on and off from frame to frame) may give at most IsoFloor, or IsoK x its brightest 4-neighbour: the sun disc
		// and glint lines (bright neighbours) keep their full glare, a single flashing pixel can't throw a halo. agx_post.glsl
		// takes exactly the same amount off the pixel, so energy is still kept.
		ivec2 sm = ivec2(pc.d.xy) - 1; ivec2 b = 2 * p - 2;
		vec3 e[36];
		for (int j = 0; j < 6; j++) for (int i = 0; i < 6; i++) {
			vec3 v = texelFetch(src, clamp(b + ivec2(i, j), ivec2(0), sm), 0).rgb;
			v = mix(v, vec3(0.0), bvec3(uvec3(isnan(v)) | uvec3(isinf(v))));   // a broken texel (NaN / fp16 overflow) gives no glare
			e[j * 6 + i] = clamp(v * pc.b.x * pc.b.yzw - pc.a.w, vec3(0.0), vec3(pc.d.z));
		}
		const float tw[4] = float[](0.125, 0.375, 0.375, 0.125);
		o = vec3(0.0);
		for (int j = 1; j < 5; j++) for (int i = 1; i < 5; i++) {
			vec3 nb = max(max(e[j * 6 + i - 1], e[j * 6 + i + 1]), max(e[(j - 1) * 6 + i], e[(j + 1) * 6 + i]));
			o += tw[i - 1] * tw[j - 1] * min(e[j * 6 + i], max(vec3(pc.d.w), pc.c.x * nb));
		}
	} else if (pc.a.x < 1.5) {
		// Call of Duty 13-tap downsample (Jimenez 2014): four 2x2 boxes at the corners, one in the middle
		vec3 A = tap(uv + t * vec2(-2, -2)), B = tap(uv + t * vec2(0, -2)), C = tap(uv + t * vec2(2, -2));
		vec3 D = tap(uv + t * vec2(-1, -1)), E = tap(uv + t * vec2(1, -1));
		vec3 F = tap(uv + t * vec2(-2, 0)), G = tap(uv), H = tap(uv + t * vec2(2, 0));
		vec3 I = tap(uv + t * vec2(-1, 1)), J = tap(uv + t * vec2(1, 1));
		vec3 K = tap(uv + t * vec2(-2, 2)), L = tap(uv + t * vec2(0, 2)), M = tap(uv + t * vec2(2, 2));
		vec3 g0 = (D + E + I + J) * 0.25, g1 = (A + B + F + G) * 0.25, g2 = (B + C + G + H) * 0.25;
		vec3 g3 = (F + G + K + L) * 0.25, g4 = (G + H + L + M) * 0.25;
		o = 0.5 * g0 + 0.125 * (g1 + g2 + g3 + g4);
	} else {
		// separable gaussian, two taps per bilinear fetch would be cheaper; the levels are small, so plain taps
		float s = max(pc.a.y, 0.3); int r = int(pc.a.z);
		vec2 dir = pc.c.xy * t;
		vec3 acc = vec3(0.0); float ws = 0.0;
		for (int i = -r; i <= r; i++) {
			float w = exp(-0.5 * float(i * i) / (s * s));
			acc += w * texture(src, uv + dir * float(i)).rgb; ws += w;
		}
		o = acc / ws;
	}
	imageStore(dst, p, vec4(o, 1.0));
}
