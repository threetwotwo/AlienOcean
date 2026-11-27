## M03 camera on Jolt: headless stress cases (STRESS_MATRIX C1, C2 + monkey).
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/test_camera.gd -- --rate 60 [--monkey 2] [--monkey-secs 300] [--fault] [--only C1]
## Invariants every tick: camera sphere never inside geometry; line of sight eye -> camera clear; no jump > 0.5 m
## relative to the head or
## > 20 deg between ticks (no cuts, ever); 1P sits on the eye; body hidden when the lens is inside the head;
## third-person lens at least 0.15 m off the water line (3-tick crossings allowed). Planted fault: probe disabled -> camera goes into walls and must FAIL.
extends SceneTree

const Packet := preload("res://core/m01_input/input_packet.gd")
const Body := preload("res://adapters/godot/player_body.gd")
const Rig := preload("res://adapters/godot/camera_rig.gd")
const Worlds := preload("res://core/m23_harness/test_worlds.gd")
const Motor := preload("res://core/m02_motor/player_motor.gd")

var rate := 60
var out_path := ""
var fault := false
var only := ""
var monkey_runs := 0
var monkey_secs := 300.0
var cases := []
var ci := -1
var cur := {}
var world: Node3D
var body
var cam
var env
var t := 0.0
var warm := 0
var rec := {}
var results := []
var prev_pos := Vector3.ZERO
var prev_rot := Vector3.ZERO
var prev_eye := Vector3.ZERO

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		match a[i]:
			"--rate": rate = int(a[i + 1])
			"--out": out_path = a[i + 1]
			"--fault": fault = true
			"--only": only = a[i + 1]
			"--monkey": monkey_runs = int(a[i + 1])
			"--monkey-secs": monkey_secs = float(a[i + 1])
	Engine.physics_ticks_per_second = 60
	Engine.max_physics_steps_per_frame = 8
	# C1: 20 blend cycles 3P -> 1P -> 3P while moving, in the open and in a 1.0 m cave
	var cycle := func(tt, third: String):
		return "first_person" if int(tt / 1.5) % 2 == 1 else third
	_case("C1 20x explore<->1P walking a circle (open)", "wall", {"start": Vector3(-8, 0.05, 0)}, 60.0,
		func(tt):
			var k = Packet.new(); k.move = Vector2(0.3, 0.8); return [k, Vector2(0.5, 0.0), cycle.call(tt, "explore")])
	_case("C1 20x swim<->1P inside a 1.0 m cave", "cave", {"s": 1.0, "start": Vector3(0, -10.42, -6), "mode": Motor.Mode.SWIM}, 60.0,
		func(tt):
			var k = Packet.new(); k.move = Vector2(0, 0.25 if int(tt / 6.0) % 2 == 0 else -0.25)
			return [k, Vector2(0.4 * sin(tt), 0.2 * cos(tt * 0.7)), cycle.call(tt, "swim")])
	# C2: hostile spots for a third-person camera
	_case("C2 look 360 deg standing against a wall", "wall", {"start": Vector3(0.6, 0.05, 0)}, 20.0,
		func(tt): return [Packet.new(), Vector2(1.2, 0.6 * sin(tt)), "explore"])
	_case("C2 look around under a 1.75 m overhang", "overhang", {"start": Vector3(0, 0.05, 0)}, 20.0,
		func(tt): return [Packet.new(), Vector2(0.8, 1.2 * sin(tt * 0.8)), "explore"])
	_case("C2 treading at the surface, looking up and down", "pool", {"start": Vector3(0, -1.2, 0), "mode": Motor.Mode.SWIM}, 20.0,
		func(tt): return [Packet.new(), Vector2(0.5, 1.4 * sin(tt * 0.9)), "swim" if int(tt / 4.0) % 2 == 0 else "first_person"])
	_case("C2 treading in Beaufort 4 waves", "pool", {"start": Vector3(0, -1.2, 0), "mode": Motor.Mode.SWIM, "waves": 0.5}, 20.0,
		func(tt): return [Packet.new(), Vector2(0.6, 0.8 * sin(tt)), "swim"])
	_case("C2 interrupted blends (shot change every 0.3 s)", "wall", {"start": Vector3(-0.2, 0.05, 0)}, 20.0,
		func(tt):
			var names := ["explore", "first_person", "observe", "explore", "swim"]
			return [Packet.new(), Vector2(0.9, 0.3 * sin(tt)), names[int(tt / 0.3) % names.size()]])
	for m in monkey_runs:
		_case("CM camera monkey seed %d (%ds)" % [2000 + m, int(monkey_secs)], "shore", {"start": Vector3(0, 1.05, 4), "waves": 0.5 if m % 2 else 0.0}, monkey_secs, _monkey(2000 + m))

func _monkey(seed: int) -> Callable:
	var st := {"g": RandomNumberGenerator.new(), "next": 0.0, "k": null, "look": Vector2.ZERO, "shot": "explore"}
	st.g.seed = seed
	return func(tt):
		var g: RandomNumberGenerator = st.g
		if tt >= st.next or st.k == null:
			var k = Packet.new()
			k.move = Vector2(g.randf_range(-1, 1), g.randf_range(-1, 1)).limit_length(1.0)
			k.thrust = g.randf() if g.randf() < 0.3 else 0.0
			k.ascend = g.randf() < 0.25; k.descend = (not k.ascend) and g.randf() < 0.2
			st.k = k
			st.look = Vector2(g.randf_range(-2.6, 2.6), g.randf_range(-2.0, 2.0))
			st.shot = ["explore", "swim", "first_person", "observe"][g.randi() % 4]
			st.next = tt + g.randf_range(0.2, 2.0)
		var p: Vector3 = body.global_position
		if Vector2(p.x, p.z + 20).length() > 35:
			# steer back with look input like a player would (never by setting the camera directly)
			var home_yaw := atan2(p.x, p.z + 20)
			st.look = Vector2(clampf(-angle_difference(cam.yaw, home_yaw) * 3.0, -2.6, 2.6), 0.0)   # yaw -= look.x dt
			st.k.move = Vector2(0, 1)
		return [st.k, st.look, st.shot]

func _case(name: String, kind: String, p: Dictionary, dur: float, input: Callable) -> void:
	if only != "" and not name.contains(only): return
	cases.append({"name": name, "kind": kind, "p": p, "dur": dur, "input": input})

func _build(c: Dictionary) -> void:
	world = Node3D.new(); root.add_child(world)
	env = Worlds.build(world, c.kind, c.p)
	body = Body.new(); world.add_child(body); body.global_position = c.p.start
	if c.p.has("mode"): body.motor.mode = c.p.mode
	cam = Rig.new(); world.add_child(cam)
	cam.exclude.append(body.get_rid())
	cam.body = body
	if fault:
		cam.probe_enabled = false

func _start_next() -> bool:
	ci += 1
	if ci >= cases.size(): return false
	cur = cases[ci]; _build(cur); t = 0.0; warm = 2
	rec = {"fail": [], "ticks": 0, "max_jump": 0.0, "max_rot": 0.0, "inside": 0, "los": 0, "fp_err": 0.0, "water": 0, "alpha": 0, "blends": 0, "last_shot": ""}
	return true

func _eye() -> Vector3:
	return body.eye_point()

func _physics_process(dt: float) -> bool:
	if cur.is_empty():
		if not _start_next(): return _finish()
	if warm > 0:
		warm -= 1; return false
	var inp: Array = cur.input.call(t)
	var k = inp[0]
	if inp[2] != rec.last_shot:
		cam.request(inp[2]); rec.blends += 1; rec.last_shot = inp[2]
	k.cam_yaw = cam.yaw; k.cam_pitch = cam.pitch
	body.tick(dt, k, env, t)
	t += dt
	var eye := _eye()
	var wy: float = env.water_y(eye.x, eye.z, t) if env.level > -999.0 else -INF
	var f: Dictionary = cam.tick(dt, eye, inp[1], wy)
	_check(f, eye, wy)
	if t >= cur.dur - 1e-6:
		_end()
		if not _start_next(): return _finish()
	return false

func _fail(msg: String) -> void:
	if rec.fail.size() < 4 and not rec.fail.has(msg): rec.fail.append(msg)

func _check(f: Dictionary, eye: Vector3, wy: float) -> void:
	var pos: Vector3 = f.pos
	var rot := Vector3(f.pitch, f.yaw, 0)   # view direction angles from the core
	if rec.ticks > 0:
		# a cut is the lens moving relative to the head: the whole rig travelling with a sprinting girl is not one
		var j := (pos - eye).distance_to(prev_pos - prev_eye)
		var r := rad_to_deg(maxf(absf(angle_difference(rot.x, prev_rot.x)), absf(angle_difference(rot.y, prev_rot.y))))
		rec.max_jump = maxf(rec.max_jump, j); rec.max_rot = maxf(rec.max_rot, r)
		if j > 0.5:
			_fail("I6 jump %.2f m at t=%.2f" % [j, t])
			if OS.get_environment("CAMDBG") != "": print("  jump t=%.2f prev %s now %s eye %s\n    dbg %s\n    prev %s" % [t, prev_pos, pos, eye, cam.last.get("arm_pull", 0.0), rec.get("pd", {})])
		if r > 20.0: _fail("I6 turn %.1f deg at t=%.2f" % [r, t])
	prev_pos = pos; prev_eye = eye; prev_rot = rot; rec.pd = {"arm": cam.last.get("arm_pull", 0.0), "blend": cam.last.get("third_person_blend", 0.0)}
	rec.ticks += 1
	var space: PhysicsDirectSpaceState3D = cam.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var sp := SphereShape3D.new(); sp.radius = 0.1
	q.shape = sp; q.transform = Transform3D(Basis(), pos); q.collision_mask = 1; q.exclude = [body.get_rid()]
	if space.intersect_shape(q, 1).size() > 0:
		rec.inside += 1; _fail("I6 lens inside geometry at t=%.2f pos %s" % [t, pos])
	# occlusion: a wall may stand between eye and lens while the boom draws in (the renderer fades it), but for no
	# more than 0.3 s in a row
	var blocked := false
	if eye.distance_to(pos) > 0.05:
		var rq := PhysicsRayQueryParameters3D.create(eye, pos, 1, [body.get_rid()])
		blocked = not space.intersect_ray(rq).is_empty()
	rec.los = rec.los + 1 if blocked else 0
	rec.max_los = maxi(rec.get("max_los", 0), rec.los)
	if rec.los > int(0.3 * 60): _fail("I6 eye hidden from the lens over 0.3 s at t=%.2f" % t)
	var d := eye.distance_to(pos)
	if d < 0.2 and f.body_alpha > 0.0:
		rec.alpha += 1; _fail("body visible with lens inside head at t=%.2f" % t)
	var settled_fp: bool = (cam.shot == "first_person" or cam.shot == "observe") and f.blend >= 1.0
	if settled_fp and (wy < -1e8 or absf(eye.y - wy) > 0.4):
		# (at the surface the water-line rule moves the lens off the eye on purpose)
		# Thalassa 1P lens = the eye plus its heave / stroke bob / plunge dip (fp_pos), rigidly locked
		var de: float = pos.distance_to(f.fp_pos)
		rec.fp_err = maxf(rec.fp_err, de)
		if de > 0.03: _fail("1P lens %.3f m off the eye at t=%.2f" % [de, t])
	# the lens may touch the water line for at most 3 ticks in a row (crossing sides when the eye crosses the surface)
	# third person only: a first-person lens at the surface bobs through the water line as in Thalassa (heave and
	# chop near the surface); the renderer draws the meniscus there (engine thread)
	if wy > -1e8 and absf(pos.y - wy) < 0.15 and cam.last.third_person_blend > 0.5:
		rec.water += 1
		if rec.water > 3: _fail("lens %.2f m from the water line over 3 ticks at t=%.2f" % [absf(pos.y - wy), t])
		if rec.water > 3 and OS.get_environment("CAMDBG") != "" and rec.fail.size() <= 1: print("  water t=%.2f lens %s wy %.2f eye %s blend %.2f arm %.2f" % [t, pos, wy, eye, cam.last.third_person_blend, cam.last.arm_pull])
	else:
		rec.water = 0

func _end() -> void:
	var okk: bool = rec.fail.is_empty()
	var detail := "%d blends, max jump %.2f m, max turn %.1f deg, 1P err %.3f m, longest occlusion %d ticks, snaps %d" % [rec.blends, rec.max_jump, rec.max_rot, rec.fp_err, rec.get("max_los", 0), cam.hard_snaps]
	print("%s  %s  (%s)%s" % ["PASS" if okk else "FAIL", cur.name, detail, "" if okk else "  " + "; ".join(rec.fail)])
	var p: Vector3 = cam.global_position
	results.append({"name": cur.name, "ok": okk, "detail": detail, "end": [p.x, p.y, p.z]})
	world.queue_free(); world = null; cur = {}

func _finish() -> bool:
	var n := 0
	for r in results: if r.ok: n += 1
	print("M03 camera fps %d: %d/%d PASS%s" % [rate, n, results.size(), "  (planted fault run)" if fault else ""])
	if out_path != "":
		var fh := FileAccess.open(out_path, FileAccess.WRITE); fh.store_string(JSON.stringify({"rate": rate, "fault": fault, "results": results}))
	return true
