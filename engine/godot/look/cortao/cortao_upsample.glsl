#version 450
// CORTAO half-resolution upsample (ao thread, 28 Nov 2026). With half_res the occlusion pass and its filter run on a quarter of
// the pixels (Godot's own SSAO does the same by default); this brings the filtered result back to full resolution.
// Half-res pixel h was computed at full-res pixel 2h + 1 (its depth and normal), so each full-res pixel blends its four nearest
// half-res pixels bilinearly, each weighted by how close its depth is to this pixel's depth (no AO bleeding across edges).
// Output as the filter's: r = occlusion, gba = view-space bent normal * 0.5 + 0.5 (look/screen_ao.gdshaderinc).

layout(push_constant, std430) uniform Params {
	ivec2 full_res;
	ivec2 half_res;
	float depth_k;     // depth sensitivity: relative depth difference 1 / depth_k halves a tap's weight
	float pad0;
	float pad1;
	float pad2;
} P;

layout(set = 0, binding = 0) uniform usampler2D packedDataBuffer;   // full res, mip 0: linear depth (uint bits)
layout(set = 0, binding = 1) uniform usampler2D halfAO;             // packSnorm4x8(occlusion, bent normal), half res
layout(rgba8, set = 0, binding = 2) uniform restrict writeonly image2D outputBuffer;

float depth_at(ivec2 p) { return uintBitsToFloat(texelFetch(packedDataBuffer, clamp(p, ivec2(0), P.full_res - 1), 0).r); }

layout(local_size_x = 8, local_size_y = 8) in;
void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= P.full_res.x || p.y >= P.full_res.y) return;
	float z = depth_at(p);
	if (z == 0.0) { imageStore(outputBuffer, p, vec4(1.0, 0.5, 0.5, 1.0)); return; }   // sky
	// position of p in half-res pixel space (half pixel h sits at full 2h + 1)
	vec2 hp = (vec2(p) - 1.0) * 0.5;
	ivec2 h0 = ivec2(floor(hp));
	vec2 f = hp - vec2(h0);
	vec4 acc = vec4(0.0);
	float wsum = 0.0;
	for (int j = 0; j < 2; j++) {
		for (int i = 0; i < 2; i++) {
			ivec2 h = clamp(h0 + ivec2(i, j), ivec2(0), P.half_res - 1);
			float zh = depth_at(h * 2 + 1);
			if (zh == 0.0) continue;
			float bil = (i == 0 ? 1.0 - f.x : f.x) * (j == 0 ? 1.0 - f.y : f.y) + 1e-3;
			float w = bil * exp2(-abs(zh - z) / z * P.depth_k);
			acc += unpackSnorm4x8(texelFetch(halfAO, h, 0).r) * w;
			wsum += w;
		}
	}
	vec4 r = wsum > 1e-6 ? acc / wsum : vec4(1.0, 0.0, 0.0, 1.0);
	vec3 bn = dot(r.yzw, r.yzw) > 1e-8 ? normalize(r.yzw) : vec3(0.0, 0.0, 1.0);
	imageStore(outputBuffer, p, vec4(clamp(r.x, 0.0, 1.0), bn * 0.5 + 0.5));
}
