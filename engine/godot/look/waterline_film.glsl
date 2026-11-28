#version 450
// Waterline film 0.1.0 (water surface thread, 28 Nov 2026): the water film on the lens where the waterline crosses it,
// from the Unreal open-water tank (openocean_tank v374 WATERLINE_HLSL, v162-v204). Run by adapters/godot/waterline_film.gd
// after the transparent pass, so it lies over the finished picture (the sea from above is transparent and draws after
// the underwater quad: a film drawn there was painted over). As the tank: within about 1.5 % of the screen's height of
// the line the picture is blurred across it (radius 1 + 5 t^2 px, seven taps), pulled toward it (-0.55 x the distance
// x t^2) and wobbled slowly along it, with a dark foot on the line and a pale rim 4 px above it.
// The line is where the lens's near clip plane meets the drawn waves, found as look/sea_side.gdshaderinc does
// (the same test the underwater quad uses for wet or dry, so the film sits exactly on its cut).
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_out;
layout(set = 0, binding = 1) uniform sampler2D color_src;
layout(set = 0, binding = 2) uniform sampler2DArray sea_disp;
layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inv_proj;
	mat4 cam;          // the camera's world transform (Godot, y up)
	vec4 casc;         // the cascades' sizes, m (sea_patch)
	vec4 P0;           // still level (Godot y), time s, band (share of height), strength
	vec4 P1;           // width, height px
} P;

float lens_h(vec2 uv) {
	vec4 vn = P.inv_proj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 g = (P.cam * vec4(vn.xyz / vn.w, 1.0)).xyz;
	vec3 pn = vec3(g.x, -g.z, g.y);                          // the island frame (sea_isl)
	vec2 X = pn.xy;
	vec3 D = vec3(0.0);
	for (int it = 0; it < 3; it++) {
		D = vec3(0.0);
		for (int c = 0; c < 3; c++) D += textureLod(sea_disp, vec3(X / P.casc[c], float(c)), 0.0).xyz;
		X = pn.xy - D.xy;
	}
	return pn.z - (P.P0.x + D.z);
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = ivec2(P.P1.xy);
	if (any(greaterThanEqual(px, sz))) return;
	vec2 inv = 1.0 / vec2(sz);
	vec2 uv = (vec2(px) + 0.5) * inv;
	float h = lens_h(uv);
	vec2 g = vec2(lens_h(uv + vec2(inv.x, 0.0)) - h, lens_h(uv + vec2(0.0, inv.y)) - h);   // m per px
	float gl = length(g);
	float B = P.P0.z * float(sz.y);                          // about 16 px at 1080
	if (gl < 1e-7) return;
	float dpx = h / gl;                                      // px from the waterline (+ = the dry side)
	if (abs(dpx) > 1.6 * B) return;
	vec2 nrm = g / gl;                                       // across the line, toward the dry side
	float t = clamp(1.0 - abs(dpx) / B, 0.0, 1.0);
	float t2 = t * t * (3.0 - 2.0 * t);
	vec2 tg = vec2(-nrm.y, nrm.x);
	float along = dot(vec2(px), tg);
	float T = P.P0.y;
	float wob = (1.5 * sin(along * 0.045 + T * 1.7) + 0.8 * sin(along * 0.11 - T * 2.3)) * t2;
	vec2 o0 = nrm * (-0.55 * dpx * t2) + tg * wob;           // px: the film pulls the picture toward its line
	float r = 1.0 + 5.0 * t2;                                // the blur across the line, px
	vec3 acc = vec3(0.0);
	float wsum = 0.0;
	for (int k = -3; k <= 3; k++) {
		float wk = exp(-0.5 * float(k * k) / 4.0);
		vec2 q = clamp(uv + (o0 + nrm * (float(k) * r)) * inv, vec2(0.0), vec2(1.0));
		acc += wk * textureLod(color_src, q, 0.0).rgb;
		wsum += wk;
	}
	vec4 base = texelFetch(color_src, px, 0);
	vec3 bl = acc / wsum;
	vec3 col = mix(base.rgb, bl, t2);
	float foot = exp(-0.5 * dpx * dpx / 2.25);               // the film's dark foot, right on the line
	float rim = exp(-0.5 * (dpx - 4.0) * (dpx - 4.0) / 4.0); // a pale rim just above it
	float lum = dot(bl, vec3(0.2126, 0.7152, 0.0722));
	col = col * (1.0 - 0.45 * foot) + rim * 0.25 * lum * vec3(0.85, 0.95, 1.0);
	imageStore(color_out, px, vec4(mix(base.rgb, col, P.P0.w), base.a));
}
