#version 450
// Sea assemble pass 0.1.0 (water surface thread): lagoonwater v98 ASSEMBLE_HLSL, as a Godot compute shader. The sea's
// fields per cascade (array layer), world-anchored (uv = island xy / patch), 16-bit float:
//   disp  = (Dx, Dy, Dz, dDx/dy)          m (sideways push and height; Dx, Dy x chop)
//   deriv = (dDz/dx, dDz/dy, dDx/dx, dDy/dy)   (slope of the height, the squeeze)
// v98 split these over RT_LW_Disp / RT_LW_Deriv / RT_LW_Deriv2 with one texel of wrap padding; Godot's samplers
// wrap, so no padding. Mips (look/sea_mip.glsl) are wrap-averaged, so a far pixel reads its footprint's mean.
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2DArray fA;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2DArray fB;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D disp[4];    // one slice per cascade (mip 0)
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D deriv[4];
layout(push_constant, std430) uniform Asm { float chop; float pad0; float pad1; float pad2; } P;

void main() {
	ivec3 at = ivec3(gl_GlobalInvocationID.xyz);
	if (at.x >= 256 || at.y >= 256) return;
	float s = -P.chop;
	vec4 a = imageLoad(fA, at);   // F0 (re, im), F1 (re, im)
	vec4 b = imageLoad(fB, at);   // F2, F3
	imageStore(disp[at.z], at.xy, vec4(s * a.x, s * a.y, a.z, s * a.w));
	imageStore(deriv[at.z], at.xy, vec4(b.x, b.y, s * b.z, s * b.w));
}
