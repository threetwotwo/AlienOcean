#version 450
// Sea foam step 0.1.0 (water surface thread, 28 Nov 2026): the Unreal open-water tank's whitecaps, one step
// (openocean_tank v374 FOAM_HLSL with FOAM_SIM_V320, FOAM_DETILE v340, the v326 deep fold, the v330 seed and v331 spread,
// the v345 longer storm fade). Not ported: the floats', swimmers' and breach's churn and the ripples (no such bodies
// here yet) and the v336 foam fluid (the foam rides the wind drift only, as v347's carry test drew it).
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
	vec4 A;        // deep-fold step (W/3 -> W/10), breaker speed m/s, storm ramp (0 under 20 m/s, 1 at 30), 0
	vec4 Patch;    // the cascades' patch sizes m
} F;

const float N = 1024.0;
const float BRK_ON = 0.6, BRK_REFR = 3.0, BRK_CAP = 6.0;    // v330
const float SPREAD_ON = 0.2, SPREAD_V = 3.0;                // v330
const float SK_T = 2.0;                                     // v345

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
	vec4 prev = vec4(0.0);
	if (all(greaterThan(up, vec2(0.0))) && all(lessThan(up, vec2(1.0)))) prev = imageLoad(prevMap, ivec2(floor(up * N)));
	float f = max(prev.r * exp(-dt / max(F.K.z * (1.0 + SK_T * F.A.z), 0.1)), fresh);
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
