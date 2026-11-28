// Screen AO 0.1.0 (ao thread, 28 Nov 2026): the CORTAO result (adapters/godot/cortao_effect.gd) for the lit materials.
// Godot applies its own SSAO as ao = min(ao, ssao) on the ambient / GI only; with CORTAO on, Godot's SSAO is off and each lit
// material does the same with this: AO = min(AO, screen_ao(SCREEN_UV)); so the fill is occluded and the sun / light net are not.
// cortao_ao: r = occlusion (1 = open), gba = view-space bent normal * 0.5 + 0.5. cortao_on 0 = off (returns 1).
global uniform sampler2D cortao_ao;
global uniform float cortao_on;
float screen_ao(vec2 suv) {
	return cortao_on > 0.5 ? texture(cortao_ao, suv).r : 1.0;
}
vec3 screen_bent_normal(vec2 suv, vec3 view_normal) {
	return cortao_on > 0.5 ? normalize(texture(cortao_ao, suv).gba * 2.0 - 1.0) : view_normal;
}
