#version 450
// CORTAO filter pass, Godot wrapper (see cortao_prepass.glsl): the large symmetric depth/normal-aware filter with bent normals.
// CORTAO_OUT_PACKED (defined by the effect): the same filter again on its own output, for renders with no temporal filter.
// Output for the materials (look/screen_ao.gdshaderinc): r = occlusion (1 = open), gba = view-space bent normal * 0.5 + 0.5.
#extension GL_EXT_control_flow_attributes : enable
#define CORTAO_GLSL 1
#define CORTAO_PERSPECTIVE_PROJECTION 1
#define CORTAO_16_BIT 0
#define CORTAO_FILTER_BENT_NORMAL 1
#define CORTAO_LARGE_FILTER 1
#define CORTAO_FILTER_SYMMETRY 1
#include <CORTAOFilterPass.h>

layout(push_constant, std430) uniform CORTAOFilterPassPushUniforms { CORTAOFilterPassParameters parameters; };
layout(set = 0, binding = 0) uniform usampler2D packedDataBuffer;   // NEAREST, clamp to border
layout(set = 0, binding = 1) uniform usampler2D ssaoBuffer;         // NEAREST, clamp to border
#ifdef CORTAO_OUT_PACKED
layout(r32ui, set = 0, binding = 2) uniform restrict writeonly uimage2D outputBuffer;   // a second filter pass follows
#else
layout(rgba8, set = 0, binding = 2) uniform restrict writeonly image2D outputBuffer;
#endif

uvec4 cortao_gatherPackedData(vec2 texCoords, ivec2 offset) { return textureGatherOffset(packedDataBuffer, texCoords, offset); }
mat4 cortao_gatherSSAO(vec2 texCoords, ivec2 offset) {
	uvec4 q = textureGatherOffset(ssaoBuffer, texCoords, offset);
	return mat4(unpackSnorm4x8(q[0]), unpackSnorm4x8(q[1]), unpackSnorm4x8(q[2]), unpackSnorm4x8(q[3]));
}
void cortao_writeFilterOutput(ivec2 p, vec4 ssao) {
#ifdef CORTAO_OUT_PACKED
	imageStore(outputBuffer, p, uvec4(packSnorm4x8(ssao), 0u, 0u, 0u));
#else
	vec3 bn = dot(ssao.yzw, ssao.yzw) > 1e-8 ? normalize(ssao.yzw) : vec3(0.0, 0.0, 1.0);
	imageStore(outputBuffer, p, vec4(clamp(ssao.x, 0.0, 1.0), bn * 0.5 + 0.5));
#endif
}

layout(local_size_x = 8, local_size_y = 8) in;   // each thread writes a 2x2 block
void main() { cortao_filterPass(gl_GlobalInvocationID.xy, parameters); }
