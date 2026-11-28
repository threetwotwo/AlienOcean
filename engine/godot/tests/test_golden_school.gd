## Port check: core/m31_school/school_sim.gd must reproduce the Nov 1 schooling paper's numpy prototype step for step
## (tests/golden/school_trace.py: school.py's ao step, y up, shared random stream, D1). 60 fish, 90 steps (3 s), a startle
## planted on the middle fish at step 20 so the cascade runs through the school.
## Run: godot --headless --path . --script res://tests/test_golden_school.gd   (exit 0 = match)
extends SceneTree

const Sim := preload("res://core/m31_school/school_sim.gd")
const Species := preload("res://core/m31_school/school_species.gd")

func _initialize() -> void:
	var g: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/golden/school_v1.json"))
	var gp: Dictionary = g.params
	var p := Species.params("open", 1.0, {"search_R": 60.0, "d0_scared_k": 1.0, "pitch_max_deg": 90.0,
		"abs_depth": [gp.depth[0], gp.depth[1]], "env_period": 1000000, "overlap_pairs": false, "overlap": 0.3, "burst_hops": -1})
	for key in ["v0", "d0", "la", "lal", "g_att", "g_ali", "eps", "tau_v", "k_speed", "k_turn", "wmax", "noise", "vmin", "fov", "g_far", "alert_T", "alert_far", "alert_ali"]:
		p[key] = float(gp[key])
	p.k = int(gp.k); p.n_far = int(gp.n_far)
	var s = Sim.new()
	s.setup(p, int(g.N), int(g.seed), 1.0, Vector3.ZERO)
	var ini: Dictionary = g.init
	s.load_state(ini.x, ini.e, ini.v, ini.L, ini.v0, ini.phase)
	var fi := 0
	var worst_x := 0.0
	var worst_e := 0.0
	var trig_ok := true
	var late_off := 0
	var late_worst := 0.0
	var frames: Array = g.frames
	for i in int(g.steps):
		if i == int(g.poke_at): s.poke(int(g.poke_i))
		s.step({})
		if fi < frames.size() and int(frames[fi].step) == i + 1:
			var f: Dictionary = frames[fi]; fi += 1
			var wx := 0.0
			var we := 0.0
			var off := 0
			for j in s.N:
				var dj: float = s.x[j].distance_to(Vector3(f.x[j][0], f.x[j][1], f.x[j][2]))
				if dj > 1e-3: off += 1
				wx = maxf(wx, dj)
				we = maxf(we, s.e[j].distance_to(Vector3(f.e[j][0], f.e[j][1], f.e[j][2])))
			var burst := 0
			for q in s.s: if q > 0.5: burst += 1
			if burst != int(f.burst): trig_ok = false
			print("  step %3d: worst position %.7f BL, heading %.7f, bursting %d (numpy %d), fish off by > 1 mBL: %d" % [i + 1, wx, we, burst, int(f.burst), off])
			if i + 1 <= 40:
				worst_x = maxf(worst_x, wx); worst_e = maxf(worst_e, we)
			else:
				late_off = maxi(late_off, off); late_worst = maxf(late_worst, wx)
	# exact through the startle wave (steps 1-40); after it Godot's 32-bit vectors against numpy's 64-bit floats let a
	# few fish take another discrete branch (overlap guard, neighbour order): bounded, under 10 % of the school and 0.1 BL
	var ok: bool = worst_x < 1e-3 and worst_e < 1e-3 and trig_ok and late_off <= s.N / 10 and late_worst < 0.1
	print("%s  M31 port vs numpy school.py: steps 1-40 worst %.7f BL, heading %.7f; steps 41-90 %d fish apart, worst %.3f BL; startle counts %s" % ["PASS" if ok else "FAIL", worst_x, worst_e, late_off, late_worst, "match" if trig_ok else "DIFFER"])
	quit(0 if ok else 1)
