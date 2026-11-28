#version 450
// CORTAO prepass, Godot wrapper (look/cortao, ao thread 28 Nov 2026). The algorithm is third_party/cortao (MIT, v1.0.3, unchanged);
// adapters/godot/cortao_effect.gd inlines the #include lines. Inputs: Godot's reverse-Z depth and its view-space normal_roughness
// buffer (best-fit normals stored as n * 0.5 + 0.5). Output: the packed linear depth + normal buffer, mips 0-7.
#extension GL_EXT_control_flow_attributes : enable
#define CORTAO_GLSL 1
#define CORTAO_PERSPECTIVE_PROJECTION 1
#include <CORTAOPrepass.h>

layout(push_constant, std430) uniform CORTAOPrepassPushUniforms { CORTAOPrepassParameters parameters; };
layout(set = 0, binding = 0) uniform sampler2D depthBuffer;
layout(set = 0, binding = 1) uniform sampler2D normalBuffer;
layout(r32ui, set = 0, binding = 2) uniform restrict writeonly uimage2D packedDataBufferMipmaps[8];

float cortao_loadDepth(ivec2 p) { return texelFetch(depthBuffer, p, 0).r; }
vec3 cortao_loadNormal(ivec2 p) { return normalize(texelFetch(normalBuffer, p, 0).xyz * 2.0 - 1.0); }
void cortao_writePackedData(ivec2 p, int mipLevel, uint data) { imageStore(packedDataBufferMipmaps[mipLevel], p, uvec4(data, 0u, 0u, 0u)); }

layout(local_size_x = 8, local_size_y = 8) in;
void main() { cortao_prepass(gl_GlobalInvocationID.xy, parameters); }
