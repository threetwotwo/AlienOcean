#version 450
// Screen AO temporal accumulation (ao thread, 28 Nov 2026). The occlusion pass draws a new noise pattern each frame; this blends
// each pixel with its own history, found where the camera saw that point last frame (camera reprojection through linear depth),
// so the noise averages out in the world instead of crawling on the screen. Measured with tools/ao_motion_check.gd: under FSR 2
// CORTAO's own flicker was 1.5 levels vs Godot SSAO 0.8, because FSR 2 at half resolution does not hold the AO's noise.
// History is rejected where the reprojected depth disagrees (disocclusion, moving things) and clamped to the current
// neighbourhood's range (no ghosts). Output as the filter's: r = occlusion, gba = bent normal * 0.5 + 0.5 (screen_ao.gdshaderinc).

layout(push_constant, std430) uniform Params {
	vec4 unproj;        // this frame: view xy = (uv * unproj.xy + unproj.zw) * linear depth
	vec4 unproj_prev;   // last frame's
	vec4 m0;            // view (this frame) -> view (last frame), rows of the 3x4 affine
	vec4 m1;
	vec4 m2;
	vec2 inv_res;
	float alpha;        // weight of the new frame (1 = no history)
	float depth_tol;    // relative depth difference that rejects the history
	float clamp_pad;    // slack around the neighbourhood's range
	float pad0;
	float pad1;
	float pad2;
} P;

layout(set = 0, binding = 0) uniform usampler2D packedDataBuffer;   // full res, mip 0: linear depth (uint bits); 0 = sky
layout(set = 0, binding = 1) uniform sampler2D current;             // this frame's filtered AO (rgba8), full res
layout(set = 0, binding = 2) uniform sampler2D history;             // last frame's result (rgba16f: ao, bent normal xyz)
layout(set = 0, binding = 3) uniform sampler2D historyDepth;        // last frame's linear depth (r32f)
layout(rgba8, set = 0, binding = 4) uniform restrict writeonly image2D outputBuffer;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D historyOut;
layout(r32f, set = 0, binding = 6) uniform restrict writeonly image2D historyDepthOut;

layout(local_size_x = 8, local_size_y = 8) in;
void main() {
	ivec2 res = textureSize(current, 0);
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= res.x || p.y >= res.y) return;
	float z = uintBitsToFloat(texelFetch(packedDataBuffer, p, 0).r);
	vec4 c = texelFetch(current, p, 0);
	if (z == 0.0) {   // sky
		imageStore(outputBuffer, p, vec4(1.0, 0.5, 0.5, 1.0));
		imageStore(historyOut, p, vec4(1.0, 0.0, 0.0, 1.0));
		imageStore(historyDepthOut, p, vec4(0.0));
		return;
	}
	vec3 cn = c.gba * 2.0 - 1.0;
	// neighbourhood range of the occlusion: taps 3 px apart cover the filter's blotches
	float lo = c.r, hi = c.r;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			float v = texelFetch(current, clamp(p + ivec2(i, j) * 3, ivec2(0), res - 1), 0).r;
			lo = min(lo, v); hi = max(hi, v);
		}
	}
	float a = P.alpha;
	vec4 h = vec4(c.r, cn);
	if (a < 1.0) {
		vec2 uv = (vec2(p) + 0.5) * P.inv_res;
		vec4 v = vec4(fma(uv, P.unproj.xy, P.unproj.zw) * z, -z, 1.0);
		vec3 q = vec3(dot(P.m0, v), dot(P.m1, v), dot(P.m2, v));   // the same point in last frame's view
		float zq = -q.z;
		vec2 puv = (q.xy / zq - P.unproj_prev.zw) / P.unproj_prev.xy;
		bool ok = zq > 0.0 && all(greaterThanEqual(puv, vec2(0.0))) && all(lessThanEqual(puv, vec2(1.0)));
		if (ok) {
			float hz = texelFetch(historyDepth, clamp(ivec2(puv * vec2(res)), ivec2(0), res - 1), 0).r;
			ok = hz > 0.0 && abs(hz - zq) < P.depth_tol * zq;
		}
		if (ok) h = textureLod(history, puv, 0.0);
		else a = 1.0;
	}
	h.x = clamp(h.x, lo - P.clamp_pad, hi + P.clamp_pad);
	vec4 r = mix(h, vec4(c.r, cn), a);
	vec3 bn = dot(r.yzw, r.yzw) > 1e-8 ? normalize(r.yzw) : cn;
	imageStore(historyOut, p, vec4(r.x, bn));
	imageStore(historyDepthOut, p, vec4(z));
	imageStore(outputBuffer, p, vec4(clamp(r.x, 0.0, 1.0), bn * 0.5 + 0.5));
}
