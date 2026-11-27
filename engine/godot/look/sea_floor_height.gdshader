// Sea floor height pass 0.1.0 (water surface thread): drawn only by adapters/godot/sea_floor_map.gd's orthographic
// height capture: writes the world height of whatever the capture sees from above, as r = (y + 50) / 100 and g = 1, alpha 1 where
// something was hit (0 = nothing: the shader falls back to the still floor). Any perspective camera discards it.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
void vertex() { POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0); }
void fragment() {
	if (PROJECTION_MATRIX[3][3] < 0.5) discard;      // perspective camera: not the floor capture
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vp.xyz /= vp.w;
	vec3 w = (INV_VIEW_MATRIX * vec4(vp.xyz, 1.0)).xyz;
	ALBEDO = vec3((w.y + 50.0) / 100.0, 1.0, 0.0);   // g = 1: the reader divides by it (any output scale cancels)
	ALPHA = depth > 1e-6 ? 1.0 : 0.0;
}
