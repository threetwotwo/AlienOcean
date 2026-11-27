#version 450
// Sea FFT pass 0.1.0 (water surface thread): lagoonwater v98 FFT_HLSL (the tank's radix-16 Stockham pass of the
// inverse FFT), as a Godot compute shader. Four passes make the 256 x 256 inverse FFT: radix 16 twice along x
// (ns 1, 16), then along y. Each texel carries two complex fields (rgba), both images at once.
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2DArray srcA;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2DArray srcB;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2DArray dstA;
layout(rgba32f, set = 0, binding = 3) uniform restrict writeonly image2DArray dstB;
layout(push_constant, std430) uniform Pass { int ns; int axis; int pad0; int pad1; } P;

vec4 cmul2(vec4 v, float cs, float sn) {
	return vec4(v.x * cs - v.y * sn, v.x * sn + v.y * cs, v.z * cs - v.w * sn, v.z * sn + v.w * cs);
}

void main() {
	ivec2 o = ivec2(gl_GlobalInvocationID.xy);
	int layer = int(gl_GlobalInvocationID.z);
	if (o.x >= 256 || o.y >= 256) return;
	int ns = P.ns;
	bool ax = P.axis > 0;
	int oi = ax ? o.y : o.x;
	int p = oi % ns;
	int r = (oi / ns) % 16;
	int j = (oi / (ns * 16)) * ns + p;
	float ang = 6.28318530718 * float(p) / float(ns * 16);
	vec4 accA = vec4(0.0), accB = vec4(0.0);
	for (int t = 0; t < 16; t++) {
		int idx = j + 16 * t;
		ivec3 s = ax ? ivec3(o.x, idx, layer) : ivec3(idx, o.y, layer);
		float ph = float(t) * ang + 0.392699081699 * float((r * t) & 15);
		float cs = cos(ph), sn = sin(ph);
		accA += cmul2(imageLoad(srcA, s), cs, sn);
		accB += cmul2(imageLoad(srcB, s), cs, sn);
	}
	imageStore(dstA, ivec3(o, layer), accA);
	imageStore(dstB, ivec3(o, layer), accB);
}
