// Blockout grey 0.1.0 (blockout kit): flat grey with a world-space metre grid, so size and slope read at a glance.
// Major lines every 1 m, faint minor lines every 10 cm (close up only). Floors a touch lighter than walls, so a ledge
// edge reads against the wall under it. Used by the kit's own meshes and by grey mode (blockout/grey_mode.gd).
shader_type spatial;
render_mode cull_back;
#include "res://look/screen_ao.gdshaderinc"

uniform vec3 base : source_color = vec3(0.55, 0.55, 0.55);
uniform vec3 line_col : source_color = vec3(0.30, 0.30, 0.30);
uniform float tint_amount = 0.0;                 // per-station tint (0 = pure grey)
uniform vec3 tint : source_color = vec3(0.6, 0.7, 0.8);

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float grid(vec2 p, float step_m, float width_m) {
	vec2 g = abs(fract(p / step_m + 0.5) - 0.5) * step_m;   // distance (m) to the nearest line
	vec2 aa = fwidth(p) * 0.75;
	vec2 l = 1.0 - smoothstep(vec2(width_m) - aa, vec2(width_m) + aa, g);
	return max(l.x, l.y);
}

float tri_grid(vec3 p, vec3 n, float step_m, float width_m) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= (w.x + w.y + w.z);
	return grid(p.yz, step_m, width_m) * w.x + grid(p.xz, step_m, width_m) * w.y + grid(p.xy, step_m, width_m) * w.z;
}

void fragment() {
	vec3 n = normalize(wnrm);
	float up = clamp(n.y, 0.0, 1.0);
	vec3 c = mix(base * 0.82, base * 1.08, up);
	c = mix(c, c * tint * 1.6, tint_amount);
	float major = tri_grid(wpos, n, 1.0, 0.012);
	float fade = clamp(1.0 - length(VERTEX) / 12.0, 0.0, 1.0);   // minor lines only within ~12 m of the camera
	float minor = tri_grid(wpos, n, 0.1, 0.004) * fade * 0.45;
	c = mix(c, line_col, max(major, minor));
	ALBEDO = c;
	ROUGHNESS = 0.9;
	AO = min(AO, screen_ao(SCREEN_UV));   // CORTAO (default AO): Godot's SSAO is off, so the screen AO comes in here
	SPECULAR = 0.2;
}
