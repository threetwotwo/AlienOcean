// God rays 0.1.0 (engine thread): the light shafts under the water, ported from the Unreal lagoon as it ran at
// lagoonwater v98 (GodPhys 1, GodUnits 1, GodPick 1, GodLod 0, GodK 1, SubBand 0).
// Sources (ue_era): the god-ray node as built, lw/lagoonwater/logs/god_code_v53.txt (ocean setup_godrays + ocean v10's
// jitter + lagoonwater v3 / v8 / v29 / v32 patches), and lagoonwater_v98.py: GOD_FFT 3328-3353 (the caustic read),
// tb_weights_cached 2592-2612 (v66: the copy weights kept per 7 m cell along the ray; the same numbers),
// GOD_NEW_ADD 3374, NEW_FORM 3379, GOD_RET_NEW 2013 (v54 / v62: the node returns acc / a, metres), PHYS_CODE 2539-2547
// (the shafts = the physics sun's in-scatter per metre x that sum, gaps never below -0.9 of the sun's haze).
//
// Along the view ray: N steps over min(path, 5 / a) with a = 3 / Visibility (the old look's grey haze, which only
// weights the sum); each step is jittered per pixel, reads the light net's map (water_caus_map) at the point where
// that step's sunlight came through the surface, in ONE of the three tile-break copies picked by its weight (x the
// weights' sum), mixes the map's three depths by the step's depth and adds exp(-a s) x step x (c - 1). The net is
// the sand's own map at the same entry point, so a shaft ends on its bright line on the sand.
// Left out, as in Unreal at v98: the old painted colour path (GodPhys 0: WaterCol, Strength, ShadowMask, the 0.3 +
// 0.7 HG phase), GodLod, the three-read path (GodPick 0). The sub-band path (SubBand 1) was saved off in Unreal.
// Not Unreal: the per-pixel check path of the net (water_caus_k.x 0) has no map, so the rays are off there.
// Needs look/water_physics.gdshaderinc and look/caustics.gdshaderinc included first.

const float GOD_VIS = 15.0;        // MPC_Ocean Visibility, m (lw/lagoonwater/colour/calm_lagoon_colour_check_2026-11-06.md:65)
const int GOD_STEPS = 20;          // MPC_Ocean ShaftSteps (v98 note 457: "a 20-step ray"; v30's note 1107 said 12), clamp 4..48
const float GOD_FLOOR = 0.9;       // PHYS_CODE 2539: dark gaps never below -0.9 of the sun's in-scatter

// the caustic sum along the ray, metres (the god-ray node's return with GodPhys 1, GodUnits 1).
// cam, dir: Godot world; len_m: the path to the scene; frag: the pixel; frame8: the frame count mod 8 (0 without TAA)
float god_acc(vec3 cam, vec3 dir, float len_m, vec2 frag, float frame8) {
	// wet or dry is the caller's (look/underwater_view: per pixel at the drawn waves, look/sea_side.gdshaderinc)
	float a = 3.0 / max(GOD_VIS, 0.1);                              // haze per metre: 95% after Visibility metres
	float Lm = min(len_m, 5.0 / a);                                 // beyond that, under 1% of the haze is left to add
	// sun down: no shafts (Unreal: sunD.z < 0.02, the sun in air; here from the refracted sun, n 1.333)
	float sw = clamp(water_sun_w.y, 0.0, 1.0);
	if (1.0 - 1.333 * 1.333 * (1.0 - sw * sw) < 0.02 * 0.02 || water_sun_w.y <= 0.0) return 0.0;
	// a different start point per pixel (interleaved gradient noise), moved on by the golden ratio each frame
	float j = fract(52.9829189 * fract(dot(frag, vec2(0.06711056, 0.00583715))) + frame8 * 0.618034);
	int N = clamp(GOD_STEPS, 4, 48);
	float ds = Lm / float(N);
	float seg = 1.0 - exp(-a * ds);
	float acc = 0.0;
	// v66: each copy's 4 corner hashes, kept while the ray stays in the same 7 m cell
	vec2 cI0 = vec2(1e9), cI1 = vec2(1e9), cI2 = vec2(1e9);
	vec4 cH0 = vec4(0.0), cH1 = vec4(0.0), cH2 = vec4(0.0);
	const vec2 HA = vec2(127.1, 311.7);
	for (int i = 0; i < N; i++) {
		float s = (float(i) + j) * ds;
		vec3 q = cam + dir * s;
		float d = water_y - q.y;                                    // depth of this point, m
		if (d <= 0.0) continue;
		// lagoonwater v3: the caustics of the waves, at this point's depth, where its sunlight came in
		vec2 eg = q.xz + water_sun_w.xz * (d / max(water_sun_w.y, 0.2));
		vec2 e = vec2(eg.x, -eg.y);                                 // the island's frame (as caustic_net)
		float u = clamp(log2(max(d, 1e-3) / CAUS_D0) / CAUS_DSTEP, 0.0, 2.0);
		// v8: the same three copies as the surface above e
		vec3 tb;
		{ vec2 q_ = e / CAUS_TB_CELL; vec2 i_ = floor(q_); vec2 f_ = q_ - i_; f_ = f_ * f_ * (3.0 - 2.0 * f_);
		  if (any(notEqual(i_, cI0))) { cI0 = i_; cH0 = fract(sin(vec4(dot(i_, HA), dot(i_ + vec2(1.0, 0.0), HA), dot(i_ + vec2(0.0, 1.0), HA), dot(i_ + vec2(1.0, 1.0), HA))) * 43758.5453); }
		  tb.x = smoothstep(0.25, 0.75, mix(mix(cH0.x, cH0.y, f_.x), mix(cH0.z, cH0.w, f_.x), f_.y)) + 0.05; }
		{ vec2 q_ = e / CAUS_TB_CELL + vec2(13.7, 7.9); vec2 i_ = floor(q_); vec2 f_ = q_ - i_; f_ = f_ * f_ * (3.0 - 2.0 * f_);
		  if (any(notEqual(i_, cI1))) { cI1 = i_; cH1 = fract(sin(vec4(dot(i_, HA), dot(i_ + vec2(1.0, 0.0), HA), dot(i_ + vec2(0.0, 1.0), HA), dot(i_ + vec2(1.0, 1.0), HA))) * 43758.5453); }
		  tb.y = smoothstep(0.25, 0.75, mix(mix(cH1.x, cH1.y, f_.x), mix(cH1.z, cH1.w, f_.x), f_.y)) + 0.05; }
		{ vec2 q_ = e / CAUS_TB_CELL + vec2(27.4, 15.8); vec2 i_ = floor(q_); vec2 f_ = q_ - i_; f_ = f_ * f_ * (3.0 - 2.0 * f_);
		  if (any(notEqual(i_, cI2))) { cI2 = i_; cH2 = fract(sin(vec4(dot(i_, HA), dot(i_ + vec2(1.0, 0.0), HA), dot(i_ + vec2(0.0, 1.0), HA), dot(i_ + vec2(1.0, 1.0), HA))) * 43758.5453); }
		  tb.z = smoothstep(0.25, 0.75, mix(mix(cH2.x, cH2.y, f_.x), mix(cH2.z, cH2.w, f_.x), f_.y)) + 0.05; }
		tb *= inversesqrt(dot(tb, tb));
		// v32 / v33 (GodPick 1): one copy a step, picked by its weight, x the weights' sum: the same average
		float W = tb.x + tb.y + tb.z;
		float r = fract(j * 3.1123 + float(i) * 0.5698403) * W;
		vec2 pp = (r < tb.x) ? e : ((r < tb.x + tb.y) ? caus_tb_x1(e) : caus_tb_x2(e));
		vec3 cs = vec3(1.0) + W * (textureLod(water_caus_map, pp / CAUS_TILE, 0.0).rgb - 1.0);
		cs = max(cs, vec3(0.0));
		float c = (u < 1.0) ? mix(cs.r, cs.g, u) : mix(cs.g, cs.b, u - 1.0);
		c = mix(1.0, c, clamp(d / CAUS_D0, 0.0, 1.0) * clamp(1.5 - s * 0.02, 0.0, 1.0));
		acc += exp(-a * s) * seg * (c - 1.0);                       // v3: the map's average is 1; form = 1 (NEW_FORM)
	}
	return acc / a;                                                 // v62 GodUnits 1: metres (seg / a = the step)
}

// The shafts in nits (PHYS_CODE: gsun = b x ScatK x the sun at the eye's depth x the phase, per metre; x the sum;
// gaps floored at -0.9 x the sun's haze on this ray). z0: the eye's depth m; L: the path to the scene.
// GlowK is not applied, as in Unreal (GlowK scales the glow only).
vec3 god_rays(vec3 cam, vec3 dir, float L, vec2 frag, float frame8) {
	if (water_caus_k.x < 0.5) return vec3(0.0);                     // no map (the net's per-pixel check path)
	float z0 = water_y - cam.y;
	float gx = god_acc(cam, dir, L, frag, frame8);
	float muw = max(water_sun_w.y, 0.05);                           // as w_glow (Unreal: max(-tr.z, 0.2))
	vec3 Es = water_es0 * exp(-water_kd * z0) / muw;
	float ct = dot(dir, water_sun_w);
	float ph = (1.0 - W_G * W_G) / (4.0 * PI * pow(max(1.0 + W_G * W_G - 2.0 * W_G * ct, 1e-4), 1.5));
	float bt = max(water_y - water_floor_y, z0);
	float Lp = L;
	if (dir.y > 1e-3) Lp = min(Lp, z0 / dir.y);
	if (dir.y < -1e-3) Lp = min(Lp, (bt - z0 + 1.0) / -dir.y);
	vec3 gsun = water_b * Es * ph;
	return max(gsun * gx, -GOD_FLOOR * gsun * w_G(water_a + water_b - water_kd * dir.y, Lp));
}
