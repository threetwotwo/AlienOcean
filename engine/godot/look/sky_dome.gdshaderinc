// Sky dome for water shaders 0.1.0 (water surface thread): the clear-air dome's radiance in nits along any direction,
// for the sky seen through Snell's window from below and the sky mirrored on the sea from above.
// dome(): look/sky.gdshader includes this file for its dome (one copy) (Godot's PhysicalSkyMaterial shape; WorldRoot.dome() mirrors it on the
// CPU); WorldRoot pushes the same shape sun and scale the sky uses (water_dome_sun, water_sky_norm), so the sky in
// the water is the sky overhead.
global uniform vec3 water_dome_sun;
global uniform float water_sky_norm;
global uniform float sky_turbidity;   // Preetham turbidity (WorldRoot.turbidity)
global uniform vec3 sky_rayleigh;     // the air's Rayleigh colour (WorldRoot.rayleigh)
vec3 sky_dome_shape(vec3 v, vec3 s) {
	float zenith_angle = clamp(s.y, -1.0, 1.0);
	float sun_energy = max(0.0, 1.0 - exp(-((PI * 0.5) - acos(zenith_angle))));
	float sun_fade = 1.0 - clamp(1.0 - exp(s.y), 0.0, 1.0);
	vec3 rayleigh_beta = (2.0 - (1.0 - sun_fade)) * sky_rayleigh * 0.0001;
	vec3 mie_beta = sky_turbidity * 0.005 * vec3(0.69, 0.729, 0.812) * 0.000434;
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
// nits along v (Godot y-up); below the horizon the dome's horizon value (the sea itself is drawn by the sea)
vec3 sky_dome_nits(vec3 v) {
	vec3 w = normalize(vec3(v.x, max(v.y, 0.0), v.z));
	return sky_dome_shape(w, normalize(water_dome_sun)) * water_sky_norm;
}
