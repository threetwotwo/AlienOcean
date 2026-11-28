// Sky stars 0.1.0 (engine thread): the Unreal night sky, M_Stars (sun_v184 STARS_HLSL, lines 6744-7877), ported line
// for line: the star field (two random stars per cube cell + the catalogue of bright stars with its named figures),
// the glints, the moons' sky glow (Krisciunas & Schaefer 1991), the planet, the Milky Way with its dust, star clouds
// and nebulae, the faint-star haze and speckle, airglow, zodiacal light, clusters, and the night haze on the horizon.
// Included by sky.gdshader, which adds the result (nits) over the dome; the parameters keep Unreal's names and values.
// All of it runs in the clock's z-up axes (Unreal's), so every constant is Unreal's: Unreal (x, y, z) = Godot (x, z, y),
// the inverse of WorldRoot.to_godot (a swap: Unreal is left-handed, so the figures are not mirrored).
// Not carried over (no such system here, or dead code in Unreal at its shipped values):
//   clouds in front (CloudOn 0: no clouds), SceneDepth occlusion (the sky is behind everything in Godot: vis 1, isSky 1,
//   so the haze over far geometry, hzG, is not drawn), the under-water refraction through the tank's waves (v27-v30;
//   since v32 nothing is drawn under water), the old aureole (v25; MoonSky > 0 replaced it in v81), the airglow ripples
//   (AirRipple 0 since v80).
// The catalogue comes from look/star_catalogue.gd as a float texture (StarCatalogue.texture()).
// water_y: from water_physics.gdshaderinc (look/sky.gdshader includes it first)
uniform sampler2D star_cat : filter_nearest, repeat_disable;
// ---- from the clock (WorldRoot._push_sky), as Unreal's MPC_Sky and the Stars actor
uniform float stars_on = 0.0;            // the star cube is shown below 50 lux on the ground, or in an eclipse's glow
uniform vec4 star_spin = vec4(0.0, 0.0, 1.0, 0.0);   // StarSpin: the planet's axis (north, z-up), the sky's turn (rad)
uniform float moon_a_r = 0.0;            // MoonAView.w / MoonBView.w: drawn radius (rad), 0 = not in view
uniform float moon_b_r = 0.0;
uniform float star_expo = 1.0;           // Expo (EyeAdaptation): exposed units per nit
uniform float site_lux = 100000.0;       // SiteLux: the light on level ground
uniform float eclipse_glow = 0.0;        // EclipseGlow, nits at the horizon
uniform float key_kelvin = 5772.0;       // the key light's temperature (LightColour = its colour against the sun's)
uniform float night_sky = 2.75;          // MPC_Sky NightSky: the stops AgX takes off the night sky
uniform float deep_comp = 1.5;           // DeepComp: AgX's NightDeep, solved for the backdrop
uniform float planet_km = 200.0;         // PlanetKm: the sea's radius (curved levels: 200), 0 = flat
// ---- M_Stars parameters (STAR_GLINT and the graph's defaults, sun_v184)
uniform float star_cells = 96.0;
uniform float mag_limit = 8.0;
uniform float star_light = 1.0;          // MPC_Sky StarLight
uniform float star_cap = 1.2;
uniform float star_dim = -1.0;
uniform float star_arm = 4.0;
uniform float arm_from = 0.02;
uniform float star_fringe = 0.4;
uniform float star_halo = 0.08;
uniform float glint_peak = 0.7;
uniform float glint_pulse = 1.0;
uniform float star_veil = 3.0;
uniform float milky_way = 1.5;
uniform float star_core = 0.65;
uniform float horizon_fog = 0.005;
uniform float fog_deg = 3.0;
uniform float star_gamma = 1.0;
uniform float star_p0 = 0.03;
uniform float star_grow = 0.0;
uniform float star_colour = 0.35;
uniform float star_top = 4.0;
uniform float star_limit = 8.5;
uniform float moon_wash = 0.0;
uniform float glint_curve = 2.2;
uniform float star_gain = 1.0;
uniform float twilight_soft = 1.0;
uniform float backdrop = 0.006;
uniform float airglow = 0.7;
uniform float zodiacal = 0.7;
uniform float planet_mag = -4.4;
uniform float planet_elong = 40.0;
uniform float planet_day = 0.3;
uniform float photo = 0.5;
uniform float haze = 1.0;
uniform float speckle = 1.0;
uniform float moon_sky = 0.28;
uniform float sky_gamma = 0.2;
uniform float catalogue = 1.0;
uniform float cat_mag = 5.0;
uniform float cat_margin = 0.6;
uniform vec3 moon_glow_tint = vec3(0.82, 0.90, 1.12);

const vec3 S_LUMA = vec3(0.2126, 0.7152, 0.0722);
// a star's blackbody colour against daylight white at B-V -0.4, 0, 0.4 ... 2.0 (21700 K to 3170 K), luminance 1
const vec3 S_BVC[7] = {vec3(0.709, 1.004, 1.812), vec3(0.833, 1.010, 1.390), vec3(0.972, 1.003, 1.054),
	vec3(1.125, 0.984, 0.793), vec3(1.289, 0.956, 0.589), vec3(1.458, 0.921, 0.430), vec3(1.630, 0.883, 0.308)};
// v84: clusters, globulars, a galaxy (direction, size deg; kind, magnitude)
const vec4 S_CATX[6] = {vec4(0.91257, -0.16038, -0.37615, 1.000), vec4(0.88456, -0.32241, -0.33704, 3.000),
	vec4(0.04010, 0.99492, -0.09233, 0.800), vec4(0.82357, 0.56692, 0.01821, 0.300), vec4(0.77812, 0.30126, -0.55116, 0.300),
	vec4(-0.82425, 0.18001, -0.53685, 1.600)};
const vec2 S_CATK[6] = {vec2(0.0, 0.00), vec2(0.0, 0.00), vec2(1.0, 3.70), vec2(2.0, 3.90), vec2(2.0, 4.60), vec2(3.0, 3.40)};
const float S_NSC[3] = {90.0, 18.0, 6.0};
const float S_NOF[3] = {3.1, 7.7, 5.3};
const float S_NSD[3] = {17.0, 41.0, 23.0};
const int S_NOC[3] = {3, 4, 4};

float s_sat(float x) { return clamp(x, 0.0, 1.0); }
float s_log10(float x) { return log(x) * 0.4342944819032518; }
vec3 s_zup(vec3 g) { return vec3(g.x, g.z, g.y); }
float s_h3(vec3 q) { return fract(sin(dot(q, vec3(12.9898, 78.233, 37.719))) * 43758.5453); }
// value noise, oct octaves (x 2.03, half the weight each), the lattice shifted by seed; -1..1
float s_vn(vec3 fp, float seed, int oct) {
	float fa = 0.5, tot = 0.0, acn = 0.0;
	for (int o = 0; o < oct; o++) {
		vec3 q = floor(fp) + seed;
		vec3 f = fract(fp);
		f = f * f * (3.0 - 2.0 * f);
		acn += fa * mix(mix(mix(s_h3(q), s_h3(q + vec3(1, 0, 0)), f.x), mix(s_h3(q + vec3(0, 1, 0)), s_h3(q + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(s_h3(q + vec3(0, 0, 1)), s_h3(q + vec3(1, 0, 1)), f.x), mix(s_h3(q + vec3(0, 1, 1)), s_h3(q + vec3(1, 1, 1)), f.x), f.y), f.z);
		tot += fa;
		fp *= 2.03;
		fa *= 0.5;
	}
	return acn / max(tot, 1e-6) * 2.0 - 1.0;
}
// sun_v184 planck_rgb: linear sRGB of a blackbody (Kim et al. 2002), luminance 1
vec3 s_planck(float kelvin) {
	float t = clamp(kelvin, 1667.0, 25000.0);
	float x = (t <= 4000.0) ? -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
		: -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390;
	float y = (t <= 2222.0) ? -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
		: ((t <= 4000.0) ? -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
		: 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483);
	float X = x / y, Z = (1.0 - x - y) / y;
	return max(vec3(3.2404542 * X - 1.5371385 - 0.4985314 * Z, -0.9692660 * X + 1.8760108 + 0.0415560 * Z,
		0.0556434 * X - 0.2040259 + 1.0572252 * Z), vec3(0.0));
}
vec4 s_cat(int i) { return texelFetch(star_cat, ivec2(i % 64, i / 64), 0); }

// eye: view direction (Godot axes); cam: camera position (Godot axes, metres); sun_g, ma_g, mb_g: the sun and the moons
// (Godot axes). Returns nits, to add over the sky.
vec3 stars(vec3 eye, vec3 cam, float time, vec3 sun_g, vec3 ma_g, vec3 mb_g) {
	// v32: no stars from under the water (Gary 13:06Z): camera 0.5 m below sea level
	if (stars_on < 0.5 || cam.y < water_y - 0.5) return vec3(0.0);
	float Expo = max(star_expo, 1e-12);
	vec3 vv = s_zup(eye);
	vec3 SunTrue = s_zup(sun_g);
	vec4 MA = vec4(s_zup(ma_g), moon_a_r);
	vec4 MB = vec4(s_zup(mb_g), moon_b_r);
	// v64: the curved sea (R = PlanetKm, 0 = flat) has its horizon sqrt(2h/R) below the eye
	float hc = max(cam.y - water_y, 0.0);                                  // metres over the sea
	float dipS = (planet_km > 0.0) ? min(sqrt(2.0 * hc / (planet_km * 1000.0)), 0.05) : 0.0;
	float vz = vv.z + dipS;                                                // sine of the elevation over that edge
	float s2 = max(star_core * star_core, 0.09);                           // v40 StarCore
	// the star cube's local direction: the actor is turned about north by StarSpin.w (FQuat(axis, angle)), so the
	// local direction is the view direction turned back
	vec3 nA = normalize(star_spin.xyz);
	float cA = cos(star_spin.w), sA = sin(star_spin.w);
	vec3 d = normalize(vv * cA - cross(nA, vv) * sA + nA * dot(nA, vv) * (1.0 - cA));
	vec3 ad = abs(d);
	vec3 uvw = (ad.x > ad.y && ad.x > ad.z) ? vec3(d.y, d.z, d.x) : ((ad.y > ad.z) ? vec3(d.x, d.z, d.y) : d);
	float face = (ad.x > ad.y && ad.x > ad.z) ? (d.x > 0.0 ? 0.0 : 1.0) : ((ad.y > ad.z) ? (d.y > 0.0 ? 2.0 : 3.0) : (d.z > 0.0 ? 4.0 : 5.0));
	vec2 uv = uvw.xy / abs(uvw.z) * 0.5 + 0.5;
	vec2 cell = floor(uv * star_cells);
	// v27: the screen's pixel axes on the sky (continuous across cube faces), to measure a star in pixels
	vec3 dX = dFdx(d);
	vec3 dY = dFdy(d);
	float gxx = dot(dX, dX);
	float gxy = dot(dX, dY);
	float gyy = dot(dY, dY);
	float gdet = max(gxx * gyy - gxy * gxy, 1e-24);
	float Opx = sqrt(gdet);                                                // one pixel's solid angle, sr
	float cellPx = 2.0 * uvw.z * uvw.z / max(abs(uvw.z), 1e-3) / star_cells / max(sqrt(Opx), 1e-9);   // a cell, in pixels
	float el = s_sat(vz);                                                  // sine of the elevation (v64, v79)
	float am = 1.0 / (el + 0.50572 * pow(degrees(asin(el)) + 6.07995, -1.6364));
	float T0 = exp(-0.16 * am) * step(0.0, vz);
	float sb = dot(d, normalize(vec3(0.46, -0.30, 0.83)));                 // sine of the Milky Way latitude
	float band = exp(-sb * sb / 0.045);                                    // the band, about +-12 deg
	float nz = sin(dot(d, vec3(7.1, 3.3, 5.7))) * sin(dot(d, vec3(-4.3, 6.9, 2.1))) * sin(dot(d, vec3(2.7, -5.1, 8.3)));
	float nz2 = sin(dot(d, vec3(23.1, -11.7, 17.9))) * sin(dot(d, vec3(-15.3, 21.9, 9.1))) * sin(dot(d, vec3(12.7, 17.1, -24.3)));
	float keep = s_sat(0.5 * (1.0 + 0.9 * nz) * (0.6 + 0.4 * (1.0 + 0.9 * nz2)) * (1.0 + 1.5 * band));   // v24, v38
	float wn0 = s_sat((1.477 - s_log10(max(0.18 / Expo, 1e-9))) / 3.0);   // 0 by day, 1 at night
	// v81: each moon's sky, Krisciunas & Schaefer 1991: Rayleigh + Mie scattering of its light, by its phase (I*), its
	// air on the way in (Xm) and the air along the view (Xv), in S10; Moon B x 1.14; faded as it sets. On screen (Fm)
	// compressed by SkyGamma.
	vec3 msk = vec3(0.0);
	vec3 Fm = vec3(0.0);
	if (moon_sky > 0.0) {
		vec3 sTm = normalize(SunTrue + vec3(0.0, 0.0, 1e-6));
		float Xv = inversesqrt(max(1.0 - 0.96 * (1.0 - el * el), 1e-4));
		float ev = (1.0 - pow(10.0, -0.0688 * Xv)) * step(0.0, vz);
		for (int mi = 0; mi < 2; mi++) {
			vec4 M = (mi == 0) ? MA : MB;
			vec3 md = normalize(M.xyz + vec3(0.0, 0.0, 1e-6));
			float rho = max(degrees(acos(clamp(dot(vv, md), -1.0, 1.0))), 0.5);
			float pa = 180.0 - degrees(acos(clamp(dot(sTm, md), -1.0, 1.0)));
			float Is = pow(10.0, -0.4 * (3.84 + 0.026 * pa + 4e-9 * pa * pa * pa * pa));
			float emz = md.z + dipS;
			float sm2 = s_sat(emz);
			float Xm = inversesqrt(max(1.0 - 0.96 * (1.0 - sm2 * sm2), 1e-4));
			float cm = Is * pow(10.0, -0.0688 * Xm) * ev * smoothstep(-0.035, 0.017, emz) * ((mi == 0) ? 4.0 : 4.56) * step(1e-6, dot(M.xyz, M.xyz));
			float cr = cos(radians(rho));
			msk += cm * (229086.8 * (1.06 + cr * cr) * vec3(0.785, 1.038, 1.582)
				+ max(pow(10.0, 6.15 - rho / 40.0), 6.2e7 / (rho * rho)) * vec3(0.935, 1.011, 1.174));
		}
		float um = max(dot(msk, S_LUMA) / 220.0, 1e-9);
		Fm = backdrop * moon_sky * pow(um, sky_gamma) / um * msk / 220.0;
	}
	// v38 / v81: a star shows only when it outshines the moonlit sky behind it, on screen
	float vl = star_veil * dot(Fm, S_LUMA) * wn0 * exp2(star_dim * wn0);
	vec3 acc = vec3(0.0);
	// v84: the catalogue of the bright stars after the cell's two random stars; the random ones brighter than CatMag
	// give way to it. Its stars run through the same code below.
	int cb0 = 0;
	int catN = 0;
	if (catalogue > 0.5) {
		int cbi = int(face) * 64 + int(min(floor(uv.y * 8.0), 7.0)) * 8 + int(min(floor(uv.x * 8.0), 7.0));
		cb0 = int(texelFetch(star_cat, ivec2(cbi % 64, 37 + cbi / 64), 0).r + 0.5);
		int cbj = cbi + 1;
		catN = int(texelFetch(star_cat, ivec2(cbj % 64, 37 + cbj / 64), 0).r + 0.5) - cb0;
	}
	float limC = clamp(radians(cat_margin) / max(sqrt(Opx), 1e-9) - 0.5, 0.5, 25.0);   // a catalogue star's arms, px
	for (int k = 0; k < 2 + catN; k++) {
		float h1, h2, h3, h4, h5, mag, bv, lim0;
		vec3 s3;
		if (k < 2) {
			vec2 o = cell + face * 131.0 + float(k) * 57.31;
			h1 = fract(sin(dot(o, vec2(12.9898, 78.233))) * 43758.5453);
			h2 = fract(sin(dot(o, vec2(39.3468, 11.135))) * 24634.6345);
			h3 = fract(sin(dot(o, vec2(73.156, 52.235))) * 13758.937);
			h4 = fract(sin(dot(o, vec2(94.673, 27.315))) * 31158.2389);
			h5 = fract(sin(dot(o, vec2(18.231, 63.977))) * 27183.1415);
			vec2 f = 0.03 + 0.94 * vec2(h1, h2);                           // v38: anywhere in the cell
			vec2 star = (cell + f) / star_cells;
			vec3 fv = normalize(vec3(star * 2.0 - 1.0, (uvw.z >= 0.0) ? 1.0 : -1.0));
			s3 = (face < 1.5) ? fv.zxy : ((face < 3.5) ? fv.xzy : fv);     // v27: the star's direction
			mag = mag_limit + 2.0 * s_log10(max(h3, 1e-6));               // N(<m) grows 10^0.5 per magnitude
			if (catalogue > 0.5 && mag < cat_mag)                          // v84: the catalogue holds the bright stars
				continue;
			// v53: the naked-eye colour mix (B-V): 35% hot blue-white, 25% white-yellow, 32% orange giants, 8% red
			bv = (h4 < 0.35) ? mix(-0.25, 0.3, h4 / 0.35) : ((h4 < 0.6) ? mix(0.3, 0.8, (h4 - 0.35) / 0.25)
				: ((h4 < 0.92) ? mix(0.8, 1.4, (h4 - 0.6) / 0.32) : mix(1.4, 1.9, (h4 - 0.92) / 0.08)));
			lim0 = max(min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)) * cellPx - 0.5, 0.5);
		} else {
			vec4 cs = s_cat(cb0 + k - 2);                                  // direction x (B-V + 2), magnitude
			float ln = length(cs.xyz);
			s3 = cs.xyz / ln;
			bv = ln - 2.0;
			mag = cs.w;
			float fi = float(cb0 + k);
			h1 = fract(fi * 0.7548777);
			h2 = fract(fi * 0.5698403);
			h3 = 0.5;
			h4 = fract(fi * 0.3819660);
			h5 = 0.0;                                                      // always kept
			lim0 = limC;
		}
		vec3 q = d - s3;
		vec2 pp = vec2(gyy * dot(q, dX) - gxy * dot(q, dY), gxx * dot(q, dY) - gxy * dot(q, dX)) / gdet;   // pixels
		float r2 = dot(pp, pp);
		if (r2 > 900.0 || dot(d, s3) < 0.0)                                // v84: over 30 px away
			continue;
		float Elux = 2.54e-6 * pow(10.0, -0.4 * mag) * exp2(star_gain);    // lux above the air; v87 StarGain
		float bi = clamp((bv + 0.4) / 0.4, 0.0, 5.999);
		int bk = int(bi);
		vec3 tint = mix(S_BVC[bk], S_BVC[bk + 1], bi - float(bk));
		tint /= dot(tint, S_LUMA);
		tint = max(1.0 + star_colour * (tint - 1.0), vec3(0.0));           // v53: StarColour 1 = the true colour
		float tw = 1.0 + 0.35 * s_sat((am - 1.5) / 6.0) * sin(time * (9.0 + 7.0 * h1) + 6.2831853 * h2);   // twinkle low
		float peak = star_light * T0 * tw * Elux / (6.2831853 * s2 * Opx);
		float pex = peak * Expo;                                           // v53: exposed, on the StarCore dot
		float s2s = s2;
		float fade = 1.0;
		float nkS = 1.0;                                                   // v55: kept for the glint's ceiling
		{
			// v53 / v55: on screen a star rises StarGamma as fast as its light above StarP0 and eases into StarTop,
			// below the moon's disc; nothing fainter than StarLimit
			float nk = exp2((night_sky - star_dim) * wn0);
			float x = pex * nk;
			float x0 = star_p0 * nk;
			float y = (x > x0) ? x0 * pow(x / x0, star_gamma) : x;
			y = y / (1.0 + y / max(star_top, 1e-6));                       // v55: a soft ceiling that keeps the order
			nkS = nk;
			peak = y / (nk * Expo);
			float gw = 1.0 + star_grow * s_sat(log2(max(pex / 0.3, 1e-9)) / 4.0);
			s2s = s2 * gw * gw;
			float ml = s_sat(s_log10(max(site_lux, 1e-6) / 0.003) / 1.9);
			fade = s_sat(star_limit - moon_wash * ml + 0.5 - mag);
			float cap = star_cap / Expo;
			if (peak > cap)
				peak = cap * pow(peak / cap, 0.3);
		}
		float rv = peak * Expo / max(vl, 1e-9);
		float seen = (vl > 0.0) ? smoothstep(0.5, 1.5, rv) * rv / (rv + 1.0) : 1.0;   // v38; v42 dimmed by the glow
		vec3 lit = peak * exp(-0.5 * r2 / s2s) * tint;
		// v27: the brighter stars glint like the sand's jewels: four arms, a small halo, a turning hue, a pulse
		float gl = s_sat(log2(max(pex / max(arm_from, 1e-6), 1.0)) / 4.0);   // v53: the star's own light
		if (gl > 0.0 && h5 < keep) {
			float lim = lim0;                                              // v84: the cell's room, or CatMargin
			float L = max(min(2.5 + (star_arm - 2.5) * gl, lim), 1e-3);
			vec2 a2 = abs(pp);
			float arm = max(exp(-a2.y * a2.y / 0.2) * pow(s_sat(1.0 - a2.x / L), 1.5),
				exp(-a2.x * a2.x / 0.2) * pow(s_sat(1.0 - a2.y / L), 1.5));
			float hr = min(1.0 + 0.2 * L, lim);
			float halo = exp(-2.0 * r2 / (hr * hr)) * step(r2, lim * lim);
			float ph = fract(time * 0.8 + h1 * 13.7 + h3 * 5.3);
			float pulse = mix(1.0, 0.35 + 0.65 * smoothstep(0.0, 0.25, ph) * (1.0 - smoothstep(0.6, 0.95, ph)), glint_pulse);   // v38
			float hue = h4 + 0.25 * atan(pp.y, pp.x + 1e-6) / 6.2831853 + 0.15 * sqrt(r2);
			vec3 tc = 0.5 + 0.5 * cos(6.2831853 * (hue + vec3(0.0, 0.33, 0.67)));
			vec3 fr = 1.0 + (tc / max(max(tc.r, tc.g), max(tc.b, 1e-3)) - 1.0) * star_fringe;
			// a glinting star flashes up to GlintPeak (exposed), pulsing on its own phase, under the core's soft ceiling
			float xg = glint_peak * pow(gl, max(glint_curve, 0.1)) * nkS;   // v60: the brightest keep the flash
			xg = xg / (1.0 + xg / max(star_top, 1e-6));
			float gp = max(peak, xg / (nkS * Expo)) * pulse;
			lit = max(peak, gp) * exp(-0.5 * r2 / s2s) * tint + gp * (0.9 * arm + star_halo * halo) * tint * fr;   // v40: sharp core
		}
		acc += step(h5, keep) * seen * fade * lit;                         // v53: fade, moonlight's limit
	}
	// v78: a Venus PlanetElong east of the sun on the ecliptic (an evening star), steady and round; at night a star at
	// its light under the stars' ceiling, by day PlanetDay exposed over the sky
	vec3 sT = normalize(SunTrue + vec3(0.0, 0.0, 1e-6));
	vec3 nP = normalize(star_spin.xyz + vec3(1e-6, 0.0, 0.0));
	vec3 eN = normalize(nP - sT * dot(nP, sT) + vec3(0.0, 0.0, 1e-6));     // the ecliptic's pole
	vec3 eT = normalize(cross(eN, sT));                                    // east along the ecliptic
	vec3 pd = sT * cos(radians(planet_elong)) + eT * sin(radians(planet_elong));
	if (pd.z + dipS > 0.0) {
		vec3 qp = vv - pd;
		vec3 wX = dFdx(vv);                                                // v79: the screen's axes in the world
		vec3 wY = dFdy(vv);
		float wxx = dot(wX, wX);
		float wxy = dot(wX, wY);
		float wyy = dot(wY, wY);
		float wdet = max(wxx * wyy - wxy * wxy, 1e-24);
		vec2 ppl = vec2(wyy * dot(qp, wX) - wxy * dot(qp, wY), wxx * dot(qp, wY) - wxy * dot(qp, wX)) / wdet;   // pixels
		float elp = pd.z + dipS;
		float amp = 1.0 / (elp + 0.50572 * pow(degrees(asin(s_sat(elp))) + 6.07995, -1.6364));
		float Tp = exp(-0.16 * amp);
		float s2p = max(star_core * star_core, 0.09) * mix(3.0, 2.0, wn0);   // a little wider by day
		float pexp = star_light * Tp * 2.54e-6 * pow(10.0, -0.4 * planet_mag) / (6.2831853 * s2p * Opx) * Expo;
		float nkp = exp2((night_sky - star_dim) * wn0);
		float yp = pexp * nkp;
		yp = yp / (1.0 + yp / max(star_top, 1e-6));
		float capP = star_cap;
		float pn = yp / nkp;
		pn = (pn > capP) ? capP * pow(pn / capP, 0.3) : pn;
		float pf = mix(planet_day * Tp, pn, wn0);                          // exposed, on screen
		acc += pf / Expo * exp(-0.5 * dot(ppl, ppl) / s2p) * vec3(1.02, 1.0, 0.94);
	}
	float mask = 1.0;
	if (MA.w > 0.0) {
		vec3 o = normalize(MA.xyz);
		float a = atan(length(cross(vv, o)), dot(vv, o));
		mask *= s_sat((a - MA.w) / max(fwidth(a), 1e-6) + 0.5);
	}
	if (MB.w > 0.0) {
		vec3 o = normalize(MB.xyz);
		float a = atan(length(cross(vv, o)), dot(vv, o));
		mask *= s_sat((a - MB.w) / max(fwidth(a), 1e-6) + 0.5);
	}
	// v10: the all-round horizon glow of totality
	vec3 glow = eclipse_glow * exp(-max(vv.z + dipS, 0.0) / 0.08) * step(0.0, vv.z + dipS) * vec3(1.35, 0.92, 0.55);
	vec3 gt = moon_glow_tint / dot(moon_glow_tint, S_LUMA);
	// v34: AgX darkens the night sky by NightSky stops; the stars are raised by the same, so they keep their light
	float nsk = exp2((night_sky - star_dim) * wn0);                        // v37: StarDim
	// v78: the night backdrop behind the stars, in S10 (a dark zenith is ~220 S10: airglow ~145, zodiacal ~60, faint
	// stars ~15), on screen Backdrop exposed per 220 S10, washed out by the moon and twilight. It is aimed at its final
	// value: x 2^NightSky (the sky's night darkening) and NightDeep's curve solved (DeepComp).
	vec3 pole = normalize(vec3(0.46, -0.30, 0.83));
	vec3 gc = normalize(vec3(1.0, 0.4, 0.0) - pole * dot(vec3(1.0, 0.4, 0.0), pole));
	vec3 gy = cross(pole, gc);
	float gb = asin(clamp(sb, -1.0, 1.0));                                 // galactic latitude
	float glon = atan(dot(d, gy), dot(d, gc));                             // galactic longitude, 0 at the core
	float m1 = sin(dot(d, vec3(11.3, -7.9, 5.1))) * sin(dot(d, vec3(-6.2, 9.7, 12.4)));
	float m2 = sin(dot(d, vec3(27.1, 19.3, -14.7))) * sin(dot(d, vec3(-21.4, 16.8, 25.9)));
	float m3 = s_vn(d * 7.0 + 11.3, 0.0, 4);                               // star clouds: 4 octaves of value noise
	float bulge = exp(-glon * glon / 0.30);
	float sgb = (0.11 + 0.12 * bulge) * (1.0 - 0.45 * photo);              // the band ~15 deg wide, the bulge ~30 deg
	float along = 0.6 + 1.3 * bulge + 0.35 * exp(-(glon - 0.45) * (glon - 0.45) / 0.02)   // Scutum
		+ 0.30 * exp(-(glon - 1.35) * (glon - 1.35) / 0.06) + 0.20 * exp(-(glon + 0.9) * (glon + 0.9) / 0.08);   // Cygnus, Carina
	float rb = gb - 0.025 - 0.015 * m2 - 0.012 * m3;                       // the Great Rift: core to Cygnus
	float rift = 0.6 * exp(-rb * rb / (2.0 * 0.032 * 0.032)) * smoothstep(-0.35, -0.05, glon) * (1.0 - smoothstep(1.4, 1.8, glon));
	float lanes = 0.25 * exp(-gb * gb / 0.0012) * s_sat(0.5 + 0.8 * m1);
	float clouds = max(0.75 + 0.08 * m1 + 0.06 * m2 + 0.55 * m3, 0.15);
	// v81 Photo: the star clouds' grain (~1 deg and finer), dust filaments, the off-band haze's patches: value noise
	float vn[3] = {0.0, 0.0, 0.0};
	if (photo > 0.0) {
		for (int ni = 0; ni < 3; ni++)
			vn[ni] = s_vn(d * S_NSC[ni] + S_NOF[ni], S_NSD[ni], S_NOC[ni]);
	}
	float dust = photo * (0.55 * smoothstep(0.72, 0.93, 1.0 - abs(vn[1])) + 0.35 * smoothstep(0.15, 0.45, vn[1]))
		* exp(-gb * gb / (2.0 * 0.08 * 0.08));
	clouds *= 1.0 + photo * (2.2 * max(vn[0], 0.0) * max(vn[0], 0.0) - 0.25);
	float mwv = exp(-gb * gb / (2.0 * sgb * sgb)) * along * max(clouds, 0.05) * (1.0 - rift) * (1.0 - lanes) * (1.0 - dust)
		+ 0.12 * exp(-gb * gb / 0.18);
	float tb = s_sat(bulge * 1.2);
	vec3 mwc = mix(mix(vec3(0.97, 0.99, 1.04), vec3(1.08, 1.0, 0.86), tb),
		mix(vec3(0.93, 0.97, 1.12), vec3(1.25, 1.0, 0.72), tb), photo);
	vec3 bS = (350.0 * milky_way * (1.0 + 9.0 * photo) * max(mwv, 0.0) + 15.0) * T0 * mwc;   // the Milky Way and the faint stars
	float hii = exp(-((glon - 0.12) * (glon - 0.12) + (gb + 0.03) * (gb + 0.03)) / (2.0 * 0.02 * 0.02))
		+ exp(-((glon - 0.3) * (glon - 0.3) + (gb - 0.02) * (gb - 0.02)) / (2.0 * 0.015 * 0.015))
		+ exp(-((glon + 0.6) * (glon + 0.6) + (gb + 0.01) * (gb + 0.01)) / (2.0 * 0.025 * 0.025))
		+ exp(-((glon - 1.2) * (glon - 1.2) + (gb - 0.04) * (gb - 0.04)) / (2.0 * 0.03 * 0.03));
	bS += photo * 900.0 * hii * T0 * vec3(1.5, 0.55, 0.85);                // v81: HII regions
	// v81 Haze: the unresolved faint stars off the band, patchy
	bS += haze * photo * 2.0 * (40.0 + 70.0 * exp(-abs(gb) / 0.45)) * (1.0 + 0.45 * vn[2]) * T0 * vec3(0.98, 1.0, 1.04);
	// airglow: the 97 km layer, brighter toward the horizon (van Rhijn), dimmed by the air and lit back by the low
	// air's scattering, so it peaks ~10 deg up and the horizon keeps ~2x the zenith (ripples: AirRipple 0 since v80)
	float vzA = max(vz, 0.0);
	float vrG = inversesqrt(max(1.0 - 0.97023 * (1.0 - vzA * vzA), 1e-4));
	float ag = vrG * (T0 + 0.45 * (1.0 - T0)) * step(0.0, vz);
	vec3 bAg = 145.0 * airglow * (1.0 + 0.3 * photo) * ag * mix(vec3(0.9, 1.0, 0.86), vec3(0.32, 0.55, 2.0), photo);
	bS += bAg;                                                             // v86: kept apart, it lies in front of the moons
	// zodiacal light along the ecliptic, the gegenschein at the antisun, ~60 S10 at the ecliptic's poles; dimmed by the air
	float ez = degrees(acos(clamp(dot(vv, sT), -1.0, 1.0)));
	float bz = degrees(asin(clamp(dot(vv, eN), -1.0, 1.0)));
	float zE = 140.0 + 4000.0 * exp(-max(ez - 20.0, 0.0) / 14.0) + 60.0 * exp(-(180.0 - ez) * (180.0 - ez) / 128.0);
	float wz = 8.0 + 0.3 * ez;
	float zl = 60.0 + (zE - 60.0) * exp(-bz * bz / (wz * wz));
	bS += zodiacal * (1.0 + 0.5 * photo) * zl * T0 * vec3(1.0, 0.97, 0.9);
	float wash = 1.0 / (1.0 + max(site_lux - 0.001, 0.0) / 0.02);
	// v81 Speckle: stars too faint to pick out one by one, one point in ~23 % of the cells of a 4x finer cube (more
	// toward the band), on screen; fades where a fine cell is under 2-4 px so it can't shimmer
	vec3 spk = vec3(0.0);
	if (photo > 0.0 && speckle > 0.0) {
		float C4 = star_cells * 4.0;
		vec2 c4 = floor(uv * C4);
		vec2 o4 = c4 + face * 523.0;
		float k1 = fract(sin(dot(o4, vec2(12.9898, 78.233))) * 43758.5453);
		float k2 = fract(sin(dot(o4, vec2(39.3468, 11.135))) * 24634.6345);
		float k3 = fract(sin(dot(o4, vec2(73.156, 52.235))) * 13758.937);
		float k4 = fract(sin(dot(o4, vec2(94.673, 27.315))) * 31158.2389);
		float pw = 0.452 * (0.35 + 0.55 * exp(-abs(gb) / 0.3));
		vec3 fv4 = normalize(vec3((c4 + 0.2 + 0.6 * vec2(k1, k2)) / C4 * 2.0 - 1.0, (uvw.z >= 0.0) ? 1.0 : -1.0));
		vec3 s4 = (face < 1.5) ? fv4.zxy : ((face < 3.5) ? fv4.xzy : fv4);
		vec3 q4 = d - s4;
		vec2 p4 = vec2(gyy * dot(q4, dX) - gxy * dot(q4, dY), gxx * dot(q4, dY) - gxy * dot(q4, dX)) / gdet;
		float pk4 = min(0.010 * pow(-log(max(k3, 1e-9)), 1.5), 0.05) * 2.0 * photo * speckle;
		spk = step(k4, pw) * pk4 * exp(-0.5 * dot(p4, p4) / 0.49) * smoothstep(2.0, 4.0, cellPx / 4.0) * T0 * wash
			* vec3(0.95, 1.0, 1.08);
	}
	vec3 cx = vec3(0.0);                                                   // v84: clusters, globulars, a galaxy
	if (catalogue > 0.5) {
		for (int ei = 0; ei < 6; ei++) {
			vec3 ed = S_CATX[ei].xyz;
			float er = S_CATX[ei].w;
			float ea = degrees(acos(clamp(dot(d, ed), -1.0, 1.0)));
			float ek = S_CATK[ei].x;
			if (ek < 0.5)                                                  // a young cluster's blue haze
				cx += 0.004 * exp(-(ea / (er * 0.8)) * (ea / (er * 0.8))) * vec3(0.8, 0.9, 1.3);
			else if (ek < 1.5)                                             // a cluster too faint to split
				cx += 0.012 * exp(-(ea / er) * (ea / er)) * vec3(1.0, 0.98, 0.92);
			else if (ek < 2.5)                                             // a globular: a fuzzy round star
				cx += 0.06 * pow(10.0, -0.4 * (S_CATK[ei].y - 3.9)) * exp(-ea / (er * 0.35)) * vec3(1.05, 1.0, 0.9);
			else if (dot(d, ed) > 0.0) {                                   // a galaxy: an oval smudge with a bright middle
				vec3 ta = normalize(cross(ed, (abs(dot(ed, pole)) < 0.95) ? pole : gc));
				vec3 tb2 = cross(ed, ta);
				float gx = degrees(asin(clamp(dot(d, ta), -1.0, 1.0)));
				float gy2 = degrees(asin(clamp(dot(d, tb2), -1.0, 1.0)));
				float xr = gx * 0.825 - gy2 * 0.565;
				float yr = gx * 0.565 + gy2 * 0.825;
				float rg = sqrt((xr / er) * (xr / er) + (yr / (er * 0.3)) * (yr / (er * 0.3)));
				cx += (0.02 * exp(-rg * 3.0) + 0.03 * exp(-(rg * 8.0) * (rg * 8.0))) * vec3(1.05, 1.0, 0.92);
			}
		}
		cx *= T0 * wash;
	}
	vec3 bF = (backdrop * bS / 220.0 * wash + Fm + spk + cx) * wn0;        // exposed, on screen
	float yF = dot(bF, S_LUMA);
	float qd = log2(max(yF * exp2(night_sky * wn0), 1e-12));               // before the sky's night darkening
	float Dd = deep_comp * wn0 * (1.0 - twilight_soft * smoothstep(-0.2756, -0.1045, sT.z));   // v87: as AgX's NightDeep in twilight
	float lo2 = qd;
	float hi2 = qd + Dd;
	for (int it = 0; it < 10; it++) {                                      // NightDeep's curve, solved
		float mid = 0.5 * (lo2 + hi2);
		float fm = mid - Dd * (1.0 - smoothstep(log2(0.06), log2(0.5), mid));
		if (fm < qd) lo2 = mid; else hi2 = mid;
	}
	vec3 mw = (yF > 1e-12) ? bF * (exp2(0.5 * (lo2 + hi2)) / yF) / Expo : vec3(0.0);
	// v86: the air's own light (airglow, the moonlit sky) is in front of the moons, so their mask leaves it; only what
	// lies beyond them (stars, Milky Way, zodiacal light, clusters) is hidden
	vec3 bAir = (backdrop * bAg / 220.0 * wash + Fm) * wn0;
	vec3 fAir = clamp(bAir / max(bF, vec3(1e-12)), vec3(0.0), vec3(1.0));
	// v40: a moonlit haze on the horizon: over the sky it falls off over FogDeg of elevation; the stars dim in it.
	// HorizonFog is its exposed brightness, at night only, lifted past the sky's night darkening.
	float hzS = exp(-degrees(asin(s_sat(abs(vz)))) / max(fog_deg, 0.1));   // v64: peaks on the sea's edge
	vec3 LightTint = s_planck(key_kelvin) / s_planck(5772.0);              // light_colour(): the key light against the sun
	LightTint /= max(dot(LightTint, S_LUMA), 1e-12);
	vec3 fc = mix(vec3(1.0), gt, 0.5) * LightTint;
	fc /= max(dot(fc, S_LUMA), 1e-6);
	vec3 fog = horizon_fog * hzS * wn0 / Expo * exp2(night_sky * wn0) * fc;
	acc *= 1.0 - 0.85 * hzS * s_sat(horizon_fog / 0.01);
	return (acc * LightTint * nsk + glow + mw * (1.0 - fAir)) * mask + mw * fAir + fog;
}
