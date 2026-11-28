#version 450
// CORTAO main pass, Godot wrapper (see cortao_prepass.glsl). 16 samples, 16 rays, occluder lookup table; the bent normal is summed
// from the rays (no lookup table: Godot's RD has no typed texel buffer from script). Output: occlusion + view-space bent normal,
// packSnorm4x8 into R32_UINT for the filter pass.
#extension GL_EXT_control_flow_attributes : enable
#define CORTAO_GLSL 1
#define CORTAO_PERSPECTIVE_PROJECTION 1
#define CORTAO_16_BIT 0
#define CORTAO_SAMPLE_COUNT CORTAO_SAMPLES
#define CORTAO_RAY_COUNT 16
#define CORTAO_OCCLUDER_LOOKUP_TABLE 1
#define CORTAO_BENT_NORMAL_LOOKUP_TABLE 0
#include <CORTAOMainPass.h>

layout(push_constant, std430) uniform CORTAOMainPassPushUniforms { CORTAOMainPassParameters parameters; };
layout(set = 0, binding = 0) uniform usampler2D packedDataBuffer;      // NEAREST, clamp to border (int transparent black = sky)
layout(set = 0, binding = 1) uniform sampler2D normalBuffer;
layout(set = 0, binding = 2) uniform usampler3D occluderLookupTable;   // NEAREST, clamp to edge
layout(r32ui, set = 0, binding = 3) uniform restrict writeonly uimage2D outputBuffer;

uint cortao_samplePackedData(vec2 texCoords, float mipmap) { return textureLod(packedDataBuffer, texCoords, mipmap).r; }
vec3 cortao_loadNormal(ivec2 p) { return normalize(texelFetch(normalBuffer, p, 0).xyz * 2.0 - 1.0); }
uint cortao_sampleOccluderLookupTable(vec3 texCoords) { return textureLod(occluderLookupTable, texCoords, 0.0).r; }
void cortao_writeResult(ivec2 p, float occlusion, vec3 bentNormal, mat3 tangentSpaceTransform, uint rayBits) {
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
	cortao_mainPass(pixelCoords, parameters);
}
