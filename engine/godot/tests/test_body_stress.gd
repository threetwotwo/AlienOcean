## M04 body stress test: the ported Thalassa body rig (core/m04_body) driven by the real motor on real Jolt worlds, every
## case the motor tests cover plus body-specific ones (standing, turning on the spot, jumps, hits, walls, ceilings),
## with body invariants checked every tick on every limb.
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/test_body_stress.gd -- [--tick 60] [--monkey 2]
##        [--monkey-secs 60] [--only B7] [--fault len|flip|clip] [--out /tmp/b.json]
## exit 0 = every case passed except the KNOWN open ones below. --fault plants a known body bug and the run must FAIL (run_all.sh checks that).
##
## Invariants (per tick, per limb; thresholds at the top):
##  J1 finite        every joint and matrix finite
##  J2 bones rigid   upper arm, forearm, thigh, shin keep their length (1 mm); spine, neck, shoulder and hip
##                   widths stay within 20 % of the standing pose
##  J3 hinge range   elbow 0..142 deg, knee 0..132 deg flex (Thalassa limits + 1 deg); a hinge never flips its bend
##                   direction in one tick while bent more than 20 deg; knees never point backwards (> 3 cm)
##  J4 neck range    neck yaw / pitch inside the solve_head limits; head never faces more than 100 deg from the chest
##  J5 no pops       no joint moves faster than 14 m/s relative to the pelvis; the pelvis never jumps 25 cm in a tick
##  J6 no rock       sampled spheres along every limb, hands, feet, head, chest and pelvis (mannequin radii less 2 cm)
##                   never sit inside world geometry for 3 ticks running
##  J7 feet          soles never 2 cm under the floor; standing still both soles within 3 cm of it; a foot on the
##                   ground does not skate (> 0.35 m/s for 6 ticks running) while walking
##  J8 self contact  thighs and shins of the two legs never overlap; forearms and hands never sink 3 cm into the
##                   torso
extends SceneTree

const Packet := preload("res://core/m01_input/input_packet.gd")
const Body := preload("res://adapters/godot/player_body.gd")
const Motor := preload("res://core/m02_motor/player_motor.gd")
const Worlds := preload("res://tests/harness/test_worlds.gd")
const Rig := preload("res://core/m04_body/body_rig.gd")
const WorldQuery := preload("res://adapters/godot/world_query.gd")

# canonical body (Thalassa stature 1.38 m) and limits
const UPPER_ARM := 0.245
const FOREARM := 0.228
const THIGH := 0.345
const SHIN := 0.335
const BONE_TOL := 0.001
const SPAN_TOL := 0.20
const SPAN_ABS := 0.015
const ELBOW_MAX := 143.0
const KNEE_MAX := 133.0
const FLIP_MIN_FLEX := 20.0
const KNEE_BACK_TOL := 0.03
const NECK_TOL := 0.02
const HEAD_CHEST_MAX := 100.0
const POP_REL := 14.0
const PELVIS_JUMP := 0.12      # m in one tick, relative to the eye
const PEN_RUN := 3
const PEN_MARGIN := 0.02
const SOLE_UNDER := 0.02
const STAND_GAP := 0.03
const SLIDE_MAX := 0.03       # a planted foot: heel or ball may drift at most 3 cm over the whole stance (the other rolls)
const HOVER_GAP := 0.03       # a planted foot: lowest sole point at most 3 cm above the ground...
const HOVER_RUN := 6          # ...for more than this many ticks
const TORSO_R := 0.085
const TORSO_SINK := 0.03

## Open cases, listed so the suite still gates everything else: a KNOWN case may fail (reported, not counted against
## the exit code); every other case must pass, and a KNOWN case that starts passing is reported so it can come off.
## Each entry says what fails and why, as found; fix one, then delete its line.
const KNOWN := {
	"B12 step": "trailing foot slides 3.6 cm for a few ticks walking back down off the step (forced step waits for the other foot)",
	"B17": "a foot slides 3.4 cm at the beach crease: it lands short of a spot it can't reach and is stepped again",
	"B18": "as B17",
	"B19": "as B17",
	"B34": "as B17",
	"B35": "toe of the swing foot scuffs 3 cm into a 30 deg slope walked across: the pelvis is low and the uphill knee is folded",
	"B36": "as B35, standing across the slope",
	"B37": "stairs: the eye climbs each riser as her centre crosses it, faster than the steps, so the trailing foot is left stretched and slides",
}

var tick := 60
var monkey_runs := 0
var monkey_secs := 60.0
var only := ""
var fault := ""
var out_path := ""
var cases: Array = []
var ci := -1
var cur := {}
var rec := {}
var world: Node3D
var body
var env
var rig
var wq
var renv := {}
var t := 0.0
var warm := 0
var prev := {}
var ref_spans := {}
var results: Array = []
# --film <dir>: render every case that is not KNOWN (needs a renderer: xvfb-run ... --rendering-driver vulkan
# --fixed-fps 15), one PNG per frame into <dir>/<case>/, with the case name and live checks written on screen.
# --shard i/n runs every n-th case starting at i (to film in parallel).
const Mannequin := preload("res://adapters/godot/mannequin.gd")
var film := ""
var shard := Vector2i(0, 1)
var mq
var cam: Camera3D
var label: Label
var frame_i := 0
var film_case_dir := ""

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		match a[i]:
			"--tick": tick = int(a[i + 1])
			"--monkey": monkey_runs = int(a[i + 1])
			"--monkey-secs": monkey_secs = float(a[i + 1])
			"--only": only = a[i + 1]
			"--fault": fault = a[i + 1]
			"--out": out_path = a[i + 1]
			"--film": film = a[i + 1]
			"--shard":
				var sp: PackedStringArray = a[i + 1].split("/")
				shard = Vector2i(int(sp[0]), int(sp[1]))
	Engine.physics_ticks_per_second = tick
	Engine.max_physics_steps_per_frame = 8
	_define_cases()
	if film != "" or shard.y > 1:
		var keep: Array = []
		for idx in cases.size():
			var c: Dictionary = cases[idx]
			var is_known := false
			for k in KNOWN:
				if c.name.begins_with(k): is_known = true
			if idx % shard.y == shard.x and not (film != "" and is_known and only == ""): keep.append(c)     # --only films a KNOWN case too
		cases = keep
	if film != "":
		root.size = Vector2i(800, 450)
		var rock := StandardMaterial3D.new(); rock.albedo_color = Color(0.78, 0.72, 0.6); rock.roughness = 0.95
		Worlds.visual_material = rock
		var cl := CanvasLayer.new(); root.add_child(cl)
		label = Label.new(); label.position = Vector2(12, 8); label.add_theme_font_size_override("font_size", 17)
		label.add_theme_color_override("font_color", Color.WHITE); label.add_theme_color_override("font_outline_color", Color.BLACK)
		label.add_theme_constant_override("outline_size", 5); cl.add_child(label)
	print("M04 body stress: tick %d, %d cases%s" % [tick, cases.size(), "  (planted fault: %s)" % fault if fault != "" else ""])

# ---------------------------------------------------------------- cases
func _pk(move := Vector2.ZERO, yaw := 0.0, pitch := 0.0):
	var k = Packet.new()
	k.move = move; k.cam_yaw = yaw; k.cam_pitch = pitch
	return k

## The camera can't turn faster than the M01 look limit (2.4 rad/s x outer-zone boost 1.45 = 3.5 rad/s), so a
## scripted "turn round" ramps the yaw instead of jumping it.
const LOOK_MAX := 3.5
func _turn(tt: float, t0: float) -> float:
	return PI * clampf((tt - t0) * LOOK_MAX / PI, 0.0, 1.0)

func _case(name: String, kind: String, p: Dictionary, dur: float, input: Callable, opts := {}) -> void:
	if only != "" and not name.begins_with(only):
		return
	cases.append({"name": name, "kind": kind, "p": p, "dur": dur, "input": input, "opts": opts})

func _define_cases() -> void:
	var flat := {"start": Vector3(-3, 0.05, 0)}      # wall world: open floor, wall along x = 1
	_case("B1 stand still", "wall", flat, 6.0, func(_t): return _pk(), {"stand": true})
	_case("B2 walk, stop, walk", "wall", flat, 10.0, func(tt): return _pk(Vector2(0, 1) if fmod(tt, 4.0) < 2.5 else Vector2.ZERO))
	_case("B3 turn on the spot", "wall", flat, 8.0, func(tt): return _pk(Vector2(sin(tt * 2.5), cos(tt * 2.5)) * 0.25, tt * 1.2))
	_case("B4 sprint, stop dead, reverse", "wall", {"start": Vector3(-3, 0.05, 6)}, 10.0, func(tt):
		var k = _pk(Vector2(0, 1) if tt < 4.0 else (Vector2.ZERO if tt < 5.0 else Vector2(0, -1)))
		k.thrust = 1.0 if tt < 4.0 else 0.0
		return k)
	_case("B5 strafe circles", "wall", flat, 10.0, func(tt): return _pk(Vector2(cos(tt * 1.6), sin(tt * 1.6))))
	_case("B6 zigzag at full speed", "wall", flat, 10.0, func(tt):
		var k = _pk(Vector2(1 if fmod(tt, 1.0) < 0.5 else -1, 1).normalized()); k.thrust = 1.0; return k)
	_case("B7 standing jumps", "wall", flat, 8.0, func(tt):
		var k = _pk(); k.jump_pressed = fmod(tt, 1.6) < 0.02; return k)
	_case("B8 running jumps", "wall", {"start": Vector3(-3, 0.05, 6)}, 8.0, func(tt):
		var k = _pk(Vector2(0, 1)); k.thrust = 1.0; k.jump_pressed = fmod(tt, 1.5) < 0.02; return k)
	_case("B9 crouch walk", "wall", flat, 6.0, func(_t):
		var k = _pk(Vector2(0, 0.6)); k.descend = true; k.descend_amount = 1.0; return k)
	_case("B10 walk into a wall and push", "wall", {"start": Vector3(-1.5, 0.05, 0)}, 6.0, func(_t): return _pk(Vector2(0, 1), -PI * 0.5))
	_case("B11 walk along a wall, touching", "wall", {"start": Vector3(0.6, 0.05, 6)}, 8.0, func(_t): return _pk(Vector2(0.25, 1).normalized()))
	for h in [0.10, 0.30]:
		_case("B12 step %d cm up and back down" % int(h * 100), "step", {"h": h, "start": Vector3(0, 0.05, 2)}, 10.0,
			func(tt): return _pk(Vector2(0, 1), _turn(tt, 5.0)))
	_case("B13 step 50 cm: blocked, pushing", "step", {"h": 0.5, "start": Vector3(0, 0.05, 2)}, 6.0, func(_t): return _pk(Vector2(0, 1)))
	for ang in [15.0, 30.0]:
		_case("B14 ramp %d deg up and down" % int(ang), "ramp", {"angle": ang, "start": Vector3(0, 0.05, 4)}, 14.0,
			func(tt): return _pk(Vector2(0, 1), _turn(tt, 7.0)))
	_case("B15 ramp 60 deg: too steep, pushing", "ramp", {"angle": 60.0, "start": Vector3(0, 0.05, 4)}, 8.0, func(_t): return _pk(Vector2(0, 1)))
	_case("B16 under a low ceiling", "overhang", {"start": Vector3(0, 0.05, 6)}, 8.0, func(_t): return _pk(Vector2(0, 1)))
	var shore_io := func(tt): return _pk(Vector2(0, 1), _turn(tt, 16.0))
	_case("B17 shore: walk, wade, swim, back out", "shore", {"start": Vector3(0, 1.05, 4)}, 34.0, shore_io)
	_case("B18 shore in waves", "shore", {"start": Vector3(0, 1.05, 4), "waves": 0.5}, 34.0, shore_io)
	_case("B19 wade standing in waves", "shore", {"start": Vector3(0, 1.05, 4), "waves": 0.5}, 16.0,
		func(tt): return _pk(Vector2(0, 1) if tt < 3.4 else Vector2.ZERO))
	var swim := {"start": Vector3(0, -8, 0), "mode": Motor.Mode.SWIM}
	_case("B20 swim cruise then sprint", "pool", swim, 12.0, func(tt):
		var k = _pk(Vector2(0, 1)); k.thrust = 1.0 if tt > 6.0 else 0.0; return k)
	_case("B21 swim tight turns", "pool", swim, 12.0, func(tt):
		var k = _pk(Vector2(0, 1), tt * 2.2); k.thrust = 1.0 if fmod(tt, 4.0) < 2.0 else 0.0; return k)
	_case("B22 swim straight up and down", "pool", swim, 12.0, func(tt):
		var k = _pk(Vector2(0, 1), 0.0, 1.3 if fmod(tt, 6.0) < 3.0 else -1.3); return k)
	_case("B23 swim backwards and sideways", "pool", swim, 10.0, func(tt):
		return _pk(Vector2(0, -1) if tt < 5.0 else Vector2(1 if fmod(tt, 2.0) < 1.0 else -1, 0)))
	_case("B24 hover still underwater", "pool", swim, 8.0, func(_t): return _pk())
	_case("B25 dive and rise to tread", "pool", {"start": Vector3(0, -3, 0), "mode": Motor.Mode.SWIM}, 16.0, func(tt):
		var k = _pk(Vector2(0, 1), 0.0, -0.9 if tt < 4.0 else 0.0)
		k.ascend = tt >= 4.0 and tt <= 11.0
		if tt > 11.0: k.move = Vector2.ZERO
		return k)
	_case("B26 tread in waves", "pool", {"start": Vector3(0, -1.2, 0), "mode": Motor.Mode.SWIM, "waves": 0.5}, 14.0, func(_t): return _pk())
	_case("B27 breach chain at the surface", "pool", {"start": Vector3(0, -1.2, 0), "mode": Motor.Mode.SWIM}, 14.0, func(_t):
		var k = _pk(Vector2(0, 1)); k.thrust = 1.0; k.ascend = true; return k)
	_case("B28 cave 1.0 m: through the tube", "cave", {"s": 1.0, "start": Vector3(0, -10.42, 2), "mode": Motor.Mode.SWIM}, 14.0,
		func(_t): return _pk(Vector2(0, 1)), {"tight": true})
	_case("B29 cave 0.8 m: face against the mouth", "cave", {"s": 0.8, "start": Vector3(0, -10.42, 2), "mode": Motor.Mode.SWIM}, 10.0,
		func(tt): return _pk(Vector2(0, 1), 0.3 * sin(tt), 0.2 * sin(tt * 1.3)), {"tight": true})
	_case("B30 sea floor: swim along the bottom", "pool", {"start": Vector3(0, -9.3, 0), "mode": Motor.Mode.SWIM}, 10.0,
		func(_t): var k = _pk(Vector2(0, 1), 0.0, -0.5); k.descend = true; k.descend_amount = 1.0; return k)
	_case("B31 against a 3 m/s current", "pool", {"start": Vector3(0, -8, 0), "mode": Motor.Mode.SWIM, "current": Vector3(0, 0, 3.0)}, 10.0,
		func(_t): var k = _pk(Vector2(0, 1)); k.thrust = 1.0; return k)
	# hits: random bumps / bursts / splashes every 0.6 s, walking and swimming
	_case("B32 hits while walking", "wall", flat, 10.0, func(tt): return _pk(Vector2(0, 1) if fmod(tt, 3.0) < 2.0 else Vector2.ZERO), {"hits": 0.6})
	_case("B33 hits while swimming", "pool", swim, 10.0, func(tt): return _pk(Vector2(0, 1), tt * 0.6), {"hits": 0.6})
	_case("B34 hits while wading", "shore", {"start": Vector3(0, 1.05, 4)}, 14.0, func(tt): return _pk(Vector2(0, 1) if tt < 4.0 else Vector2.ZERO), {"hits": 0.5})
	# cases the rig review asked for
	_case("B35 ramp 30 deg diagonally, up and down", "ramp", {"angle": 30.0, "start": Vector3(-2, 0.05, 4)}, 12.0,
		func(tt): return _pk(Vector2(0.6, 0.8), _turn(tt, 6.0)))
	_case("B36 standing on a 30 deg ramp, turning", "ramp", {"angle": 30.0, "start": Vector3(0, 1.6, -2.6)}, 10.0,
		func(tt): return _pk(Vector2.ZERO if tt < 4.0 else Vector2(0.2, 0) , tt * 0.5 if tt < 4.0 else 2.0))
	_case("B37 stairs up and back down", "stairs", {"start": Vector3(0, 0.05, 3)}, 12.0,
		func(tt): return _pk(Vector2(0, 1), _turn(tt, 5.0)))
	_case("B38 jump off a 30 cm step", "step", {"h": 0.3, "start": Vector3(0, 0.35, -5)}, 6.0, func(tt):
		var k = _pk(Vector2(0, 1), PI); k.jump_pressed = tt > 1.1 and tt < 1.13; return k)
	_case("B39 sprint off a 50 cm ledge", "step", {"h": 0.5, "start": Vector3(0, 0.55, -6)}, 6.0, func(_t):
		var k = _pk(Vector2(0, 1), PI); k.thrust = 1.0; return k)
	_case("B40 frame hitches while walking", "wall", flat, 10.0,
		func(tt): return _pk(Vector2(0, 1) if fmod(tt, 4.0) < 2.5 else Vector2.ZERO, tt * 0.4), {"hitch": true})
	_case("B41 teleport mid-walk", "wall", flat, 8.0, func(_t): return _pk(Vector2(0, 1)), {"teleport": 4.0})
	_case("B42 swim up into a ceiling", "ceiling", {"start": Vector3(0, -9, 0), "mode": Motor.Mode.SWIM}, 10.0,
		func(tt): var k = _pk(Vector2(0, 0.3), 0.0, 1.2); k.ascend = true; k.thrust = 1.0 if tt > 5.0 else 0.0; return k)
	_case("B43 sprint-swim into a wall", "cave", {"s": 1.0, "start": Vector3(6, -10, 2), "mode": Motor.Mode.SWIM}, 8.0,
		func(_t): var k = _pk(Vector2(0, 1)); k.thrust = 1.0; return k, {"tight": true})
	for m in monkey_runs:
		var seed := 2000 + m
		_case("BM monkey seed %d (%ds)" % [seed, int(monkey_secs)], "shore", {"start": Vector3(0, 1.05, 4), "waves": 0.5 if m % 2 == 1 else 0.0},
			monkey_secs, _monkey_input(seed), {"hits": 2.5})

func _monkey_input(seed: int) -> Callable:
	var st := {"rng": RandomNumberGenerator.new(), "next": 0.0, "k": null, "yaw": 0.0, "pitch": 0.0, "tyaw": 0.0, "tpitch": 0.0, "last": 0.0}
	st.rng.seed = seed
	return func(tt):
		var step: float = LOOK_MAX * (tt - st.last)
		st.last = tt
		st.yaw += clampf(wrapf(st.tyaw - st.yaw, -PI, PI), -step, step)
		st.pitch += clampf(st.tpitch - st.pitch, -step, step)
		if tt >= st.next or st.k == null:
			var g: RandomNumberGenerator = st.rng
			var k = _pk(Vector2(g.randf_range(-1, 1), g.randf_range(-1, 1)).limit_length(1.0), st.yaw, st.pitch)
			st.tyaw = g.randf_range(-PI, PI); st.tpitch = g.randf_range(-1.3, 1.3)
			k.thrust = g.randf() if g.randf() < 0.3 else 0.0
			k.ascend = g.randf() < 0.25
			k.descend = (not k.ascend) and g.randf() < 0.2
			k.descend_amount = 1.0 if k.descend else 0.0
			k.jump_pressed = g.randf() < 0.15
			st.k = k
			st.next = tt + g.randf_range(0.15, 1.6)
		else:
			st.k.jump_pressed = false
		st.k.cam_yaw = st.yaw; st.k.cam_pitch = st.pitch
		var p: Vector3 = body.global_position
		if Vector2(p.x, p.z + 20).length() > 35:
			st.tyaw = atan2(p.x, p.z + 20)
			st.k.move = Vector2(0, 1)
		return st.k

# ---------------------------------------------------------------- run loop
func _start_next() -> bool:
	ci += 1
	if ci >= cases.size():
		return false
	cur = cases[ci]
	world = Node3D.new()
	root.add_child(world)
	env = Worlds.build(world, cur.kind, cur.p)
	body = Body.new()
	world.add_child(body)
	body.global_position = cur.p.start
	if cur.p.has("mode"): body.motor.mode = cur.p.mode
	rig = Rig.new()
	if film != "":
		_film_setup()
	if fault == "len": rig.shin_len = 0.30          # planted: rig solves with a short shin, the checker knows the real one
	wq = WorldQuery.new(world.get_world_3d(), 1)
	wq.exclude.append(body.get_rid())
	renv = wq.as_env()
	if fault == "clip": renv.erase("nearest_surface")   # planted: limbs no longer pushed clear of rock
	t = 0.0
	warm = 2
	prev = {}
	rec = {"name": cur.name, "fail": [], "ticks": 0, "modes": [], "pen": {}, "stance": {}, "count": {},
		"worst": {"bone_mm": 0.0, "span": 0.0, "elbow": 0.0, "knee": 0.0, "knee_back": 0.0, "neck": 0.0, "head_chest": 0.0,
			"pop": 0.0, "pelvis_jump": 0.0, "pen_run": 0, "sole_under": 0.0, "stand_gap": 0.0, "skate": 0.0, "leg_overlap": 0.0,
			"torso_sink": 0.0, "flips": 0}}
	rec.hit_rng = RandomNumberGenerator.new()
	rec.hit_rng.seed = 77 + ci
	rec.next_hit = 1.0
	return true

func _physics_process(dt: float) -> bool:
	if ci < 0 or cur.is_empty():
		if not _start_next():
			return _finish()
	if warm > 0:
		warm -= 1
		return false
	var k = cur.input.call(t)
	rig.update_timers(dt)
	body.tick(dt, k, env, t)
	var s = body.motor.swimmer
	s.config.surface_y = env.water_y(s.pos.x, s.pos.z, t) if env.level > -999.0 else -1000.0
	wq.top = s.pos.y + 0.05      # floor rays start at the eye: from higher up, a cave roof reads as "floor"
	if cur.opts.has("hits") and t >= rec.next_hit:
		var g: RandomNumberGenerator = rec.hit_rng
		var kinds := ["bump", "bump", "burst", "splash"]
		rig.apply_impact_impulse(Vector3(g.randf_range(-1, 1), g.randf_range(-1, 1), g.randf_range(-1, 1)), g.randf_range(0.2, 1.0), kinds[g.randi() % 4])
		rec.next_hit = t + cur.opts.hits * g.randf_range(0.5, 1.5)
	if cur.opts.has("teleport") and t >= cur.opts.teleport and not rec.has("teleported"):
		rec.teleported = true                         # moved 9 m sideways by the game (respawn, fast travel)
		var np: Vector3 = s.pos + Vector3(-9, 0, 0)
		s.set_pose(np, s.yaw, s.pitch)
		body.global_position += Vector3(-9, 0, 0)
		prev = {}
		rec.stance = {}
	var rdt := dt
	if cur.opts.get("hitch", false):
		# the rig drawn per frame: every 23 ticks it misses 1-5 frames, then catches up in one long step
		rec.hitch_acc = float(rec.get("hitch_acc", 0.0)) + dt
		var ph: int = int(rec.ticks) % 23
		if ph > 0 and ph <= 1 + (int(rec.ticks) / 23) % 5:
			t += dt
			rec.ticks += 1
			return false
		rdt = rec.hitch_acc
		rec.hitch_acc = 0.0
	var pose: Dictionary = rig.update_swim(rdt, s, null, t, renv)
	if fault == "flip" and rec.ticks == 120:
		var a: Dictionary = pose.armL
		a.mid = a.root + (a.root - a.mid)             # planted: elbow mirrored through the shoulder for one tick
	t += dt
	_check(pose, rdt)
	if film != "" and int(rec.ticks) % maxi(1, tick / 15) == 0:
		_film_frame(pose)
	if t >= cur.dur - 1e-6:
		_end_case()
		if not _start_next():
			return _finish()
	return false

# ---------------------------------------------------------------- invariants
func _fail(code: String, msg: String) -> void:
	var line := "%s %s at t=%.2f" % [code, msg, t]
	rec.count[code] = rec.count.get(code, 0) + 1     # how often, not just whether: reported beside the first failure
	for f in rec.fail:
		if f.begins_with(code): return
	rec.fail.append(line)

func _w(key: String, v: float) -> void:
	rec.worst[key] = maxf(rec.worst[key], v)

func _flex(a: Vector3, m: Vector3, b: Vector3) -> float:
	var u := (a - m).normalized(); var v := (b - m).normalized()
	return 180.0 - rad_to_deg(acos(clampf(u.dot(v), -1.0, 1.0)))

func _spans(p: Dictionary) -> Dictionary:
	return {"pelvis_waist": p.pelvisPos.distance_to(p.waistPos), "waist_chest": p.waistPos.distance_to(p.chestPos),
		"chest_neck": p.chestPos.distance_to(p.neckPos), "neck_head": p.neckPos.distance_to(p.headMat.origin),
		"shoulders": p.shoulderL.distance_to(p.shoulderR), "hips": p.hipL.distance_to(p.hipR)}

func _joints(p: Dictionary) -> Dictionary:
	return {"chest": p.chestPos, "pelvis": p.pelvisPos, "neck": p.neckPos, "head": p.headMat.origin,
		"elbowL": p.armL.mid, "handL": p.armL.eff, "elbowR": p.armR.mid, "handR": p.armR.eff,
		"kneeL": p.legL.ik.mid, "ankleL": p.legL.ik.eff, "kneeR": p.legR.ik.mid, "ankleR": p.legR.ik.eff}

func _inside(c: Vector3, r: float) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var sp := SphereShape3D.new(); sp.radius = maxf(0.005, r - PEN_MARGIN)
	q.shape = sp
	q.transform = Transform3D(Basis(), c)
	q.collision_mask = 1
	q.exclude = [body.get_rid()]
	return world.get_world_3d().direct_space_state.intersect_shape(q, 1).size() > 0

func _seg_dist(a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3) -> float:
	var cp: PackedVector3Array = Geometry3D.get_closest_points_between_segments(a0, a1, b0, b1)
	return cp[0].distance_to(cp[1])

func _sole_points(fin: Transform3D) -> Array:
	return [fin * Vector3(0, 0.0, -0.046), fin * Vector3(0, 0.08, -0.046), fin * Vector3(0, 0.16, -0.046)]

## What J7 tests: the four corners and the toe and heel ends of the mannequin's sole plate (adapters/godot/mannequin.gd:
## box centre (0, 0.058, -0.046), size 0.056 x 0.168), not just the centreline points the rig's toe lift uses (the review's
## point: a fix must not be graded only on its own samples). z -0.046 is 6 mm above the plate's underside.
const SOLE_X := 0.028
const SOLE_HEEL := -0.026
const SOLE_TOE := 0.142
func _sole_points_full(fin: Transform3D) -> Array:
	var pts := []
	for e in [Vector3(0, SOLE_HEEL, -0.046), Vector3(0, 0.058, -0.046), Vector3(0, SOLE_TOE, -0.046),
			Vector3(SOLE_X, SOLE_HEEL, -0.046), Vector3(-SOLE_X, SOLE_HEEL, -0.046), Vector3(SOLE_X, SOLE_TOE, -0.046), Vector3(-SOLE_X, SOLE_TOE, -0.046)]:
		pts.append(fin * e)
	return pts

func _check(p: Dictionary, dt: float) -> void:
	rec.ticks += 1
	var mode: String = p.mode
	if not rec.modes.has(mode): rec.modes.append(mode)
	var J := _joints(p)
	if OS.has_environment("BS_DEBUG"):
		var w0 := float(OS.get_environment("BS_T0")); var w1 := float(OS.get_environment("BS_T1"))
		if t >= w0 and t <= w1:
			var sw = body.motor.swimmer
			if OS.has_environment("BS_LEG"):
				var lr: Dictionary = p.legR.ik
				print("    R hip %s knee %s ank %s flex %.1f fin %s" % [(lr.root - p.pelvisPos).snappedf(0.001), (lr.mid - p.pelvisPos).snappedf(0.001), (lr.eff - p.pelvisPos).snappedf(0.001), _flex(lr.root, lr.mid, lr.eff), p.legR.finDir.snappedf(0.01)])
			if OS.has_environment("BS_KNEE"):
				for sd in ["L", "R"]:
					var kk: Vector3 = p["leg" + sd].ik.mid
					var hh: Vector3 = p["leg" + sd].ik.root
					print("    knee%s %s hip %s solid=%s ray=%s ank=%s" % [sd, kk.snappedf(0.001), hh.snappedf(0.001), wq.point_solid(kk), wq.ray(hh, kk + (kk - hh).normalized() * 0.05), p["leg" + sd].ik.eff.snappedf(0.001)])
			if OS.has_environment("BS_FOOT"):
				var fm: Transform3D = p.legL.finMat
				var c := fm * Vector3(0, 0.08, -0.02)
				print("    footL c=%s ank=%s hit=%s solid=%s fwd=%s" % [c.snappedf(0.001), p.legL.ik.eff.snappedf(0.001), wq.nearest_surface(c, 0.065, func(_a, n): return absf(n.y) < 0.7), wq.point_solid(c), fm.basis.y.snappedf(0.01)])
			var line := "  t=%.2f %s eye=%s pel=%s yaw=%.2f air=%s off=%.2f floor=%.2f gwb=%.2f" % [t, p.mode, sw.pos.snappedf(0.01), p.pelvisPos.snappedf(0.01), sw.yaw, sw.shore_is_airborne, sw.shore_jump_offset, sw.shore_floor_y, sw.ground_walk_blend]
			for side in ["L", "R"]:
				var fin: Transform3D = p["leg" + side].finMat
				var gaps := _sole_points(fin).map(func(q): var h: Dictionary = wq.ray_down(q.x, q.z, q.y + 0.6, 2.0); return snappedf(q.y - h.position.y, 0.001) if not h.is_empty() else 9.0)
				var fp = rig.world_foot_placer.feet[side]
				line += " %s ank=%s fp=%s step=%s soles=%s" % [side, p["leg" + side].ik.eff.snappedf(0.001), fp.cur.snappedf(0.001), fp.stepping, gaps]
			print(line)
	# J1
	for k in J:
		if not J[k].is_finite():
			_fail("J1", "%s not finite" % k); return
	for k in ["chestMat", "pelvisMat", "headMat", "handLMat", "handRMat"]:
		var m: Transform3D = p[k]
		if not (m.origin.is_finite() and m.basis.x.is_finite() and m.basis.y.is_finite() and m.basis.z.is_finite()):
			_fail("J1", "%s not finite" % k); return
	# J2 rigid bones
	var limbs := {"armL": [p.armL, UPPER_ARM, FOREARM], "armR": [p.armR, UPPER_ARM, FOREARM],
		"legL": [p.legL.ik, THIGH, SHIN], "legR": [p.legR.ik, THIGH, SHIN]}
	for name in limbs:
		var ik: Dictionary = limbs[name][0]
		var e1: float = absf(ik.root.distance_to(ik.mid) - limbs[name][1])
		var e2: float = absf(ik.mid.distance_to(ik.eff) - limbs[name][2])
		_w("bone_mm", maxf(e1, e2) * 1000.0)
		if maxf(e1, e2) > BONE_TOL:
			_fail("J2", "%s bone off by %.1f mm" % [name, maxf(e1, e2) * 1000.0])
	var sp := _spans(p)
	if ref_spans.is_empty():     # Thalassa's standing body (solve_walk_wade constants)
		ref_spans = {"pelvis_waist": 0.160, "waist_chest": 0.195, "chest_neck": 0.118, "neck_head": 0.008, "shoulders": 0.264, "hips": 0.176}
	if not ref_spans.is_empty():
		for k in sp:
			var d: float = absf(sp[k] - ref_spans[k])
			var r: float = d / ref_spans[k]
			if d < SPAN_ABS: continue          # a few mm on a short span (neck to skull base is 8 mm) is not a stretch
			_w("span", r)
			if r > SPAN_TOL:
				_fail("J2", "%s span %.0f%% off standing (%.0f mm)" % [k, r * 100.0, d * 1000.0])
	# J3 hinges
	for side in ["L", "R"]:
		var arm: Dictionary = p["arm" + side]
		var lg: Dictionary = p["leg" + side].ik
		var ef: float = _flex(arm.root, arm.mid, arm.eff)
		var kf: float = _flex(lg.root, lg.mid, lg.eff)
		_w("elbow", ef); _w("knee", kf)
		if ef > ELBOW_MAX: _fail("J3", "elbow%s flexed %.0f deg" % [side, ef])
		if kf > KNEE_MAX: _fail("J3", "knee%s flexed %.0f deg" % [side, kf])
		# knee points forward: knee offset from the hip-ankle line along the body front
		var front: Vector3 = -p.bodyBack
		var line: Vector3 = (lg.eff - lg.root).normalized()
		var off: Vector3 = (lg.mid - lg.root) - line * (lg.mid - lg.root).dot(line)
		var back: float = -off.dot(front)
		if kf > FLIP_MIN_FLEX:
			_w("knee_back", back)
			if back > KNEE_BACK_TOL: _fail("J3", "knee%s points backwards %.0f mm" % [side, back * 1000.0])
		for limb in [["arm" + side, arm, ef], ["leg" + side, lg, kf]]:
			var key: String = limb[0]
			var ik2: Dictionary = limb[1]
			var plane: Vector3 = (ik2.mid - ik2.root).cross(ik2.eff - ik2.mid)
			if prev.has("plane_" + key) and limb[2] > FLIP_MIN_FLEX and prev["flex_" + key] > FLIP_MIN_FLEX:
				if plane.normalized().dot(prev["plane_" + key]) < 0.0:
					rec.worst.flips += 1
					_fail("J3", "%s bend flipped in one tick" % key)
			prev["plane_" + key] = plane.normalized()
			prev["flex_" + key] = limb[2]
	# J4 neck
	var hm: Dictionary = p.headMotion
	var max_yaw := 1.04
	var nerr: float = maxf(absf(hm.neckYaw) - max_yaw, maxf(-0.58 - hm.neckPitch, hm.neckPitch - 1.08))
	_w("neck", maxf(0.0, nerr))
	if nerr > NECK_TOL: _fail("J4", "neck yaw %.2f pitch %.2f past limits" % [hm.neckYaw, hm.neckPitch])
	var chest_fwd: Vector3 = -p.chestMat.basis.z.normalized()
	var head_fwd: Vector3 = hm.fwd
	var hc: float = rad_to_deg(acos(clampf(chest_fwd.dot(head_fwd.normalized()), -1.0, 1.0)))
	_w("head_chest", hc)
	if hc > HEAD_CHEST_MAX: _fail("J4", "head %.0f deg from chest" % hc)
	# J5 pops
	if prev.has("J"):
		var pj: Dictionary = prev.J
		# against the eye the motor moves (a sprint-swim breach moves the whole body 0.25 m in a 30 Hz tick legitimately)
		var eye: Vector3 = body.motor.swimmer.pos
		var dpel: Vector3 = (J.pelvis - eye) - (pj.pelvis - prev.get("eye", eye))
		_w("pelvis_jump", dpel.length())
		if dpel.length() > PELVIS_JUMP: _fail("J5", "pelvis jumped %.2f m against the eye" % dpel.length())
		for k in J:
			var v: float = ((J[k] - pj[k]) - dpel).length() / dt
			_w("pop", v)
			if v > POP_REL: _fail("J5", "%s moved %.1f m/s against the pelvis" % [k, v])
	prev.J = J
	prev.eye = body.motor.swimmer.pos
	# J6 world: spheres along limbs (mannequin radii)
	var samples := [["head", p.headMat * Vector3(0, 0.10, 0), 0.095], ["chest", p.chestPos, 0.08], ["pelvis", p.pelvisPos, 0.08]]
	for side in ["L", "R"]:
		var arm2: Dictionary = p["arm" + side]
		var lg2: Dictionary = p["leg" + side].ik
		samples.append(["uparm" + side, arm2.root.lerp(arm2.mid, 0.6), 0.032])
		samples.append(["elbow" + side, arm2.mid, 0.027])
		samples.append(["forearm" + side, arm2.mid.lerp(arm2.eff, 0.5), 0.025])
		samples.append(["hand" + side, (p["hand" + side + "Mat"] as Transform3D) * Vector3(0, 0.05, 0), 0.03])
		samples.append(["thigh" + side, lg2.root.lerp(lg2.mid, 0.5), 0.048])
		samples.append(["knee" + side, lg2.mid, 0.038])
		samples.append(["shin" + side, lg2.mid.lerp(lg2.eff, 0.5), 0.034])
		samples.append(["foot" + side, (p["leg" + side].finMat as Transform3D) * Vector3(0, 0.08, -0.02), 0.03])
	for smp in samples:
		var key2: String = smp[0]
		if _inside(smp[1], smp[2]):
			rec.pen[key2] = rec.pen.get(key2, 0) + 1
			rec.worst.pen_run = maxi(rec.worst.pen_run, rec.pen[key2])
			if rec.pen[key2] == PEN_RUN: _fail("J6", "%s inside rock" % key2)
		else:
			rec.pen[key2] = 0
	# J7 feet
	var walking := mode.begins_with("shore")
	for side in ["L", "R"]:
		var fin: Transform3D = p["leg" + side].finMat
		var soles := _sole_points_full(fin)
		var lowest_gap := INF
		for sp_ in soles:
			var h: Dictionary = wq.ray_down(sp_.x, sp_.z, sp_.y + 0.6, 2.0)
			if h.is_empty(): continue
			var gap: float = sp_.y - h.position.y
			lowest_gap = minf(lowest_gap, gap)
			if walking and gap < 0.0:
				# a sole point counts as sunk only if the point SOLE_UNDER above it is still inside rock
				var pq := PhysicsPointQueryParameters3D.new()
				pq.position = sp_ + Vector3(0, SOLE_UNDER, 0); pq.collision_mask = 1; pq.exclude = [body.get_rid()]
				if world.get_world_3d().direct_space_state.intersect_point(pq, 1).size() > 0:
					_w("sole_under", -gap)
					_fail("J7", "sole%s %.0f mm under the floor" % [side, -gap * 1000.0])
					if OS.has_environment("BS_SOLE"): print("    sole t=%.2f %s pt %d %s gap %.3f" % [t, side, soles.find(sp_), sp_.snappedf(0.001), gap])
		if cur.opts.get("stand", false) and t > 1.0 and is_finite(lowest_gap):
			_w("stand_gap", absf(lowest_gap))
			if absf(lowest_gap) > STAND_GAP: _fail("J7", "standing sole%s %.0f mm off the floor" % [side, lowest_gap * 1000.0])
		var ankle: Vector3 = p["leg" + side].ik.eff
		var planted: bool = not rig.world_foot_placer.feet[side].stepping and not body.motor.swimmer.shore_is_airborne
		if walking and planted and is_finite(lowest_gap):
			# slide: from touchdown, how far the heel and the ball have each moved; she slides if both have
			var heel: Vector3 = fin * Vector3(0, SOLE_HEEL, -0.046)
			var ball: Vector3 = fin * Vector3(0, 0.11, -0.046)
			if not rec.stance.has(side):
				rec.stance[side] = {"heel": heel, "ball": ball, "hover": 0}
			var st: Dictionary = rec.stance[side]
			var dh := Vector2(heel.x - st.heel.x, heel.z - st.heel.z).length()
			var db := Vector2(ball.x - st.ball.x, ball.z - st.ball.z).length()
			var slide := minf(dh, db)
			if OS.has_environment("BS_SLIDE") and slide > 0.008:
				var fpf = rig.world_foot_placer.feet[side]
				print("    slide t=%.2f %s heel %.0f ball %.0f mm  ank=%s fp=%s forced=%s otherStep=%s gap=%.3f" % [t, side, dh * 1000, db * 1000, ankle.snappedf(0.001), fpf.cur.snappedf(0.001), rig.world_foot_placer.forced[side], rig.world_foot_placer.feet["R" if side == "L" else "L"].stepping, lowest_gap])
			_w("skate", slide)
			if slide > SLIDE_MAX: _fail("J7", "foot%s slid %.0f mm while planted" % [side, slide * 1000.0])
			# hover: a planted foot must be on the ground
			st.hover = st.hover + 1 if lowest_gap > HOVER_GAP else 0
			if st.hover > 0: _w("stand_gap", lowest_gap)
			if st.hover >= HOVER_RUN: _fail("J7", "planted foot%s floating %.0f mm above the ground" % [side, lowest_gap * 1000.0])
		else:
			rec.stance.erase(side)
		prev["ankle" + side] = ankle
	# J8 self contact
	var L: Dictionary = p.legL.ik
	var R: Dictionary = p.legR.ik
	var pairs := [[L.root, L.mid, R.root, R.mid, 0.048 + 0.048], [L.mid, L.eff, R.mid, R.eff, 0.034 + 0.034],
		[L.root, L.mid, R.mid, R.eff, 0.048 + 0.034], [L.mid, L.eff, R.root, R.mid, 0.034 + 0.048]]
	for pr in pairs:
		var ov: float = pr[4] - _seg_dist(pr[0], pr[1], pr[2], pr[3])
		_w("leg_overlap", ov)
		if ov > 0.02: _fail("J8", "legs overlap %.0f mm" % (ov * 1000.0))
	for side in ["L", "R"]:
		var arm3: Dictionary = p["arm" + side]
		for pt in [arm3.mid.lerp(arm3.eff, 0.5), arm3.eff]:
			var cp: Vector3 = Geometry3D.get_closest_point_to_segment(pt, p.pelvisPos, p.neckPos)
			var sink: float = TORSO_R + 0.025 - pt.distance_to(cp)
			_w("torso_sink", sink)
			if sink > TORSO_SINK: _fail("J8", "arm%s %.0f mm into the torso" % [side, sink * 1000.0])

func _film_setup() -> void:
	var rock := Worlds.visual_material as StandardMaterial3D
	rock.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if cur.kind == "cave" else BaseMaterial3D.TRANSPARENCY_DISABLED
	rock.albedo_color.a = 0.35 if cur.kind == "cave" else 1.0
	mq = Mannequin.new(); world.add_child(mq)
	var we := WorldEnvironment.new(); var e := Environment.new()
	var under: bool = env.level > -999.0 and cur.p.start.y < env.level - 0.5
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.25, 0.35) if under else Color(0.55, 0.75, 0.88)
	e.background_intensity = 1.2     # nits: the project uses physical light units (as tools/motion_film.gd)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.6, 0.7, 0.75); e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	if under:
		e.fog_enabled = true; e.fog_light_color = Color(0.08, 0.35, 0.45); e.fog_density = 0.03
	we.environment = e; world.add_child(we)
	if env.level > -999.0:
		var sf := MeshInstance3D.new(); var sb := BoxMesh.new(); sb.size = Vector3(60, 0.04, 120); sf.mesh = sb
		var sfm := StandardMaterial3D.new(); sfm.albedo_color = Color(0.75, 0.92, 1.0, 0.45); sfm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sfm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; sfm.cull_mode = BaseMaterial3D.CULL_DISABLED; sf.material_override = sfm
		sf.position = Vector3(0, env.level, -20); world.add_child(sf)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-55, 35, 0); sun.light_energy = 1.4; sun.light_intensity_lux = PI * 1.2; sun.shadow_enabled = true; world.add_child(sun)
	cam = Camera3D.new(); cam.fov = 45.0; world.add_child(cam); cam.current = true
	film_case_dir = "%s/%s" % [film, cur.name.split(" ")[0] + ("_" + cur.name.split(" ")[2] if cur.name.begins_with("B12") or cur.name.begins_with("B14") else "")]
	DirAccess.make_dir_recursive_absolute(film_case_dir)
	frame_i = 0

func _film_frame(pose: Dictionary) -> void:
	mq.apply(pose, true)
	var p: Vector3 = body.global_position
	# documentary side camera, on the open side of each world (the wall world's wall is at +x)
	var side := Vector3(-3.2, 0.9, 1.6) if cur.kind in ["wall", "ramp", "step", "stairs", "overhang", "shore"] else Vector3(3.6, 0.8, 1.2)
	if cur.kind == "cave": side = Vector3(4.5, 1.2, 0.5)
	var tgt := p + Vector3(0, 0.75, 0)
	cam.global_position = cam.global_position.lerp(p + side, 0.15) if frame_i > 0 else p + side
	cam.look_at(tgt)
	var fails: String = "  ".join(rec.fail.map(func(f): return f.substr(0, f.find(" at t="))))
	label.text = "%s\nt = %.1f s   %s   %s" % [cur.name, t, pose.mode, "all checks holding" if fails == "" else "FAILING: " + fails]
	RenderingServer.frame_post_draw.connect(_film_save.bind("%s/f%05d.png" % [film_case_dir, frame_i]), CONNECT_ONE_SHOT)
	frame_i += 1

func _film_save(path: String) -> void:
	root.get_texture().get_image().save_png(path)

func _end_case() -> void:
	var ok: bool = rec.fail.is_empty()
	var w: Dictionary = rec.worst
	var summary := "bone %.2f mm, span %.0f%%, elbow %.0f, knee %.0f, knee back %.0f mm, neck +%.2f, head/chest %.0f, pop %.1f m/s, pelvis %.2f m, rock %d ticks, sole under %.0f mm, stand gap %.0f mm, slide %.0f mm, legs %.0f mm, torso %.0f mm" % [
		w.bone_mm, w.span * 100.0, w.elbow, w.knee, w.knee_back * 1000.0, w.neck, w.head_chest, w.pop, w.pelvis_jump, w.pen_run,
		w.sole_under * 1000.0, w.stand_gap * 1000.0, w.skate * 1000.0, w.leg_overlap * 1000.0, w.torso_sink * 1000.0]
	var fails: Array = rec.fail.map(func(f): return "%s  (%d ticks)" % [f, rec.count.get(f.substr(0, f.find(" ")), 1)])
	var known := ""
	for k in KNOWN:
		if cur.name.begins_with(k): known = KNOWN[k]
	var tag := "PASS" if ok else "FAIL"
	if known != "": tag = "XPASS" if ok else "KNOWN"
	print("%s  %s  [%s]  %s%s" % [tag, cur.name, ",".join(rec.modes), summary,
		"" if ok else "\n      " + "\n      ".join(fails)])
	results.append({"name": cur.name, "ok": ok, "known": known, "fail": rec.fail, "counts": rec.count, "modes": rec.modes, "worst": w})
	world.queue_free()
	world = null
	cur = {}

func _finish() -> bool:
	var npass := 0
	var nknown := 0
	var gate_ok := true
	for r in results:
		if r.ok: npass += 1
		elif r.known != "": nknown += 1
		else: gate_ok = false
	print("M04 body stress tick %d: %d/%d PASS, %d known open%s" % [tick, npass, results.size(), nknown, "  (planted fault: %s)" % fault if fault != "" else ""])
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"tick": tick, "fault": fault, "results": results}, "  "))
	quit(0 if gate_ok else 1)
	return true
