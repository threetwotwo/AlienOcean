// Water surface seen from below 0.1.0: bright Snell's window overhead, darker total internal reflection toward the horizon,
// moving normals from two wave layers. Unshaded on purpose: the surface is a light source for the scene below.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;
uniform vec3 window_colour : source_color = vec3(0.75, 0.93, 1.0);
uniform vec3 deep_colour : source_color = vec3(0.05, 0.28, 0.36);
uniform float wave_scale = 0.35;
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 p = wpos.xz * wave_scale;
	float t = TIME * 0.6;
	vec3 n = normalize(vec3(sin(p.x * 1.7 + t) * 0.25 + sin(p.y * 2.3 - t * 1.3) * 0.18, 1.0, cos(p.y * 1.9 + t * 0.8) * 0.25 + cos(p.x * 2.9 + t) * 0.15));
	vec3 v = normalize(wpos - CAMERA_POSITION_WORLD);
	float cosv = dot(-n, -v) * -1.0;            // how directly we look up through the surface
	float up = clamp(v.y, 0.0, 1.0);
	float window = smoothstep(0.62, 0.78, up + n.x * 0.08);   // 48.6 deg critical angle: sin -> 0.75
	ALBEDO = mix(deep_colour, window_colour, window) * (0.85 + 0.15 * n.z);
	ALPHA = 1.0;
}
