#version 450
// Sea mip pass 0.1.0 (water surface thread): one mip level of the sea's fields from the level above, 2 x 2 mean.
// The fields repeat on their patch, so the mean is wrap-averaged by construction (LESSONS water, tank v361: read each
// cascade from a wrap-averaged mip chain at the pixel footprint, never fade a whole cascade by its shortest wave).
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D dispHi[4];    // one slice per cascade
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dispLo[4];
layout(rgba16f, set = 0, binding = 2) uniform restrict readonly image2D derivHi[4];
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D derivLo[4];
layout(push_constant, std430) uniform Mip { float k; float pad0; float pad1; float pad2; } P;   // k = 0.25 (the 2 x 2 mean)

void main() {
	ivec3 at = ivec3(gl_GlobalInvocationID.xyz);
	int c = at.z;
	ivec2 sz = imageSize(dispLo[c]);
	if (at.x >= sz.x || at.y >= sz.y) return;
	ivec2 h = at.xy * 2;
	vec4 d = imageLoad(dispHi[c], h) + imageLoad(dispHi[c], h + ivec2(1, 0)) + imageLoad(dispHi[c], h + ivec2(0, 1)) + imageLoad(dispHi[c], h + ivec2(1, 1));
	vec4 g = imageLoad(derivHi[c], h) + imageLoad(derivHi[c], h + ivec2(1, 0)) + imageLoad(derivHi[c], h + ivec2(0, 1)) + imageLoad(derivHi[c], h + ivec2(1, 1));
	imageStore(dispLo[c], at.xy, P.k * d);
	imageStore(derivLo[c], at.xy, P.k * g);
}
