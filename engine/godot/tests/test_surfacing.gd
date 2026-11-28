## Surfacing stress (water surface thread, 28 Nov 2026; Gary 09:02Z: "water surface feels like a ceiling that player cant get
## pass from underwater", 09:01Z: "under water to over water transitions ... not great/responsive").
## The swimmer's eye through the surface on real Jolt, at any frame rate (the simulation tick is fixed):
##   S1 swims up looking up (no ascend): the head must break the surface and keep its momentum through the tread band
##      (no ceiling), overshoot once at most, settle to tread without bouncing
##   S2 the same holding ascend (straight up): head out, then one breach or a tread, never stuck under
##   S3 from a tread, dives: the eye under 0.5 m within 0.9 s (responsive)
##   S4 lagoon pool 2.4 m: up from the sand at a shallow angle, the same as S1
##   S5 tread in Beaufort-4-like waves: the eye follows the swell without a jitter
## Jitter (NO JITTER rule, Gary 28 Nov 07:13Z): the eye's height, sampled every tick, has no back-and-forth at tick scale
## (sign flips of its second difference above 2 mm/tick^2 more than 2 in any 0.25 s once settled).
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/test_surfacing.gd -- --rate 60 [--trace] [--only S1]
extends SceneTree

const Packet := preload("res://core/m01_input/input_packet.gd")
const Body := preload("res://adapters/godot/player_body.gd")
const Motor := preload("res://core/m02_motor/player_motor.gd")
const Worlds := preload("res://tests/harness/test_worlds.gd")

var rate := 60
var trace := false
var only := ""
var cases: Array = []
var ci := -1
var world: Node3D
var body
var env
var t := 0.0
var warm := 0
var cur: Dictionary = {}
var ys: Array = []      # eye height above the water at the eye, every tick
var vys: Array = []
var fails := 0

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		match a[i]:
			"--rate": rate = int(a[i + 1])
			"--trace": trace = true
			"--only": only = a[i + 1]
	Engine.physics_ticks_per_second = 60
	Engine.max_physics_steps_per_frame = 8
	var up := func(pitch: float, asc: bool) -> Callable:
		return func(_tt):
			var k = Packet.new(); k.move = Vector2(0, 1); k.cam_pitch = pitch; k.ascend = asc; return k
	_case("S1 swim up looking up breaks the surface", "pool", {"start": Vector3(0, -3.5, 0)}, 7.0, up.call(0.75, false), _check_up)
	_case("S2 straight up holding ascend", "pool", {"start": Vector3(0, -3.5, 0)}, 7.0,
		func(tt):
			var k = Packet.new(); k.ascend = tt < 3.0; return k, _check_up_ascend)
	_case("S3 dive from tread is quick", "pool", {"start": Vector3(0, -0.6, 0)}, 6.0,
		func(tt):
			var k = Packet.new()
			if tt >= 4.0: k.move = Vector2(0, 1); k.cam_pitch = -0.7
			return k, _check_dive)
	_case("S4 lagoon 2.4 m: up from the sand at a shallow angle", "lagoon_pool", {"start": Vector3(0, -2.0, 0)}, 7.0, up.call(0.45, false), _check_up)
	_case("S5 tread in waves, no jitter", "pool", {"start": Vector3(0, -0.6, 0), "waves": 0.5}, 14.0,
		func(_tt): return Packet.new(), _check_waves)

func _case(name: String, kind: String, p: Dictionary, dur: float, input: Callable, check: Callable) -> void:
	if only != "" and not name.begins_with(only): return
	cases.append({"name": name, "kind": kind, "p": p, "dur": dur, "input": input, "check": check})

func _start_next() -> bool:
	ci += 1
	if ci >= cases.size(): return false
	cur = cases[ci]
	world = Node3D.new(); root.add_child(world)
	env = Worlds.build(world, cur.kind, cur.p)
	body = Body.new(); world.add_child(body)
	body.global_position = cur.p.start
	body.motor.mode = Motor.Mode.SWIM
	body.motor.swimmer.config["tread_eye"] = 0.08     # as the game sets it (adapters/godot/actor_rig.gd)
	t = 0.0; warm = 2; ys = []; vys = []
	return true

func _physics_process(delta: float) -> bool:
	if cur.is_empty():
		if not _start_next(): return _finish()
	if warm > 0: warm -= 1; return false
	body.tick(delta, cur.input.call(t), env, t)
	t += delta
	var e: Vector3 = body.eye_point()
	var wy: float = env.water_y(e.x, e.z, t)
	ys.append(e.y - wy); vys.append(body.motor.swimmer.vel.y)
	if trace and int(round(t * 60.0)) % 6 == 0:
		print("  t=%.2f eye-water %+.3f vy %+.2f %s tread %.2f" % [t, e.y - wy, body.motor.swimmer.vel.y, body.motor.mode_name(), body.motor.swimmer.surface_tread_blend])
	if t >= cur.dur - 1e-6:
		var r: Array = cur.check.call()
		var jit := _jitter(ys, int(1.5 * 60))
		var ok: bool = r[0] and jit <= 2
		if not ok: fails += 1
		print("%s  %s  (%s; jitter %d)" % ["PASS" if ok else "FAIL", cur.name, r[1], jit])
		world.queue_free(); world = null; cur = {}
		if not _start_next(): return _finish()
	return false

func _first(cond: Callable) -> int:
	for i in ys.size():
		if cond.call(i): return i
	return -1

## worst count of second-difference sign flips (above 2 mm/tick^2) in any 0.25 s window, from tick `from` on
func _jitter(y: Array, from: int) -> int:
	var flips: Array = []
	var last := 0.0
	for i in range(maxi(from, 2), y.size()):
		var d2: float = y[i] - 2.0 * y[i - 1] + y[i - 2]
		if absf(d2) < 0.002: continue
		if last != 0.0 and signf(d2) != signf(last): flips.append(i)
		last = d2
	var worst := 0
	for i in flips.size():
		var n := 0
		for j in range(i, flips.size()):
			if flips[j] - flips[i] < 15: n += 1
		worst = maxi(worst, n)
	return worst

func _check_up() -> Array:
	var out := _first(func(i): return ys[i] > 0.0)
	if out < 0: return [false, "the head never broke the surface (max %+.2f m)" % ys.max()]
	# momentum through the band: rise speed 0.3 m under the water vs 1.0 m under (no ceiling)
	var i1 := _first(func(i): return ys[i] > -1.0)
	var i3 := _first(func(i): return ys[i] > -0.3)
	var v1: float = vys[i1] if i1 >= 0 else 0.0
	var v3: float = vys[i3] if i3 >= 0 else 0.0
	var peak: float = ys.slice(out).max()
	var tail: Array = ys.slice(ys.size() - 60)
	var settle: float = tail.max() - tail.min()
	var ok: bool = v3 >= 0.6 * v1 and peak > 0.12 and peak < 0.8 and settle < 0.08
	return [ok, "out at %.2f s, rise %.2f -> %.2f m/s through the band, peak %+.2f, last-second swing %.3f" % [out / 60.0, v1, v3, peak, settle]]

func _check_up_ascend() -> Array:
	var out := _first(func(i): return ys[i] > 0.05)
	var tail: Array = ys.slice(ys.size() - 60)
	var ok: bool = out >= 0 and out < 3 * 60 and tail.max() > -0.05
	return [ok, "head out at %.2f s, end %+.2f" % [out / 60.0 if out >= 0 else -1.0, ys[-1]]]

func _check_dive() -> Array:
	var i0 := 4 * 60
	var under := -1
	for i in range(i0, ys.size()):
		if ys[i] < -0.5: under = i; break
	var dt := (under - i0) / 60.0 if under >= 0 else 99.0
	return [dt < 0.9, "eye 0.5 m under %.2f s after the dive input" % dt]

func _check_waves() -> Array:
	var tail: Array = ys.slice(3 * 60)
	return [tail.min() > -0.35 and tail.max() < 0.45, "eye over the wave %+.2f .. %+.2f" % [tail.min(), tail.max()]]

func _finish() -> bool:
	print("surfacing %d failed at %d fps" % [fails, rate])
	quit(1 if fails > 0 else 0)
	return true
