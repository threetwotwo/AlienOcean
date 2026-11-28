#version 450
// Horizon-based screen AO, two variants on the same slice march, for the head to head against CORTAO (ao thread, 28 Nov 2026):
//   default:      XeGTAO main pass (Intel, MIT, github.com/GameTechDev/XeGTAO, Source/Rendering/Shaders/XeGTAO.hlsli
//                 XeGTAO_MainPass, ported to GLSL): per slice the two horizon angles, cosine-weighted visibility, bent normal
//                 (Jimenez et al. 2016, "Practical Real-Time Strategies for Accurate Indirect Occlusion", Algorithms 1 and 2).
//   GTAO_BITMASK: visibility bitmask (Therrien, Levesque, Gilet 2023, "Screen Space Indirect Lighting with Visibility Bitmask"):
//                 each slice is 32 sectors; a sample occludes only the sectors between its front face and its back face
//                 (depth + thickness), so thin things don't cast a horizon over everything behind them.
// Inputs are CORTAO's (cortao_prepass.glsl): packed linear depth mips and the shape normal, both in Godot view space
// (camera looks down -Z, Y up). Output is CORTAO's main-pass format (packSnorm4x8(visibility, view-space bent normal)) so
// CORTAO's depth/normal-aware filter denoises it and the materials read it the same way (look/screen_ao.gdshaderinc).
// Ported conventions: XeGTAO's view space looks down +Z, so its "towards the camera" (0,0,-1) is (0,0,1) here.
#extension GL_EXT_control_flow_attributes : enable

layout(push_constant, std430) uniform Params {
	vec4 unproj;        // view xy = (uv * unproj.xy + unproj.zw) * linear depth (CORTAO's unprojectParams)
	vec2 inv_res;
	uint packed_res;    // x | y << 16
	uint seed;
	float radius;       // effect radius, m
	float max_px;       // largest screen radius, pixels
	float thickness;    // bitmask: an occluder's assumed depth, m
	float slices;
	float steps;
	float final_power;  // XeGTAO FinalValuePower (2.2)
	float pad0;
	float pad1;
} P;

layout(set = 0, binding = 0) uniform usampler2D packedDataBuffer;   // NEAREST, clamp to border (0 = sky)
layout(set = 0, binding = 1) uniform sampler2D normalBuffer;        // shape normal * 0.5 + 0.5
layout(r32ui, set = 0, binding = 3) uniform restrict writeonly uimage2D outputBuffer;

const float PI = 3.14159265358979;
const float HALF_PI = 1.5707963267949;

float lin_depth(vec2 uv, float mip) { return uintBitsToFloat(textureLod(packedDataBuffer, uv, mip).r); }
vec3 view_pos(vec2 uv, float z) { return vec3(fma(uv, P.unproj.xy, P.unproj.zw) * z, -z); }
float fast_acos(float x) {   // XeGTAO_FastACos
	float r = -0.156583 * abs(x) + HALF_PI;
	r *= sqrt(1.0 - abs(x));
	return x >= 0.0 ? r : PI - r;
}
uint hash(uint n) { n ^= n >> 16; n *= 0x7feb352du; n ^= n >> 15; n *= 0x846ca68bu; n ^= n >> 16; return n; }

#ifdef GTAO_BITMASK
// antiderivative of the slice's cosine-weighted, projected-solid-angle integrand cos(t - n) |sin t|, 0 at t = 0
float slice_G(float t, float n) {
	float a = (2.0 * t * sin(n) - cos(2.0 * t - n) + cos(n)) * 0.25;
	return t >= 0.0 ? a : -a;
}
#endif

layout(local_size_x = 8, local_size_y = 8) in;
void main() {
	ivec2 res = ivec2(P.packed_res & 0xFFFFu, P.packed_res >> 16);
	ivec2 pix = ivec2(gl_GlobalInvocationID.xy);
	if (pix.x >= res.x || pix.y >= res.y) return;
	vec2 uv = (vec2(pix) + 0.5) * P.inv_res;
	float z = lin_depth(uv, 0.0);
	if (z == 0.0) return;   // sky
	vec3 N = normalize(texelFetch(normalBuffer, pix, 0).xyz * 2.0 - 1.0);
	vec3 C = view_pos(uv, z * 0.99999);
	vec3 V = normalize(-C);

	float px_size = z * abs(P.unproj.x) * P.inv_res.x;   // view-space size of one pixel at this depth
	float r_px = min(P.radius / px_size, P.max_px);
	float radius = r_px * px_size;                        // the radius actually reached after the screen clamp
	float falloff_range = 0.615 * radius;                 // XeGTAO defaults: falloff 0.615, distribution power 2
	float falloff_mul = -1.0 / falloff_range;
	float falloff_add = radius * (1.0 - 0.615) / falloff_range + 1.0;
	float min_s = 1.3 / r_px;

	uint h = hash(uint(pix.x) * 1973u + uint(pix.y) * 9277u + P.seed * 26699u);
	float noise_slice = float(h & 0xFFFFu) / 65536.0;
	float noise_sample = float(h >> 16) / 65536.0;

	float visibility = 0.0;
	vec3 bent = vec3(0.0);
	int slices = int(P.slices), steps = int(P.steps);
	for (int sl = 0; sl < slices; sl++) {
		float phi = (float(sl) + noise_slice) / P.slices * PI;
		vec3 dir = vec3(cos(phi), sin(phi), 0.0);
		vec2 omega = vec2(cos(phi), -sin(phi)) * r_px;   // screen pixels, y down
		vec3 ortho = dir - dot(dir, V) * V;
		vec3 axis = normalize(cross(ortho, V));
		vec3 pn = N - axis * dot(N, axis);
		float pn_len = length(pn);
		float sgn = sign(dot(ortho, pn));
		float cos_n = clamp(dot(pn, V) / max(pn_len, 1e-6), 0.0, 1.0);
		float n = sgn * fast_acos(cos_n);
#ifdef GTAO_BITMASK
		uint bits = 0u;
		vec3 ortho_n = normalize(ortho);
#else
		float low0 = cos(n + HALF_PI), low1 = cos(n - HALF_PI);
		float hc0 = low0, hc1 = low1;
#endif
		for (int st = 0; st < steps; st++) {
			float step_noise = fract(noise_sample + float(sl + st * steps) * 0.6180339887498948);
			float s = (float(st) + step_noise) / P.steps;
			s = s * s + min_s;
			vec2 off = s * omega;
			float mip = clamp(log2(length(off)) - 3.3, 0.0, 5.0);
			off = round(off) * P.inv_res;
			[[unroll]] for (int side = 0; side < 2; side++) {
				vec2 suv = side == 0 ? uv + off : uv - off;
				float sz = lin_depth(suv, mip);
				if (sz == 0.0) continue;   // sky or off screen: no occluder
				vec3 d = view_pos(suv, sz) - C;
				float dist = length(d);
#ifdef GTAO_BITMASK
				if (dist > radius) continue;
				// front and back of the occluder, as signed angles from V within the slice (+ = this side's direction)
				vec3 db = d - V * P.thickness;
				float af = fast_acos(clamp(dot(d / dist, V), -1.0, 1.0));
				float ab = fast_acos(clamp(dot(normalize(db), V), -1.0, 1.0));
				vec2 fb = side == 0 ? vec2(af, ab) : vec2(-ab, -af);
				// to sector space: the hemisphere around the projected normal, [n - pi/2, n + pi/2] -> [0, 1]
				fb = clamp((fb - n + HALF_PI) / PI, 0.0, 1.0);
				uint b0 = uint(fb.x * 32.0);
				uint cnt = uint(ceil((fb.y - fb.x) * 32.0));
				uint m = cnt >= 32u ? 0xFFFFFFFFu : (cnt == 0u ? 0u : ((1u << cnt) - 1u));
				bits |= b0 >= 32u ? 0u : (m << b0);
#else
				float w = clamp(dist * falloff_mul + falloff_add, 0.0, 1.0);
				float shc = dot(d / dist, V);
				if (side == 0) hc0 = max(hc0, mix(low0, shc, w));
				else hc1 = max(hc1, mix(low1, shc, w));
#endif
			}
		}
		pn_len = mix(pn_len, 1.0, 0.05);   // XeGTAO's fudge for slight overdarkening on steep slopes
#ifdef GTAO_BITMASK
		// visibility: the open sectors' share of the slice's cosine-weighted integral; bent normal: their mean direction
		float lo = n - HALF_PI;
		float g0 = slice_G(lo, n);
		float vis = 0.0;
		[[unroll]] for (int k = 0; k < 32; k++) {
			float t1 = lo + float(k + 1) * (PI / 32.0);
			float g1 = slice_G(t1, n);
			if ((bits & (1u << uint(k))) == 0u) {
				float wk = g1 - g0;
				vis += wk;
				float tc = t1 - PI / 64.0;
				bent += (cos(tc) * V + sin(tc) * ortho_n) * wk;
			}
			g0 = g1;
		}
		visibility += pn_len * vis;
#else
		float h0 = -fast_acos(hc1);
		float h1 = fast_acos(hc0);
		float iarc0 = (cos_n + 2.0 * h0 * sin(n) - cos(2.0 * h0 - n)) * 0.25;
		float iarc1 = (cos_n + 2.0 * h1 * sin(n) - cos(2.0 * h1 - n)) * 0.25;
		visibility += pn_len * (iarc0 + iarc1);
		// Algorithm 2: the slice's bent normal in its own frame (towards the camera = +Z here), then rotated onto V
		float t0 = (6.0 * sin(h0 - n) - sin(3.0 * h0 - n) + 6.0 * sin(h1 - n) - sin(3.0 * h1 - n) + 16.0 * sin(n) - 3.0 * (sin(h0 + n) + sin(h1 + n))) / 12.0;
		float t1 = (-cos(3.0 * h0 - n) - cos(3.0 * h1 - n) + 8.0 * cos(n) - 3.0 * (cos(h0 + n) + cos(h1 + n))) / 12.0;
		// the frame's "towards camera" axis is V; its in-slice axis is the slice direction made perpendicular to V
		bent += (normalize(ortho) * t0 + V * t1) * pn_len;
#endif
	}
	visibility /= P.slices;
#ifndef GTAO_BITMASK
	visibility = pow(clamp(visibility, 0.0, 1.0), P.final_power);
#endif
	visibility = clamp(visibility, 0.03, 1.0);
	vec3 bn = dot(bent, bent) > 1e-12 ? normalize(bent) : N;
	imageStore(outputBuffer, pix, uvec4(packSnorm4x8(vec4(visibility, bn)), 0u, 0u, 0u));
}
