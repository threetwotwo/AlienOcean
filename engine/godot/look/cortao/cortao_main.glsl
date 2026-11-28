#version 450
// CORTAO main pass, Godot wrapper (see cortao_prepass.glsl). CORTAO_SAMPLES samples, CORTAO_RAYS rays (16/32), occluder lookup table; the bent normal is summed
// from the rays (no lookup table: Godot's RD has no typed texel buffer from script). Output: occlusion + view-space bent normal,
// packSnorm4x8 into R32_UINT for the filter pass.
#extension GL_EXT_control_flow_attributes : enable
#define CORTAO_GLSL 1
#define CORTAO_PERSPECTIVE_PROJECTION 1
#define CORTAO_16_BIT 0
#define CORTAO_SAMPLE_COUNT CORTAO_SAMPLES
#define CORTAO_RAY_COUNT CORTAO_RAYS
#define CORTAO_OCCLUDER_LOOKUP_TABLE 1
#define CORTAO_BENT_NORMAL_LOOKUP_TABLE 0
#include <CORTAOMainPass.h>

layout(push_constant, std430) uniform CORTAOMainPassPushUniforms { CORTAOMainPassParameters parameters; };
layout(set = 0, binding = 0) uniform usampler2D packedDataBuffer;      // NEAREST, clamp to border (int transparent black = sky)
layout(set = 0, binding = 1) uniform sampler2D normalBuffer;            // the prepass's shape normal (n * 0.5 + 0.5)
layout(set = 0, binding = 2) uniform usampler3D occluderLookupTable;   // NEAREST, clamp to edge; R16_UINT (16 rays) / R32_UINT (32)
layout(r32ui, set = 0, binding = 3) uniform restrict writeonly uimage2D outputBuffer;
// Light weighting (Godot wrapper addition): up_on.xyz = world up in view space, up_on.w 1 = on; light.x/y = luminance of the water's
// light from above / below (the same two halves the GI reads, look/sky.gdshader under_down / under_up).
layout(set = 0, binding = 4, std140) uniform LightParams { vec4 up_on; vec4 light; } LW;
#ifdef CORTAO_HALF   // the filter's depth / normal at half res: the full-res texel this pixel was computed at (CORTAO's own mips
                     // alternate their picks, which streaks the depth-aware filter)
layout(r32ui, set = 0, binding = 5) uniform restrict writeonly uimage2D halfPacked;
#endif

uint cortao_samplePackedData(vec2 texCoords, float mipmap) { return textureLod(packedDataBuffer, texCoords, mipmap).r; }
#ifdef CORTAO_HALF   // half resolution: half pixel p was computed at full pixel 2p + 1 (cortao_effect.gd half_res_ao)
vec3 cortao_loadNormal(ivec2 p) { return normalize(texelFetch(normalBuffer, p * 2 + 1, 0).xyz * 2.0 - 1.0); }
#else
vec3 cortao_loadNormal(ivec2 p) { return normalize(texelFetch(normalBuffer, p, 0).xyz * 2.0 - 1.0); }
#endif
uint cortao_sampleOccluderLookupTable(vec3 texCoords) { return textureLod(occluderLookupTable, texCoords, 0.0).r; }
// Under water the fill is far from uniform: most comes from above, little from the sand below. CORTAO's rays are cosine
// distributed, so the fill a pixel still receives is sum(open rays x L(dir)) / sum(all rays x L(dir)), with L the field's
// luminance from that direction. A crevice that only sees down keeps little; a side open to the water above keeps its fill.
void cortao_writeResult(ivec2 p, float occlusion, vec3 bentNormal, mat3 tangentSpaceTransform, uint rayBits) {
	if (LW.up_on.w > 0.5) {
		float open_w = 0.0, all_w = 0.0;
		for (uint i = 0u; i < uint(CORTAO_RAY_COUNT); i++) {
			float u = dot(tangentSpaceTransform * cortao_rayDirection(i), LW.up_on.xyz);
			float w = u >= 0.0 ? LW.light.x : LW.light.y;
			all_w += w;
			open_w += (rayBits & (1u << i)) == 0u ? w : 0.0;
		}
		if (all_w > 0.0) occlusion = open_w / all_w;
	}
	imageStore(outputBuffer, p, uvec4(packSnorm4x8(vec4(occlusion, bentNormal)), 0u, 0u, 0u));
}

uvec2 deinterleave(uint index) {
	uvec2 p = uvec2(index, index) >> uvec2(0, 1);
	p &= 0x5555u;
	p = (p ^ (p >> 1u)) & 0x3333u;
	p = (p ^ (p >> 2u)) & 0x0f0fu;
	p = (p ^ (p >> 4u)) & 0x00ffu;
	return p;
}

layout(local_size_x = 16, local_size_y = 16) in;
void main() {
	uvec2 pixelCoords = gl_WorkGroupID.xy * gl_WorkGroupSize.xy + deinterleave(gl_LocalInvocationIndex);
#ifdef CORTAO_HALF   // every pixel, sky included (0 = sky for the filter); before the pass, which returns early on sky
	if (all(lessThan(pixelCoords, uvec2(imageSize(halfPacked))))) imageStore(halfPacked, ivec2(pixelCoords), uvec4(texelFetch(packedDataBuffer, ivec2(pixelCoords) * 2 + 1, 0).r, 0u, 0u, 0u));
#endif
	cortao_mainPass(pixelCoords, parameters);
}
