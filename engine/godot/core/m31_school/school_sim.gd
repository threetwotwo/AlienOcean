## M31 school sim 0.1.0: one fish school, engine-free (RefCounted, no Nodes, no physics calls).
## A port of the Nov 1 2026 schooling paper's rule set ("Fish Schools at Sixty", papers/systems/schooling/; the numpy
## prototype research/schooling/school.py, model "ao") with the Unreal school lab's fixes (schoollab v1-v87):
##   Calovi et al. 2018 smooth attraction / alignment, Katz et al. 2011 split (along-heading pull -> speed, sideways ->
##   turn), k visible nearest neighbours weighted by size on the eye, a few random far schoolmates a step, Rosenthal et al.
##   2015 startle cascade on ONSETS with a 3 s refractory time, vision fading with light, the alarm (alert_T), lateral
##   line inside 1 BL, rotational noise, Bainbridge tail beat.
## Units inside: body lengths (BL) and seconds, positions relative to `origin` (metres) divided by `bl` (metres per BL).
## Everything the world gives (floor, water surface, rocks, the girl) comes in through `env` in metres and is converted.
## Steps at a FIXED rate (`dt`, 1/30 s as the prototype); the adapter interpolates for drawing, so the school does the
## same thing at 30, 60 or 120 frames a second.
## Deviations from school.py, each one a lab-proven fix (listed in engine/godot/CHANGELOG.md):
##   D1 startle onset window centred on the latency, [LAT - dt/2, LAT + dt/2) (LESSONS: schools, event timing, v1)
##   D2 neighbours from a uniform grid inside search_R (default 8 BL), exact inside it; fish farther than that are
##      reached by the far glimpses only (school.py searches every pair, O(N^2))
##   D3 a fish startled directly by an actor flees away from it (school.py kept its stale cascade direction)
##   D4 rocks are the world's own surfaces (env.nearest_surface ahead of the fish + a swept-segment guard), not spheres
##   D5 calm and scared personal space differ (behaviour v3: 0.8 vs 0.48 BL) and the girl is perceived calmly (M08)
##   D6 an actor's push also changes speed (Katz split) and urgency raises the swim speed (escape swim, flee_v);
##      no fish ends a step inside the girl's keep-out sphere; a touch startles
extends RefCounted

const Rng := preload("res://core/m31_school/school_rng.gd")

const LAT_S := 2.0 / 30.0       # visual startle latency, two 30 Hz frames
const REFRACTORY := 3.0

# ---------------------------------------------------------------- parameters (BL, BL/s, s, rad); see school_species.gd
var p: Dictionary = {}
var N := 0
var bl := 0.2                   # metres per body length
var origin := Vector3.ZERO      # metres; positions are stored relative to it, in BL
var dt := 1.0 / 30.0
var light := 1.0                # 0 dark .. 1 day (the sky clock gives it)
var flow := Vector3.ZERO        # BL/s, the water current at the school
var actors: Array = []          # M08 perceived actors: [{pos: Vector3 m, vel: Vector3 m/s, radius: m, kind: "player"|"predator",
                                #   optional axis: Vector3, half_len: m (a capsule)}]
var spheres: Array = []         # [(centre BL, radius BL)]: test obstacles (school.py's own), world rocks come from env

# ---------------------------------------------------------------- state
var x := PackedVector3Array()   # BL from origin
var x_prev := PackedVector3Array()  # before the last step (drawing interpolates; the swept guard)
var e := PackedVector3Array()   # heading, unit
var v := PackedFloat64Array()   # speed BL/s
var L := PackedFloat64Array()   # own size (BL of the species' mean), size matched within 5 %
var v0i := PackedFloat64Array() # own preferred speed
var phase := PackedFloat64Array()
var s := PackedFloat64Array()   # startle level 0..1
var t_on := PackedFloat64Array()
var t_alert := PackedFloat64Array()   # last time it fled an actor (keeps the alarm on, D6)
var cdir := PackedVector3Array()  # escape direction of the last startle
var calm := PackedFloat64Array()  # 1 calm .. 0 scared, eases back after a threat (personal space follows it)
var turn_rate := PackedFloat64Array()
var yaw_rate := PackedFloat64Array()   # signed rad/s about world up
var keep_outs := 0              # fish put back on the girl's keep-out sphere this step (a last-resort constraint, counted)
var _swept := PackedByteArray()  # fish moved by a constraint this step: the swept guard checks them too
var nb := PackedInt32Array()    # k neighbours per fish of the last step (-1 none), for metrics and the GPU check
var t := 0.0
var steps := 0
var rng
var seed := 1
var br_y := 0.0
var br_yd := 0.0
var ou := 0.0
var by_cascade := 0             # fish startled by a neighbour this step
var by_actor := 0               # fish startled by an actor this step

# world cache (staggered queries; see env_period)
var _wall_pt := PackedVector3Array()   # nearest rock point ahead (BL), or INF
var _wall_n := PackedVector3Array()
var _floor_y := PackedFloat64Array()   # floor under the fish (BL, relative to origin), -INF = none
var _surf_y := 1.0e9                   # water surface (BL, relative to origin)
var hits := 0                          # swept-segment guard catches (a fish that would have entered rock)

## p: species parameters (school_species.gd fills defaults). seed: the school's seed.
func setup(params: Dictionary, n: int, seed_: int, body_m: float, origin_m: Vector3, home_rel_bl = null) -> void:
	p = params.duplicate()
	N = n
	bl = body_m
	origin = origin_m
	seed = seed_
	rng = Rng.new(seed_)
	for a in [x, x_prev, e, cdir, _wall_pt, _wall_n]: a.resize(N)
	for a in [v, L, v0i, phase, s, t_on, t_alert, calm, turn_rate, yaw_rate, _floor_y]: a.resize(N)
	_swept.resize(N)
	nb.resize(N * int(p.k))
	nb.fill(-1)
	var c: Vector3 = home_rel_bl if home_rel_bl != null else Vector3.ZERO
	var sp: float = p.spread / 2.5
	for i in N:
		x[i] = c + Vector3(rng.normal(), rng.normal() * 0.4, rng.normal()) * sp
		e[i] = (Vector3(1.0, 0.0, 0.2) + Vector3(rng.normal(), rng.normal() * 0.1, rng.normal()) * p.get("init_spread", 0.5)).normalized()
		L[i] = clampf(1.0 + 0.05 * rng.normal(), 0.85, 1.15)
		v0i[i] = p.v0 * clampf(1.0 + p.vspread * rng.normal(), 0.7, 1.3)
		v[i] = v0i[i]
		phase[i] = rng.uniform() * TAU
		s[i] = 0.0
		t_on[i] = -99.0
		t_alert[i] = -99.0
		cdir[i] = Vector3.ZERO
		calm[i] = 1.0
		_wall_pt[i] = Vector3.INF
		_wall_n[i] = Vector3.UP
		_floor_y[i] = -INF
	x_prev = x.duplicate()
	assert(p.look_R >= p.env_period * p.burst_v * dt, "look_R must cover a burst between world queries")

## Overwrite the state (golden traces): arrays in BL / BL/s.
func load_state(xs: Array, es: Array, vs: Array, Ls: Array, v0s: Array, ph: Array) -> void:
	for i in N:
		x[i] = Vector3(xs[i][0], xs[i][1], xs[i][2]); e[i] = Vector3(es[i][0], es[i][1], es[i][2]).normalized()
		v[i] = vs[i]; L[i] = Ls[i]; v0i[i] = v0s[i]; phase[i] = ph[i]
	rng = Rng.new(seed)      # the step's stream starts fresh, as the reference's (its start state came from elsewhere)

## A startle that begins now (tests, a predator's lunge): fish i bursts away from `away`.
func poke(i: int, away: Vector3 = Vector3.ZERO) -> void:
	t_on[i] = t
	s[i] = 1.0
	cdir[i] = away.normalized() if away.length() > 0.0 else e[i]
	calm[i] = 0.0

func world_pos(i: int) -> Vector3:
	return origin + x[i] * bl

# ---------------------------------------------------------------- neighbours: uniform grid (D2)
var _grid := {}

func _key(q: Vector3, inv: float) -> Vector3i:
	return Vector3i(floori(q.x * inv), floori(q.y * inv), floori(q.z * inv))

func _build_grid(cs: float) -> void:
	_grid.clear()
	var inv := 1.0 / cs
	for i in N:
		var k := _key(x[i], inv)
		if _grid.has(k): _grid[k].append(i)
		else: _grid[k] = PackedInt32Array([i])

# ---------------------------------------------------------------- one step
## env (all optional, metres): floor_height(x, z) -> float (-INF none), water_y(x, z, t) -> float,
##   nearest_surface(p, r) -> {dist, normal, point} or {}, segment_hit(a, b) -> {point, normal} or {}, current(p, t) -> Vector3
func step(env: Dictionary = {}) -> void:
	var kk: int = p.k
	var nf: int = p.n_far
	var cosfov := cos(p.fov * 0.5)
	var d0b: float = p.d0
	# breathing (lagoon shoals): an underdamped random oscillator on the spacing
	var br: float = p.breathe
	var pre_breathe := 0.0
	if br > 0.0:
		pre_breathe = rng.normal()
	# all of this step's random numbers, in the reference's order
	var far_j := PackedInt32Array(); far_j.resize(N * nf)
	for q in N * nf: far_j[q] = rng.integer(N)
	var cas_u := PackedFloat64Array(); cas_u.resize(N * kk)
	for q in N * kk: cas_u[q] = rng.uniform()
	var noise := PackedVector3Array(); noise.resize(N)
	for q in N: noise[q] = Vector3(rng.normal(), rng.normal(), rng.normal())
	if br > 0.0:
		var w0: float = TAU / p.breathe_T
		var Q := 2.0
		var ydd: float = -w0 / Q * br_yd - w0 * w0 * br_y + w0 * sqrt(2.0 * w0 / Q) * pre_breathe / sqrt(dt)
		br_yd += ydd * dt; br_y += br_yd * dt
		ou = br_y
	var d0 := d0b * clampf(1.0 + br * ou, 0.5, 1.5)     # breathing, bounded (an unbounded oscillator could blow up)
	var aT: float = p.alert_T
	if not env.is_empty():
		world_queries(env)

	var S := PackedVector3Array(); S.resize(N)
	var dvv := PackedFloat64Array(); dvv.resize(N)
	var trig := PackedByteArray(); trig.resize(N)
	var nearest_j := PackedInt32Array(); nearest_j.resize(N)
	var nearest_d := PackedFloat64Array(); nearest_d.resize(N)
	var cs: float = p.grid_cell
	var inv := 1.0 / cs
	var rmax := int(ceil(p.search_R / cs))
	_build_grid(cs)
	by_cascade = 0
	var idx := PackedInt32Array(); idx.resize(kk)
	var dk := PackedFloat64Array(); dk.resize(kk)
	for i in N:
		var xi := x[i]
		var ei := e[i]
		var al := clampf(1.0 - (t - maxf(t_on[i], t_alert[i])) / aT, 0.0, 1.0) if aT > 0.0 else 0.0
		# k nearest visible (exact inside search_R), and the nearest of all directions (overlap guard)
		var cnt := 0
		var nd := INF
		var nj := -1
		var kc := _key(xi, inv)
		var r := 0
		while r <= rmax:
			for gx in range(-r, r + 1):
				for gy in range(-r, r + 1):
					for gz in range(-r, r + 1):
						if maxi(absi(gx), maxi(absi(gy), absi(gz))) != r: continue
						var cell = _grid.get(kc + Vector3i(gx, gy, gz))
						if cell == null: continue
						for j in cell:
							if j == i: continue
							var rv := x[j] - xi
							var d := rv.length()
							if d < nd:
								nd = d; nj = j
							if d > p.search_R: continue
							if ei.dot(rv) < cosfov * d: continue      # blind cone behind
							if cnt < kk:
								var q := cnt
								while q > 0 and dk[q - 1] > d:
									dk[q] = dk[q - 1]; idx[q] = idx[q - 1]; q -= 1
								dk[q] = d; idx[q] = j; cnt += 1
							elif d < dk[kk - 1]:
								var q2 := kk - 1
								while q2 > 0 and dk[q2 - 1] > d:
									dk[q2] = dk[q2 - 1]; idx[q2] = idx[q2 - 1]; q2 -= 1
								dk[q2] = d; idx[q2] = j
			# ring r covers every fish nearer than r * cs: stop once the k-th found is inside that
			if cnt == kk and dk[kk - 1] <= r * cs: break
			r += 1
		nearest_j[i] = nj
		nearest_d[i] = nd
		# weights ~ size on the eye, (L/d)^2, normalised over the k
		var wsum := 0.0
		var wk := PackedFloat64Array(); wk.resize(kk)
		for q in cnt:
			wk[q] = pow(L[idx[q]] / maxf(dk[q], 0.3), 2.0)
			wsum += wk[q]
		wsum = maxf(wsum, 1e-9)
		var Sv := Vector3.ZERO
		var ali_gain: float = p.g_ali * (1.0 + p.alert_ali * al)
		# personal space: scared fish pack closer (behaviour v3, D5); calm = 1 keeps the species' d0
		var d0i := d0 * lerpf(p.d0_scared_k, 1.0, calm[i])
		for q in cnt:
			var j := idx[q]
			var d := dk[q]
			var rh := (x[j] - xi) / maxf(d, 1e-9)
			var cv := ei.dot(rh)
			var w := wk[q] / wsum
			var fa: float = p.g_att * (d - d0i) / (1.0 + pow(d / p.la, 2.0)) * (1.0 + p.eps * cv)
			if d < d0i: fa *= 3.0
			var fl := ali_gain * (d + 0.3) * exp(-pow(d / p.lal, 2.0)) * 0.5 * (1.0 + cv)
			var ej := e[j]
			var ali := ej - ei * ej.dot(ei)
			var g := 1.0 if d < 1.0 else light
			Sv += (rh * fa + ali * fl) * (w * g)
		# far schoolmates: a few random members a step (re-joins split schools)
		if nf > 0:
			var acc := Vector3.ZERO
			for q in nf:
				var j := far_j[i * nf + q]
				var fr := x[j] - xi
				var fd := fr.length()
				var fu := fr / maxf(fd, 1e-9)
				if j == i or fd <= 3.0 or ei.dot(fu) < cosfov: continue
				var fw := 1.0 - exp(-(fd - 3.0) / 5.0)
				acc += fu * fw
			var gf: float = p.g_far * (1.0 + p.alert_far * al)
			Sv += acc * (gf * light / nf)
		# Katz: along-heading part -> speed, sideways part -> turn
		var par := Sv.dot(ei)
		dvv[i] = p.k_speed * par
		S[i] = Sv - ei * par
		# startle cascade: a neighbour's startle ONSET seen after the latency (window centred on it, D1)
		var hit_any := false
		var away := Vector3.ZERO
		var refr := (t - t_on[i]) > REFRACTORY
		for q in cnt:
			var j := idx[q]
			var age := t - t_on[j]
			if age < LAT_S - dt * 0.5 or age >= LAT_S + dt * 0.5: continue
			var rank := 1
			for q2 in cnt:
				if wk[q2] > wk[q]: rank += 1
			var pr: float = 1.0 / (1.0 + exp(-0.302 + 1.421 * log(maxf(dk[q], 0.3)) + 0.126 * rank)) * light * p.startle_k
			if cas_u[i * kk + q] < pr:
				hit_any = true
				away -= (x[j] - xi) / maxf(dk[q], 1e-9)
		if hit_any and refr:
			trig[i] = 1
			by_cascade += 1
			cdir[i] = away.normalized() if away.length() > 1e-9 else ei
		for q in kk:
			nb[i * kk + q] = idx[q] if q < cnt else -1

	# environment, actors, startle state, turn, speed, move (from the pre-step state, as the reference)
	by_actor = 0
	for i in N:
		var xi := x[i]
		var ei := e[i]
		var Si := S[i]
		# keep off the floor and the surface, level the pitch (school.py's depth band, measured from the real floor)
		var y := xi.y
		var fy := _floor_y[i]
		var zlo := -1.0e9
		var zhi := 1.0e9
		if fy > -INF:
			zlo = fy + p.depth_lo; zhi = fy + p.depth_hi
		zhi = minf(zhi, _surf_y - p.surface_clear)
		if p.has("abs_depth"):     # golden traces: school.py's absolute band
			zlo = p.abs_depth[0]; zhi = p.abs_depth[1]
		var up := maxf((zlo + 2.0 - y) / 2.0, 0.0) - maxf((y - (zhi - 2.0)) / 2.0, 0.0)
		Si.y += 1.5 * up - 0.8 * ei.y
		# home tether
		if p.R_home > 0.0:
			var hv: Vector3 = p.home - xi
			hv.y *= 0.3
			var dh := Vector2(hv.x, hv.z).length()
			var pull := hv.normalized() * clampf((dh - p.R_home) / p.R_home, 0.0, 3.0)
			Si += (pull - ei * pull.dot(ei)) * 0.9
		# test spheres (school.py) and the world's rocks (D4): a push that fades over 1 BL from the surface
		for sph in spheres:
			var ov: Vector3 = xi - sph[0]
			var dist: float = ov.length() - sph[1]
			var push := ov.normalized() * (exp(-maxf(dist, 0.0) / 1.0) * 3.0)
			Si += push - ei * push.dot(ei)
		var wp := _wall_pt[i]
		if wp.x != INF:
			var ov2 := xi - wp
			var dist2 := ov2.length()
			var nrm := _wall_n[i] if ov2.dot(_wall_n[i]) >= 0.0 or dist2 < 1e-6 else ov2 / dist2
			var push2: Vector3 = nrm * (exp(-maxf(dist2 - p.rock_clear, 0.0) / p.rock_fade) * p.rock_push)
			Si += push2 - ei * push2.dot(ei)
			dvv[i] += p.k_speed * push2.dot(ei)      # D4: heading into rock slows the fish (Katz split, as for actors)
			# and a fish heading into the face turns to swim along it (slides round the rock instead of piling on it)
			var into := ei.dot(nrm)
			if into < 0.0:
				var steer: Vector3 = nrm * (-into * p.rock_steer * exp(-maxf(dist2 - p.rock_clear, 0.0) / p.look_R))
				Si += steer - ei * steer.dot(ei)
		# perceived actors (M08): the girl calmly (make way), a predator as school.py's (fountain + startle)
		var direct := false
		var flee := Vector3.ZERO
		var flee_v := 0.0
		var keep_out := []
		for a in actors:
			var ap: Vector3 = _closest_on_actor(a, xi)
			var av: Vector3 = a.vel / bl
			var pv := xi - ap
			var dp := pv.length()
			var is_pred: bool = a.get("kind", "player") == "predator"
			var R: float = p.pred_R if is_pred else p.fid + a.get("radius", 0.0) / bl
			if dp >= R: continue
			var ph := av.normalized() if av.length() > 1e-6 else -pv.normalized()
			var side := pv - ph * pv.dot(ph)
			side = side.normalized() if side.length() > 1e-6 else ei.cross(Vector3.UP).normalized()
			var fv := (pv.normalized() * 0.6 + side * 0.8).normalized()
			var gain := 1.0 - dp / R
			var closing := maxf(-av.dot(pv / maxf(dp, 1e-6)), 0.0)    # BL/s toward this fish
			var F := Vector3.ZERO
			var ra: float = a.get("radius", 0.0) / bl
			if is_pred:
				F = fv * (6.0 * gain)
				if dp < 0.6 * R: direct = true; flee = fv
			else:
				# calm: part smoothly round her, more as she comes faster (time to contact); a startle only if she
				# rushes in close, or touches
				var urg := gain * (1.0 + closing / maxf(p.v0, 0.1))
				F = fv * (p.calm_push * urg)
				# startle by time to contact (behaviour v1/v4: look ahead by the closing speed, not a fixed radius)
				var ttc := (dp - ra) / maxf(closing, 1e-6)
				if (closing > p.rush_speed and ttc < p.rush_ttc) or dp < ra + p.touch_R:
					direct = true; flee = fv
			# Katz split for the actor's push too: the sideways part turns, the along-heading part changes speed;
			# and a fish swims away faster (an escape swim, not a C-start) the more urgent the threat (D6)
			Si += F - ei * F.dot(ei)
			dvv[i] += p.k_speed * F.dot(ei)
			var fu: float = gain * (1.0 + closing / maxf(p.v0, 0.1))
			flee_v = maxf(flee_v, minf(p.flee_v * fu, p.flee_v))
			if fu > 0.5: t_alert[i] = t      # a fish that had to flee keeps the alarm too: it seeks the school after
			keep_out.append([ap, ra + p.keep_out])
		var refr := (t - t_on[i]) > REFRACTORY
		if direct and refr and trig[i] == 0:
			trig[i] = 1
			by_actor += 1
			cdir[i] = flee      # D3
		if trig[i] == 1:
			t_on[i] = t
			calm[i] = 0.0
		s[i] = maxf(s[i] * exp(-dt / 0.25), float(trig[i]))
		calm[i] = minf(calm[i] + dt / p.calm_T, 1.0)
		var burst := s[i] > 0.5
		if burst:
			var cd := cdir[i] * 6.0
			Si += cd - ei * cd.dot(ei)
		# turn, rate limited
		Si -= ei * Si.dot(ei)
		var w: float = Si.length() * p.k_turn
		w = minf(w, deg_to_rad(p.burst_turn_deg) if burst else p.wmax)
		var ang: float = w * dt
		var en := ei
		if Si.length() > 1e-12:
			en = (ei * cos(ang) + Si.normalized() * sin(ang)).normalized()
		# rotational diffusion, flatter in pitch; more in the dark (nothing to follow)
		var nz: Vector3 = noise[i] * Vector3(1.0, 0.35, 1.0) * (p.noise * (1.0 + 1.5 * (1.0 - light)) * sqrt(dt))
		nz -= en * nz.dot(en)
		en = (en + nz).normalized()
		# pitch cap (schoollab v46: a frame from world up flips near vertical)
		var pmax: float = deg_to_rad(p.pitch_max_deg)
		if absf(en.y) > sin(pmax):
			var hz := Vector2(en.x, en.z)
			if hz.length() < 1e-6: hz = Vector2(ei.x, ei.z)
			hz = hz.normalized() * cos(pmax)
			en = Vector3(hz.x, signf(en.y) * sin(pmax), hz.y)
		yaw_rate[i] = atan2(ei.cross(en).y, ei.dot(en)) / dt     # signed, about world up (drawing: bank and body bend)
		e[i] = en
		turn_rate[i] = w
		# speed
		var vt: float = p.burst_v if burst else maxf(v0i[i], flee_v)
		dvv[i] += (vt - v[i]) / (0.12 if burst else (p.tau_v if flee_v <= v0i[i] else p.flee_tau))
		v[i] = clampf(v[i] + dvv[i] * dt, p.vmin * p.v0, p.burst_v + 2.0)
	# move (all fish), then the overlap guard from the moved positions (as school.py); the swept guard against rock after
	var xn := PackedVector3Array(); xn.resize(N)
	for i in N:
		xn[i] = x[i] + (e[i] * v[i] + flow) * dt
	var pushes := PackedVector3Array(); pushes.resize(N)
	if p.no_overlap:
		for i in N:
			if nearest_j[i] >= 0 and nearest_d[i] < p.overlap:
				var away := xn[i] - xn[nearest_j[i]]
				if away.length() > 1e-9:
					pushes[i] = away.normalized() * ((p.overlap - nearest_d[i]) * 0.5)
	x_prev = x.duplicate()
	var aps := []
	for a in actors:
		if a.get("kind", "player") != "predator":
			aps.append([a, a.get("radius", 0.0) / bl + p.keep_out])
	keep_outs = 0
	_swept.fill(0)
	for i in N:
		x[i] = xn[i] + pushes[i]
		# no fish inside the girl (D6): a fish that would end inside her keep-out sphere stays on its surface
		for ka in aps:
			var cpt := _closest_on_actor(ka[0], x[i])
			var dv3: Vector3 = x[i] - cpt
			var dl := dv3.length()
			if dl < ka[1] and dl > 1e-6:
				x[i] = cpt + dv3 / dl * ka[1]
				keep_outs += 1
				_swept[i] = 1
		var f := (4.0 * v[i] / L[i] + 4.0) / 3.0                       # Bainbridge 1958: U = L(3f - 4)/4
		phase[i] = fmod(phase[i] + TAU * f * dt, TAU)
	hits = 0
	if env.has("segment_hit"):
		guard(env.segment_hit)
	t += dt
	steps += 1

## Swept guard (D4): a fish whose last move crossed a world surface is put back on the outside of it and turned away.
## Only fish that had rock or floor within look_R at their last query can reach one before the next query
## (look_R >= env_period x burst_v x dt, checked in setup), so only those are swept. Main thread only (physics).
func guard(seg: Callable) -> void:
	hits = 0
	for i in N:
		if _wall_pt[i].x == INF and _swept[i] == 0 and x_prev[i].distance_to(x[i]) < p.look_R - p.env_period * p.burst_v * dt: continue
		var a := origin + x_prev[i] * bl
		var h: Dictionary = seg.call(a, origin + x[i] * bl)
		if h.is_empty(): continue
		hits += 1
		var hn: Vector3 = h.normal
		var put: Vector3 = h.point + hn * (p.hit_margin * bl)
		# the put-back point must itself be reachable (concave corners): else the fish stays where it was
		if not seg.call(a, put).is_empty(): put = a
		x[i] = (put - origin) / bl
		var ee := e[i] - hn * minf(e[i].dot(hn), 0.0) * 2.0      # turn away from the face it met
		e[i] = ee.normalized()

## An actor is a sphere (pos, radius) or a capsule (plus axis: unit Vector3 and half_len: metres, e.g. a swimming
## child lying along her heading). Returns the nearest point of its core segment to q, in BL from origin.
func _closest_on_actor(a: Dictionary, q: Vector3) -> Vector3:
	var c: Vector3 = (a.pos - origin) / bl
	var hl: float = a.get("half_len", 0.0) / bl
	if hl <= 0.0: return c
	var ax: Vector3 = a.axis
	return c + ax * clampf((q - c).dot(ax), -hl, hl)

# ---------------------------------------------------------------- world queries (staggered)
## Floor, surface, current and rock-ahead for the fish due this step (staggered: env_period). Main thread only (physics).
func world_queries(env: Dictionary) -> void:
	var fh = env.get("floor_height")
	var wy = env.get("water_y")
	var ns = env.get("nearest_surface")
	var cur = env.get("current")
	var per: int = p.env_period
	var c := origin + _centre() * bl
	if wy != null:
		_surf_y = (wy.call(c.x, c.z, t) - origin.y) / bl
	if cur != null:
		flow = cur.call(c, t) / bl
	for i in N:
		if (i + steps) % per != 0: continue
		var wpos := origin + x[i] * bl
		if fh != null:
			var f: float = fh.call(wpos.x, wpos.z)
			_floor_y[i] = (f - origin.y) / bl if f > -INF else -INF
		if ns != null:
			# one sphere covering the fish and the water ahead of it
			var ahead: Vector3 = wpos + e[i] * (p.look_ahead * 0.5 * bl)
			var hit: Dictionary = ns.call(ahead, (p.look_R + p.look_ahead * 0.5) * bl)
			if hit.is_empty():
				_wall_pt[i] = Vector3.INF
			else:
				_wall_pt[i] = (hit.point - origin) / bl
				_wall_n[i] = hit.normal

func _centre() -> Vector3:
	var c := Vector3.ZERO
	for i in N: c += x[i]
	return c / maxf(N, 1)

# ---------------------------------------------------------------- measures (school.py metrics(), in BL)
func metrics() -> Dictionary:
	var c := _centre()
	var esum := Vector3.ZERO
	var msum := Vector3.ZERO
	var vs := 0.0
	var vs2 := 0.0
	for i in N:
		esum += e[i]
		var rc := (x[i] - c).normalized()
		msum += rc.cross(e[i])
		vs += v[i]; vs2 += v[i] * v[i]
	var nnd := PackedFloat64Array(); nnd.resize(N)
	var iid := 0.0
	var close := 0
	for i in N:
		var m := INF
		for j in N:
			if j == i: continue
			var d := x[i].distance_to(x[j])
			m = minf(m, d)
			iid += d
		nnd[i] = m
		if m < 0.3: close += 1
	var sorted := nnd.duplicate(); sorted.sort()
	var vm := vs / N
	return {"P": (esum / N).length(), "M": (msum / N).length(), "nnd_mean": _mean(nnd), "nnd_min": sorted[0],
		"nnd_med": sorted[N / 2], "iid": iid / (N * (N - 1)), "speed": vm,
		"speed_cv": sqrt(maxf(vs2 / N - vm * vm, 0.0)) / maxf(vm, 1e-9), "close": float(close) / N,
		"startled": _count_burst(), "centre_m": origin + c * bl}

func _mean(a: PackedFloat64Array) -> float:
	var sm := 0.0
	for q in a: sm += q
	return sm / maxf(a.size(), 1)

func _count_burst() -> int:
	var n := 0
	for q in s:
		if q > 0.5: n += 1
	return n

## Biggest group of fish linked by gaps under `link` BL, as a share of the school (cohesion; 1 = one school).
func largest_group(link: float = 3.0) -> float:
	var seen := PackedByteArray(); seen.resize(N)
	var best := 0
	for i0 in N:
		if seen[i0]: continue
		var stack := [i0]; seen[i0] = 1
		var n := 0
		while not stack.is_empty():
			var i: int = stack.pop_back(); n += 1
			for j in N:
				if not seen[j] and x[i].distance_to(x[j]) < link:
					seen[j] = 1; stack.append(j)
		best = maxi(best, n)
	return float(best) / maxf(N, 1)
