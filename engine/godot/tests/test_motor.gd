## M02 motor + M23 harness, headless run on real Jolt physics.
## Run (one frame rate per process, uncapped; the simulation tick stays fixed at 60 Hz):
##   godot --headless --fixed-fps 30 --path . --script res://tests/test_motor.gd -- --rate 30 --out /tmp/m02_30.json [--tick 60] [--monkey 3] [--fault] [--only T5]
## Without --fixed-fps Godot runs in real time (a full run then takes minutes): always pass it (tests/run_motor.sh does).
## Scripted cases from plans/gameplay_v2/STRESS_MATRIX.md (T1-T6) + monkey runs; invariants I1 I2 I5 I9 I10 every tick.
## --fault plants a known bug (swim sphere too small: radius 0.30 lets the 0.8 m cave through) and the run must FAIL.
extends SceneTree

const Packet := preload("res://core/m01_input/input_packet.gd")
const Body := preload("res://adapters/godot/player_body.gd")
const Env := preload("res://tests/harness/test_env.gd")
const Motor := preload("res://core/m02_motor/player_motor.gd")
const Worlds := preload("res://tests/harness/test_worlds.gd")

var rate := 60     # frames per second (pass the same number to --fixed-fps)
var tick := 60     # physics ticks per second: the fixed simulation step (project setting)
var out_path := ""
var monkey_runs := 0
var monkey_secs := 300.0
var fault := false
var only := ""
var cases: Array = []
var ci := -1
var world: Node3D
var body
var env
var t := 0.0
var warm := 0
var cur: Dictionary
var rec: Dictionary
var results: Array = []
var rng := RandomNumberGenerator.new()

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		match a[i]:
			"--rate": rate = int(a[i + 1])
			"--tick": tick = int(a[i + 1])
			"--out": out_path = a[i + 1]
			"--monkey": monkey_runs = int(a[i + 1])
			"--monkey-secs": monkey_secs = float(a[i + 1])
			"--fault": fault = true
			"--only": only = a[i + 1]
	Engine.physics_ticks_per_second = tick
	Engine.max_physics_steps_per_frame = 8
	_define_cases()
	print("M02 harness: physics=%s fps=%d tick=%d cases=%d" % [ProjectSettings.get_setting("physics/3d/physics_engine"), rate, tick, cases.size()])

# ---------------------------------------------------------------- worlds (shared: tests/harness/test_worlds.gd)
func _build(kind: String, p: Dictionary) -> void:
	world = Node3D.new()
	root.add_child(world)
	env = Worlds.build(world, kind, p)
	body = Body.new()
	if fault:
		body.swim_shape.radius = 0.30
	world.add_child(body)
	body.global_position = p.start
	if p.has("mode"):
		body.motor.mode = p.mode

# ---------------------------------------------------------------- cases
func _pk(move := Vector2.ZERO, yaw := 0.0, pitch := 0.0) -> Object:
	var k = Packet.new()
	k.move = move; k.cam_yaw = yaw; k.cam_pitch = pitch
	return k

func _case(name: String, kind: String, p: Dictionary, dur: float, input: Callable, check: Callable) -> void:
	if only != "" and not name.contains(only):
		return
	cases.append({"name": name, "kind": kind, "p": p, "dur": dur, "input": input, "check": check})

func _define_cases() -> void:
	var fwd := func(_t): return _pk(Vector2(0, 1))
	for ang in [15.0, 30.0]:
		_case("T1 ramp %d deg climbs" % ang, "ramp", {"angle": ang, "start": Vector3(0, 0.05, 4)}, 8.0, fwd,
			func(r): return [r.end.y > 6.0 * sin(deg_to_rad(ang)) - 0.3, "end y %.2f" % r.end.y])
	_case("T1 ramp 60 deg refuses (Thalassa walks up to 56 deg)", "ramp", {"angle": 60.0, "start": Vector3(0, 0.05, 4)}, 8.0, fwd,
		func(r): return [r.end.y < 1.0, "end y %.2f" % r.end.y])
	for h in [0.10, 0.30]:
		_case("T1 step %d cm climbs" % int(h * 100), "step", {"h": h, "start": Vector3(0, 0.05, 2)}, 6.0, fwd,
			func(r): return [r.end.z < -4.0 and absf(r.end.y - h) < 0.08, "end z %.2f y %.2f" % [r.end.z, r.end.y]])
	_case("T1 step 50 cm refuses", "step", {"h": 0.5, "start": Vector3(0, 0.05, 2)}, 6.0, fwd,
		func(r): return [r.end.z > -3.2, "end z %.2f" % r.end.z])
	# T2 shore: walk in until swimming, then turn round and come back out
	var shore_in_out := func(tt):
		return _pk(Vector2(0, 1), 0.0 if tt < 16.0 else PI, 0.0)
	_case("T2 shore walk-wade-swim-wade-walk", "shore", {"start": Vector3(0, 1.05, 4)}, 34.0, shore_in_out,
		func(r): return [r.visited.has("WADE") and r.visited.has("SWIM") and r.mode == "WALK" and r.end.y > 0.5,
			"visited %s end %s y %.2f" % [r.visited, r.mode, r.end.y]])
	_case("T2 shore in waves (Beaufort 4)", "shore", {"start": Vector3(0, 1.05, 4), "waves": 0.5}, 34.0, shore_in_out,
		func(r): return [r.visited.has("SWIM") and r.mode == "WALK" and r.max_trans_per_s <= 3,
			"visited %s end %s flicker %d/s" % [r.visited, r.mode, r.max_trans_per_s]])
	# T3 swim speeds
	var swim_seq := func(tt):
		var k = _pk(Vector2(0, 1))
		k.thrust = 1.0 if tt > 6.0 else 0.0
		return k
	_case("T3 cruise 3.4 then sprint 5.0 m/s", "pool", {"start": Vector3(0, -8, 0), "mode": Motor.Mode.SWIM}, 12.0, swim_seq,
		func(r): return [absf(r.speed_at[5.5] - 3.4) < 0.25 and absf(r.speed_at[11.5] - 5.0) < 0.3,
			"cruise %.2f sprint %.2f" % [r.speed_at[5.5], r.speed_at[11.5]]])
	_case("T3 dive and rise to tread", "pool", {"start": Vector3(0, -3, 0), "mode": Motor.Mode.SWIM}, 16.0,
		func(tt):
			var k = _pk(Vector2(0, 1), 0.0, -0.9 if tt < 4.0 else 0.0)
			k.ascend = tt >= 4.0
			if tt > 11.0: k.move = Vector2.ZERO; k.ascend = false   # Thalassa rise is diagonal (~2.4 m/s up): hold to the top
			return k,
		func(r): return [r.min_y < -6.0 and r.mode == "TREAD", "min y %.2f end %s" % [r.min_y, r.mode]])
	# T4 tread under waves
	_case("T4 tread holds in Beaufort 4", "pool", {"start": Vector3(0, -1.2, 0), "mode": Motor.Mode.SWIM, "waves": 0.5}, 30.0,
		func(_tt): return _pk(),
		func(r): return [r.tread_frac > 0.85 and r.max_trans_per_s <= 2, "tread %.2f flicker %d/s" % [r.tread_frac, r.max_trans_per_s]])
	# T5 caves
	var into_cave := func(_tt): return _pk(Vector2(0, 1))
	_case("T5 cave 1.0 m passes", "cave", {"s": 1.0, "start": Vector3(0, -10.42, 2), "mode": Motor.Mode.SWIM}, 14.0, into_cave,
		func(r): return [r.end.z < -26.0, "end z %.2f" % r.end.z])
	_case("T5 cave 0.8 m refuses", "cave", {"s": 0.8, "start": Vector3(0, -10.42, 2), "mode": Motor.Mode.SWIM}, 10.0, into_cave,
		func(r): return [r.end.z > -6.5, "end z %.2f" % r.end.z])
	# T6 currents (head-on: current flows +z, she swims -z)
	for c in [1.5, 3.0]:
		_case("T6 sprint into %.1f m/s current makes way" % c, "pool", {"start": Vector3(0, -8, 0), "mode": Motor.Mode.SWIM, "current": Vector3(0, 0, c)}, 10.0,
			func(_tt):
				var k = _pk(Vector2(0, 1)); k.thrust = 1.0; return k,
			func(r): return [r.end.z < -5.0, "net %.2f m in 10 s" % (-r.end.z)])
	# monkey runs: random input on the shore world (walk, wade, swim, tread, waves)
	for m in monkey_runs:
		var seed := 1000 + m
		_case("M monkey seed %d (%ds)" % [seed, int(monkey_secs)], "shore", {"start": Vector3(0, 1.05, 4), "waves": 0.5 if m % 2 == 1 else 0.0, "seed": seed}, monkey_secs,
			_monkey_input(seed), func(r): return [true, "visited %s" % [r.visited]])

func _monkey_input(seed: int) -> Callable:
	var st := {"rng": RandomNumberGenerator.new(), "next": 0.0, "k": null}
	st.rng.seed = seed
	return func(tt):
		if tt >= st.next or st.k == null:
			var g: RandomNumberGenerator = st.rng
			var k = _pk(Vector2(g.randf_range(-1, 1), g.randf_range(-1, 1)).limit_length(1.0), g.randf_range(-PI, PI), g.randf_range(-1.3, 1.3))
			k.thrust = g.randf() if g.randf() < 0.3 else 0.0
			k.ascend = g.randf() < 0.25
			k.descend = (not k.ascend) and g.randf() < 0.2
			k.jump_pressed = g.randf() < 0.1
			st.k = k
			st.next = tt + g.randf_range(0.2, 2.0)
		else:
			st.k.jump_pressed = false
		# keep her near the play area: steer back when far out
		var p: Vector3 = body.global_position
		if Vector2(p.x, p.z + 20).length() > 35:
			st.k.cam_yaw = atan2(p.x, p.z + 20)
			st.k.move = Vector2(0, 1)
		return st.k

# ---------------------------------------------------------------- run loop
func _start_next() -> bool:
	ci += 1
	if ci >= cases.size():
		return false
	cur = cases[ci]
	_build(cur.kind, cur.p)
	t = 0.0
	warm = 2
	rec = {"name": cur.name, "visited": [], "fail": [], "pen_run": 0, "max_pen_run": 0, "min_y": 1e9,
		"speed_at": {}, "trans_times": [], "tread_ticks": 0, "ticks": 0, "max_trans_per_s": 0, "last_mode": "", "ring": [], "dumped": false}
	return true

func _physics_process(delta: float) -> bool:
	if ci < 0 or cur.is_empty():
		if not _start_next():
			return _finish()
	if warm > 0:
		warm -= 1
		return false
	var k = cur.input.call(t)
	body.tick(delta, k, env, t)
	t += delta
	_invariants(delta)
	if t >= cur.dur - 1e-6:
		_end_case()
		if not _start_next():
			return _finish()
	return false

func _invariants(dt: float) -> void:
	var p: Vector3 = body.global_position
	var v: Vector3 = body.velocity
	var m: String = body.motor.mode_name()
	rec.ticks += 1
	if not rec.visited.has(m):
		rec.visited.append(m)
	# I5 counts changes of the real movement mode (Thalassa: ShoreWalking / Wading / Swimming); TREAD, SWIM and a
	# breach arc are labels inside Swimming, and a held-Cross dolphin breach chain is a feature, not flicker
	var mm: String = body.motor.mover_mode_name()
	if mm != rec.get("last_mm", "") and rec.get("last_mm", "") != "":
		rec.trans_times.append(t)
		var n := 0
		for tt in rec.trans_times:
			if t - tt <= 1.0: n += 1
		rec.max_trans_per_s = maxi(rec.max_trans_per_s, n)
	rec.last_mode = m
	rec.last_mm = mm
	var sd: Dictionary = body.last_sense
	if not sd.is_empty():
		rec.ring.append("t=%.2f %s d=%.2f floor=%s y=%.2f v=%s eye=%s tread=%.2f" % [t, m, sd.water_y - sd.feet.y, sd.on_floor, p.y, v, body.motor.swimmer.pos, body.motor.swimmer.surface_tread_blend])
		if rec.ring.size() > 40: rec.ring.pop_front()
	if m == "TREAD": rec.tread_ticks += 1
	rec.min_y = minf(rec.min_y, p.y)
	for mark in [5.5, 11.5]:
		if absf(t - mark) < dt * 0.5 + 1e-6:
			rec.speed_at[mark] = v.length()
	# I1 finite
	if not (p.is_finite() and v.is_finite()):
		_fail("I1 non-finite at t=%.3f" % t)
	# I2 penetration (more than 2 ticks in a row)
	if body.penetrating():
		rec.pen_run += 1
		rec.max_pen_run = maxi(rec.max_pen_run, rec.pen_run)
		if rec.pen_run == 3:
			_fail("I2 penetration at t=%.3f pos %s" % [t, p])
	else:
		rec.pen_run = 0
	# I9 water truth
	var s: Dictionary = body.last_sense
	if not s.is_empty():
		var d: float = s.water_y - s.feet.y
		if (m == "SWIM" or m == "TREAD") and d < -0.3:
			_fail("I9 swimming %.2f m above water at t=%.2f" % [-d, t])
		if m == "WALK" and d > body.motor.swim_enter + 0.3:
			_fail("I9 walking %.2f m deep at t=%.2f" % [d, t])
	# I10 speed cap
	var cap: float = body.motor.max_speed[body.motor.mode] + (s.current.length() if not s.is_empty() else 0.0)
	if v.length() > cap * 1.1 + 0.01:
		_fail("I10 speed %.2f over cap %.2f in %s at t=%.2f" % [v.length(), cap, m, t])
	# I5 flicker: more than 4 mode changes inside one second
	if rec.max_trans_per_s > 4:
		_fail("I5 mode flicker %d/s at t=%.2f" % [rec.max_trans_per_s, t])

func _fail(msg: String) -> void:
	if not rec.dumped:
		rec.dumped = true
		print("  first failure in %s: %s\n    " % [rec.name, msg] + "\n    ".join(rec.ring.slice(-24)))
	if rec.fail.size() < 5 and not rec.fail.has(msg):
		rec.fail.append(msg)

func _end_case() -> void:
	var p: Vector3 = body.global_position
	var r := rec.duplicate()
	r["end"] = p
	r["mode"] = body.motor.mode_name()
	r["tread_frac"] = float(rec.tread_ticks) / maxf(1.0, rec.ticks)
	r["blocked_stand"] = body.blocked_stand
	for mark in [5.5, 11.5]:
		if not r.speed_at.has(mark): r.speed_at[mark] = -1.0
	var ck: Array = cur.check.call(r)
	var ok: bool = ck[0] and rec.fail.is_empty()
	var line := "%s  %s  (%s)%s" % ["PASS" if ok else "FAIL", cur.name, ck[1], "" if rec.fail.is_empty() else "  invariants: " + "; ".join(rec.fail)]
	print(line)
	results.append({"name": cur.name, "ok": ok, "detail": ck[1], "invariants": rec.fail, "end": [p.x, p.y, p.z], "mode": r.mode,
		"transitions": body.motor.transitions})
	world.queue_free()
	world = null
	cur = {}

func _finish() -> bool:
	var npass := 0
	for r in results:
		if r.ok: npass += 1
	print("M02 harness rate %d: %d/%d PASS%s" % [rate, npass, results.size(), "  (planted fault run)" if fault else ""])
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"rate": rate, "tick": tick, "fault": fault, "results": results}, "  "))
	return true
