// Ground surface 0.1.0 (engine thread): the shared world material M_Ground_Blend (WorldSurface.ush GroundBlend, Textures thread,
// generated into look/world_surface.gdshaderinc by tools/ws_to_godot.py), lit through the ported lagoon water like the seabed.
// Locked art bible v1.6 colours come in as uniforms (look/world_textures.gd), tiles colour-free as in Unreal.
// Frame: the library works in the island frame (x east, y north, z up, metres); Godot (x, y, z) -> island (x, -z, y).
shader_type spatial;
render_mode blend_mix, cull_back, diffuse_lambert, specular_disabled, ambient_light_disabled;
#include "res://look/world_surface.gdshaderinc"
#include "res://look/water_physics.gdshaderinc"
global uniform float water_zref;

uniform sampler2D rBC : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D rN : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D rORM : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tBC : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tN : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tORM : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D cBC : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D cN : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D cORM : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D gBC : repeat_enable, filter_linear_mipmap_anisotropic;      // T_Sand_Fine_BC: LINEAR grey multiplier, mean 0.5
uniform sampler2D gN : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D gM : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D dBC : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D dN : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D dM : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D fA : filter_linear;
uniform sampler2D fB : filter_linear;
uniform sampler2D fC : filter_linear;
uniform sampler2D fD : filter_linear;
uniform vec3 cSand; uniform vec3 cSandD; uniform vec3 cRock; uniform vec3 cCrev; uniform vec3 cTurf; uniform vec3 cCrust;
uniform vec3 cRubA; uniform vec3 cRubB; uniform vec3 cRubMid;
uniform vec3 mRock = vec3(0.5); uniform vec3 mTurf = vec3(0.5); uniform vec3 mCrust = vec3(0.5); uniform vec3 mGrain = vec3(0.5);
uniform float share = 1.0;           // sand share where the mesh carries none (lagoon floor: all sand)
uniform float caustic_strength : hint_range(0.0, 2.0) = 1.0;
uniform float caustic_scale = 0.55;
uniform float caustic_speed = 0.35;
varying vec3 wpos;
varying vec3 wnorm;

vec2 chash(vec2 p) { p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3))); return fract(sin(p) * 43758.5453); }
float ccells(vec2 p, float t) {
	vec2 i = floor(p), f = fract(p); float d = 8.0;
	for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
		vec2 g = vec2(float(x), float(y)); vec2 o = chash(i + g); o = 0.5 + 0.5 * sin(t + 6.2831 * o);
		d = min(d, length(g + o - f));
	}
	return d;
}
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	vec3 P = vec3(wpos.x, -wpos.z, wpos.y);
	vec3 N = normalize(vec3(wnorm.x, -wnorm.z, wnorm.y));
	vec3 rel = wpos - CAMERA_POSITION_WORLD; float l = length(rel); vec3 v = rel / max(l, 1e-3);
	float fp = l * max(length(dFdx(v)), length(dFdy(v)));
	WsG Wg = wsNewG();
	WsGround G; G.kind = 0.; G.share = share; G.flow = vec2(0.); G.trough = 0.; G.crest = 0.; G.vc = COLOR.rgb;
	G.open0 = vec3(1e5); G.open1 = vec3(1e5); G.floorZ = 0.; G.rockT = 0.30; G.noRipple = 0.; G.haze = 0.;
	G.glit = 0.; G.cam = vec3(CAMERA_POSITION_WORLD.x, -CAMERA_POSITION_WORLD.z, CAMERA_POSITION_WORLD.y); G.sun = vec3(0., 0., 1.);
	G.cSand = cSand; G.cSandD = cSandD; G.cRock = cRock; G.cCrev = cCrev; G.cTurf = cTurf; G.cCrust = cCrust;
	G.cRubA = cRubA; G.cRubB = cRubB; G.cRubMid = cRubMid; G.mRock = mRock; G.mTurf = mTurf; G.mCrust = mCrust; G.mGrain = mGrain;
	WsSurf S = GroundBlend(Wg, P, N, fp, G, rBC, rN, rORM, tBC, tN, tORM, cBC, cN, cORM, gBC, gN, gM, dBC, dN, dM, fA, fB, fC, fD);
	ALBEDO = S.alb;
	ROUGHNESS = S.rough;
	AO = S.ao;
	vec3 ng = normalize(vec3(S.n.x, S.n.z, -S.n.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(ng, 0.0)).xyz);
	// the water's diffuse light (as seabed_surface): sky from above, sand from below, through the depth
	float z = max(water_y - wpos.y, 0.0);
	float H = max(water_y - water_floor_y, 0.05);
	vec3 ek = water_ek0 * exp(-water_ku * z);
	vec3 eh = water_es0 * exp(-water_kd * H) + water_ek0 * exp(-water_ku * H);
	vec3 eu = eh * water_sand.rgb * exp(-water_ku * max(H - z, 0.0));
	float up = 0.5 + 0.5 * ng.y;
	EMISSION = ALBEDO * S.ao * (ek * up + eu * (1.0 - up)) / PI;
}
void light() {
	float z = max(water_y - wpos.y, 0.0);
	vec3 corr = exp(-water_kd * (z - water_zref));
	vec3 L = water_sun_w;
	vec2 p = (wpos.xz + z * L.xz / max(L.y, 0.2)) * caustic_scale;
	float t = TIME * caustic_speed;
	float c = min(ccells(p, t), ccells(p * 1.37 + 3.1, -t * 1.13));
	c = pow(1.0 - smoothstep(0.0, 0.55, c), 3.0);
	float caus = mix(1.0, 0.55 + 2.6 * c, caustic_strength);
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI * corr * caus;
}
