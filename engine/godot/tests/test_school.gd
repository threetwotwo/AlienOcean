## M31 schools: stress harness on real Jolt physics (headless). Pass checks S2-S10 (plans: engine/godot/core/m31_school/PASS.md).
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/test_school.gd -- [--out f.json] [--monkey 3] [--monkey-secs 40] [--fault] [--only S3]
## Scripted cases + random (monkey) runs; invariants every step: no fish inside rock (S3), no explosion (S4), no
## clumping (S5); case checks: agreement with the paper's numbers (S2), cohesion (S6), 30/60/120 fps give the same school
## (S7), a calm girl parts the school without a startle (S8), a rush sets off the startle wave and the school regroups (S9),
## cost (S10). --fault plants a known bug (the swept guard off and rock push off) and S3 must FAIL.
extends SceneTree

# S16 bars (set 28 Nov from the measured raw vs zero-twitch drawing; see PASS.md)
const JERK_MAX := 40.0
const BEND_STEP_MAX := 0.06
const FLIPS_MAX := 6.0
const LAG_MAX := 20.0

const Worlds := preload("res://tests/harness/test_worlds.gd")
const Species := preload("res://core/m31_school/school_species.gd")

var out_path := ""
var monkey_runs := 0
var monkey_from := 0
var diag := false
var monkey_secs := 40.0
var fault := false
var only := ""
var results: Array = []
var rng := RandomNumberGenerator.new()
var boxes: Array = []     # [Transform3D, half size] of every rock in the current world
var world: Node3D

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		match a[i]:
			"--out": out_path = a[i + 1]
			"--monkey": monkey_runs = int(a[i + 1])
			"--monkey-secs": monkey_secs = float(a[i + 1])
			"--fault": fault = true
			"--only": only = a[i + 1]
			"--monkey-from": monkey_from = int(a[i + 1])
			"--diag": diag = true
	Engine.physics_ticks_per_second = 60
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _want(id: String) -> bool:
	return only == "" or only == id

# ---------------------------------------------------------------- worlds
func _new_world() -> void:
	if world: world.queue_free()
	world = Node3D.new(); root.add_child(world)
	boxes.clear()
	_rock(Vector3(0, -20.25, 0), Vector3(400, 0.5, 400))       # the sea floor (y = -20)

func _rock(c: Vector3, size: Vector3, rot_y := 0.0) -> void:
	var sb := StaticBody3D.new(); var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = size
	cs.shape = bs; sb.add_child(cs); sb.transform = Transform3D(Basis(Vector3.UP, rot_y), c); world.add_child(sb)
	boxes.append([sb.transform, size * 0.5])

func _inside_rock(p: Vector3) -> bool:
	for b in boxes:
		var l: Vector3 = (b[0] as Transform3D).affine_inverse() * p
		var h: Vector3 = b[1]
		if absf(l.x) < h.x and absf(l.y) < h.y and absf(l.z) < h.z: return true
	return false

func _school(id: String, n: int, sd: int, home: Vector3, tether: bool, threaded := false) -> FishSchool:
	var s := FishSchool.new()
	s.species_id = id; s.count = n; s.seed_ = sd; s.home = home; s.tethered = tether; s.threaded = threaded
	s.use_asset = false        # checks run on the record's body length (assets are gitignored); films use the export
	s.process_mode = Node.PROCESS_MODE_DISABLED
	world.add_child(s)
	if fault:
		s.sim.p.rock_push = 0.0
		s.seg_fn = func(_a, _b): return {}
	return s

## Physics needs a frame to see new bodies.
func _settle_physics() -> void:
	await physics_frame
	await physics_frame

# ---------------------------------------------------------------- one run with invariants
## Advances the school(s) for secs at frame delta dt; actor_fn(t) -> Array of actors (or null). Returns the run record.
func _run_school(s: FishSchool, secs: float, dt: float, actor_fn = null, watch := {}) -> Dictionary:
	var rec := {"inside": 0, "max_speed": 0.0, "nan": 0, "nnd_min": INF, "close_max": 0.0, "max_extent": 0.0,
		"main_ms_max": 0.0, "main_list": [], "wait_sum": 0.0, "frames": 0, "step_ms_sum": 0.0, "steps": 0, "startled_max": 0, "series": []}
	var bl: float = s.sim.bl
	var frames := int(round(secs / dt))
	var t0: float = s.sim.t
	for f in frames:
		if actor_fn != null: s.actors = actor_fn.call(s.sim.t - t0)
		var st0: int = s.sim.steps
		s.advance(dt)
		if s.threaded: s.sync()
		rec.main_ms_max = maxf(rec.main_ms_max, s.main_ms)
		rec.main_list.append(s.main_ms)
		rec.wait_sum += s.wait_ms; rec.frames += 1
		if s.sim.steps == st0: continue
		rec.steps += 1; rec.step_ms_sum += s.step_ms
		var sim = s.sim
		var c := Vector3.ZERO
		for i in sim.N:
			var wp: Vector3 = sim.origin + sim.x[i] * bl
			if not wp.is_finite(): rec.nan += 1; continue
			if _inside_rock(wp): rec.inside += 1
			rec.max_speed = maxf(rec.max_speed, sim.v[i])
			c += sim.x[i]
		c /= sim.N
		for i in sim.N: rec.max_extent = maxf(rec.max_extent, sim.x[i].distance_to(c))
		var st := 0
		for q in sim.s: if q > 0.5: st += 1
		rec.startled_max = maxi(rec.startled_max, st)
		if sim.steps % 15 == 0:
			var m: Dictionary = sim.metrics()
			rec.nnd_min = minf(rec.nnd_min, m.nnd_min)
			rec.close_max = maxf(rec.close_max, m.close)
			if diag and m.close > 0.03: _diag_close(sim, actor_fn.call(sim.t - t0) if actor_fn != null else [])
			if watch.get("series", false):
				rec.series.append([snappedf(sim.t - t0, 0.01), snappedf(m.P, 0.001), snappedf(m.nnd_mean, 0.001), st, snappedf(sim.largest_group(watch.get("link", 3.0)), 0.001)])
	rec["step_ms"] = rec.step_ms_sum / maxf(rec.steps, 1)
	var ml: Array = rec.main_list; ml.sort()
	rec["main_ms_p95"] = ml[int(ml.size() * 0.95)] if ml.size() > 0 else 0.0
	rec["main_ms_mean"] = (ml.reduce(func(a, b): return a + b, 0.0) / ml.size()) if ml.size() > 0 else 0.0
	rec.erase("main_list")
	return rec

## Where the crowded fish are: near the girl, near rock, startled, or in open water.
func _diag_close(sim, actors) -> void:
	var drs := []; var sw := 0
	var near_actor := 0; var near_rock := 0; var startled := 0; var open := 0; var n := 0
	for i in sim.N:
		var m := INF
		for j in sim.N:
			if j != i: m = minf(m, sim.x[i].distance_to(sim.x[j]))
		if m >= 0.3: continue
		n += 1
		var wp: Vector3 = sim.origin + sim.x[i] * sim.bl
		var da := INF
		for a in actors: da = minf(da, (wp - a.pos).length() / sim.bl)
		var dr: float = sim.x[i].distance_to(sim._wall_pt[i]) if sim._wall_pt[i].is_finite() else INF
		if da < 3.0: near_actor += 1
		elif dr < 1.5:
			near_rock += 1
			drs.append(snappedf(dr, 0.01)); sw += sim._swept[i]
		elif sim.s[i] > 0.5: startled += 1
		else: open += 1
	print("DIAG t=%.1f close=%d near_actor=%d near_rock=%d startled=%d open=%d swept=%d hits=%d dr=%s" % [sim.t, n, near_actor, near_rock, startled, open, sw, sim.hits, str(drs.slice(0, 8))])

func _invariants(rec: Dictionary, p: Dictionary) -> Dictionary:
	var ok_rock: bool = rec.inside == 0
	var ok_boom: bool = rec.nan == 0 and rec.max_speed <= p.burst_v + 2.0 + 1e-6 and rec.max_extent < 60.0
	var ok_clump: bool = rec.nnd_min >= 0.2 and rec.close_max <= 0.03
	return {"S3": ok_rock, "S4": ok_boom, "S5": ok_clump}

func _add(id: String, name: String, ok: bool, detail: Dictionary) -> void:
	results.append({"id": id, "name": name, "ok": ok, "detail": detail})
	print("%s  %s %s  %s" % ["PASS" if ok else "FAIL", id, name, JSON.stringify(detail)])

# ---------------------------------------------------------------- cases
func _run() -> void:
	# S2: agreement with the paper's numbers (schoollab REF, its I3 tolerance: 10 % or two seed spreads)
	if _want("S2"):
		# open: numpy school.py itself (the code ported, S1), same start (15 BL over the floor, band 3-40 BL), seeds 1-3,
		# 20 s warm + 10 s: P 0.988, NND 0.833, 1.929 BL/s (27 Nov). schoollab's Unreal REF (P 0.965, NND 0.80) was a
		# different implementation and sits 4 % under school.py on NND.
		var REF := {"open": {"P": [0.988, 0.0015], "nnd": [0.833, 0.005], "speed": [1.929, 0.009], "N": 300, "species": "open_scad"},
			"lagoon": {"P": [0.587, 0.0896], "nnd": [1.0229, 0.0363], "speed": [0.3917, 0.0082], "N": 300, "species": "lagoon"}}
		for preset in ["open", "lagoon"]:
			var acc := {"P": 0.0, "nnd": 0.0, "speed": 0.0}
			var seeds := 3
			for sd in seeds:
				_new_world()
				await _settle_physics()
				var bl0: float = Species.params(REF[preset].species).bl_m
				var s := _school(REF[preset].species, REF[preset].N, sd + 1, Vector3(0, -20.0 + (12.0 if preset == "lagoon" else 15.0) * bl0, 0), preset == "lagoon")
				if preset == "lagoon": s.sim.p.R_home = 8.0
				await _run_school(s, 20.0, 1.0 / 30.0)    # settle
				var sums := {"P": 0.0, "nnd": 0.0, "speed": 0.0}
				for k in 10:
					await _run_school(s, 1.0, 1.0 / 30.0)
					var m: Dictionary = s.sim.metrics()
					sums.P += m.P; sums.nnd += m.nnd_mean; sums.speed += m.speed
				for key in sums: acc[key] += sums[key] / 10.0 / seeds
			var ok := true
			var det := {}
			for key in acc:
				var ref: Array = REF[preset][key]
				var tol := maxf(0.10 * ref[0], 2.0 * ref[1])
				var good: bool = absf(acc[key] - ref[0]) <= tol
				ok = ok and good
				det[key] = "%.3f (ref %.3f +- %.3f)" % [acc[key], ref[0], tol]
			_add("S2", "agreement, %s preset, 3 seeds" % preset, ok, det)
	# S3-S6: a reef of rocks across the school's path, open school roaming through
	if _want("S3") or _want("S4") or _want("S5") or _want("S6"):
		_new_world()
		for k in 9:
			_rock(Vector3(-6 + 6 * (k % 3), -16 + (k / 3) * 1.5, -6 + 6 * (k / 3)), Vector3(2.5, 8.0, 2.5), 0.3 * k)
		_rock(Vector3(0, -8, 0), Vector3(14, 1.0, 3.0))       # an overhang slab
		await _settle_physics()
		var s := _school("trevally", 160, 4, Vector3(-14, -10, 0), true)
		s.sim.p.home = Vector3(14, 0, 0) / s.sim.bl; s.sim.p.R_home = 3.0    # pulled through the reef to the far side
		var rec := await _run_school(s, 60.0, 1.0 / 60.0, null, {"series": true, "link": 3.0})
		var inv := _invariants(rec, s.sim.p)
		var lg: float = s.sim.largest_group(3.0)
		_add("S3", "no fish inside rock: trevally through a reef and under an overhang, 60 s", inv.S3, {"inside_fish_steps": rec.inside, "guard_hits_last": s.sim.hits})
		_add("S4", "no explosion", inv.S4, {"max_speed": snappedf(rec.max_speed, 0.01), "max_extent_BL": snappedf(rec.max_extent, 0.1), "nan": rec.nan})
		_add("S5", "no clumping", inv.S5, {"nnd_min": snappedf(rec.nnd_min, 0.001), "close_share_max": rec.close_max})
		_add("S6", "cohesion after the reef (largest group, gaps < 3 BL)", lg >= 0.85, {"largest_group": snappedf(lg, 0.001)})
	# S7: 30 / 60 / 120 fps give the same school (fixed-rate sim, threaded and not)
	if _want("S7"):
		# every run records its state at each step count; runs are compared step for step on the counts they share
		var runs := {}
		for thr in [false, true]:
			for rate in [30, 60, 120]:
				_new_world()
				_rock(Vector3(2, -6, 0), Vector3(2, 6, 2))
				await _settle_physics()
				var s := _school("lagoon_baitfish", 80, 9, Vector3(0, -5, 0), true, thr)
				s.actor_fn = func(tt: float) -> Array: return [{"pos": Vector3(-4 + 0.6 * tt, -5, 0), "vel": Vector3(0.6, 0, 0), "radius": 0.25, "axis": Vector3.RIGHT, "half_len": 0.55}]
				var dt: float = 1.0 / rate
				var snaps := {}
				while s.sim.steps < 302:
					s.advance(dt)
					if thr: s.sync()
					if s.sim.steps >= 298 and not snaps.has(s.sim.steps): snaps[s.sim.steps] = s.sim.x.duplicate()
				runs["%s_%d" % ["thr" if thr else "main", rate]] = snaps
		var ref: Dictionary = runs["main_60"]
		var worst := 0.0
		var compared := 0
		for key in runs:
			for st in runs[key]:
				if not ref.has(st): continue
				compared += 1
				var xs: PackedVector3Array = runs[key][st]
				for i in xs.size(): worst = maxf(worst, xs[i].distance_to(ref[st][i]))
		_add("S7", "30/60/120 fps, threaded and main thread: the same school, step for step", worst < 1e-4 and compared >= 6, {"worst_BL": worst, "compared": compared})
	# S8: the girl swims through calmly: the school parts, nobody startles, nobody inside her, it re-forms
	if _want("S8"):
		_new_world(); await _settle_physics()
		var s := _school("lagoon_baitfish", 120, 3, Vector3(0, -6, 0), true)
		await _run_school(s, 10.0, 1.0 / 30.0)
		var bl: float = s.sim.bl
		var girl_at := func(tt: float) -> Vector3: return Vector3(-5 + 0.6 * tt, -6, 0)
		var min_gap := INF
		var startled := 0
		for f in 600:     # 20 s at 30 fps: she crosses the whole school
			var gp: Vector3 = girl_at.call(f / 30.0)
			s.actors = [{"pos": gp, "vel": Vector3(0.6, 0, 0), "radius": 0.25, "axis": Vector3.RIGHT, "half_len": 0.55}]
			s.advance(1.0 / 30.0)
			for i in s.sim.N:
				var q: Vector3 = s.sim.origin + s.sim.x[i] * bl
				var cpt := gp + Vector3.RIGHT * clampf((q - gp).x, -0.55, 0.55)
				min_gap = minf(min_gap, q.distance_to(cpt) - 0.25)
			startled = maxi(startled, s.sim.metrics().startled)
		s.actors = []
		await _run_school(s, 10.0, 1.0 / 30.0)
		var lg: float = s.sim.largest_group(4.0)
		var ok: bool = startled <= s.sim.N / 20 and min_gap >= 0.9 * s.sim.p.keep_out * bl and lg >= 0.85
		_add("S8", "calm girl swims through (0.6 m/s): parts, no startle wave, nobody inside her, re-forms", ok,
			{"startled_max": startled, "min_gap_m": snappedf(min_gap, 0.001), "keep_out_m": snappedf(s.sim.p.keep_out * bl, 0.001), "largest_group_after_10s": lg})
	# S9: a rush: the startle wave crosses the school, then the alarm brings it back together
	if _want("S9"):
		# the cascade is random: five seeds, judged on the median startle share and the worst regroup
		var shares := []; var groups := []; var nmin := INF; var inv_ok := true
		for sd in [5, 6, 7, 8, 9]:
			_new_world(); await _settle_physics()
			var s := _school("trevally", 160, sd, Vector3(0, -8, 0), true)
			await _run_school(s, 10.0, 1.0 / 30.0)
			var c: Vector3 = s.sim.metrics().centre_m
			var rush := func(tt: float) -> Array:
				if tt > 3.0: return []
				return [{"pos": c + Vector3(-4.0 + 2.5 * tt, 0, 0), "vel": Vector3(2.5, 0, 0), "radius": 0.25, "axis": Vector3.RIGHT, "half_len": 0.55}]
			var rec := await _run_school(s, 3.0, 1.0 / 30.0, rush)
			shares.append(snappedf(float(rec.startled_max) / s.sim.N, 0.01))
			var rec2 := await _run_school(s, 15.0, 1.0 / 30.0)
			groups.append(snappedf(s.sim.largest_group(3.0), 0.01))
			nmin = minf(nmin, minf(rec.nnd_min, rec2.nnd_min))
			var inv := _invariants(rec, s.sim.p)
			inv_ok = inv_ok and inv.S4 and inv.S5
		var srt := shares.duplicate(); srt.sort()
		var med: float = srt[2]
		_add("S9", "rush (2.5 m/s), 5 seeds: startle wave reaches the school (median), all regroup within 15 s", med >= 0.3 and groups.min() >= 0.85 and inv_ok,
			{"startled_share": shares, "median": med, "largest_group_15s": groups, "nnd_min": snappedf(nmin, 0.001)})
	# S11: Thalassa calm-diver circling: a trevally school near a girl hovering still circles her at a respectful distance
	if _want("S11"):
		_new_world(); await _settle_physics()
		var s := _school("trevally", 160, 4, Vector3(0, -10, 0), true)
		await _run_school(s, 8.0, 1.0 / 30.0)
		var c: Vector3 = s.sim.metrics().centre_m
		var gp := c + Vector3(6.0, 0, 0)
		var still := func(_tt: float) -> Array: return [{"pos": gp, "vel": Vector3.ZERO, "radius": 0.25, "axis": Vector3.RIGHT, "half_len": 0.55}]
		var rec := await _run_school(s, 25.0, 1.0 / 30.0, still)
		var sim = s.sim
		var mill := 0.0; var band := 0; var dmin := INF
		for i in sim.N:
			var wp: Vector3 = sim.origin + sim.x[i] * sim.bl
			var r := Vector3(wp.x - gp.x, 0, wp.z - gp.z)
			var dd := r.length(); dmin = minf(dmin, (wp - gp).length())
			if dd > 2.6 and dd < 12.5: band += 1
			mill += r.normalized().cross(Vector3(sim.e[i].x, 0, sim.e[i].z).normalized()).y
		mill = absf(mill) / sim.N
		var inv := _invariants(rec, sim.p)
		_add("S11", "calm girl hovering (Thalassa circling): trevally circle her in the 2.6-12.5 m band, nobody startled or inside her", mill >= 0.5 and float(band) / sim.N >= 0.7 and rec.startled_max <= int(0.05 * sim.N) and dmin >= 0.6 and inv.S4 and inv.S5,
			{"mill": snappedf(mill, 0.01), "in_band": snappedf(float(band) / sim.N, 0.01), "min_dist_m": snappedf(dmin, 0.01), "startled_max": rec.startled_max})
	# S12: Thalassa silent observation: the school gathers on a viewing ring round the observing girl
	if _want("S12"):
		_new_world(); await _settle_physics()
		var s := _school("trevally", 160, 6, Vector3(0, -10, 0), true)
		await _run_school(s, 5.0, 1.0 / 30.0)
		var gp: Vector3 = s.sim.metrics().centre_m + Vector3(10.0, 0, 0)
		var obs := func(_tt: float) -> Array: return [{"pos": gp, "vel": Vector3.ZERO, "radius": 0.25, "kind": "observer", "ring_m": 4.8}]
		var rec := await _run_school(s, 30.0, 1.0 / 30.0, obs)
		var sim = s.sim
		var on_ring := 0
		for i in sim.N:
			var wp: Vector3 = sim.origin + sim.x[i] * sim.bl
			var dd := Vector2(wp.x - gp.x, wp.z - gp.z).length()
			if dd > 4.8 * 0.6 and dd < 4.8 * 1.4: on_ring += 1
		var inv := _invariants(rec, sim.p)
		_add("S12", "silent observation (Thalassa): the school gathers on the viewing ring (4.8 m) round her", float(on_ring) / sim.N >= 0.7 and inv.S4 and inv.S5,
			{"on_ring": snappedf(float(on_ring) / sim.N, 0.01), "nnd_min": snappedf(rec.nnd_min, 0.001), "close_max": rec.close_max})
	# S13: Thalassa ride escort: a ridden manta cruising past; nearby fish part round it and swim along in its slipstream
	if _want("S13"):
		_new_world(); await _settle_physics()
		var s := _school("trevally", 160, 8, Vector3(0, -10, 0), false)
		await _run_school(s, 5.0, 1.0 / 30.0)
		var c0: Vector3 = s.sim.metrics().centre_m
		var mv := Vector3(1.2, 0, 0)
		var ride := func(tt: float) -> Array: return [{"pos": c0 + Vector3(-3.0, 0.5, 0) + mv * tt, "vel": mv, "radius": 1.2, "kind": "ride", "part_m": 3.8}]
		var rec := await _run_school(s, 20.0, 1.0 / 30.0, ride)
		var sim = s.sim
		var mp: Vector3 = c0 + Vector3(-3.0, 0.5, 0) + mv * 20.0
		var near := 0; var follow := 0.0; var dmin := INF
		for i in sim.N:
			var wp: Vector3 = sim.origin + sim.x[i] * sim.bl
			var dd := wp.distance_to(mp); dmin = minf(dmin, dd)
			if dd < 14.5:
				near += 1; follow += sim.e[i].dot(mv.normalized())
		follow = follow / maxf(near, 1)
		var inv := _invariants(rec, sim.p)
		_add("S13", "ride escort (Thalassa): fish keep with the ridden manta (within 14.5 m, heading its way), none inside its body or startled", float(near) / sim.N >= 0.7 and follow >= 0.7 and dmin >= 1.2 and rec.startled_max <= int(0.05 * sim.N) and inv.S4 and inv.S5,
			{"near": snappedf(float(near) / sim.N, 0.01), "heading_with_it": snappedf(follow, 0.01), "min_dist_m": snappedf(dmin, 0.01), "startled_max": rec.startled_max})
	# S14: the creature maker's export in the school (when its gitignored glbs are present; else reported as skipped)
	if _want("S14"):
		var CM = load("res://fish/creature_school_mesh.gd")
		var aid: String = Species.params("trevally").get("asset", "")
		if not CM.available(aid):
			print("SKIP  S14 export %s not present (assets are gitignored; fetch per assets.lock.json)" % aid)
		else:
			var a: Dictionary = CM.load_species(aid)
			var ok: bool = a.meshes.size() == 3
			var snout := INF; var tail := -INF
			var m0: ArrayMesh = a.meshes[0]
			var vs: PackedVector3Array = m0.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			for q in vs: snout = minf(snout, 0.5 - q.x); tail = maxf(tail, 0.5 - q.x)
			# beat: the measured (U, beat_Hz) of each r2 envelope, and the record's beat f at its cruise U_rec
			var sw: Dictionary = a.swim
			var beat_err := 0.0
			for e in sw.wave.get("envelopes_by_speed", []): beat_err = maxf(beat_err, absf(CM.beat_hz(sw, float(e.U_BLps)) - float(e.beat_Hz)))
			var f_rec: float = CM.beat_hz(sw, float(sw.steady.U_rec_BLps))
			beat_err = maxf(beat_err, absf(f_rec - float(sw.record_motion.f)))
			# burst-and-coast below U_min (r2 rule): a slow fish (v = U_min / 2) beats then glides, about half the time,
			# on the U_min table; a cruising fish (2 BL/s) beats all the time on its own speed's table
			var nd := FishSchool.new(); nd.asset = a; nd._draw_dt = 1.0 / 60.0
			nd._d_s = PackedFloat64Array([0.0, 0.0]); nd._swim_ph = PackedFloat64Array([0.0, 0.0])
			nd._bc_t = PackedFloat64Array([0.0, 0.0]); nd._bc_k = PackedFloat64Array([1.0, 1.0]); nd.look_coast = PackedByteArray([0, 0])
			var um: float = CM.u_min(sw)
			var glide := [0, 0]; var ub := [0.0, 0.0]; var steps := 600
			for t in steps:
				for j in 2:
					ub[j] = nd._swim_drive(j, [0.5 * um, 2.0][j])
					if nd._bc_k[j] < 0.1: glide[j] += 1
			nd.free()
			var g0 := float(glide[0]) / steps; var g1 := float(glide[1]) / steps
			ok = ok and absf(a.bl_m - float(sw.body_length_m)) < 1e-4 and absf(snout) < 0.01 and absf(tail - 1.0) < 0.01 and beat_err < 1e-3
			ok = ok and g0 >= 0.25 and g0 <= 0.6 and g1 == 0.0 and absf(ub[0] - um) < 1e-6 and absf(ub[1] - 2.0) < 1e-6
			_add("S14", "maker export in the school: 3 LODs, body length from the glb, snout at s 0 and tail at s 1, beat at each envelope speed and the record's cruise; below U_min it beats then glides (r2)", ok,
				{"bl_m": a.bl_m, "body_s_range": [snappedf(snout, 0.001), snappedf(tail, 0.001)], "beat_err_Hz": snappedf(beat_err, 0.0001), "f_at_U_rec": snappedf(f_rec, 0.0001),
				 "glide_frac_slow": snappedf(g0, 0.01), "glide_frac_cruise": g1, "surfaces": [a.meshes[0].get_surface_count(), a.meshes[1].get_surface_count(), a.meshes[2].get_surface_count()]})
	# S10: cost (cloud CPU; the Mac's P-cores are faster)
	# S15: drawn upright: the drawn frame (FishSchool.fish_basis) puts the fish's back up for every heading and pitch up
	# to the species cap, rolls into the turn by no more than the bank cap, and stays right-handed (not mirrored).
	# The headless renderer keeps no MultiMesh transforms, so the frame function itself is checked. Caught upside-down
	# schools (28 Nov).
	if _want("S15"):
		var worst_up := 1.0; var worst_hand := 1.0; var worst_head := 1.0; var roll_ok := true
		for a in 24:
			for pd in [-50.0, -20.0, 0.0, 20.0, 50.0]:
				var yaw := TAU * a / 24.0; var pr := deg_to_rad(pd)
				var fwd := Vector3(cos(pr) * cos(yaw), sin(pr), -cos(pr) * sin(yaw))
				var b0: Basis = FishSchool.fish_basis(fwd, 0.0)
				worst_up = minf(worst_up, b0.y.dot(Vector3.UP) / cos(pr))
				worst_hand = minf(worst_hand, b0.x.cross(b0.y).dot(b0.z))
				worst_head = minf(worst_head, b0.x.dot(fwd))
				# a left turn (positive bank) rolls the back toward the fish's left; the fish's left is -z in the mesh
				var bl: Basis = FishSchool.fish_basis(fwd, 0.3)
				var left: Vector3 = -b0.z
				roll_ok = roll_ok and bl.y.dot(left) > 0.25 and bl.y.dot(b0.y) > cos(0.3) - 1e-3
		_add("S15", "fish drawn upright for every heading and pitch, right-handed (not mirrored), rolling into the turn", worst_up > 0.999 and worst_hand > 0.999 and worst_head > 0.999 and roll_ok,
			{"worst_up": snappedf(worst_up, 0.0001), "handedness": snappedf(worst_hand, 0.0001), "heading": snappedf(worst_head, 0.0001), "roll_into_turn": roll_ok})
	# S16: no twitching (Gary 28 Nov: "trevally school swims funny, twitching around"). The drawn fish (what the viewer
	# sees: heading, body bend, swim table, amplitude, steady/phrase mode) over 10 s at 60 fps, 120 trevally, drawn raw
	# (the old look) and with the zero-twitch drawing. Measured per fish per frame: turn jerk (change of drawn turn rate,
	# rad/s^2), bend change, swim-speed change; mode flips per fish-minute; and how far the drawn heading trails the sim.
	if _want("S16"):
		var res := {}
		for smooth in [false, true]:
			_new_world(); await _settle_physics()
			# built here, not with _school(): this check draws the export when present (the swim phrase logic is the export's)
			var s := FishSchool.new()
			s.species_id = "trevally"; s.count = 120; s.seed_ = 7; s.home = Vector3(0, -8, 0); s.tethered = true; s.threaded = true
			s.process_mode = Node.PROCESS_MODE_DISABLED; s.smooth_look = smooth
			world.add_child(s)
			var dt := 1.0 / 60.0
			var n: int = s.sim.N
			var prev_w := PackedFloat64Array(); prev_w.resize(n)
			var prev_f := PackedVector3Array(); prev_f.resize(n)
			var prev_b := PackedFloat64Array(); prev_b.resize(n)
			var prev_u := PackedFloat64Array(); prev_u.resize(n)
			var prev_c := PackedByteArray(); prev_c.resize(n)
			var jerk := []; var dbend := []; var du := []; var lag := []; var flips := 0
			var frames := 600
			for fr in frames:
				s.advance(dt)
				if s.threaded: s.sync()
				for i in n:
					var f: Vector3 = s.look_fwd[i]
					if fr >= 2:
						var hp := Vector2(prev_f[i].x, prev_f[i].z); var hf := Vector2(f.x, f.z)
						var w := -hp.angle_to(hf) / dt if hp.length() > 1e-4 and hf.length() > 1e-4 else 0.0
						if fr >= 3:
							jerk.append(absf(w - prev_w[i]) / dt)
							dbend.append(absf(s.look_bend[i] - prev_b[i]))
							du.append(absf(s.look_u[i] - prev_u[i]) / dt)
							if s.look_coast[i] != prev_c[i]: flips += 1
						prev_w[i] = w
						var simf: Vector3 = s.sim.e[i]
						lag.append(rad_to_deg(f.angle_to(simf.normalized())))
					prev_f[i] = f; prev_b[i] = s.look_bend[i]; prev_u[i] = s.look_u[i]; prev_c[i] = s.look_coast[i]
			jerk.sort(); dbend.sort(); du.sort(); lag.sort()
			var q := func(a: Array, p: float) -> float: return a[int(p * (a.size() - 1))] if a.size() > 0 else 0.0
			res["smooth" if smooth else "raw"] = {"turn_jerk_p95": snappedf(q.call(jerk, 0.95), 0.1), "turn_jerk_p50": snappedf(q.call(jerk, 0.5), 0.1),
				"bend_step_p95": snappedf(q.call(dbend, 0.95), 0.0001), "swim_u_rate_p95": snappedf(q.call(du, 0.95), 0.01),
				"mode_flips_per_fish_min": snappedf(flips / float(n) / (frames * dt / 60.0), 0.1), "heading_lag_deg_p95": snappedf(q.call(lag, 0.95), 0.1),
				"export": not s.asset.is_empty()}
			s.queue_free(); await process_frame
		var sm: Dictionary = res.smooth; var rw: Dictionary = res.raw
		var ok: bool = sm.turn_jerk_p95 <= JERK_MAX and sm.bend_step_p95 <= BEND_STEP_MAX and sm.mode_flips_per_fish_min <= FLIPS_MAX and sm.heading_lag_deg_p95 <= LAG_MAX
		_add("S16", "no twitching: drawn turn jerk p95 <= %.0f rad/s^2, bend step p95 <= %.3f, <= %.0f mode flips per fish-minute, drawn heading within %.0f deg of the sim (p95)" % [JERK_MAX, BEND_STEP_MAX, FLIPS_MAX, LAG_MAX], ok, res)
	if _want("S10"):
		_new_world(); await _settle_physics()
		var s := _school("lagoon_baitfish", 120, 2, Vector3(0, -6, 0), true, true)
		var cam := Camera3D.new(); world.add_child(cam); cam.position = Vector3(0, -6, 6)
		var rec := await _run_school(s, 10.0, 1.0 / 60.0)
		_add("S10", "cost, 120 fish (cloud CPU): worker step <= 6 ms, main thread mean <= 0.8 ms, p95 <= 1.5 ms a frame", rec.step_ms <= 6.0 and rec.main_ms_mean <= 0.8 and rec.main_ms_p95 <= 1.5,
			{"step_ms_mean": snappedf(rec.step_ms, 0.01), "main_ms_mean": snappedf(rec.main_ms_mean, 0.01), "main_ms_p95": snappedf(rec.main_ms_p95, 0.01), "main_ms_max": snappedf(rec.main_ms_max, 0.01), "wait_ms_mean_headless": snappedf(rec.wait_sum / maxf(rec.frames, 1), 0.01)})
	# monkey runs: random reefs, species, actor paths, frame rates; invariants S3-S5 throughout
	for mrun in range(monkey_from, monkey_from + monkey_runs):
		rng.seed = 1000 + mrun
		_new_world()
		for k in rng.randi_range(4, 14):
			_rock(Vector3(rng.randf_range(-15, 15), rng.randf_range(-19, -8), rng.randf_range(-15, 15)), Vector3(rng.randf_range(1, 5), rng.randf_range(1, 9), rng.randf_range(1, 5)), rng.randf() * TAU)
		await _settle_physics()
		var ids := Species.species_ids()
		var sid: String = ids[rng.randi() % ids.size()]
		var home := Vector3(rng.randf_range(-6, 6), rng.randf_range(-12, -6), rng.randf_range(-6, 6))
		while _inside_rock(home): home.y += 1.0
		var s := _school(sid, rng.randi_range(40, 200), mrun + 1, home, rng.randf() < 0.6, rng.randf() < 0.5)
		var rate: int = [30, 60, 120][rng.randi() % 3]
		var a0 := home + Vector3(rng.randf_range(-8, 8), rng.randf_range(-3, 3), rng.randf_range(-8, 8))
		var av := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1)).normalized() * rng.randf_range(0.2, 3.0)
		var actor := func(tt: float) -> Array:
			var ph := fmod(tt, 12.0)
			return [{"pos": a0 + av * (ph - 6.0), "vel": av, "radius": 0.25, "axis": av.normalized(), "half_len": 0.55}]
		var rec := await _run_school(s, monkey_secs, 1.0 / rate, actor)
		var inv := _invariants(rec, s.sim.p)
		_add("M%d" % mrun, "monkey %s n=%d %d fps %s" % [sid, s.sim.N, rate, "threaded" if s.threaded else "main"], inv.S3 and inv.S4 and inv.S5,
			{"inside": rec.inside, "max_speed": snappedf(rec.max_speed, 0.01), "nnd_min": snappedf(rec.nnd_min, 0.001), "close_max": rec.close_max, "extent": snappedf(rec.max_extent, 0.1)})
	var all_ok := true
	for r in results: all_ok = all_ok and r.ok
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE); f.store_string(JSON.stringify({"results": results, "fault": fault}, "  ")); f.close()
	print("M31 schools: %s (%d checks)" % ["ALL PASS" if all_ok else "FAILURES", results.size()])
	quit(0 if all_ok else 1)
