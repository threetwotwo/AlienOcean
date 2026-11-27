## M29 water physics on Jolt: headless cases. Run (uncapped, sim tick fixed at 60 Hz):
##   godot --headless --fixed-fps 60 --path . --script res://tests/test_buoyancy.gd -- --rate 60 [--out f.json] [--fault]
## Physics truths checked: equilibrium draft = density ratio (Archimedes), drop settles, a flat box rights itself,
## a dense box sinks, a tall pole lies down (it is unstable upright), waves are followed without ejection, a current
## carries a floating body at the current's speed. Planted fault: sample volumes halved -> draft check fails.
extends SceneTree

const BB := preload("res://adapters/godot/buoyant_body.gd")
const Env := preload("res://core/m23_harness/test_env.gd")

var rate := 60
var out_path := ""
var fault := false
var cases := []
var ci := -1
var cur := {}
var world: Node3D
var body
var env
var t := 0.0
var warm := 0
var rec := {}
var results := []

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		match a[i]:
			"--rate": rate = int(a[i + 1])
			"--out": out_path = a[i + 1]
			"--fault": fault = true
	Engine.physics_ticks_per_second = 60
	Engine.max_physics_steps_per_frame = 8
	var W := 1025.0
	_case("B1 half-density cube floats at 0.50 m draft", {"size": Vector3.ONE, "density": 0.5 * W, "start": Vector3(0, 0, 0)}, 25.0,
		func(r): return [absf(r.draft - 0.5) < 0.02, "draft %.3f" % r.draft])
	_case("B2 0.878-density cube floats at 0.878 m draft", {"size": Vector3.ONE, "density": 0.878 * W, "start": Vector3(0, 0, 0)}, 25.0,
		func(r): return [absf(r.draft - 0.878) < 0.025, "draft %.3f" % r.draft])
	_case("B3 dropped from 3 m settles", {"size": Vector3.ONE, "density": 0.5 * W, "start": Vector3(0, 3.5, 0)}, 25.0,
		func(r): return [r.end_speed < 0.05 and absf(r.draft - 0.5) < 0.03, "end speed %.3f draft %.3f deepest %.2f" % [r.end_speed, r.draft, r.min_y]])
	_case("B4 flat box rolled 30 deg rights itself", {"size": Vector3(2, 0.5, 1), "density": 0.4 * W, "start": Vector3(0, 0, 0), "roll": 30.0}, 25.0,
		func(r): return [r.tilt < 3.0, "final tilt %.1f deg" % r.tilt])
	_case("B5 dense cube sinks to the floor", {"size": Vector3.ONE, "density": 2.0 * W, "start": Vector3(0, 0, 0)}, 30.0,
		func(r): return [absf(r.end.y - (-29.5)) < 0.05, "end y %.2f" % r.end.y])
	_case("B6 tall pole lies down (unstable upright)", {"size": Vector3(0.2, 3.0, 0.2), "density": 0.5 * W, "start": Vector3(0, 0, 0), "roll": 2.0}, 30.0,
		func(r): return [r.tilt > 80.0, "final tilt %.1f deg" % r.tilt])
	_case("B7 rides Beaufort 4 waves without ejection", {"size": Vector3(2, 1, 2), "density": 0.5 * W, "start": Vector3(0, 0, 0), "waves": 0.5}, 40.0,
		func(r): return [r.corr > 0.7 and r.max_off < 1.0, "heave corr %.2f, max off-surface %.2f m" % [r.corr, r.max_off]])
	_case("B8 1 m/s current carries it at ~1 m/s", {"size": Vector3.ONE, "density": 0.5 * W, "start": Vector3(0, 0, 0), "current": Vector3(1, 0, 0)}, 30.0,
		func(r): return [r.drift > 0.85 and r.drift < 1.05, "drift %.2f m/s (last 10 s)" % r.drift])

func _case(name: String, p: Dictionary, dur: float, check: Callable) -> void:
	cases.append({"name": name, "p": p, "dur": dur, "check": check})

func _build(p: Dictionary) -> void:
	world = Node3D.new(); root.add_child(world)
	env = Env.new(); env.level = 0.0; env.wave_amp = p.get("waves", 0.0)
	if p.has("current"): env.current_vec = p.current
	var floor_b := StaticBody3D.new(); var fc := CollisionShape3D.new(); var fs := BoxShape3D.new(); fs.size = Vector3(400, 1, 400)
	fc.shape = fs; floor_b.add_child(fc); floor_b.position = Vector3(0, -30.5, 0); world.add_child(floor_b)
	body = BB.new()
	var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = p.size; cs.shape = bs; body.add_child(cs)
	body.mass = p.density * p.size.x * p.size.y * p.size.z
	body.buoy.add_box(p.size, Vector3.ZERO, Vector3i(4, 6 if p.size.y > 2.0 else 4, 4))
	if fault:
		for pt in body.buoy.points: pt.v *= 0.5
	body.water = env
	world.add_child(body)
	body.global_transform = Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(p.get("roll", 0.0))), p.start)

func _start_next() -> bool:
	ci += 1
	if ci >= cases.size(): return false
	cur = cases[ci]; _build(cur.p); t = 0.0; warm = 2
	rec = {"fail": [], "min_y": 1e9, "hs": [], "ws": [], "max_off": 0.0, "x_at": {}}
	return true

func _physics_process(dt: float) -> bool:
	if cur.is_empty():
		if not _start_next(): return _finish()
	if warm > 0:
		warm -= 1; return false
	t += dt
	var p: Vector3 = body.global_position
	if not (p.is_finite() and body.linear_velocity.is_finite()):
		if rec.fail.is_empty(): rec.fail.append("I1 non-finite at t=%.2f" % t)
	rec.min_y = minf(rec.min_y, p.y)
	if t > 10.0:
		var wy: float = env.water_y(p.x, p.z, t)
		rec.hs.append(p.y); rec.ws.append(wy)
		rec.max_off = maxf(rec.max_off, absf(p.y - wy))
	for mark in [20.0, 30.0]:
		if absf(t - mark) < dt * 0.5: rec.x_at[mark] = p.x
	if body.linear_velocity.length() > 40.0 and rec.fail.is_empty():
		rec.fail.append("I10 speed %.1f m/s at t=%.2f" % [body.linear_velocity.length(), t])
	if t >= cur.dur - 1e-6:
		_end()
		if not _start_next(): return _finish()
	return false

static func _corr(a: Array, b: Array) -> float:
	var n := a.size()
	if n < 2: return 0.0
	var ma := 0.0; var mb := 0.0
	for i in n: ma += a[i]; mb += b[i]
	ma /= n; mb /= n
	var sab := 0.0; var saa := 0.0; var sbb := 0.0
	for i in n:
		sab += (a[i] - ma) * (b[i] - mb); saa += (a[i] - ma) ** 2; sbb += (b[i] - mb) ** 2
	return sab / sqrt(maxf(saa * sbb, 1e-12))

func _end() -> void:
	var p: Vector3 = body.global_position
	var up: Vector3 = body.global_basis.y
	var r := {"end": p, "end_speed": body.linear_velocity.length(),
		"draft": env.water_y(p.x, p.z, t) - (p.y - cur.p.size.y * 0.5),
		"tilt": rad_to_deg(acos(clampf(absf(up.y), 0.0, 1.0))) if cur.p.size.y >= 1.5 else rad_to_deg(acos(clampf(up.y, -1.0, 1.0))),
		"min_y": rec.min_y, "corr": _corr(rec.hs, rec.ws), "max_off": rec.max_off,
		"drift": (rec.x_at.get(30.0, 0.0) - rec.x_at.get(20.0, 0.0)) / 10.0}
	var ck: Array = cur.check.call(r)
	var okk: bool = ck[0] and rec.fail.is_empty()
	print("%s  %s  (%s)%s" % ["PASS" if okk else "FAIL", cur.name, ck[1], "" if rec.fail.is_empty() else "  " + "; ".join(rec.fail)])
	results.append({"name": cur.name, "ok": okk, "detail": ck[1], "end": [p.x, p.y, p.z]})
	world.queue_free(); world = null; cur = {}

func _finish() -> bool:
	var n := 0
	for r in results: if r.ok: n += 1
	print("M29 buoyancy fps %d: %d/%d PASS%s" % [rate, n, results.size(), "  (planted fault run)" if fault else ""])
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE); f.store_string(JSON.stringify({"rate": rate, "fault": fault, "results": results}))
	return true
