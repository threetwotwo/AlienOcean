// Sea march 0.2.0 (water surface thread, 28 Nov 2026; Gary: "water surface refraction wobble. it should be a root fix,
// physically correct for all object underwater. not just a patch fix for player model"): the ray bent at the surface,
// followed through the screen's depth until it meets whatever the screen holds there: sand, rock, grass, a body, a fish,
// alike. One model for every pixel and every object, from above (look/sea_top, the ray down into the water) and from
// below (look/sea_under, the ray up out of it). The screen was drawn along straight rays; this asks where the bent ray
// really ends, so a thing under the waves is seen where the waves put it, and moves as they move.
// 0.2.0 (independent review): one affine clip-space ray (no matrix per step); steps grow along the ray, jittered per pixel
// (and per frame under a temporal pass) so a thin fish is never stepped over the same way twice; a step that crosses from
// in front of the screen's picture to behind it is halved to the crossing, and is a hit only if the gap closes there (a
// surface). If it stays open, the ray passed behind a silhouette (her legs between the eye and the floor beyond): the march
// goes on, and a later step that comes out just under a surface is a hit; if it never does, the miss reports where it went
// behind (occ) so the caller can say what lies there without the screen.
// Needs sea_gdt (look/sea_waves.gdshaderinc). p0, dir: island coords (z up); perspective camera. Returns t (0 = miss).

float sea_lin(float d, mat4 ip) { return -(ip[2][2] * d + ip[3][2]) / (ip[2][3] * d + ip[3][3]); }   // m in front of the eye

float sea_ign(vec2 f) { return fract(52.9829189 * fract(dot(f, vec2(0.06711056, 0.00583715)))); }   // interleaved gradient noise

float sea_march(vec3 p0, vec3 dir, float tmax, int n, float jit, mat4 pvm, mat4 ip, sampler2D dtex, out vec2 uv, out vec3 occ) {
	vec4 c0 = pvm * vec4(sea_gdt(p0), 1.0);
	vec4 c1 = pvm * vec4(sea_gdt(dir), 0.0);
	uv = vec2(0.0); occ = vec3(0.0);
	float t0 = 0.0;
	bool front = true;                                       // the surface pixel itself is in front of the scene
	for (int i = 1; i <= n; i++) {
		float t = tmax * pow((float(i) - 1.0 + jit) / float(n), 1.7);
		vec4 cp = c0 + c1 * t;
		if (cp.w <= 1e-4) break;
		vec2 u = cp.xy / cp.w * 0.5 + 0.5;
		if (u.x < 0.0 || u.y < 0.0 || u.x > 1.0 || u.y > 1.0) { occ = vec3(0.0); break; }   // off the screen
		float ds = textureLod(dtex, u, 0.0).r;
		float gap = ds > 1e-7 ? cp.w - sea_lin(ds, ip) : -1.0;   // > 0: the ray is behind what the screen holds (m)
		if (gap <= 0.0) { front = true; occ = vec3(0.0); }
		else if (front) {                                    // crossed in (t0, t): a surface, or a silhouette passed behind
			float lo = t0, hi = t, gh = gap; vec2 uh = u;
			for (int k = 0; k < 5; k++) {
				float m = 0.5 * (lo + hi);
				vec4 cm = c0 + c1 * m;
				vec2 mu = cm.xy / cm.w * 0.5 + 0.5;
				float md = textureLod(dtex, mu, 0.0).r;
				float g = md > 1e-7 ? cm.w - sea_lin(md, ip) : -1.0;
				if (g > 0.0) { hi = m; gh = g; uh = mu; } else lo = m;
			}
			// a real surface: the gap closes as the bracket does (6 x the bracket covers a floor seen at a grazing angle);
			// a silhouette: it stays the two things' separation
			if (gh < 0.04 + 0.01 * cp.w + 6.0 * (hi - lo)) { uv = uh; return hi; }
			front = false; occ = vec3(uh, hi);
		} else if (gap < 0.04 + 0.01 * cp.w + 2.0 * (t - t0)) { uv = u; occ = vec3(0.0); return t; }   // came out just under a surface
		t0 = t;
	}
	return 0.0;
}
