#version 450
// AgX post 0.1.0 (engine thread): the Unreal M_PP_AgX tonemapper (sun_v184 AGX_HLSL) ported as is, run by
// adapters/godot/agx_effect.gd as a CompositorEffect after the transparent pass. Godot's own tonemapper is set to
// LINEAR, so this writes display-linear light and Godot only encodes it to sRGB.
// Unreal's Depth > SkyDepthKm (the sky) is Godot's reverse-Z depth == 0; CamV / SunT are rebuilt in y-up world space.
// Bloom 0.1.0 (28 Nov): the key frame's veiling glare (look/bloom.glsl) is added here, right after exposure and before
// the tone curve, energy kept (light above the threshold leaves its pixel, the PSF puts it back around it). Then the
// vignette (scene light, before the curve). Godot's glow stays off while this runs.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_out;
layout(set = 0, binding = 1) uniform sampler2D color_src;
layout(set = 0, binding = 2) uniform sampler2D depth_tex;
layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inv_proj;
	mat4 cam_basis;
	vec4 MA;          // moon A: direction (world, y-up), angular radius (rad); w 0 = none
	vec4 MB;
	vec4 DG;          // depth gain rgb (under-water white point)
	vec4 SunT;        // sun direction xyz (y-up), w 1 = the eye is under water
	vec4 p0;          // Exposure (exposed units per nit), Bias, BufScale (buffer units per nit), WhiteNow (K)
	vec4 p1;          // StopsBelow, StopsAbove, Punch, Saturation
	vec4 p2;          // WhiteTemp, SkyBlue, NightLook, HueKeep
	vec4 p3;          // StarKeep, NightDeep, PhotoSky, TwilightSoft
	vec4 p4;          // EmitKeep, EmitFrom, NightSky, Mode (0 AgX, 1 identity, 2 constant 0.5)
	vec4 p5;          // width, height
	vec4 p6;          // Bloom (0 off, 1 key frame), BloomThr (exposed units), Vignette (corner light lost), BloomMax (excess cap)
	vec4 p7;          // PSF weights 0-3
	vec4 p8;          // PSF weight 4, Keep (1 energy kept, 0 added glow)
} P;
layout(set = 0, binding = 4) uniform sampler2D glare0;
layout(set = 0, binding = 5) uniform sampler2D glare1;
layout(set = 0, binding = 6) uniform sampler2D glare2;
layout(set = 0, binding = 7) uniform sampler2D glare3;
layout(set = 0, binding = 8) uniform sampler2D glare4;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
float sat(float x) { return clamp(x, 0.0, 1.0); }
float lum_at(ivec2 q, ivec2 sz) {
	q = clamp(q, ivec2(0), sz - 1);
	return dot(texelFetch(color_src, q, 0).rgb, LUMA);
}
vec3 agx_curve(vec3 x) {
	vec3 x2 = x * x; vec3 x4 = x2 * x2;
	return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}
float agx_curve1(float x) {
	float x2 = x * x; float x4 = x2 * x2;
	return 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
}
// HLSL float3x3(a..i) is row-major and mul(M, v) = rows . v; GLSL mat3 is column-major, so build with transpose().
mat3 hm(float a, float b, float c, float d, float e, float f, float g, float h, float i) {
	return transpose(mat3(a, b, c, d, e, f, g, h, i));
}

void main() {
	ivec2 sz = ivec2(P.p5.xy);
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= sz.x || px.y >= sz.y) return;
	float mode = P.p4.w;
	vec3 buf = texelFetch(color_src, px, 0).rgb;
	if (mode > 1.5) { imageStore(color_out, px, vec4(0.5, 0.5, 0.5, 1.0)); return; }
	if (mode > 0.5) { imageStore(color_out, px, vec4(buf, 1.0)); return; }

	float Exposure = P.p0.x, Bias = P.p0.y, BufScale = P.p0.z, WhiteNow = P.p0.w;
	float StopsBelow = P.p1.x, StopsAbove = P.p1.y, Punch = P.p1.z, Saturation = P.p1.w;
	float WhiteTemp = P.p2.x, SkyBlue = P.p2.y, NightLook = P.p2.z, HueKeep = P.p2.w;
	float StarKeep = P.p3.x, NightDeep = P.p3.y, PhotoSky = P.p3.z, TwilightSoft = P.p3.w;
	float EmitKeep = P.p4.x, EmitFrom = P.p4.y, NightSky = P.p4.z;

	vec2 uv = (vec2(px) + 0.5) / vec2(sz);
	float depth = texelFetch(depth_tex, px, 0).r;
	// Unreal: saturate(Depth / SkyDepth - 1). Godot's water surface is transparent and writes no depth, so under water
	// nothing counts as sky (the sky is seen only through the surface shader's Snell's window there).
	float skym = (depth <= 0.0 && P.SunT.w < 0.5) ? 1.0 : 0.0;
	vec4 vp = P.inv_proj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 vd = normalize(mat3(P.cam_basis) * (vp.xyz / vp.w)); // view direction, world (Unreal -normalize(CamV))

	// the picture in scene units (nits): Godot's buffer is already multiplied by its exposure normalisation
	vec3 c = max(buf / max(BufScale, 1e-30), vec3(0.0));
	c *= max(P.DG.rgb, vec3(0.0));                        // v168 DepthGain, before the tone curve

	// v53 StarKeep: a point star keeps its colour
	float yl = dot(c, LUMA);
	float yb = dot(buf, LUMA);
	float dx = abs(lum_at(px + ivec2(1, 0), sz) - yb), dy = abs(lum_at(px + ivec2(0, 1), sz) - yb);
	float lc = max(dx, dy) / max(yb, 1e-12);              // relative slope (scale free, so buffer units are fine)
	float ye = yl * Exposure * exp2(Bias);
	float inm = 0.0;
	if (P.MA.w > 0.0) inm = max(inm, step(acos(clamp(dot(vd, normalize(P.MA.xyz)), -1.0, 1.0)), P.MA.w * 1.1));
	if (P.MB.w > 0.0) inm = max(inm, step(acos(clamp(dot(vd, normalize(P.MB.xyz)), -1.0, 1.0)), P.MB.w * 1.1));
	float pt = StarKeep * smoothstep(0.1, 0.6, ye) * smoothstep(0.15, 0.4, lc) * (1.0 - inm) * skym;
	// v88/v89 EmitKeep: strongly coloured lights keep their colour
	float cmx = max(max(c.r, c.g), c.b);
	float chs = (cmx - min(min(c.r, c.g), c.b)) / max(cmx, 1e-12);
	float yad = yl / max(0.18 / max(Exposure, 1e-12), 1e-12);
	float egt = EmitFrom > 0.0 ? smoothstep(0.4 * EmitFrom, EmitFrom, yad) : 1.0 - skym;
	float emk = EmitKeep * smoothstep(0.45, 0.7, chs) * egt * (1.0 - inm);
	float src = sat(max(pt, emk));

	// v2 night look (Purkinje shift)
	if (NightLook > 0.0) {
		float Yp = dot(c, LUMA);
		float Xp = dot(c, vec3(0.4124564, 0.3575761, 0.1804375));
		float Zp = dot(c, vec3(0.0193339, 0.1191920, 0.9503041));
		float V = max(Yp * (1.33 * (1.0 + (Yp + Zp) / max(Xp, 1e-9)) - 1.68), 0.0) / 2.575;
		float La = 0.18 / max(Exposure, 1e-12);
		float wa = sat((1.477 - log(max(La, 1e-9)) / log(10.0)) / 3.0);
		float wp = sat((1.0 - log(max(Yp, 1e-9)) / log(10.0)) / 3.0);
		float psk = PhotoSky * skym;
		c = mix(c, V * vec3(0.88, 1.0, 1.35), NightLook * wa * wp * (1.0 - src) * (1.0 - psk));
	}
	c *= Exposure * exp2(Bias);

	// camera veiling glare (bloom): same exposed units as the pyramid's prefilter (look/bloom.glsl)
	if (P.p6.x > 0.0) {
		vec3 ex = clamp(c - P.p6.y, vec3(0.0), vec3(P.p6.w));
		vec3 g = P.p7.x * texture(glare0, uv).rgb + P.p7.y * texture(glare1, uv).rgb + P.p7.z * texture(glare2, uv).rgb
		       + P.p7.w * texture(glare3, uv).rgb + P.p8.x * texture(glare4, uv).rgb;
		c = max(c + P.p6.x * (g - P.p8.y * ex), vec3(0.0));
	}
	// natural vignette: corners keep (1 - Vignette) of their light (art bible round 6 post.py)
	if (P.p6.z > 0.0) {
		vec2 q = uv * 2.0 - 1.0; float r2 = dot(q, q) * 0.5;
		float k = inversesqrt(max(1.0 - P.p6.z, 1e-3)) - 1.0;
		c /= (1.0 + k * r2) * (1.0 + k * r2);
	}

	// v69 NightDeep
	float wn = sat((1.477 - log(max(0.18 / max(Exposure, 1e-12), 1e-9)) / log(10.0)) / 3.0);   // 0 by day, 1 at night
	if (NightDeep > 0.0 && wn > 0.0) {
		float yd = dot(c, LUMA);
		float sd = smoothstep(log2(0.06), log2(0.5), log2(max(yd, 1e-10)));
		float ftw = TwilightSoft * smoothstep(-0.2756, -0.1045, normalize(P.SunT.xyz + vec3(0.0, 1e-6, 0.0)).y) * skym;
		c *= exp2(-NightDeep * wn * (1.0 - sd) * (1.0 - pt) * (1.0 - ftw));
	}

	// white balance: WhiteTemp kelvin (0 = follow the light, WhiteNow) becomes white (Bradford to D65)
	float wt = (WhiteTemp > 1.0) ? WhiteTemp : WhiteNow;
	if (abs(wt - 6500.0) > 1.0) {
		float T = clamp(wt, 4000.0, 25000.0) * (6504.0 / 6500.0);
		float T2 = T * T; float T3 = T2 * T;
		float wx = (T <= 7000.0) ? (-4.6070e9 / T3 + 2.9678e6 / T2 + 99.11 / T + 0.244063)
		                         : (-2.0064e9 / T3 + 1.9018e6 / T2 + 247.48 / T + 0.237040);
		float wy = -3.0 * wx * wx + 2.87 * wx - 0.275;
		mat3 RGB2XYZ = hm(0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750, 0.0193339, 0.1191920, 0.9503041);
		mat3 XYZ2RGB = hm(3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560, 0.0556434, -0.2040259, 1.0572252);
		mat3 BRAD = hm(0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296);
		mat3 BRADI = hm(0.9869929, -0.1470543, 0.1599627, 0.4323053, 0.5183603, 0.0492912, -0.0085287, 0.0400428, 0.9684867);
		vec3 s_ = BRAD * vec3(wx / wy, 1.0, (1.0 - wx - wy) / wy);
		vec3 d_ = BRAD * vec3(0.95047, 1.0, 1.08883);
		c = max(XYZ2RGB * (BRADI * ((BRAD * (RGB2XYZ * c)) * (d_ / s_))), vec3(0.0));
	}

	// v34 night sky: greyer and NightSky stops darker
	float kn = wn * skym;
	if (kn > 0.0) {
		float yS = dot(c, LUMA);
		vec3 cg = yS * vec3(0.93, 1.0, 1.12) / dot(vec3(0.93, 1.0, 1.12), LUMA);
		float kc = mix(mix(0.55, 1.0, PhotoSky), 1.0, src);
		c = mix(c, max(cg + kc * (c - yS), vec3(0.0)), kn) * exp2(-NightSky * kn);
	}

	// SkyBlue: the sky only, by day
	float skyY = dot(c, LUMA);
	float skyW = sat(((c.b - c.g) / max(c.b, 1e-6) - 0.12) / 0.28);
	skyW = skyW * skyW * (3.0 - 2.0 * skyW) * step(c.r, c.b);
	skyW *= sat(((c.g - c.r) / max(c.b - c.r, 1e-6) - 0.15) / 0.2);
	skyW *= skym * (1.0 - wn);
	c = max(skyY + (1.0 + SkyBlue * skyW) * (c - skyY), vec3(0.0));

	// AgX: inset, log2 encoding over StopsBelow..StopsAbove around middle grey, sigmoid
	mat3 INSET = hm(0.842479062253094, 0.0423282422610123, 0.0423756549057051,
	                0.0784335999999992, 0.878468636469772, 0.0784336,
	                0.0792237451477643, 0.0791661274605434, 0.879142973793104);
	c = c * INSET;                                        // GLSL v * M = row vector times M, as HLSL mul(c, M)
	vec3 ci = c;
	float lo = log2(0.18) - StopsBelow;
	float hi = log2(0.18) + StopsAbove;
	c = (clamp(log2(max(c, vec3(1e-10))), lo, hi) - lo) / (hi - lo);
	c = agx_curve(c);
	if (HueKeep > 0.0) {                                  // v44: night only
		float m = max(max(ci.r, ci.g), ci.b);
		float xm = (clamp(log2(max(m, 1e-10)), lo, hi) - lo) / (hi - lo);
		float tm = agx_curve1(xm);
		vec3 hk = tm * ci / max(m, 1e-10);
		float ch = sat((m - min(min(ci.r, ci.g), ci.b)) / max(m, 1e-10));
		float kb = sat((log2(max(m, 1e-10)) - log2(0.18)) / 5.0);
		c = mix(c, hk, HueKeep * max(smoothstep(0.25, 0.70, ch), src) * kb * sat(wn / 0.5));
	}
	// look (ASC CDL): Punch 0 = AgX base, 1 = Punchy
	float luma = dot(c, LUMA);
	c = pow(max(c, vec3(0.0)), vec3(mix(1.0, 1.35, Punch)));
	c = luma + mix(1.0, 1.4, Punch) * Saturation * (c - luma);
	mat3 OUTSET = hm(1.19687900512017, -0.0528968517574562, -0.0529716355144438,
	                 -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
	                 -0.0990297440797205, -0.0989611768448433, 1.15107367264116);
	c = pow(max(c * OUTSET, vec3(0.0)), vec3(2.2));      // display-linear; Godot encodes to sRGB
	imageStore(color_out, px, vec4(clamp(c, 0.0, 1.0), 1.0));
}
