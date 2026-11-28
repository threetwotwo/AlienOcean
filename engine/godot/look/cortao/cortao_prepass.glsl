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
// shape normals (Godot wrapper addition): unproj = CORTAO's unprojectParams, inv_res = 1 / resolution, flags.x 1 = normals from depth
layout(set = 0, binding = 3, std140) uniform ShapeParams { vec4 unproj; vec4 inv_res; vec4 flags; } G;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image2D shapeNormal;   // the normal the main pass uses

float cortao_loadDepth(ivec2 p) { return texelFetch(depthBuffer, p, 0).r; }
vec3 view_pos(ivec2 p) {
	float d = texelFetch(depthBuffer, clamp(p, ivec2(0), ivec2(textureSize(depthBuffer, 0)) - 1), 0).r;
	float lz = 1.0 / max(fma(d, parameters.depthScale, parameters.depthOffset), 1e-9);
	vec2 uv = (vec2(p) + 0.5) * G.inv_res.xy;
	return vec3(fma(uv, G.unproj.xy, G.unproj.zw) * lz, -lz);
}
// The occlusion is about the shape at the 1 m scale, so by default the normal comes from the depth buffer (the smaller of the
// two one-sided differences each way, so silhouettes don't bend it), oriented by the shading normal. The shading normal carries
// the materials' fine detail (sand ripples, grain): fed to CORTAO it turns every pixel's ray hemisphere a different way and the
// shadow comes out speckled (key frame 28 Nov: grain 3.47 vs SSAO 3.05 on the table coral's shadow).
vec3 cortao_loadNormal(ivec2 p) {
	vec3 nb = normalize(texelFetch(normalBuffer, p, 0).xyz * 2.0 - 1.0);
	vec3 n = nb;
	if (G.flags.x > 0.5) {
		vec3 c = view_pos(p);
		vec3 l = view_pos(p - ivec2(1, 0)), r = view_pos(p + ivec2(1, 0));
		vec3 u = view_pos(p - ivec2(0, 1)), b = view_pos(p + ivec2(0, 1));
		vec3 dx = abs(r.z - c.z) < abs(c.z - l.z) ? r - c : c - l;
		vec3 dy = abs(b.z - c.z) < abs(c.z - u.z) ? b - c : c - u;
		vec3 g = cross(dx, dy);
		if (dot(g, g) > 1e-20) {
			g = normalize(g);
			n = dot(g, nb) < 0.0 ? -g : g;
		}
	}
	imageStore(shapeNormal, p, vec4(n * 0.5 + 0.5, 0.0));
	return n;
}
void cortao_writePackedData(ivec2 p, int mipLevel, uint data) { imageStore(packedDataBufferMipmaps[mipLevel], p, uvec4(data, 0u, 0u, 0u)); }

layout(local_size_x = 8, local_size_y = 8) in;
void main() { cortao_prepass(gl_GlobalInvocationID.xy, parameters); }
