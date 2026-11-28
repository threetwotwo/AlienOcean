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
uniform vec4 pushers[PUSHERS];
uniform vec4 push_bound = vec4(0.0, -1e6, 0.0, 0.0);   // a sphere around every active pusher: blades outside it skip the loop        // xyz world, w = radius x strength (0 = unused); written by GrassField each frame
uniform float sway_amp = 0.045;       // metres at the tip (Thalassa aMat.y scale for short grass)
uniform vec2 current_dir = vec2(0.8, 0.6);
uniform float current_lean = 0.07;    // metres of tip lean down the current
uniform float thin_start = 4.0;       // metres: beyond this, blades thin out
uniform float thin_end = 20.0;        // metres: at this distance one blade in 8 is kept; GrassField swaps to its far set here
uniform float set_share = 1.0;        // share of all blades this MultiMesh holds (GrassField's far set: 0.125)
uniform float min_px = 2.5;           // survivors never narrower than this many pixels (thinner lines alias into noise at half res)
uniform vec3 col_root : source_color = vec3(0.13, 0.27, 0.10);   // key frame v7c meadow: deep green roots
uniform vec3 col_mid : source_color = vec3(0.22, 0.45, 0.16);    // a calm mid green, not lime
uniform vec3 col_tip : source_color = vec3(0.40, 0.58, 0.24);
uniform vec3 col_old : source_color = vec3(0.50, 0.52, 0.28);    // aged, epiphyte-dusted tips
uniform float caustic_strength : hint_range(0.0, 3.0) = 1.0;
// key frame look (tools/lagoon_dress/kf_paint.py grass + the rig's add_sway): every blade droops, pale margins, browning tips
uniform float droop = 0.42;           // share of blade length the tip hangs over at rest (stiffness 1); the key frame meadow droops
uniform float tile_col_mix = 0.35;     // how much the dressing's own vertex colour sets the base (0 = palette only)
uniform float saturation = 1.0;       // kf_paint used 1.2; the Mac read lime and noisy (Gary 28 Nov), so the palette carries it
uniform vec3 col_margin : source_color = vec3(0.851, 0.902, 0.627);   // #d9e6a0 leaf margins
uniform vec3 col_brown : source_color = vec3(0.435, 0.416, 0.227);    // #6f6a3a age browning toward the tip

varying vec3 wpos;
varying float h01;
varying float hue;
varying float age;
varying vec3 tile_col;
varying float edge_u;

float hash11(float n) { return fract(sin(n * 12.9898) * 43758.5453); }

void vertex() {
	// INSTANCE_CUSTOM: x = phase, y = stiffness 0.6..1.4, z = hue 0..1, w = blade length (m)
	h01 = UV.y;                        // 0 root .. 1 tip (blade mesh)
	edge_u = UV.x;                     // 0 / 1 on the two edges
	tile_col = COLOR.rgb;              // instance colour = the dressing tile's vertex colour (white = none)
	hue = INSTANCE_CUSTOM.z;
	age = hash11(INSTANCE_CUSTOM.x * 7.31);
	float L = INSTANCE_CUSTOM.w;
	vec3 root = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;      // world_vertex_coords: MODEL_MATRIX = this blade's transform
	float dist = length(root - CAMERA_POSITION_WORLD);
	// distance thinning: keep share k of blades, widen the rest by 1/sqrt(k) (coverage kept), and never below min_px
	float k = mix(1.0, 0.125, smoothstep(thin_start, thin_end, dist));
	float keep = step(hash11(INSTANCE_CUSTOM.x * 3.17 + 0.5), k / set_share);
	float px = dist * 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);    // metres per pixel at the blade
	float w0 = 0.016;   // blade mesh width (m), GrassField.BLADE_W
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
	// rest droop: the tip hangs over along the blade's own facing (its curl), soft blades more, so the meadow reads as a
	// lying, overlapping mass like the key frame rather than stiff upright spikes
	vec3 fwd = MODEL_MATRIX[2].xyz; vec2 fd = fwd.xz;
	fd = length(fd) > 1e-4 ? normalize(fd) : normalize(current_dir);
	off += fd * L * droop * (0.6 + 0.8 * hash11(INSTANCE_CUSTOM.x * 1.93)) / stiff;
	vec3 tip = root + vec3(0.0, L, 0.0);
	if (length(tip - push_bound.xyz) < push_bound.w + L) for (int i = 0; i < PUSHERS; i++) {
		vec4 p = pushers[i];
		if (p.w <= 0.0) continue;
		vec3 d = tip - p.xyz;
		float r = p.w + 0.5 * L;
		float dl = length(d.xz);
		float s = clamp(1.0 - length(d) / r, 0.0, 1.0);
		if (s > 0.0) off += (dl > 1e-3 ? d.xz / dl : vec2(1.0, 0.0)) * s * (2.0 - s) * L * 1.6;   // firm near her, soft at the rim
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
	NORMAL = normalize(mix(normalize(NORMAL), vec3(0.0, 1.0, 0.0), 0.72));   // velvet: the mass lights as one soft surface
}

void fragment() {
	vec3 c = mix(col_root, col_mid, smoothstep(0.0, 0.45, h01));
	c = mix(c, mix(col_tip, col_old, step(0.72, age)), smoothstep(0.55, 1.0, h01));
	c *= 0.8 + 0.4 * hue;
	c = mix(c, c * vec3(0.95, 1.05, 0.85), hue);
	// the dressing's own colour (kept luminance from the palette, so its root-to-tip shading stays)
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	vec3 tc = tile_col * lum / max(dot(tile_col, vec3(0.299, 0.587, 0.114)), 1e-3);
	c = mix(c, tc, tile_col_mix * step(dot(tile_col, vec3(1.0)), 2.97));
	// kf_paint.grass: saturation 1.2, age browning toward the tip, pale warm margins
	float l2 = dot(c, vec3(0.299, 0.587, 0.114));
	c = max(mix(vec3(l2), c, saturation), vec3(0.0));
	c = mix(c, col_brown, age * smoothstep(0.6, 1.0, h01) * 0.45);
	float edge = 1.0 - smoothstep(0.0, 0.10, min(edge_u, 1.0 - edge_u));
	c = mix(c, col_margin, 0.25 * edge);
	ALBEDO = c;
	ROUGHNESS = 0.7;
	SPECULAR = 0.15;
	RIM = 0.35; RIM_TINT = 0.6;                                     // velvet sheen at grazing angles
	BACKLIGHT = c * vec3(0.55, 0.75, 0.30) * (0.3 + 0.7 * h01);   // light through the blade
	AO = mix(0.6, 1.0, smoothstep(0.0, 0.7, h01));                 // the meadow's own shade at the roots
	AO_LIGHT_AFFECT = 0.6;
	float z = max(water_y - wpos.y, 0.0);
	if (water_fill_ao > 0.5) {
		AO = min(AO, screen_ao(SCREEN_UV));   // CORTAO when on (look/screen_ao.gdshaderinc)
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
