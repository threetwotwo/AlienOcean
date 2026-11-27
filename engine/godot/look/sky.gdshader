// Sky 0.1.1 (engine thread; 0.1.1: twilight dome = the shape with the sun held at 1 deg, scaled to the clock's twilight sky_lux): the Unreal sky's drawn bodies, ported, over a clear-air dome.
// Sun disc + corona: SUN_HLSL (sun_v184) as is: limb-darkened disc carrying the sun's whole light, drawn x5.29
// (2.8 deg), air extinction per band (0.0862, 0.1665, 0.2961) x air mass, masked by the moons.
// Moons A and B: MOON_HLSL as is: Lommel-Seeliger face, maria noise, planetshine, soft edge; lit by the true sun.
// Dome: stand-in for Unreal's SkyAtmosphere (an engine feature, not our code): Rayleigh + sea-salt single scatter,
// scaled by the clock so the sky's light on the ground is the clock's sky_lux (sky_norm, from WorldRoot).
// Stars (STARS_HLSL) come next. Output in nits (background_intensity 1, physical light units).
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
uniform vec3 moon_a_tint = vec3(1.0);
uniform vec3 moon_b_tint = vec3(1.0);
uniform float moon_a_albedo = 0.12;
uniform float moon_b_albedo = 0.20;
uniform float maria = 0.3;
uniform float planetshine = 2e-4;
uniform float moon_edge = 1.5;
uniform vec3 dome_sun = vec3(0.0, 1.0, 0.0);   // the sun for the dome's shape: lifted to >= 1 deg (twilight stand-in)
uniform float sky_norm = 1.0;           // set by the driver: dome scale so its ground light = clock sky_lux
uniform float sea_nits = 0.0;           // below the horizon: the sea, seen from above

const vec3 EXT = vec3(0.0862, 0.1665, 0.2961);

float airmass(float y) {
	float eld = degrees(asin(clamp(y, 0.0, 1.0)));
	return 1.0 / (clamp(y, 0.0, 1.0) + 0.50572 * pow(eld + 6.07995, -1.6364));
}
// Dome shape: Godot's own PhysicalSkyMaterial model (Preetham / three.js Sky, Godot's defaults), the closest Godot
// counterpart of Unreal's SkyAtmosphere; only its shape is used, the clock sets its brightness (sky_norm).
// Mirrored in WorldRoot.dome() (adapters/godot/world_root.gd).
vec3 dome(vec3 v, vec3 s) {
	float zenith_angle = clamp(s.y, -1.0, 1.0);
	float sun_energy = max(0.0, 1.0 - exp(-((PI * 0.5) - acos(zenith_angle))));
	float sun_fade = 1.0 - clamp(1.0 - exp(s.y), 0.0, 1.0);
	vec3 rayleigh_beta = (2.0 - (1.0 - sun_fade)) * vec3(0.3, 0.405, 0.6) * 0.0001;
	vec3 mie_beta = 10.0 * 0.005 * vec3(0.69, 0.729, 0.812) * 0.000434;
	float zenith = acos(max(0.0, v.y));
	float optical_mass = 1.0 / (cos(zenith) + 0.15 * pow(93.885 - degrees(zenith), -1.253));
	vec3 extinction = exp(-(rayleigh_beta * 8.4e3 * optical_mass + mie_beta * 1.25e3 * optical_mass));
	float cos_theta = dot(v, s);
	float rayleigh_phase = (3.0 / (16.0 * PI)) * (1.0 + pow(cos_theta * 0.5 + 0.5, 2.0));
	float g = 0.8;
	float mie_phase = (1.0 / (4.0 * PI)) * ((1.0 - g * g) / pow(1.0 - 2.0 * g * cos_theta + g * g, 1.5));
	vec3 ratio = (rayleigh_beta * rayleigh_phase + mie_beta * mie_phase) / (rayleigh_beta + mie_beta);
	vec3 Lin = pow(sun_energy * ratio * (1.0 - extinction), vec3(1.5));
	Lin *= mix(vec3(1.0), pow(sun_energy * ratio * extinction, vec3(0.5)), clamp(pow(1.0 - zenith_angle, 5.0), 0.0, 1.0));
	return Lin;
}
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
vec4 moon(vec3 v, vec3 c, float deg, float albedo, vec3 tint, vec3 s) {
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
	vec3 col = (alb / PI) * sun_toa * (ls + planetshine) * tint;
	float soft = clamp((1.0 - rr) / max(fwidth(rr) * moon_edge, 1e-5), 0.0, 1.0);
	return vec4(col * exp(-EXT * airmass(max(c.y, 0.0))), soft);
}
void sky() {
	vec3 v = EYEDIR;
	if (v.y < -0.02) { COLOR = vec3(sea_nits); }
	else {
		vec3 s = normalize(sun_dir);
		vec3 air = dome(v, normalize(dome_sun)) * sky_norm;
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
		vec4 ma = moon(v, normalize(moon_a_dir), moon_a_deg, moon_a_albedo, moon_a_tint, s);
		vec4 mb = moon(v, normalize(moon_b_dir), moon_b_deg, moon_b_albedo, moon_b_tint, s);
		float mask = (1.0 - ma.a) * (1.0 - mb.a);
		if (s.y > -0.02) col += (inside * disc + cor * vec3(1.0, 0.97, 0.92)) * sun_toa * T * mask;
		// B is nearer (18 km) than A (20 km): it covers A
		col = mix(col, air + ma.rgb, ma.a * (1.0 - mb.a));   // the air in front of a moon still glows
		col = mix(col, air + mb.rgb, mb.a);
		COLOR = col;
	}
}
