## M04 body stress test: the ported Thalassa body rig (core/m04_body) driven by the real motor on real Jolt worlds, every
## case the motor tests cover plus body-specific ones (standing, turning on the spot, jumps, hits, walls, ceilings),
## with body invariants checked every tick on every limb.
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/test_body_stress.gd -- [--tick 60] [--monkey 2]
##        [--monkey-secs 60] [--only B7] [--fault len|flip|clip|jitter] [--out /tmp/b.json]
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
##  J11 jitter       no small fast back-and-forth: for every joint (the J10 set), the head's facing and, in brain cases,
##                   the brain's gaze and breath signal, a reversal is a tick whose motion turns more than 90 deg from
##                   the last tick's, counted only when the stretch before it and the stretch after it each move more
##                   than JIT_AMP (1 mm; 0.2 deg for directions; 0.002 for the breath signal, 0..1) and less than 15x
##                   that (a step, a stroke or a breath swings centimetres; a shake does not). More than JIT_MAX
##                   (6) reversals inside any JIT_WIN (0.5 s) is jitter: a body does not reverse at 6 Hz on purpose
##                   (strokes, steps and breaths reverse at 0.2-3 Hz). Same thresholds at 30, 60 and 120 Hz.
##  J9 brain         (cases with "brain": the ported character brain fed points of interest and sounds through
##                   core/m04_body/sense_context.gd, line of sight by real rays)
##                   gaze   on land the brain's gaze stays inside the neck's reach from the chest (solve_head's yaw / pitch
##                          limits + 0.10 rad, or no further out than the look itself already is + 0.10); swimming (prone,
##                          chest to the sand) it turns at most 1.0 rad off the look direction
##                   head   the head's yaw / pitch against the chest never turn faster than 4 rad/s (a calm head turn is
##                          1-3 rad/s; a snap is a one-tick jump); the head's angular jerk p95 is reported
##                   focus  no ping-pong (back to a target within 4 s of leaving it for another), new things looked at
##                          at least 0.5 s apart (an urgent sound may interrupt at once, by design), sound turns at least
##                          the 4.6 s refractory apart, no target replaced by another within 0.3 s (flicker); at least
##                          one look and one sound turn happen
##                   breath phase only advances, at most 0.6 Hz; signal changes <= 2.5 /s, amplitude <= 1 /s, rate
##                          <= 1 rad/s^2 (continuous: no jumps); "effort" cases: the breath rate in the sprint is >= 1.3x
##                          the rate at rest and falls again after it
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
const PELVIS_JUMP := 0.12      # m per 1/60 s against the eye (a longer tick may move further, a shorter one is not held tighter)
const PEN_RUN := 3
const PEN_MARGIN := 0.02
const SOLE_UNDER := 0.02
const STAND_GAP := 0.03
const SLIDE_MAX := 0.03       # a planted foot: heel or ball may drift at most 3 cm over the whole stance (the other rolls)
const HOVER_GAP := 0.03       # a planted foot: lowest sole point at most 3 cm above the ground...
const HOVER_RUN := 6          # ...for more than this many ticks
const TORSO_R := 0.085
const TORSO_SINK := 0.03
const JIT_AMP := 0.001          # m
const JIT_AMP_DIR := 0.0035      # rad (0.2 deg)
const JIT_AMP_BREATH := 0.002
const JIT_WIN := 0.5             # s
const JIT_MAX := 6               # reversals per JIT_WIN
const JIT_BIG := 15.0            # x JIT_AMP: a stretch longer than this is deliberate motion, not a shake
const SenseContext := preload("res://core/m04_body/sense_context.gd")
const BM := preload("res://core/m04_body/body_math.gd")
const BRAIN_GAZE_YAW_PAD := 0.10
const BRAIN_SWIM_OFF_LOOK := 1.0  # rad: the brain's turn from the look while swimming (its reach window 0.92 x blend <= 0.66)
const BRAIN_HEAD_RATE := 4.0      # rad/s, neck yaw and pitch
const BRAIN_PINGPONG := 4.0       # s
const BRAIN_FOCUS_GAP := 0.5      # s between new things looked at (the brain's shortest scan beat after a loss is 0.55)
const BRAIN_SOUND_GAP := 4.6      # s, the brain's sound refractory
const BRAIN_FLICKER := 0.3        # s: a target replaced by another sooner than this is a flicker
const BRAIN_MAX_HZ := 0.6
const BRAIN_SIG_RATE := 2.5
const BRAIN_AMP_RATE := 1.0
const BRAIN_RATE_RATE := 1.0
const BRAIN_EFFORT_GAIN := 1.3

## Open cases, listed so the suite still gates everything else: a KNOWN case may fail (reported, not counted against
## the exit code); every other case must pass, and a KNOWN case that starts passing is reported so it can come off.
## Each entry says what fails and why, as found; fix one, then delete its line.
const KNOWN := {
	# empty since 27 Nov round 3: B35/B36 (30 deg slope across) and B37 (stairs) pass at 30/60/120 Hz
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
var film_close := false     # --close: a near side-on camera that frames the body (Gary: clearer, bigger shots of the body), 30 fps
var cam_side := Vector3.ZERO
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
			"--close": film_close = true
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
	# Mac playtest: a foot poked into the sand while she hovered and drifted slowly just above the floor (pool floor y=-20)
	_case("B44 hover low over the sand", "pool", {"start": Vector3(0, -17.5, 0), "mode": Motor.Mode.SWIM}, 12.0,
		func(tt): var k = _pk(Vector2(0, 0.35) if fmod(tt, 4.0) < 2.0 else Vector2.ZERO, tt * 0.3); k.descend = true; k.descend_amount = 0.4 if fmod(tt, 3.0) < 1.5 else 1.0; return k)
	# the brain (J9): points of interest around her (one moving, one behind, one hidden behind a rock) and loud sounds
	_case("B45 brain: swim among things, a loud sound behind, sprint and recover", "pool", {"start": Vector3(0, -8, 0), "mode": Motor.Mode.SWIM}, 22.0,
		func(tt):
			var k = _pk(Vector2(0, 0.3) if tt < 6.0 else (Vector2(0, 1) if tt < 11.0 else Vector2.ZERO), 0.35 * sin(tt * 0.4))
			k.thrust = 1.0 if (tt >= 6.0 and tt < 11.0) else 0.0
			return k, {"brain": "swim", "effort": [[2.0, 5.5], [9.0, 11.0], [20.0, 22.0]]})
	_case("B46 brain: stand idle on land, then walk, things to look at and sounds", "senses", {"start": Vector3(0, 0.05, 0)}, 20.0,
		func(tt): return _pk(Vector2(0, 0.7) if (tt >= 12.0 and tt < 16.0) else Vector2.ZERO, 0.2 * sin(tt * 0.25)), {"brain": "walk"})
	# Mac breach test: holding ascend and forward from the 2.4 m lagoon floor skimmed 20 m through the air
	_case("B47 lagoon: breach from the floor, ascend held", "lagoon_pool", {"start": Vector3(0, -1.4, 0), "mode": Motor.Mode.SWIM}, 12.0,
		func(_t): var k = _pk(Vector2(0, 1)); k.thrust = 1.0; k.ascend = true; return k)
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
	rec = {"name": cur.name, "jerk": [], "jk_by": {}, "fail": [], "ticks": 0, "modes": [], "pen": {}, "stance": {}, "count": {},
		"worst": {"bone_mm": 0.0, "span": 0.0, "elbow": 0.0, "knee": 0.0, "knee_back": 0.0, "neck": 0.0, "head_chest": 0.0,
			"pop": 0.0, "pelvis_jump": 0.0, "pen_run": 0, "sole_under": 0.0, "stand_gap": 0.0, "skate": 0.0, "leg_overlap": 0.0,
			"torso_sink": 0.0, "flips": 0}}
	if cur.opts.has("brain"): _brain_setup()
	# BS_QUIET=1: run every case on the quiet brain (to tell a brain-caused failure from a body one)
	if OS.has_environment("BS_QUIET"): rig.brain = preload("res://core/m04_body/quiet_brain.gd").new()
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
	var pose: Dictionary = rig.update_swim(rdt, s, null, t, renv, _brain_sense(s) if cur.opts.has("brain") else null)
	if fault == "jitter":
		_shift_pose(pose, Vector3(0.002 if int(rec.ticks) % 2 == 0 else -0.002, 0, 0))   # planted: the whole body shaking +-2 mm
	if fault == "flip" and rec.ticks == 120:
		var a: Dictionary = pose.armL
		a.mid = a.root + (a.root - a.mid)             # planted: elbow mirrored through the shoulder for one tick
	t += dt
	_check(pose, rdt)
	if film != "" and int(rec.ticks) % maxi(1, tick / (30 if film_close else 15)) == 0:
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
const BREACH_AIR_MAX := 1.4    # s: a 5.8 m/s launch is ~0.9 s out of the water
const SWIM_SOLE_SINK := 0.010   # quality ceiling: sole sink <= 1 cm
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
	# J12 (Mac breach test at the 2.4 m lagoon): holding ascend kept relaunching her off the water, a 20 m skim. A breach
	# is one arc: her eye may be out of the water (swimming, not standing or walking) for at most BREACH_AIR_MAX at a time
	if env.level > -999.0 and mode == "swim" and not body.motor.swimmer.shore_grounded:
		var sw_ = body.motor.swimmer
		if sw_.pos.y > env.water_y(sw_.pos.x, sw_.pos.z, t) + 0.10: rec.air_t = rec.get("air_t", 0.0) + dt
		else: rec.air_t = 0.0
		if rec.air_t > BREACH_AIR_MAX: _fail("J12", "out of the water %.1f s in one breach" % rec.air_t)
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
		var pj_lim: float = PELVIS_JUMP * maxf(1.0, dt * 60.0)
		if dpel.length() > pj_lim: _fail("J5", "pelvis jumped %.2f m against the eye" % dpel.length())
		for k in J:
			var v: float = ((J[k] - pj[k]) - dpel).length() / dt
			_w("pop", v)
			if v > POP_REL: _fail("J5", "%s moved %.1f m/s against the pelvis" % [k, v])
	# J10 smoothness (report): world jerk of every joint, the third difference of its path. Buttery motion keeps it low;
	# a pop, a snap or a step change in a speed shows as a spike. p95 over the case's ticks (the worst joint each tick)
	if prev.has("J") and prev.has("Jv"):
		var jmax := 0.0
		var jv := {}
		var ja := {}
		for k in J:
			var v3: Vector3 = (J[k] - prev.J[k]) / dt
			jv[k] = v3
			var a3: Vector3 = (v3 - prev.Jv[k]) / dt
			ja[k] = a3
			if prev.has("Ja"):
				var jj: float = ((a3 - prev.Ja[k]) / dt).length()
				jmax = maxf(jmax, jj)
				if OS.has_environment("BS_JERK"): rec.jk_by[k] = rec.jk_by.get(k, 0.0) + jj * jj
				if OS.has_environment("BS_JERKT") and k == "ankleL" and jj > float(OS.get_environment("BS_JERKT")):
					var fpl = rig.world_foot_placer.feet["L"]
					print("    jk t=%.3f ankleL %.0f step=%s ft=%.2f dur=%.3f v=%s a=%s" % [t, jj, fpl.stepping, fpl.t, fpl.dur, v3.snappedf(0.01), a3.snappedf(0.1)])
		prev.Jv = jv
		if prev.has("Ja"): rec.jerk.append(jmax)
		prev.Ja = ja
	elif prev.has("J"):
		var jv0 := {}
		for k in J: jv0[k] = (J[k] - prev.J[k]) / dt
		prev.Jv = jv0
	prev.J = J
	# J11 jitter
	if not prev.has("jit"): prev.jit = {}
	for k in J: _jitter(prev.jit, k, J[k], JIT_AMP)
	_jitter(prev.jit, "head facing", (p.headMotion.fwd as Vector3).normalized(), JIT_AMP_DIR)
	if cur.opts.has("brain") and rig.brain_out.has("breathSignal"):
		_jitter(prev.jit, "brain gaze", rig.brain_out.gazeDirWorld, JIT_AMP_DIR)
		_jitter(prev.jit, "breath signal", Vector3(rig.brain_out.breathSignal, 0, 0), JIT_AMP_BREATH)
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
		if p["leg" + side].has("toeMat"):
			# with a toe joint the toe end of the plate follows the toe bone (bent at the ball, toe frame origin = ball on the sole line)
			var tm: Transform3D = p["leg" + side].toeMat
			soles[2] = tm * Vector3(0, SOLE_TOE - 0.11, 0); soles[5] = tm * Vector3(SOLE_X, SOLE_TOE - 0.11, 0); soles[6] = tm * Vector3(-SOLE_X, SOLE_TOE - 0.11, 0)
		var lowest_gap := INF
		for sp_ in soles:
			var h: Dictionary = wq.ray_down(sp_.x, sp_.z, sp_.y + 0.6, 2.0)
			if h.is_empty(): continue
			var gap: float = sp_.y - h.position.y
			lowest_gap = minf(lowest_gap, gap)
			if not walking and gap < -SWIM_SOLE_SINK and h.normal.y > 0.5 and not wq.point_solid(sp_ + Vector3(0, 0.6, 0)):   # a floor, not a ceiling the ray started in
				# swimming (Mac playtest): settling onto the bottom put the feet into the sand. The point itself must be in
				# rock (a sole just under a thin slab's underside measures the slab's top as its floor)
				if wq.point_solid(sp_):
					_w("sole_under", -gap)
					_fail("J7", "swimming sole%s %.0f mm into the floor" % [side, -gap * 1000.0])
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
	if cur.opts.has("brain"): _check_brain(p, dt)
	for side in ["L", "R"]:
		var arm3: Dictionary = p["arm" + side]
		for pt in [arm3.mid.lerp(arm3.eff, 0.5), arm3.eff]:
			var cp: Vector3 = Geometry3D.get_closest_point_to_segment(pt, p.pelvisPos, p.neckPos)
			var sink: float = TORSO_R + 0.025 - pt.distance_to(cp)
			_w("torso_sink", sink)
			if sink > TORSO_SINK: _fail("J8", "arm%s %.0f mm into the torso" % [side, sink * 1000.0])

## J11: one signal's reversal counter (see the header). st holds per-signal state across ticks.
func _jitter(st: Dictionary, key: String, x: Vector3, amp: float) -> void:
	var j: Dictionary = st.get(key, {})
	if j.is_empty():
		st[key] = {"x": x, "d": Vector3.ZERO, "len": 0.0, "last": 0.0, "rev": []}
		return
	var dx: Vector3 = x - j.x
	j.x = x
	var L := dx.length()
	if L < 1e-9: return
	var turned: bool = j.d != Vector3.ZERO and dx.dot(j.d) < 0.0
	j.d = dx / L
	if not turned:
		j.len += L
		return
	# a turn back: the reversal between the last two stretches counts when both were small but real (amp..JIT_BIG x amp):
	# a step, a stroke or a breath swings far more than that, a shake does not
	var big := amp * JIT_BIG
	var counts: bool = j.last >= amp and j.last <= big and j.len >= amp and j.len <= big
	j.last = j.len
	j.len = L
	if counts:
		var rv: Array = j.rev
		rv.append(t)
		while rv.size() > 0 and rv[0] < t - JIT_WIN: rv.pop_front()
		rec.worst.jitter = maxi(rec.worst.get("jitter", 0), rv.size())
		if rv.size() > JIT_MAX: _fail("J11", "%s jitters: %d reversals in %.1f s" % [key, rv.size(), JIT_WIN])

## planted fault: move every point of the pose by off (bones keep their lengths)
func _shift_pose(p: Dictionary, off: Vector3) -> void:
	for k in ["chestPos", "pelvisPos", "neckPos", "waistPos", "shoulderL", "shoulderR", "hipL", "hipR", "clavicleL", "clavicleR"]:
		if p.has(k): p[k] += off
	for k in ["headMat", "chestMat", "pelvisMat", "handLMat", "handRMat", "torchMat"]:
		if p.has(k): p[k] = Transform3D(p[k].basis, p[k].origin + off)
	for k in ["armL", "armR"]:
		for q in ["root", "mid", "eff"]: p[k][q] += off
	for k in ["legL", "legR"]:
		for q in ["root", "mid", "eff"]: p[k].ik[q] += off
		for m in ["finMat", "toeMat"]:
			if p[k].has(m): p[k][m] = Transform3D(p[k][m].basis, p[k][m].origin + off)
	p.headMotion.pos += off

# ---------------------------------------------------------------- brain cases (J9)
func _brain_setup() -> void:
	var st: Vector3 = cur.p.start
	var sc = SenseContext.new()
	sc.world = wq
	var reg := ActorRegistry.new()
	sc.registry = reg; sc.self_id = "girl"
	var swim: bool = cur.opts.brain == "swim"
	if swim:
		Worlds.box(world, st + Vector3(2.2, 0, -6), Vector3(2, 3, 2), 0)      # a rock between her and the vent
		sc.landmarks = [
			{"id": "arch", "kind": "arch", "label": "Arch", "pos": st + Vector3(-4, 1, -10), "priority": 0.8, "selfRadius": 2.0, "maxRange": 54.0},
			{"id": "vent", "kind": "vent", "label": "Vent (behind the rock)", "pos": st + Vector3(5, -1, -15), "priority": 0.8, "selfRadius": 1.0, "maxRange": 54.0}]
		reg.add("fish", "fish", 0.3, {"label": "Fish", "priority": 0.87})
		reg.add("buoy", "vessel", 0.6, {"label": "Buoy behind", "priority": 0.8, "moving": false, "pos": st + Vector3(0, 0.5, 6)})
		rec.brain_sounds = [[4.0, "impact", Vector3(3, 0, 4), 0.95], [13.0, "ping", Vector3(6, 0, -2), 0.6], [16.0, "crack", Vector3(-4, 1, 3), 0.9]]
	else:
		# the blockout kit's "senses" world (blockout/blockout_kit.gd): an object ahead, a creature circling, an object
		# behind her, a knock that sounds 0.5 s every 3 s; read each tick through BlockoutKit.pois
		rec.brain_sounds = []
	rec.brain = {"sc": sc, "reg": reg, "swim": swim, "focus": "", "focus_t": -99.0, "left": {}, "last_new": -99.0, "last_snd": -99.0,
		"looks": 0, "sounds": 0, "prev": {}, "rates": [], "head_rate": 0.0, "gaze_yaw": 0.0, "hjerk": []}

func _brain_sense(s) -> Dictionary:
	var b: Dictionary = rec.brain
	var st: Vector3 = cur.p.start
	var reg: ActorRegistry = b.reg
	var eye: Vector3 = s.pos
	reg.begin()
	if b.swim:     # a fish circling her at 3 m, bobbing: in and out of view
		var fp := eye + Vector3(3.0 * cos(t * 0.6), 0.6 * sin(t * 0.9), 3.0 * sin(t * 0.6))
		reg.move("fish", fp, Vector3.ZERO)
		# the player UI's interact target, engaged every tick as the game does (it circles behind her in this window)
		if t >= 7.0 and t < 9.5: rig.brain.engage_objective_focus("interact", fp)
	else:
		var lm := []
		for q in BlockoutKit.pois(world):
			if q.kind == "sound":
				if q.alive and not b.get("snd_" + q.name, false):     # each knock as it starts
					rig.brain.register_sound_event(q.name, q.pos, 0.9, 1.8)
				b["snd_" + q.name] = q.alive
			else:
				var cr: bool = q.kind == "creature"
				# interact target engaged every tick: the object behind her (out of the neck's reach), then the one ahead
				if (q.name == "behind" and t >= 5.0 and t < 7.0) or (q.name == "ahead" and t >= 9.0 and t < 10.5):
					rig.brain.engage_objective_focus("interact", q.pos)
				lm.append({"id": q.name, "kind": "fauna" if cr else "console", "label": q.name, "pos": q.pos,
					"priority": 0.9 if cr else 0.78, "moving": cr, "selfRadius": 0.3, "maxRange": 32.0})
		b.sc.landmarks = lm
	reg.commit(int(rec.ticks))
	for snd in rec.brain_sounds:     # sounds placed around where she is when they ring
		if t >= snd[0] and t - 1.0 / tick < snd[0]:
			rig.brain.register_sound_event(snd[1], eye + snd[2], snd[3], 1.8)
	return b.sc.build(s.pos, BM.fwd(s.yaw, s.pitch), [])

func _check_brain(p: Dictionary, dt: float) -> void:
	var b: Dictionary = rec.brain
	var o: Dictionary = rig.brain_out
	if o.is_empty() or not o.has("gazeDirWorld"): return
	# gaze inside the neck's reach from the chest, beyond what the look itself already asks (swimming prone the chest
	# faces the sand and the look ahead is already past the neck's pitch; the brain must not add to it)
	var cm: Basis = p.chestMat.basis
	var cf: Vector3 = -cm.z.normalized(); var cx: Vector3 = cm.x.normalized(); var cy: Vector3 = cm.y.normalized()
	var g: Vector3 = o.gazeDirWorld
	var sw = body.motor.swimmer
	var lk := BM.fwd(sw.yaw, sw.pitch)
	var gyaw := atan2(g.dot(cx), g.dot(cf)); var lyaw := atan2(lk.dot(cx), lk.dot(cf))
	var gpitch := asin(clampf(g.dot(cy), -1.0, 1.0)); var lpitch := asin(clampf(lk.dot(cy), -1.0, 1.0))
	var off_look := acos(clampf(g.dot(lk), -1.0, 1.0))
	b.gaze_yaw = maxf(b.gaze_yaw, off_look)
	if p.mode == "swim":
		# prone, the chest faces the sand: yaw / pitch in its frame are ill-conditioned round the look ahead, so the
		# brain's own turn is checked: at most BRAIN_SWIM_OFF_LOOK from where she looks (solve_head takes it from there)
		if off_look > BRAIN_SWIM_OFF_LOOK: _fail("J9 gaze", "brain gaze %.2f rad off the look" % off_look)
	else:
		var ylim := maxf(0.96 + BRAIN_GAZE_YAW_PAD, absf(lyaw) + BRAIN_GAZE_YAW_PAD)
		var plo := minf(-0.54 - BRAIN_GAZE_YAW_PAD, lpitch - BRAIN_GAZE_YAW_PAD)
		var phi := maxf(0.60 + BRAIN_GAZE_YAW_PAD, lpitch + BRAIN_GAZE_YAW_PAD)
		if absf(gyaw) > ylim: _fail("J9 gaze", "brain gaze yaw %.2f rad from the chest (neck reach %.2f, look %.2f)" % [gyaw, ylim, lyaw])
		if gpitch < plo or gpitch > phi: _fail("J9 gaze", "brain gaze pitch %.2f rad from the chest (look %.2f)" % [gpitch, lpitch])
	# head: no snaps (the head's yaw and pitch in the chest frame: the swim / walk blend pose reports no neck angles)
	var hm: Dictionary = p.headMotion
	var hf: Vector3 = (hm.fwd as Vector3).normalized()
	var hy := atan2(hf.dot(cx), hf.dot(cf))
	var hp := asin(clampf(hf.dot(cy), -1.0, 1.0))
	var pv: Dictionary = b.prev
	var hl := Vector3(hf.dot(cx), hf.dot(cy), hf.dot(cf))      # the head's forward in the chest frame
	if pv.has("ny"):
		# ROOT (B45 interact window): yaw / pitch deltas blow up where the head's forward nears the chest's up (swimming
		# prone, looking ahead), so a smooth turn read 4.7 rad/s; the rate is the angle the head swept in the chest frame
		var rate: float = (pv.hl as Vector3).angle_to(hl) / dt
		b.head_rate = maxf(b.head_rate, rate)
		if rate > BRAIN_HEAD_RATE: _fail("J9 head", "head turned %.1f rad/s against the chest" % rate)
		var w := Vector2(wrapf(hy - pv.ny, -PI, PI), hp - pv.np) / dt
		if pv.has("w"):
			var a: Vector2 = (w - pv.w) / dt
			if pv.has("a"): b.hjerk.append(((a - pv.a) / dt).length())
			pv.a = a
		pv.w = w
	pv.ny = hy; pv.np = hp; pv.hl = hl
	# focus: dwell, cooldowns, no ping-pong
	var fid = o.get("focusId")
	var fs: String = fid if fid != null else ""
	if fs != b.focus:
		if b.focus != "":
			b.left[b.focus] = t
			if t - b.focus_t < BRAIN_FLICKER and fs != "" and not o.get("focusIsSound", false): _fail("J9 focus", "%s held only %.2f s before %s took over" % [b.focus, t - b.focus_t, fs])
		b.focus_t = t
		if fs != "":
			# ping-pong: A, then another thing looked at, then A again within 4 s (turning to a sound and back is not)
			var vis_prev: String = b.get("vis_prev", "")
			if not o.get("focusIsSound", false) and vis_prev != "" and vis_prev != fs and b.left.has(fs) and t - b.left[fs] < BRAIN_PINGPONG \
					and b.left.get(vis_prev, -99.0) > b.left[fs]:
				_fail("J9 focus", "ping-pong back to %s after %.1f s" % [fs, t - b.left[fs]])
			if not o.get("focusIsSound", false): b.vis_prev = fs
			if o.get("focusIsSound", false):
				if t - b.last_snd < BRAIN_SOUND_GAP - 1e-6: _fail("J9 focus", "sound turn %.1f s after the last" % (t - b.last_snd))
				b.last_snd = t; b.sounds += 1
			else:
				if t - b.last_new < BRAIN_FOCUS_GAP: _fail("J9 focus", "new target %s %.2f s after the last" % [fs, t - b.last_new])
				b.last_new = t
				b.looks += 1
		b.focus = fs
	# breath: continuous, paced by effort
	if pv.has("bp"):
		var dph := fposmod(float(o.breathPhase) - pv.bp, 1.0)
		if dph > BRAIN_MAX_HZ * dt * 1.001: _fail("J9 breath", "breath phase jumped %.3f in a tick" % dph)
		if absf(o.breathSignal - pv.bs) / dt > BRAIN_SIG_RATE: _fail("J9 breath", "breath signal %.1f /s" % (absf(o.breathSignal - pv.bs) / dt))
		if absf(o.breathAmp - pv.ba) / dt > BRAIN_AMP_RATE: _fail("J9 breath", "breath amplitude %.2f /s" % (absf(o.breathAmp - pv.ba) / dt))
		if absf(o.breathRate - pv.br) / dt > BRAIN_RATE_RATE: _fail("J9 breath", "breath rate changing %.2f rad/s^2" % (absf(o.breathRate - pv.br) / dt))
	pv.bp = o.breathPhase; pv.bs = o.breathSignal; pv.ba = o.breathAmp; pv.br = o.breathRate
	b.rates.append([t, o.breathRate])

func _brain_end() -> String:
	var b: Dictionary = rec.brain
	if b.looks == 0: _fail("J9 focus", "she never looked at anything")
	if b.sounds == 0: _fail("J9 focus", "she never turned to a sound")
	var win := func(a: float, z: float) -> float:
		var sm := 0.0; var n := 0
		for r in b.rates:
			if r[0] >= a and r[0] < z: sm += r[1]; n += 1
		return sm / maxf(1.0, n)
	var eff_txt := ""
	if cur.opts.has("effort"):
		var e: Array = cur.opts.effort
		var rest: float = win.call(e[0][0], e[0][1]); var peak: float = win.call(e[1][0], e[1][1]); var after: float = win.call(e[2][0], e[2][1])
		eff_txt = ", breath %.2f -> %.2f -> %.2f rad/s" % [rest, peak, after]
		if peak < rest * BRAIN_EFFORT_GAIN: _fail("J9 breath", "sprint breath %.2f rad/s not above rest %.2f x %.1f" % [peak, rest, BRAIN_EFFORT_GAIN])
		if after >= peak: _fail("J9 breath", "breath did not settle after the sprint (%.2f -> %.2f)" % [peak, after])
	var hj: Array = b.hjerk.duplicate(); hj.sort()
	return "; brain: %d looks, %d sound turns, gaze off look max %.2f rad, head rate max %.2f rad/s, head ang. jerk p95 %.0f rad/s3%s" % [
		b.looks, b.sounds, b.gaze_yaw, b.head_rate, hj[int(hj.size() * 0.95)] if hj.size() > 0 else 0.0, eff_txt]

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
	if film_close:
		# side-on to her heading, 2.3 m out, framing her from feet to head; the side follows her slowly so turns stay readable
		var pel: Vector3 = pose.pelvisPos
		var br: Vector3 = pose.get("bodyRight", Vector3.RIGHT)
		br.y = 0.0
		if br.length() < 0.1: br = Vector3.RIGHT
		br = br.normalized()
		if cam_side == Vector3.ZERO or frame_i == 0: cam_side = br
		if cam_side.dot(br) < 0.0: br = -br     # (keep the same side when she reverses)
		cam_side = cam_side.slerp(br, 0.06).normalized()
		tgt = pel + Vector3(0, 0.08, 0)
		var cp := tgt + cam_side * 2.6 + Vector3(0, 0.10, 0)
		cam.fov = 38.0
		cam.global_position = cam.global_position.lerp(cp, 0.35) if frame_i > 0 else cp
		cam.look_at(tgt)
		var fails0: String = "  ".join(rec.fail.map(func(f): return f.substr(0, f.find(" at t="))))
		label.text = "%s\nt = %.1f s   %s   %s" % [cur.name, t, pose.mode, "all checks holding" if fails0 == "" else "FAILING: " + fails0]
		RenderingServer.frame_post_draw.connect(_film_save.bind("%s/f%05d.png" % [film_case_dir, frame_i]), CONNECT_ONE_SHOT)
		frame_i += 1
		return
	cam.global_position = cam.global_position.lerp(p + side, 0.15) if frame_i > 0 else p + side
	cam.look_at(tgt)
	var fails: String = "  ".join(rec.fail.map(func(f): return f.substr(0, f.find(" at t="))))
	label.text = "%s\nt = %.1f s   %s   %s" % [cur.name, t, pose.mode, "all checks holding" if fails == "" else "FAILING: " + fails]
	RenderingServer.frame_post_draw.connect(_film_save.bind("%s/f%05d.png" % [film_case_dir, frame_i]), CONNECT_ONE_SHOT)
	frame_i += 1

func _film_save(path: String) -> void:
	root.get_texture().get_image().save_png(path)

func _end_case() -> void:
	var brain_txt: String = _brain_end() if cur.opts.has("brain") else ""
	var ok: bool = rec.fail.is_empty()
	var w: Dictionary = rec.worst
	var summary := "bone %.2f mm, span %.0f%%, elbow %.0f, knee %.0f, knee back %.0f mm, neck +%.2f, head/chest %.0f, pop %.1f m/s, pelvis %.2f m, rock %d ticks, sole under %.0f mm, stand gap %.0f mm, slide %.0f mm, legs %.0f mm, torso %.0f mm" % [
		w.bone_mm, w.span * 100.0, w.elbow, w.knee, w.knee_back * 1000.0, w.neck, w.head_chest, w.pop, w.pelvis_jump, w.pen_run,
		w.sole_under * 1000.0, w.stand_gap * 1000.0, w.skate * 1000.0, w.leg_overlap * 1000.0, w.torso_sink * 1000.0]
	var jk: Array = rec.jerk.duplicate()
	jk.sort()
	var jerk_p95: float = jk[int(jk.size() * 0.95)] if jk.size() > 0 else 0.0
	var jerk_p50: float = jk[int(jk.size() * 0.50)] if jk.size() > 0 else 0.0
	w["jerk_p95"] = jerk_p95
	w["jerk_p50"] = jerk_p50
	summary += ", jerk p50 %.0f p95 %.0f m/s3, jitter %d rev/%.1fs" % [jerk_p50, jerk_p95, w.get("jitter", 0), JIT_WIN] + brain_txt
	if OS.has_environment("BS_JERK"):
		for k in rec.jk_by: summary += "\n        jerk %s rms %.0f" % [k, sqrt(rec.jk_by[k] / maxf(1.0, rec.jerk.size()))]
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
