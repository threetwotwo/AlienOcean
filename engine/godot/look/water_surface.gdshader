// Water surface seen from below 0.2.0: the ported UNDER_PHYS (lagoonwater v67, under_model.py 'new' mirror).
// Inside Snell's window: the sky's light through the surface (n^2 brighter, Fresnel loss) plus the reflected part;
// outside it (total internal reflection): the water below, mirrored: glow along the reflected ray + the lit sand.
// Values in nits x exposure; the eye's own water path is added by underwater_view.gdshader.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, fog_disabled;
#include "res://look/water_physics.gdshaderinc"
global uniform float water_sky_nits;
uniform float wave_scale = 0.35;
uniform float wave_tilt = 0.06;
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 p = wpos.xz * wave_scale;
	float t = TIME * 0.6;
	vec3 n = normalize(vec3((sin(p.x * 1.7 + t) * 0.6 + sin(p.y * 2.3 - t * 1.3) * 0.4) * wave_tilt, 1.0,
		(cos(p.y * 1.9 + t * 0.8) * 0.6 + cos(p.x * 2.9 + t) * 0.4) * wave_tilt));
	vec3 v = normalize(wpos - CAMERA_POSITION_WORLD);   // up toward the surface
	vec3 nd = -n;                                      // the surface normal facing the water
	float ci = clamp(dot(-v, nd), 0.0, 1.0);           // cos of the incidence angle, water side
	float st2 = 1.777 * (1.0 - ci * ci);               // sin^2 of the transmitted angle (n = 1.333)
	vec3 r = reflect(v, nd);
	float H = max(water_y - water_floor_y, 0.05);
	float Lr = H / max(-r.y, 0.02);
	vec3 c = water_a + water_b;
	vec3 mir = w_glow(r, 0.0, Lr) + w_EH() * water_sand.rgb / PI * exp(-c * Lr);
	vec3 col;
	if (st2 >= 1.0) { col = mir; }
	else {
		float ct = sqrt(1.0 - st2);
		float rs = (1.333 * ci - ct) / (1.333 * ci + ct); float rp = (ci - 1.333 * ct) / (ci + 1.333 * ct);
		float R = 0.5 * (rs * rs + rp * rp);
		col = (1.0 - R) * water_sky_nits * 1.777 + R * mir;
	}
	ALBEDO = col * water_exposure;
}
