// Sea side 0.1.0 (water surface thread, 28 Nov 2026): which side of the waves a pixel is seen from, and how far it is
// from the waterline across the lens. Ported from the Unreal open-water tank (openocean_tank v374): ABYSS_MASK_HLSL /
// SEA_SIDE_HLSL (v162-v366), the test both the deep water and the sea used so they always agreed. The ray's point on
// the near clip plane (where the sea mesh is cut) is set against the waves: below the drawn surface = seen from under
// the water. So the waterline across the lens is the line where the water meets that plane, and a lens half in a
// crest is half under water, whatever the flat sea level says.
// As the tank: the waves under that point are found by undoing the sideways push of cascades 0-2 (three fixed-point
// steps, X = p - D(X)); far from every wave (more than 2 Hs + 1 m off the still level) the eye's own side answers.
// Changes for Godot: the near-plane point comes from the inverse projection at depth 1 (Godot's reversed Z) instead of
// a near distance along the camera's forward; the planet's curve is left out (under a millimetre at the lens).
// Needs look/sea_waves.gdshaderinc included first (sea_disp, sea_patch, sea_mom_r, sea_on, sea_isl).

// the signed height (m) above the drawn water of the pixel's point on the near clip plane: + dry, - wet.
// uv: SCREEN_UV; surf: the still level (Godot y, the water_y global). far: set true when the eye is far from the waves
// (then the answer is the eye's height above the still level and needs no texture reads).
float sea_lens_height(vec2 uv, mat4 inv_proj, mat4 inv_view, float surf, out bool far) {
	vec3 cam = inv_view[3].xyz;
	float zc = cam.y - surf;
	far = abs(zc) > 2.0 * sea_mom_r.w + 1.0 || sea_on < 0.5;
	if (far) return zc;
	vec4 vn = inv_proj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 pn = sea_isl((inv_view * vec4(vn.xyz / vn.w, 1.0)).xyz);
	vec2 X = pn.xy;
	vec3 D = vec3(0.0);
	for (int it = 0; it < 3; it++) {
		D = vec3(0.0);
		for (int c = 0; c < 3; c++) D += textureLod(sea_disp, vec3(X / sea_c_sel(sea_patch, c), float(c)), 0.0).xyz;
		X = pn.xy - D.xy;
	}
	return pn.z - (surf + D.z);
}
