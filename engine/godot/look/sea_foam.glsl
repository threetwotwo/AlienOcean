#version 450
// Sea foam step 0.2.0 (water surface thread, 28 Nov 2026): the Unreal open-water tank's whitecaps, one step
// (openocean_tank v374 FOAM_HLSL with FOAM_SIM_V320, FOAM_DETILE v340, the v326 deep fold, the v330 seed and v331 spread,
// the v345 storm streaks and longer storm fade, the v336 windrows and bilinear carry).
// 0.2.0: 0.1.0 left out the carry's velocity with the foam fluid and read the old foam at one texel, so it never blurred
// and drew confetti, and storm foam had no lines (the critique of 27 Nov). The tank's carry velocity is the fluid's plus
// two closed-form fields that need no fluid: the windrows (v336, Langmuir lines 18 m apart from 6 m/s of wind) and the
// storm streaks (v345, lines 4 m and 9 m apart from 20 m/s). Those are ported, with the old foam read bilinearly where
// they carried it from, as the tank did. Not ported: the fluid itself (v374 had its swirl and confinement at 0; what it
// still added was a fresh whitecap's downwind jet, 0.15 x the breaker's speed for 1.5 s), the floats', swimmers' and
// breach's churn and the ripples (no such bodies here yet).
// The map is kept where the water rests (each texel a parcel of still sea, island metres): X = Map.xy + (uv - 0.5) Map.z.
// Where cascades 0-2 fold the surface (Jacobian under K.x) the foam is fresh; old foam drifts with the wind drift
// (Prev.zw m/s, whole texels: the map's centre carries the sub-texel part) and fades (K.z s).
// Out: r = foam (0-1), g = this step's fresh foam, b = the break clock (s since the sea last broke here, capped at
// BRK_CAP; the spray reads it), a = 1.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D disp[4];    // mip 0 of each cascade
layout(rgba16f, set = 0, binding = 1) uniform restrict readonly image2D deriv[4];
layout(rgba16f, set = 0, binding = 2) uniform restrict readonly image2D prevMap;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D outMap;
layout(set = 0, binding = 4, std140) uniform Foam {
	vec4 Map;      // centre x, y (island m), size m, dt s
	vec4 Prev;     // last step's centre x, y, the wind drift x, y m/s
	vec4 K;        // Jacobian threshold (cascades 0-2), soft width, fade s, 1
	vec4 A;        // deep-fold step (W/3 -> W/10), breaker speed m/s, storm ramp (0 under 20 m/s, 1 at 30), windrow m/s
	vec4 Patch;    // the cascades' patch sizes m
} F;

const float N = 1024.0;
const float BRK_ON = 0.6, BRK_REFR = 3.0, BRK_CAP = 6.0;    // v330
const float SPREAD_ON = 0.2, SPREAD_V = 3.0;                // v330
const float SK_T = 2.0, SK_A = 0.8;                         // v345: storm fade x (1 + SK_T), crosswind pull m/s
const float ROW_L = 18.0, ROW_M = 4.0;                      // v336: the windrows' spacing and meander, m

vec4 tap(int c, bool d, vec2 X) {          // cascade c's disp (d false) or deriv at island X, bilinear, wrapped
	float L = F.Patch[c];
	vec2 u = fract(X / L) * 256.0 - 0.5;
	ivec2 i0 = ivec2(floor(u)); vec2 f = u - vec2(i0);
	ivec2 a = (i0 + 256) & 255, b = (i0 + 257) & 255;
	vec4 v00 = d ? imageLoad(deriv[c], a) : imageLoad(disp[c], a);
	vec4 v10 = d ? imageLoad(deriv[c], ivec2(b.x, a.y)) : imageLoad(disp[c], ivec2(b.x, a.y));
	vec4 v01 = d ? imageLoad(deriv[c], ivec2(a.x, b.y)) : imageLoad(disp[c], ivec2(a.x, b.y));
	vec4 v11 = d ? imageLoad(deriv[c], b) : imageLoad(disp[c], b);
	return mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
}

void main() {
	ivec2 at = ivec2(gl_GlobalInvocationID.xy);
	if (at.x >= int(N) || at.y >= int(N)) return;
	vec2 UV = (vec2(at) + 0.5) / N;
	vec2 X = F.Map.xy + (UV - 0.5) * F.Map.z;
	float dt = F.Map.w;
	// the Jacobian of cascades 0-2 (deriv: dDz/dx, dDz/dy, dDx/dx, dDy/dy; disp.w = dDx/dy)
	float jxx = 1.0, jyy = 1.0, jxy = 0.0;
	for (int c = 0; c < 3; c++) {
		float w = c == 2 ? 0.7071068 : 1.0;   // v340: the detiled cascade is two half-weight copies
		vec4 g = tap(c, true, X); vec4 a = tap(c, false, X);
		jxx += w * g.z; jyy += w * g.w; jxy += w * a.w;
	}
	{   // v340: cascade 2 read again, turned 37 deg and scaled 0.83 (its tile never lines up with the first)
		vec2 dx = vec2(0.798636 * X.x + 0.601815 * X.y, -0.601815 * X.x + 0.798636 * X.y) * 0.83 + vec2(7.3, 3.1);
		vec4 g = tap(2, true, dx); vec4 a = tap(2, false, dx);
		float dA = 0.83 * g.z, dB = 0.83 * g.w, dC = 0.83 * a.w;
		jxx += 0.707107 * (0.637819 * dA + 0.362181 * dB - 2.0 * 0.480631 * dC);
		jyy += 0.707107 * (0.362181 * dA + 0.637819 * dB + 2.0 * 0.480631 * dC);
		jxy += 0.707107 * (0.480631 * (dA - dB) + (0.637819 - 0.362181) * dC);
	}
	float J = jxx * jyy - jxy * jxy;
	float fresh = clamp((F.K.x - J) / F.K.y, 0.0, 1.0);
	// the old foam, carried by the wind drift: whole texels (the centre carries the rest)
	vec2 up = (X - F.Prev.zw * dt - F.Prev.xy) / F.Map.z + 0.5;
	// v336: the carry's velocity here: the windrows (the water converges on lines along the wind and runs faster on them)
	vec2 wd = length(F.Prev.zw) > 1e-5 ? normalize(F.Prev.zw) : vec2(1.0, 0.0);
	vec2 pd = vec2(-wd.y, wd.x);
	vec2 xw = vec2(dot(X, wd), dot(X, pd));
	vec2 ffv = vec2(0.0);
	if (F.A.w > 0.0) {
		float rq = xw.x / 60.0 + 7.7;
		float ri = floor(rq);
		float rf = rq - ri;
		rf = rf * rf * (3.0 - 2.0 * rf);
		float ra = fract(sin(ri * 127.1 + 311.7) * 43758.5453);
		float rb = fract(sin((ri + 1.0) * 127.1 + 311.7) * 43758.5453);
		float ph = 6.2831853 * (xw.y + ROW_M * (mix(ra, rb, rf) * 2.0 - 1.0)) / ROW_L;
		ffv = F.A.w * (wd * cos(ph) - pd * sin(ph));
	}
	// v345: storm streaks: from 20 m/s (full at 30) the foam is drawn into meandering lines 4 m and 9 m apart along the wind
	float skr = F.A.z;
	if (skr > 0.0) {
		for (int k = 0; k < 2; k++) {
			float l = k == 0 ? 4.0 : 9.0;
			float m = k == 0 ? 1.2 : 2.5;
			float w = k == 0 ? 0.6 : 0.4;
			float sd = k == 0 ? 3.1 : 5.7;
			float q = xw.x / (6.0 * l) + sd;
			float j = floor(q);
			float fq = q - j;
			fq = fq * fq * (3.0 - 2.0 * fq);
			float a = fract(sin(j * 127.1 + 17.0 * sd) * 43758.5453);
			float b = fract(sin((j + 1.0) * 127.1 + 17.0 * sd) * 43758.5453);
			float ph = 6.2831853 * (xw.y + m * (mix(a, b, fq) * 2.0 - 1.0)) / l;
			ffv -= pd * (skr * w * SK_A * sin(ph));
		}
	}
	// v336: the old foam is read where that velocity carried it from, bilinear (the frame's drift is whole texels)
	float pr = 0.0;
	vec2 upv = up - ffv * dt / F.Map.z;
	if (all(greaterThan(upv, vec2(0.0))) && all(lessThan(upv, vec2(1.0)))) {
		vec2 pu = upv * N - 0.5;
		ivec2 p0 = ivec2(floor(pu)); vec2 pf = pu - vec2(p0);
		ivec2 p1 = min(p0 + 1, ivec2(int(N) - 1)); p0 = max(p0, ivec2(0));
		pr = mix(mix(imageLoad(prevMap, p0).r, imageLoad(prevMap, ivec2(p1.x, p0.y)).r, pf.x),
			mix(imageLoad(prevMap, ivec2(p0.x, p1.y)).r, imageLoad(prevMap, p1).r, pf.x), pf.y);
	}
	float f = max(pr * exp(-dt / max(F.K.z * (1.0 + SK_T * F.A.z), 0.1)), fresh);
	// v9: the break clock stays put (exact one-texel copy); a break after BRK_REFR s quiet restarts it
	vec2 u0 = (X - F.Prev.xy) / F.Map.z + 0.5;
	float ab = BRK_CAP;
	ivec2 t0 = ivec2(floor(u0 * N));
	if (all(greaterThan(u0, vec2(0.0))) && all(lessThan(u0, vec2(1.0)))) ab = imageLoad(prevMap, t0).b;
	float deep = clamp((F.K.x - F.A.x - J) / F.K.y, 0.0, 1.0);   // v326: the fold is deep (stage A)
	float ign = (deep > BRK_ON && ab > BRK_REFR) ? 1.0 : 0.0;     // v330: the seed
	// v331: a whitecap lengthens along the crest at 0.56 of the breaker's speed and widens across it at 0.19
	float cth = 0.5 * atan(2.0 * jxy, jxx - jyy);
	vec2 cd = vec2(cos(cth), sin(cth));
	float va = F.A.y > 0.0 ? 0.56 * F.A.y : SPREAD_V;
	float vc = F.A.y > 0.0 ? 0.19 * F.A.y : SPREAD_V;
	float tx = F.Map.z / N;
	if (ign < 0.5 && deep > SPREAD_ON && ab > BRK_REFR) {
		for (int ni = 0; ni < 9; ni++) {
			if (ni == 4) continue;
			ivec2 no = ivec2(ni % 3 - 1, ni / 3 - 1);
			ivec2 nt = t0 + no;
			if (any(lessThan(nt, ivec2(0))) || any(greaterThanEqual(nt, ivec2(int(N))))) continue;
			float nb = imageLoad(prevMap, nt).b;
			float nl = length(vec2(no));
			float cph = dot(vec2(no) / nl, cd);
			float tk = nl * tx * sqrt(vc * vc * cph * cph + va * va * (1.0 - cph * cph)) / (va * vc);
			if (nb <= tk && nb + dt > tk) ign = 1.0;
		}
	}
	float s = ign > 0.5 ? 0.0 : min(ab + dt, BRK_CAP);
	imageStore(outMap, at, vec4(f, fresh, s, 1.0));
}
