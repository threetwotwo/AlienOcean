// Sand bake 0.1.0 (test level thread, 28 Nov 2026): writes the lagoon sand's fixed world-xy noise fields into two textures once at load
// (adapters/godot/sand_bake.gd), so look/ground_surface.gdshader with WS_BAKED reads them instead of hashing them every pixel, every frame.
// Exactly the expressions of SandRipples and GroundBlend's debris in look/world_surface.gdshaderinc (pure functions of p = island xy):
//   A = (nRdg raw fbm2n p/1.4, fo3 p/2.5 x7, fo3 p/2.2 x7, fo3 p/2.1 x7)
//   B = (warp coarse + 8 = 1.2*(fbm2n p/0.8 - .5)*2 + 10*fo3 p/2.0 + 8, fbm2v p/1.2 xy, 1)
// The finer terms (fbm2n p/0.45 of the warp, fb p/0.48 of the debris) stay per pixel: too fine to bake over the whole floor.
shader_type canvas_item;
render_mode unshaded, blend_disabled;
#include "res://look/world_surface.gdshaderinc"

uniform vec2 org;        // island xy (m) of the texture's first texel CENTRE
uniform vec2 span;       // island xy (m) from the first to the last texel centre
uniform vec2 px;         // texture size in texels
uniform int which = 0;

void fragment() {
	vec2 t = (floor(FRAGCOORD.xy) ) / max(px - 1.0, vec2(1.0));   // texel centres land exactly on org + t*span
	vec2 p = org + t * span;
	WsG Wg_ = wsNewG();
	if (which == 0) {
		COLOR = vec4(fbm2n(Wg_, vec3(p/1.4, 19.)), fo3(Wg_, vec3(p/2.5, 71.))*7., fo3(Wg_, vec3(p/2.2, 83.))*7., fo3(Wg_, vec3(p/2.1, 29.))*7.);
	} else if (which == 2) {
		COLOR = vec4(t, 0., 1.);   // the bake's own check: where each texel sits
	} else {
		float w = 1.2*(fbm2n(Wg_, vec3(p/0.8, 3.)) - 0.5)*2. + 10.*fo3(Wg_, vec3(p/2.0, 0.));
		COLOR = vec4(w + 8., fbm2v(Wg_, vec3(p/1.2, 41.)), 1.);   // +8: kept positive
	}
}
