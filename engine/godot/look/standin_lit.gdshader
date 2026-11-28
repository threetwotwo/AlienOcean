// Stand-in lit 0.1.0 (ao thread, 28 Nov 2026): what the stand-ins (mannequin, skinned body) used from StandardMaterial3D
// (vertex colour as albedo, flat roughness) plus the screen AO. With CORTAO the default, Godot's SSAO is off, and a
// StandardMaterial3D would get no ambient occlusion at all (tests/test_screen_ao_gate.gd lists every lit shader for that).
shader_type spatial;
render_mode cull_back;
#include "res://look/screen_ao.gdshaderinc"

uniform float roughness_v : hint_range(0.0, 1.0) = 0.6;

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = roughness_v;
	AO = min(AO, screen_ao(SCREEN_UV));
}
