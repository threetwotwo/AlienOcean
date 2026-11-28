#version 450
// Waterline 0.1.0 (water surface thread, 28 Nov 2026), after the transparent pass (adapters/godot/waterline_effect.gd):
// the Unreal tank's M_PP_OO_Waterline (WATERLINE_HLSL, openocean v374), ported. Gary 28 Nov: "under water to over water
// transitions ... not great/responsive", "cant you check ue5 open water code?". Each pixel's point on the lens (the near
// plane) is over or under the wave there: the FFT sea's height with its sideways push undone (three fixed-point steps
// over the long cascades, as the tank did). Where the lens is half in a wave the line between the two runs along the
// real wave; along it a thin film of water drags the picture toward the line and blurs it across, a wobble running along
// it, a dark foot on the line and a pale rim just above it. (Which side of the line gets the water's haze is the
// underwater view's per-pixel test, look/underwater_view 0.5.0, the same height.)
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_out;
layout(set = 0, binding = 1) uniform sampler2D color_src;
layout(set = 0, binding = 2) uniform sampler2DArray sea_disp;
layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inv_proj;
	mat4 cam;          // camera transform (basis + origin), Godot world
	vec4 tiles;        // the cascades' tile sizes (m)
	vec4 p0;           // water_y (still level), time, width, height
} P;

vec3 disp(vec2 X) {    // island xy -> (push x, push y, height), the three long cascades (the 0.32 m one is mm)
	vec3 D = vec3(0.0);
	D += textureLod(sea_disp, vec3(X / P.tiles.x, 0.0), 0.0).xyz;
	D += textureLod(sea_disp, vec3(X / P.tiles.y, 1.0), 0.0).xyz;
	D += textureLod(sea_disp, vec3(X / P.tiles.z, 2.0), 0.0).xyz;
	return D;
}

// metres above the water at pixel q's point on the lens
float lens_h(vec2 q, vec2 sz) {
	vec2 uv = (q + 0.5) / sz;
	vec4 vp = P.inv_proj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 pn = (P.cam * vec4(vp.xyz / vp.w, 1.0)).xyz;
	vec2 xi = vec2(pn.x, -pn.z);                      // island xy
	vec2 X = xi;
	vec3 D = vec3(0.0);
	for (int it = 0; it < 3; it++) { D = disp(X); X = xi - D.xy; }
	return pn.y - (P.p0.x + D.z);
}

void main() {
	vec2 sz = P.p0.zw;
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= int(sz.x) || px.y >= int(sz.y)) return;
	vec2 q = vec2(px);
	float d = lens_h(q, sz);
	vec2 g = vec2(lens_h(q + vec2(1.0, 0.0), sz) - d, lens_h(q + vec2(0.0, 1.0), sz) - d);
	float gl = length(g);
	if (gl < 1e-7) return;
	float dpx = d / gl;                                   // pixels from the waterline (+ = the dry side)
	float B = 0.015 * sz.y;                               // the film's half width (about 16 px at 1080)
	if (abs(dpx) > 1.6 * B) return;
	vec2 nrm = g / gl;                                    // across the line, toward the dry side
	vec2 tg = vec2(-nrm.y, nrm.x);
	float t = clamp(1.0 - abs(dpx) / B, 0.0, 1.0);
	float t2 = t * t * (3.0 - 2.0 * t);
	float along = dot(q, tg);
	float wob = (1.5 * sin(along * 0.045 + P.p0.y * 1.7) + 0.8 * sin(along * 0.11 - P.p0.y * 2.3)) * t2;
	vec2 c0 = (q + 0.5) + nrm * (-0.55 * dpx * t2) + tg * wob;   // the film stretches the picture toward its line
	float r = 1.0 + 5.0 * t2;                             // blur across the line, px
	vec3 acc = vec3(0.0);
	float ws = 0.0;
	for (int k = -3; k <= 3; k++) {
		float wk = exp(-0.5 * float(k * k) / 4.0);
		acc += wk * textureLod(color_src, clamp((c0 + nrm * (float(k) * r)) / sz, vec2(0.0), vec2(1.0)), 0.0).rgb;
		ws += wk;
	}
	acc /= ws;
	vec3 base = texelFetch(color_src, px, 0).rgb;
	vec3 col = mix(base, acc, t2);
	float foot = exp(-0.5 * dpx * dpx / 2.25);            // the film's dark foot, right on the line
	float rim = exp(-0.5 * (dpx - 4.0) * (dpx - 4.0) / 4.0);   // a pale rim just above it
	float lum = dot(acc, vec3(0.2126, 0.7152, 0.0722));
	col = col * (1.0 - 0.45 * foot) + rim * 0.25 * (lum + 0.02 * dot(base, vec3(0.333)) + 1e-4) * vec3(0.85, 0.95, 1.0);
	imageStore(color_out, px, vec4(col, 1.0));
}
