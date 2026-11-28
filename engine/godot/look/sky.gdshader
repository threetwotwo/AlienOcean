// Sky 0.2.1 (engine thread; 0.2.1: the moons' night face, MoonCap; 0.2.0: the night sky, M_Stars, in look/sky_stars.gdshaderinc; 0.1.1: twilight dome = the shape with the sun held at 1 deg, scaled to the clock's twilight sky_lux): the Unreal sky's drawn bodies, ported, over a clear-air dome.
// Sun disc + corona: SUN_HLSL (sun_v184) as is: limb-darkened disc carrying the sun's whole light, drawn x5.29
// (2.8 deg), air extinction per band (0.0862, 0.1665, 0.2961) x air mass, masked by the moons.
// Moons A and B: MOON_HLSL as is: Lommel-Seeliger face, maria noise, planetshine, soft edge; lit by the true sun;
// at night the face held at MoonCap (exposed), its night tint (MoonBlue, MoonTint) and MoonSat (0.2.1).
// Dome: stand-in for Unreal's SkyAtmosphere (an engine feature, not our code): Rayleigh + sea-salt single scatter,
// scaled by the clock so the sky's light on the ground is the clock's sky_lux (sky_norm, from WorldRoot).
// Night sky: STARS_HLSL (M_Stars) in look/sky_stars.gdshaderinc, added over everything as in Unreal (an additive cube);
// above water only, and not in the radiance cubemap passes (a star is measured in screen pixels).
// Output in nits (background_intensity 1, physical light units).
shader_type sky;
render_mode use_debanding;

uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform float sun_toa = 128000.0;
uniform float sun_size = 5.288461538461538;
uniform float corona = 1.0;
uniform vec3 moon_a_dir = vec3(0.0, -1.0, 0.0);
uniform vec3 moon_b_dir = vec3(0.0, -1.0, 0.0);
uniform float moon_a_deg = 2.75;
uniform float moon_b_deg = 2.25;
uniform float moon_a_kelvin = 4100.0;   // MI_MoonA/B Tint = planck(moon) / planck(sun), luminance 1
uniform float moon_b_kelvin = 6500.0;
uniform vec3 moon_a_night = vec3(1.0);   // MoonTint after moon_tint_mix (v41/v83): the night colour, luminance kept
uniform vec3 moon_b_night = vec3(1.0);
uniform float moon_cap = 3.0;            // MoonCap (v25/v86): the highlands' brightness at night, exposed units
uniform float moon_blue = 0.2;           // MoonBlue (v37)
uniform float moon_sat = 0.5;            // MoonSat (v86): how much colour the night face keeps
uniform float night_cut = 0.0;           // NightCut (v83: 0)
uniform float moon_a_albedo = 0.12;
uniform float moon_b_albedo = 0.20;
uniform float maria = 0.3;
uniform float planetshine = 2e-4;
uniform float moon_edge = 1.5;
uniform vec3 dome_sun = vec3(0.0, 1.0, 0.0);   // the sun for the dome's shape: lifted to >= 1 deg (twilight stand-in)
uniform float sky_norm = 1.0;           // set by the driver: dome scale so its ground light = clock sky_lux
uniform float sea_nits = 0.0;           // below the horizon: the sea, seen from above (flat grey: before sea_deep_nits)
uniform vec3 sea_deep_nits = vec3(0.0); // the far sea's own light just above it (open ocean Rrs x Ed, nits; WorldRoot), 0 = flat sea_nits
uniform float sky_oc_beam = 1.0;        // the share of the clear sky's direct beam that cloud cover lets through (WorldRoot)
// Under water, the sky Godot's lighting reads (the radiance cubemap: SDFGI's escaping rays) is the water's own light field at
// water_zref, not the air above: two uniform hemispheres whose irradiance on a normal is exactly w_fill(z_ref, up)
// (look/water_physics.gdshaderinc): the sky's light through the water from above, the sand's bounce from below. Set by WorldRoot.
uniform float under_k = 0.0;            // 1 = the eye is under water
uniform vec3 under_down = vec3(0.0);    // nits, the upper hemisphere (Ek(z_ref) / pi)
uniform vec3 under_up = vec3(0.0);      // nits, the lower hemisphere (Eu(z_ref) / pi)

const vec3 EXT = vec3(0.0862, 0.1665, 0.2961);
#include "water_physics.gdshaderinc"   // water_y and the water's optics (the far sea below the horizon); before sky_stars
#include "sky_stars.gdshaderinc"

float airmass(float y) {
	float eld = degrees(asin(clamp(y, 0.0, 1.0)));
	return 1.0 / (clamp(y, 0.0, 1.0) + 0.50572 * pow(eld + 6.07995, -1.6364));
}
// Dome shape: Godot's own PhysicalSkyMaterial model (Preetham / three.js Sky, Godot's defaults), the closest Godot
// counterpart of Unreal's SkyAtmosphere; only its shape is used, the clock sets its brightness (sky_norm). One copy,
// shared with the water shaders (look/sky_dome.gdshaderinc); mirrored on the CPU in WorldRoot.dome().
#include "sky_dome.gdshaderinc"
#include "sky_overcast.gdshaderinc"
#include "sea_bathy.gdshaderinc"
global uniform vec3 water_sun_air;
global uniform float water_sun_lux;
global uniform float water_sky_nits;
vec3 dome(vec3 v, vec3 s) { return sky_dome_shape(v, s); }
float h31(vec3 q) { return fract(sin(dot(q, vec3(12.9898, 78.233, 37.719))) * 43758.5453); }
float vnoise(vec3 p) {
	float m = 0.0, amp = 0.5;
	for (int i = 0; i < 4; i++) {
		vec3 q = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
		float a = mix(mix(h31(q), h31(q + vec3(1, 0, 0)), f.x), mix(h31(q + vec3(0, 1, 0)), h31(q + vec3(1, 1, 0)), f.x), f.y);
		float b = mix(mix(h31(q + vec3(0, 0, 1)), h31(q + vec3(1, 0, 1)), f.x), mix(h31(q + vec3(0, 1, 1)), h31(q + vec3(1, 1, 1)), f.x), f.y);
		m += amp * mix(a, b, f.z); p *= 2.03; amp *= 0.5;
	}
	return m;
}
// one moon's face (MOON_HLSL), or -1 outside its disc
vec4 moon(vec3 v, vec3 c, float deg, float real_deg, float albedo, float kelvin, vec3 night_tint, vec3 s) {
	float R = radians(deg * 0.5);
	float a = acos(clamp(dot(v, c), -1.0, 1.0));
	if (a > R) return vec4(0.0);
	vec3 t1 = normalize(abs(c.y) < 0.9 ? cross(c, vec3(0, 1, 0)) : cross(c, vec3(1, 0, 0)));
	vec3 t2 = cross(c, t1);
	vec2 o = vec2(dot(v - c, t1), dot(v - c, t2)) / sin(R);
	float rr = clamp(length(o), 0.0, 1.0);
	vec3 n = normalize(-c * sqrt(1.0 - rr * rr) + t1 * o.x + t2 * o.y);   // the face toward us
	float mu0 = clamp(dot(n, s), 0.0, 1.0);
	float mu = clamp(dot(n, -v), 0.0, 1.0);
	float ls = 2.0 * mu0 / max(mu0 + mu, 1e-4);
	float m = vnoise(n * 3.0);
	float alb = albedo * mix(1.0 - maria, 1.0 + 0.5 * maria, smoothstep(0.35, 0.65, m));
	const vec3 LUM = vec3(0.2126, 0.7152, 0.0722);
	vec3 tint = s_planck(kelvin) / s_planck(5772.0);
	tint /= max(dot(tint, LUM), 1e-4);
	// v21: at night the drawn disc can carry the real moon's light (NightCut; 0 since v83 = the full drawn face)
	float dil = pow(real_deg / max(deg, real_deg), 2.0);
	float night = clamp((3.0 - log(max(site_lux, 1e-6)) / log(10.0)) / 3.0, 0.0, 1.0);
	float k = mix(1.0, pow(dil, night_cut), night);
	vec3 col = (alb / PI) * sun_toa * (ls + planetshine) * tint * k;
	// v25: at night the whole disc is scaled so its highlands sit at MoonCap (exposed), one factor so the maria keep
	// their contrast; v37 MoonBlue, v41 MoonTint (luminance kept), v86 MoonSat. By day nothing changes.
	float high = albedo / PI * sun_toa * k;
	float sc = (star_expo > 0.0) ? min(1.0, moon_cap / max(high * star_expo, 1e-9)) : 1.0;
	vec3 LightTint = s_planck(key_kelvin) / s_planck(5772.0);
	LightTint /= max(dot(LightTint, LUM), 1e-4);                      // light_colour(): luminance 1
	vec3 mt = night_tint / max(dot(night_tint, LUM), 1e-4);
	col *= mix(vec3(1.0), sc * mix(LightTint, vec3(1.0), moon_blue) * mt, night);
	float my0 = dot(col, LUM);
	col = mix(col, vec3(my0), (1.0 - clamp(moon_sat, 0.0, 1.0)) * night);
	float soft = clamp((1.0 - rr) / max(fwidth(rr) * moon_edge, 1e-5), 0.0, 1.0);
	return vec4(col * exp(-EXT * airmass(max(c.y, 0.0))), soft);
}
void sky() {
	vec3 v = EYEDIR;
	if (AT_CUBEMAP_PASS && under_k > 0.5) { COLOR = v.y >= 0.0 ? under_down : under_up; }
	else if (v.y < 0.0) {     // 28 Nov: was -0.02, so the dome's own below-horizon light showed as a dark line between the drawn sea (to 400 m) and the sky
		// the far sea, past the camera's far plane (seen from height it is a wide band under the horizon: it read flat grey
		// over the reef, water surface thread 28 Nov): the sky in its mirror by Fresnel (the waves turn facets toward the eye,
		// RMS slope ~0.09, so the mirror sees a little higher than the flat sea would) + the deep's own blue through it
		if (dot(sea_deep_nits, vec3(1.0)) > 0.0) {
			float mu = clamp(-v.y + 0.09, 0.0, 1.0);
			float F = 0.02 + 0.98 * pow(1.0 - mu, 5.0);
			vec3 r = normalize(vec3(v.x, mu, v.z));
			// 28 Nov: the water's own light as look/sea_top draws it where nothing is drawn under it (the floor beyond from
			// sea_bathy at that point, faded on the way up, + Rrs x Ed): was the open ocean's blue everywhere, so over a
			// lagoon that goes on (no reef) a dark line sat between the drawn sea and the sky (Gary 28 Nov playtest "still a
			// slight seaming happening in the horizon")
			vec3 far_c = sea_deep_nits;
			float ch = POSITION.y - water_y;
			if (ch > 0.0) {
				vec2 xz = POSITION.xz + v.xz * (ch / max(-v.y, 1e-4));
				float H = sea_bathy_depth(xz);
				vec3 Tg = refract(v, vec3(0.0, 1.0, 0.0), 1.0 / 1.333);
				float Lb = min(min(H, 60.0) / max(-Tg.y, 0.05), 400.0);
				vec3 c = water_a + water_b;
				float Ed = water_sun_lux * max(water_sun_air.y, 0.0) + PI * water_sky_nits;
				vec3 rrs0 = mix(water_rrs, max(water_rrs, water_rrs_deep), sea_bathy_ss(20.0, 120.0, H));
				vec3 rrs = mix(rrs0, rrs0.z * vec3(0.03, 0.55, 1.0), sea_open_teal) * sea_open_gain;
				far_c = sea_bathy_sand(H) * exp(-c * Lb) + w_glow(Tg, 0.0, Lb) + rrs * Ed / 0.98 * (vec3(1.0) - exp(-(water_kd + water_ku) * H));
			}
			COLOR = F * sky_overcast_air(dome(r, normalize(dome_sun)) * sky_norm, r) + (1.0 - F) * far_c;
			vec3 hz = normalize(vec3(v.x, 0.0015, v.z));          // the sea's last half degree melts into the horizon (look/sea_top)
			COLOR = mix(COLOR, sky_overcast_air(dome(hz, normalize(dome_sun)) * sky_norm, hz), sea_horizon_melt * (1.0 - smoothstep(0.0, 0.012, -v.y)));
		} else { COLOR = vec3(sea_nits); }
	}
	else {
		vec3 s = normalize(sun_dir);
		vec3 air = sky_overcast_air(dome(v, normalize(dome_sun)) * sky_norm, v);
		vec3 col = air;
		// sun disc + corona (SUN_HLSL)
		float th = acos(clamp(dot(v, s), -1.0, 1.0));
		float R = radians(0.2665 * sun_size);
		float px = max(fwidth(th), 1e-6);
		vec3 T = exp(-EXT * airmass(max(v.y, 0.0)));
		float x = th / R;
		float inside = clamp((R - th) / px + 0.5, 0.0, 1.0);
		float mu = sqrt(clamp(1.0 - x * x, 0.0, 1.0));
		float disc = (1.0 - 0.6 * (1.0 - mu)) / (0.8 * PI * R * R);
		vec3 t1 = normalize(abs(s.y) < 0.9 ? cross(s, vec3(0, 1, 0)) : cross(s, vec3(1, 0, 0)));
		vec3 t2 = cross(s, t1);
		float phi = atan(dot(v, t2), dot(v, t1));
		float r = max(x, 1.0);
		float streak = 0.6 + 0.4 * pow(abs(cos(phi - 0.3)), 4.0) + 0.12 * sin(7.0 * phi + 1.3) + 0.08 * sin(13.0 * phi + 0.4) + 0.05 * sin(29.0 * phi + 2.1);
		float cor = corona * 1e-6 / (6.2831853 * R * R) * pow(r, -3.0) * max(streak, 0.2) * clamp((7.0 - r) / 2.0, 0.0, 1.0);
		vec4 ma = moon(v, normalize(moon_a_dir), moon_a_deg, 0.52, moon_a_albedo, moon_a_kelvin, moon_a_night, s);
		vec4 mb = moon(v, normalize(moon_b_dir), moon_b_deg, 0.43, moon_b_albedo, moon_b_kelvin, moon_b_night, s);
		float mask = (1.0 - ma.a) * (1.0 - mb.a);
		// the sun disc behind the cloud: its beam share (WorldRoot sky_oc_beam, Kasten-Czeplak)
		if (s.y > -0.02) col += sky_oc_beam * (inside * disc + cor * vec3(1.0, 0.97, 0.92)) * sun_toa * T * mask;
		// B is nearer (18 km) than A (20 km): it covers A
		col = mix(col, air + ma.rgb * sky_oc_beam, ma.a * (1.0 - mb.a));   // the air in front of a moon still glows
		col = mix(col, air + mb.rgb * sky_oc_beam, mb.a);
		if (!AT_CUBEMAP_PASS) col += sky_oc_beam * stars(v, POSITION, TIME, s, normalize(moon_a_dir), normalize(moon_b_dir));
		COLOR = col;
	}
}
