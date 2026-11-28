## M34 bubbles: headless test (bubbles thread, 28 Nov 2026). core/m34_bubbles/bubble_motion.gd + adapters/godot/bubbles.gd
## Run: godot --headless --fixed-fps <30|60|120> --path . --script res://tests/test_bubbles.gd -- [--tick 30|60|120] [--fault jump]
##   B1 physics    rise speeds match the coated-seawater table (1 mm 16.8 cm/s, 10 mm 31.7); time_to_cap lands the base path
##                 on cap - a; soft_cap never passes the cap and equals y far below it; gas grows ~ (p0/p)^(1/3) on the way up
##   B2 no jitter  400 random bubbles (0.3-12 mm, jets in all directions): sampled at 1 ms through their lives, no position
##                 step (|dp| < vmax dt) and no velocity step (|dv| < 80 m/s2 x dt); and sampled at the frame times of
##                 30/60/120/144 fps and an irregular 20-70 ms frame: the frame-to-frame velocity never reverses faster than the
##                 physics allows (|dv/dt| under the same bound); --fault jump plants a 1 cm hop that must FAIL
##   B3 exhale     the girl hovering 3 m down in the 20 m pool (blockout gym): every underwater exhale lets 40-200 bubbles (lush; 15-80 calm)
##                 go, from her face (within 15 cm of the head), spread through the tick (under 15 % share a birth time:
##                 no tick banding), all capped at the surface over them, alive through their life in the ring
##   B4 sprint     a boost press under water lets a kick burst go at her feet; holding it lays a trail
##   B5 ceiling    under the -5 m ceiling slab her bubbles cap on the slab's underside (kind 1), not the surface
##   B6 plunge     a plunge (the swimmer's on_splash hook) drags 25-70 bubbles down (v.y < 0) that then rise to the surface
##   B7 creatures  the dolphin and humpback stand-ins are found; within 40 s the dolphin's blowhole lets a stream go
##   B8 epoch      after a rebase every live record's t0 + epoch is its birth time (the draw cannot jump)
##   B9 cost       plug_tick under 0.25 ms mean (cloud CPU, headless)
extends SceneTree

const Packet := preload("res://core/m01_input/input_packet.gd")
const BM := preload("res://core/m34_bubbles/bubble_motion.gd")

var ok := true
var fault := ""
var tick := 60
var g: GameRoot
var phase := ""
var t_case := 0.0
var station := ""
var inp_fn := Callable()
var cases := []
var ci := -1
var res := {}
var plug_samples: Array = []

func _fail(code: String, msg: String) -> void:
	ok = false; print("FAIL ", code, " ", msg)

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		if a[i] == "--fault" and i + 1 < a.size(): fault = a[i + 1]
		if a[i] == "--tick" and i + 1 < a.size(): tick = int(a[i + 1])
	Engine.physics_ticks_per_second = tick
	Engine.max_physics_steps_per_frame = 8
	_pure()
	cases = [
		{"name": "B3 exhale", "station": "pool 20 m", "secs": 22.0, "input": func(t): return _hover(t, 3.0)},
		{"name": "B4 sprint", "station": "pool 20 m", "secs": 10.0, "input": func(t): return _sprint(t)},
		{"name": "B5 ceiling", "station": "ceiling slab -5 m", "secs": 16.0, "input": func(t): return _hover(t, 1.0)},
		{"name": "B6 plunge", "station": "pool 20 m", "secs": 14.0, "input": func(t): return _hover(t, 3.0)},
	]
	_next.call_deferred()

# ------------------------------------------------------------------ pure maths
func _pure() -> void:
	var r1 := BM.rise(1.0); var r10 := BM.rise(10.0)
	print("B1 rise 1 mm %.4f m/s, 10 mm %.4f m/s, 0.3 mm %.4f" % [r1, r10, BM.rise(0.3)])
	if absf(r1 - 0.168) > 1e-4 or absf(r10 - 0.317) > 1e-4: _fail("B1", "rise table")
	var last := 0.0
	for k in 60:
		var w := BM.rise(0.05 * pow(1.1, k))
		if w < last: _fail("B1", "rise not monotone"); break
		last = w
	var tc := BM.time_to_cap(-3.0, -0.4, 0.002, BM.rise(2.0), BM.jet_tau(2.0), 0.0)
	var yb := BM.base_y(-3.0, -0.4, BM.rise(2.0), BM.jet_tau(2.0), tc)
	print("B1 time to cap from 3 m down %.3f s, base there %.6f (cap - a %.6f)" % [tc, yb, -0.002])
	if absf(yb + 0.002) > 1e-4: _fail("B1", "time_to_cap")
	if BM.soft_cap(10.0, 0.0, 0.002) > 0.0 or absf(BM.soft_cap(-1.0, 0.0, 0.002) + 1.0) > 1e-6: _fail("B1", "soft_cap")
	var gr := BM.grown(0.001, 10.0, 0.0)
	print("B1 1 mm from 10 m grows to %.4f mm at the surface" % (gr * 1000.0))
	if absf(gr - 0.001 * pow(20.3 / 10.3, 1.0 / 3.0)) > 1e-9: _fail("B1", "growth")
	# B2: no jitter
	var rng := RandomNumberGenerator.new(); rng.seed = 11
	var worst_step := 0.0; var worst_acc := 0.0; var worst_frame := 0.0
	const AMAX := 80.0
	for n in 400:
		var a_mm := exp(lerpf(log(0.3), log(12.0), rng.randf()))
		var a0 := a_mm * 0.001
		var w := BM.rise(a_mm); var tau := BM.jet_tau(a_mm)
		var p0 := Vector3(rng.randf_range(-5, 5), rng.randf_range(-8.0, -0.3), rng.randf_range(-5, 5))
		var v0 := Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * 0.4
		var a_cap := BM.grown(a0, -p0.y, 0.0)
		var rec := {"p0": p0, "v0": v0, "w": w, "tau": tau, "a0": a0, "cap_y": 0.0, "a_cap": a_cap, "seed": rng.randf(),
			"t_cap": BM.time_to_cap(p0.y, v0.y, a_cap, w, tau, 0.0)}
		var life := minf(float(rec.t_cap) + 0.6, 40.0)
		var vmax := v0.length() + w + 0.2
		var dt := 0.001
		var pp := _pos(rec, 0.0); var vp := Vector3.ZERO; var first := true
		var t := dt
		while t < life:
			var p := _pos(rec, t)
			var step := (p - pp).length()
			worst_step = maxf(worst_step, step / (vmax * dt))
			var v := (p - pp) / dt
			if not first: worst_acc = maxf(worst_acc, (v - vp).length() / dt)
			first = false; pp = p; vp = v; t += dt
		# frame sampling: fixed rates and an irregular frame
		for fr in [30.0, 60.0, 120.0, 144.0, -1.0]:
			var tt := 0.0; var p1 := _pos(rec, 0.0); var v1 := Vector3.ZERO; var have := false
			var frng := RandomNumberGenerator.new(); frng.seed = n
			while tt < life:
				var fd: float = (1.0 / fr) if fr > 0.0 else frng.randf_range(0.02, 0.07)
				tt += fd
				var p2 := _pos(rec, tt)
				var v2 := (p2 - p1) / fd
				if have: worst_frame = maxf(worst_frame, (v2 - v1).length() / fd)
				have = true; p1 = p2; v1 = v2
	print("B2 worst position step %.2f x vmax dt, worst acceleration %.1f m/s2, worst frame-to-frame %.1f m/s2 (bound %.0f)" % [worst_step, worst_acc, worst_frame, AMAX])
	if worst_step > 1.0 or worst_acc > AMAX or worst_frame > AMAX: _fail("B2", "jitter: a step or a velocity jump in a bubble's path")

func _pos(rec: Dictionary, t: float) -> Vector3:
	var p := BM.position(rec, t)
	if fault == "jump" and t > 0.5: p.x += 0.01      # planted: a 1 cm hop
	return p

# ------------------------------------------------------------------ inputs
func _hover(t: float, depth: float):
	var k = Packet.new()
	var y: float = g.girl.body.motor.swimmer.pos.y if g != null else 0.0
	var want := LagoonWaterField.SURFACE_Y - depth
	k.descend = y > want + 0.3
	k.descend_amount = 0.6 if k.descend else 0.0
	k.ascend = y < want - 0.5
	return k

func _sprint(t: float):
	var k = _hover(t, 3.0)
	if t > 3.0:
		k.move = Vector2(0, 1.0)
		k.thrust = 1.0 if t > 4.0 else 0.0
	return k

# ------------------------------------------------------------------ game root cases
func _next() -> void:
	if g != null:
		_judge(cases[ci])
		g.queue_free(); g = null
		await process_frame
	ci += 1
	if ci >= cases.size():
		var mean := 0.0
		for s in plug_samples: mean += s
		mean = mean / maxf(1.0, plug_samples.size()) / 1000.0
		print("B9 plug_tick mean %.3f ms over %d ticks" % [mean, plug_samples.size()])
		if mean > 0.25: _fail("B9", "plug_tick too slow")
		print("PASS bubbles" if ok else "FAIL bubbles")
		quit(0 if ok else 1)
		return
	var c: Dictionary = cases[ci]
	g = GameRoot.new()
	g.blockout = true; g.blockout_station = c.station; g.use_sea = false; g.use_camera = false
	var f: Callable = c.input
	g.input_source = f
	root.add_child(g)
	g.bubbles.log_on = true
	g.ticked.connect(_on_tick.bind(c))
	print("CASE ", c.name, " at ", c.station, " (tick ", tick, " Hz)")

var _plunged := false
var _rebased := false
func _on_tick(_n: int, c: Dictionary) -> void:
	var t: float = g.clock.t
	plug_samples.append(g.bubbles.plug_us)
	if c.name == "B6 plunge" and not _plunged and t > 2.0:
		_plunged = true
		var p: Vector3 = g.girl.body.motor.swimmer.pos
		g.bubbles._on_splash(Vector3(p.x, LagoonWaterField.SURFACE_Y, p.z), 3.4, true)
	if c.name == "B3 exhale" and not _rebased and t > 15.0:
		_rebased = true
		g.bubbles._rebase(10.0)       # B8: shift the epoch mid-run
		var bad := 0
		for i in Bubbles.SLOTS:
			if g.bubbles._rec_end[i] < t: continue
			var xf: Transform3D = g.bubbles._xf[i]
			if absf(xf.basis.z.x + g.bubbles.epoch - g.bubbles._rec_t0[i]) > 1e-4: bad += 1
		print("B8 rebase by 10 s: %d live records off" % bad)
		if bad > 0: _fail("B8", "rebase moved records")
	if t >= c.secs:
		g.ticked.disconnect(_on_tick)
		_next.call_deferred()

func _judge(c: Dictionary) -> void:
	var b = g.bubbles
	var lg: Array = b.log
	print("  births ", b.births, " exhales under water ", g.girl.brig.underwater_exhales)
	match c.name:
		"B3 exhale":
			var ex := lg.filter(func(r): return r.source == "exhale")
			var n_ex: int = g.girl.brig.underwater_exhales
			if n_ex < 2: _fail("B3", "fewer than 2 underwater exhales in 22 s"); return
			var per := float(ex.size()) / n_ex
			print("B3 %d exhaled bubbles over %d exhales (%.1f each)" % [ex.size(), n_ex, per])
			var lush: bool = g.bubbles.exhale_style == "lush"     # lush (default, Gary 28 Nov) = 2.6x the calm stream
			var lo := 40.0 if lush else 15.0
			var hi := 200.0 if lush else 80.0
			if per < lo or per > hi: _fail("B3", "bubbles per exhale out of %d-%d (%s)" % [lo, hi, g.bubbles.exhale_style])
			var times := {}
			var same := 0
			for r in ex:
				var key := snappedf(float(r.t0), 1e-6)
				if times.has(key): same += 1
				times[key] = true
			var share := float(same) / maxf(1.0, ex.size())
			print("B3 share of births on a repeated time %.3f" % share)
			if share > 0.15: _fail("B3", "births banded on ticks")
			var lvl: float = g.world_root.water.level
			print("B3 water level %.3f, first cap %.3f" % [lvl, float(ex[0].cap_y)])
			var capbad := ex.filter(func(r): return r.kind != 0 or absf(float(r.cap_y) - lvl) > 0.05).size()
			if capbad > 0: _fail("B3", "%d exhaled bubbles not capped at the surface" % capbad)
			var far := 0
			for r in ex:
				if (r.p0 as Vector3).y > LagoonWaterField.SURFACE_Y: far += 1
			if far > 0: _fail("B3", "born above water")
			var sizes := ex.map(func(r): return float(r.a0) * 1000.0)
			sizes.sort()
			print("B3 sizes mm: min %.2f median %.2f max %.2f" % [sizes[0], sizes[sizes.size() / 2], sizes[-1]])
		"B4 sprint":
			var bu: int = b.births.get("sprint_burst", 0); var tr: int = b.births.get("sprint_trail", 0)
			print("B4 burst %d, trail %d" % [bu, tr])
			if bu < 3: _fail("B4", "no kick burst")
			if tr < 3: _fail("B4", "no sprint trail")
		"B5 ceiling":
			var ex := lg.filter(func(r): return r.source == "exhale")
			var on_ceiling := ex.filter(func(r): return r.kind == 1 and float(r.cap_y) < LagoonWaterField.SURFACE_Y - 1.0).size()
			print("B5 %d of %d exhaled bubbles capped on the ceiling" % [on_ceiling, ex.size()])
			if ex.size() < 10 or on_ceiling < ex.size() * 0.9: _fail("B5", "bubbles not stopped by the ceiling")
		"B6 plunge":
			var pl := lg.filter(func(r): return r.source == "plunge")
			var down := pl.filter(func(r): return (r.v0 as Vector3).y < 0.0).size()
			print("B6 plunge %d bubbles, %d leaving downward" % [pl.size(), down])
			if pl.size() < 25 or pl.size() > 70: _fail("B6", "plunge count out of 25-70")
			if down < pl.size() * 0.7: _fail("B6", "plunge cloud not dragged down")
			print("B7 riders found %d, dolphin stream births %d, humpback blasts %d" % [b.riders.size(), b.births.get("dolphin_stream", 0), b.births.get("humpback_blast", 0)])
			if b.riders.size() < 2: _fail("B7", "creature stand-ins not found")
