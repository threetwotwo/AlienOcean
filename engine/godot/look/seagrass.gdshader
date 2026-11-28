// Seagrass 0.1.0 (test level thread): instanced turtle-grass blades (adapters/godot/grass_field.gd), lit by the lagoon water like
// the seabed (water fill + the sun's beam with the light net), plus what the rock shader could not give grass:
// - sway: Thalassa v20.19 style/shaders.js flora law (sin 1.35 t / cos 1.05 t travelling over the meadow, 0.7 cross share),
//   weighted by height squared so the root stays put, plus a slow lean down the current;
// - bend map: the girl and the fish push blades away (Thalassa only parted kelp around its two submarines, as an ellipsoid
//   with no memory); here each pusher is a sphere with a fading trail, so grass closes back in behind her over ~1 s;
// - blade length kept while bending (the tip drops as it leans), light through the blade from behind (BACKLIGHT),
//   root-to-tip colour with darker roots (the meadow's own shade), per-blade hue;
// - far blades: thinned by distance and the survivors widened to keep coverage, so no blade is thinner than ~1.5 px
//   (6 mm blades shimmer as noise past a few metres otherwise).
shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_lambert, specular_schlick_ggx, world_vertex_coords;

#include "res://look/water_physics.gdshaderinc"
#include "res://look/caustics.gdshaderinc"

#define PUSHERS 24
uniform vec4 pushers[PUSHERS];        // xyz world, w = radius x strength (0 = unused); written by GrassField each frame
uniform float sway_amp = 0.045;       // metres at the tip (Thalassa aMat.y scale for short grass)
uniform vec2 current_dir = vec2(0.8, 0.6);
uniform float current_lean = 0.07;    // metres of tip lean down the current
uniform float thin_start = 6.0;       // metres: beyond this, blades thin out
uniform float thin_end = 40.0;        // metres: at this distance one blade in 8 is kept
uniform float min_px = 1.5;           // survivors never narrower than this many pixels
uniform vec3 col_root : source_color = vec3(0.30, 0.40, 0.14);
uniform vec3 col_mid : source_color = vec3(0.45, 0.64, 0.22);
uniform vec3 col_tip : source_color = vec3(0.68, 0.74, 0.34);
uniform vec3 col_old : source_color = vec3(0.66, 0.60, 0.36);    // aged, epiphyte-dusted tips
uniform float caustic_strength : hint_range(0.0, 3.0) = 1.0;

varying vec3 wpos;
varying float h01;
varying float hue;
varying float age;

float hash11(float n) { return fract(sin(n * 12.9898) * 43758.5453); }

void vertex() {
	// INSTANCE_CUSTOM: x = phase, y = stiffness 0.6..1.4, z = hue 0..1, w = blade length (m)
	h01 = UV.y;                        // 0 root .. 1 tip (blade mesh)
	hue = INSTANCE_CUSTOM.z;
	age = hash11(INSTANCE_CUSTOM.x * 7.31);
	float L = INSTANCE_CUSTOM.w;
	vec3 root = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;      // world_vertex_coords: MODEL_MATRIX = this blade's transform
	float dist = length(root - CAMERA_POSITION_WORLD);
	// distance thinning: keep share k of blades, widen the rest by 1/sqrt(k) (coverage kept), and never below min_px
	float k = mix(1.0, 0.125, smoothstep(thin_start, thin_end, dist));
	float keep = step(hash11(INSTANCE_CUSTOM.x * 3.17 + 0.5), k);
	float px = dist * 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);    // metres per pixel at the blade
	float w0 = 0.008;                                                              // blade mesh width (m)
	float widen = max(1.0 / sqrt(k), min_px * px / w0);
	vec3 side = normalize(MODEL_MATRIX[0].xyz);
	vec3 wp = VERTEX + side * dot(VERTEX - root, side) * (widen - 1.0);        // VERTEX is already world here
	// tip offset (horizontal), then applied along the blade by height squared, length kept
	float f = h01 * h01;
	vec2 off = vec2(0.0);
	float stiff = INSTANCE_CUSTOM.y;
	off.x += sin(TIME * 1.35 + root.z * 0.14 * 6.0 + root.y * 0.18 + INSTANCE_CUSTOM.x) * sway_amp / stiff;
	off.y += cos(TIME * 1.05 + root.x * 0.13 * 6.0 + root.y * 0.15 + INSTANCE_CUSTOM.x) * sway_amp * 0.7 / stiff;
	off += normalize(current_dir) * current_lean * (0.7 + 0.6 * hash11(INSTANCE_CUSTOM.x));
	vec3 tip = root + vec3(0.0, L, 0.0);
	for (int i = 0; i < PUSHERS; i++) {
		vec4 p = pushers[i];
		if (p.w <= 0.0) continue;
		vec3 d = tip - p.xyz;
		float r = p.w + 0.5 * L;
		float dl = length(d.xz);
		float s = clamp(1.0 - length(d) / r, 0.0, 1.0);
		if (s > 0.0) off += (dl > 1e-3 ? d.xz / dl : vec2(1.0, 0.0)) * s * s * L * 1.6;
	}
	float ol = length(off);
	if (ol > 0.92 * L) off *= 0.92 * L / ol;                                       // at most a near-flat blade
	float drop = L - sqrt(max(L * L - dot(off, off), 0.0));                        // the tip drops as it leans (length kept)
	wp.xz += off * f;
	wp.y -= drop * f;
	if (keep < 0.5) wp = root;                                                     // thinned: a zero-area blade
	wpos = wp;
	VERTEX = wp;
	// soft normal: the blade face bent toward up, so a meadow lights as a volume, not as 6 mm mirrors
	NORMAL = normalize(mix(normalize(NORMAL), vec3(0.0, 1.0, 0.0), 0.55));
}

void fragment() {
	vec3 c = mix(col_root, col_mid, smoothstep(0.0, 0.45, h01));
	c = mix(c, mix(col_tip, col_old, step(0.72, age)), smoothstep(0.55, 1.0, h01));
	c *= 0.8 + 0.4 * hue;
	c = mix(c, c * vec3(0.95, 1.05, 0.85), hue);
	ALBEDO = c;
	ROUGHNESS = 0.55;
	SPECULAR = 0.25;
	BACKLIGHT = c * vec3(0.55, 0.75, 0.30) * (0.3 + 0.7 * h01);   // light through the blade
	AO = mix(0.6, 1.0, smoothstep(0.0, 0.7, h01));                 // the meadow's own shade at the roots
	AO_LIGHT_AFFECT = 0.6;
	float z = max(water_y - wpos.y, 0.0);
	if (water_fill_ao > 0.5) {
		ALBEDO *= w_fill_ratio(z, 0.8);
	} else {
		EMISSION = ALBEDO * AO * w_fill(z, 0.8);
		AO = 0.0;
	}
}

void light() {
	float z = max(water_y - wpos.y, 0.0);
	vec3 corr = exp(-water_kd * (z - water_zref));
	float px = length(wpos - INV_VIEW_MATRIX[3].xyz) * 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);
	float caus = caustic_sun(wpos, water_y - wpos.y, water_sun_w, px, TIME, caustic_strength);
	vec3 fr = vec3(1.0);
	if (water_fill_ao > 0.5) fr = w_fill_ratio(z, 0.8);
	// wrapped diffuse (thin blades take light on both faces) + the backlight path Godot adds from BACKLIGHT
	float nl = dot(NORMAL, LIGHT);
	float wrap = clamp((abs(nl) + 0.35) / 1.35, 0.0, 1.0);
	DIFFUSE_LIGHT += wrap * ATTENUATION * LIGHT_COLOR / PI * corr * caus / fr;
	// light through the blade when looking toward the sun
	float tr = pow(clamp(dot(VIEW, -LIGHT), 0.0, 1.0), 4.0);
	DIFFUSE_LIGHT += BACKLIGHT * tr * ATTENUATION * LIGHT_COLOR / PI * corr * caus / fr;
}
