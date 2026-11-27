// School fish 0.1.0: one MultiMesh draw per school and LOD; the swim lives here, driven per fish by INSTANCE_CUSTOM:
//   r = tail-beat phase (rad), g = tail amplitude (body lengths, from Strouhal), b = body bend (turning; signed, BL^-1
//   curvature x L, capped by the species' safe bend), a = startle (0..1).
// Swim law (STAND-IN until the creature maker exports its swim parameters as glTF extras): a carangiform travelling wave,
// lateral offset A(s) sin(2 pi s / lambda - phase) with the envelope through head sway 0.30, minimum 0.11 near s 0.3 and
// 1.0 at the tail (Videler 1993 shape; the Unreal swim engine's recoil 0.5 gives the head its sway), lambda ~1 BL.
// Mesh contract: one body length along +x (head) .. -x, y up, z = side; COLOR r = fin, g = eye, b = s (0 snout .. 1 tail).
// No fog here: the underwater view quad (WorldRoot.attach_camera) fogs every pixel along the view ray.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec3 back_colour : source_color = vec3(0.10, 0.22, 0.32);
uniform vec3 flank_colour : source_color = vec3(0.78, 0.82, 0.86);
uniform vec3 belly_colour : source_color = vec3(0.93, 0.94, 0.92);
uniform vec3 fin_colour : source_color = vec3(0.70, 0.74, 0.62);
uniform vec3 stripe_colour : source_color = vec3(0.95, 0.82, 0.30);
uniform float stripe = 0.0;          // a lateral stripe (species readability), 0 = none
uniform float flank_metal = 0.55;    // mirror-flat flank reflectors flash as the school turns (iridescence study)
uniform float wavelength = 1.0;      // body lengths
uniform float swim_on = 1.0;

varying vec3 obj_pos;
varying vec3 obj_n;
varying float zone_fin;
varying float zone_eye;

float env_a(float s) { return 0.30 - 1.193 * s + 1.893 * s * s; }

void vertex() {
	float s = clamp(0.5 - VERTEX.x, 0.0, 1.0);
	float ph = INSTANCE_CUSTOM.r;
	float amp = INSTANCE_CUSTOM.g * swim_on;
	float bend = INSTANCE_CUSTOM.b;
	float k = 6.2831853 / wavelength;
	float w = env_a(s) * amp * sin(k * s - ph);
	float dw = amp * (env_a(s) * k * cos(k * s - ph) + (-1.193 + 3.786 * s) * sin(k * s - ph));
	// turning: the body curves into the turn (a parabola about mid-body, zero offset at the centre of mass)
	float sb = s - 0.42;
	w += 0.5 * bend * sb * sb;
	dw += bend * sb;
	VERTEX.z += w;
	// rotate the normal by the local slope of the midline (dz/dx = -dz/ds)
	float ang = atan(dw);
	float c = cos(ang), sn = sin(ang);
	NORMAL = normalize(vec3(NORMAL.x * c - NORMAL.z * sn, NORMAL.y, NORMAL.x * sn + NORMAL.z * c));
	obj_pos = VERTEX;
	obj_n = NORMAL;
	zone_fin = COLOR.r;
	zone_eye = COLOR.g;
}

void fragment() {
	vec3 n = normalize(obj_n);
	if (!FRONT_FACING) n = -n;
	// countershading: dark back, silver flank, white belly (Finding Nemo readability: a clear value split)
	float up = n.y;
	vec3 body = mix(flank_colour, back_colour, smoothstep(0.15, 0.7, up));
	body = mix(body, belly_colour, smoothstep(-0.2, -0.75, up));
	float st = stripe * (1.0 - smoothstep(0.012, 0.02, abs(obj_pos.y - 0.02))) * step(-0.38, obj_pos.x) * step(obj_pos.x, 0.36);
	body = mix(body, stripe_colour, st);
	vec3 col = mix(body, fin_colour, zone_fin);
	col = mix(col, vec3(0.02, 0.025, 0.03), zone_eye);
	ALBEDO = col;
	float flank = (1.0 - zone_fin) * (1.0 - zone_eye) * (1.0 - smoothstep(0.3, 0.8, abs(up)));
	METALLIC = flank_metal * flank;
	ROUGHNESS = mix(0.55, 0.22, flank) - 0.15 * zone_eye;
	SPECULAR = 0.5;
}
