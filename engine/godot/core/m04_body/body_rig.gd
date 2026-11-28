## M04 Body, core 0.1.0: GDScript port of Thalassa v20.19 core/ik-rig.js DiverBodyRig (free swim, shore walk/wade
## and the swim <-> walk blend from core/ik-poses-world.js). 1.38 m girl, NASA neutral-body-posture springs, soft
## joint limits, breaststroke + flutter kick, foot placement on land, anatomical head, no-clip limbs.
## Differences from the JS (each written down):
## - the brain is the ported character-brain.js (character_brain.gd); thalassa_exact runs swap in quiet_brain.gd, the
##   stand-in the golden body trace was recorded with, so the rig port stays checked on its own;
## - HairBobPhysics is not ported: the minimal mannequin has no hair (its bob meshes are 1 mm placeholders);
## - buildUE5SkeletonPose is not ported (only the .glb skinning used it);
## - cockpit / deck / helm / mantle / ride poses come with their modules.
## env Callables: floor_height(x, z) -> float (-INF none), floor_normal(x, z) -> Vector3,
##   nearest_surface(p, r, filter = null) -> {dist, normal, point} or {} (filter(p: Vector3, n: Vector3) -> bool)
extends RefCounted

const BM := preload("res://core/m04_body/body_math.gd")
const PhysicsControl := preload("res://core/m04_body/physics_control.gd")
const FootPlacer := preload("res://core/m04_body/foot_placer.gd")
const QuietBrain := preload("res://core/m04_body/quiet_brain.gd")
const CharacterBrain := preload("res://core/m04_body/character_brain.gd")

## true = reproduce Thalassa v20.19 exactly, bugs included (the golden test sets it). false = with the fixes the body
## stress test (tests/test_body_stress.gd) forced; each one is marked FIX and listed in CHANGELOG.md.
var thalassa_exact := false:
	set(v):
		thalassa_exact = v
		brain = QuietBrain.new() if v else CharacterBrain.new()
var ground_follow := NAN
var noclip_off := {}
var _step_dt := 1.0 / 60.0
const NOCLIP_RATE := 3.0
const HARD_MISS := 0.03     # m: a planted foot this far out of reach steps at once, even just landed (foot_placer.FORCED_HARD)
const MAX_STEP := 1.0 / 55.0     # longest rig step; a longer frame is caught up in sub-steps (30 Hz runs as two 60 Hz steps)
const SWIM_ANKLE_RATE := 6.0
var swim_ankle_rel := {}
var swim_fold := {}         # per side: how far each leg is folded toward trim to keep the foot out of the sand
var swing_floor := {"L": NAN, "R": NAN}
var swing_floor_v := {"L": 0.0, "R": 0.0}     # the speed the swing floor is rising at
var pelv_yaw_off := 0.0     # pelvis held back by a planted foot's hip rotation range (fast turns)
var support_dg := 0.0     # pelvis ground from the feet's support minus the floor under her centre (stairs)
var pelvis_yield := 0.0     # how far the pelvis is lowered so a planted foot stays reachable
var pivot_carry := {"L": Vector3.ZERO, "R": Vector3.ZERO}     # the planted foot's last pivot offset, faded through lift-off
var land_drop := {"L": -INF, "R": -INF}     # a foot that touched down above where it stands settles, not snaps
var last_ank := {"L": NAN, "R": NAN}
var last_stepping := {"L": false, "R": false}
var swing_soft := {"L": 0.0, "R": 0.0}     # running: extra soft-reach margin of a swinging leg (see shore_leg)
var plant_off := {"L": Vector2.ZERO, "R": Vector2.ZERO}     # where the contact touched down, against where the plant puts it
var plant_fresh := {"L": true, "R": true}
var land_age := {"L": 0.0, "R": 0.0}     # seconds each foot has been planted
const SWIM_SOLE_CLEAR := 0.015   # swimming: sole plate kept this far above the floor
const SWIM_KNEE_CLEAR := 0.07    # and the knee joint centre (the knee cap's radius plus a little)
const SWIM_FOLD_W_IN := 40.0    # swimming leg fold spring, rad/s: folding away from the sand
const SWIM_FOLD_W_OUT := 7.0    # and unfolding again
const FOOT_R := 0.035       # foot half-width used for wall clearance
## The sole plate's heel, ball-centre and toe ends plus its four corners in the foot frame (the mannequin's sole box:
## centre (0, 0.058, -0.046), 0.056 x 0.168), 4 mm above its underside: what the toe lift keeps out of the ground.
const SOLE_PTS := [Vector3(0, -0.026, -0.048), Vector3(0, 0.058, -0.048), Vector3(0, 0.142, -0.048),
	Vector3(0.028, -0.026, -0.048), Vector3(-0.028, -0.026, -0.048), Vector3(0.028, 0.142, -0.048), Vector3(-0.028, 0.142, -0.048)]
## the toe end of the plate with the toes bent up 1 rad at the ball: what even a full toe bend can't clear still lifts the ankle
const SOLE_PTS_TOE_BENT := [Vector3(0, 0.11 + 0.032 * 0.5403, -0.048 + 0.032 * 0.8415), Vector3(0.028, 0.11 + 0.032 * 0.5403, -0.048 + 0.032 * 0.8415),
	Vector3(-0.028, 0.11 + 0.032 * 0.5403, -0.048 + 0.032 * 0.8415)]
## planted: the heel, mid and ball rows (the toes bend at the ball and lie on the ground, see _skeleton)
const SOLE_PTS_PLANTED := [Vector3(0, -0.026, -0.048), Vector3(0, 0.058, -0.048), Vector3(0, 0.11, -0.048),
	Vector3(0.028, -0.026, -0.048), Vector3(-0.028, -0.026, -0.048), Vector3(0.028, 0.11, -0.048), Vector3(-0.028, 0.11, -0.048)]
const NECK_LEN := 0.118      # chest to skull base, Thalassa's standing value
var stature_m := 1.38
var upper_arm_len := 0.245
var forearm_len := 0.228
var thigh_len := 0.345
var shin_len := 0.335
var shoulder_half_w := 0.132
var hip_half_w := 0.088

var body_yaw := 0.12
var _spawned := false
var body_pitch := 1.32
var body_roll := 0.0
var swim_blend := 0.0
var sprint_blend := 0.0
var reverse_blend := 0.0
var strafe_blend := 0.0
var vert_blend := 0.0
var arm_phase := 0.0
var kick_phase := 0.0
var breath_phase := 0.0
var prev_ubr := 0.0
var brace_l := 0.0
var brace_r := 0.0
var prev_vel := Vector3.ZERO
var smooth_accel := Vector3.ZERO
var prev_yaw := 0.12
var smooth_yaw_vel := 0.0
var impact_energy := 0.0
var seabed_align_blend := 0.0

var pitch_spring = BM.SoftJoint1D.new(1.32, -1.40, 2.28, 0.30, 1.32)
var roll_spring = BM.SoftJoint1D.new(0.0, -0.56, 0.56, 0.14, 0.0)
var glide_blend := 0.0
var seabed_align_spring = BM.CritSpring1D.new(0.0)
var support_y_spring = BM.CritSpring1D.new(-20.0)
var _support_y_init := false
var swim_lift_spring = BM.CritSpring1D.new(0.0)
var ankle_lift_spring_l = BM.CritSpring1D.new(0.0)
var ankle_lift_spring_r = BM.CritSpring1D.new(0.0)
var swim_spine_push = BM.CritSpring3D.new()
var swim_arm_push_l = BM.CritSpring3D.new()
var swim_arm_push_r = BM.CritSpring3D.new()
var swim_foot_push_l = BM.CritSpring3D.new()
var swim_foot_push_r = BM.CritSpring3D.new()
var arm_spring_l = BM.SoftJoint3D.new(Vector3(-0.36, -0.02, 0.50), Vector3(-0.66, -0.36, -0.10), Vector3(0.16, 0.72, 0.72), Vector3(0.14, 0.16, 0.14))
var arm_spring_r = BM.SoftJoint3D.new(Vector3(0.36, -0.02, 0.50), Vector3(-0.16, -0.36, -0.10), Vector3(0.66, 0.72, 0.72), Vector3(0.14, 0.16, 0.14))
var leg_spring_l = BM.SoftJoint3D.new(Vector3(0.58, 0.14, -0.09), Vector3(0.30, -0.22, -0.34), Vector3(0.68, 0.50, 0.08), Vector3(0.08, 0.08, 0.08))
var leg_spring_r = BM.SoftJoint3D.new(Vector3(0.58, 0.14, 0.09), Vector3(0.30, -0.22, -0.08), Vector3(0.68, 0.50, 0.34), Vector3(0.08, 0.08, 0.08))
var fin_spring_l = BM.SoftJoint1D.new(0.32, -0.58, 0.96, 0.24, 0.32)
var fin_spring_r = BM.SoftJoint1D.new(0.32, -0.58, 0.96, 0.24, 0.32)

var light_button_timer := 0.0
var light_button_duration := 0.54
var light_button_depression := 0.0

var world_foot_placer = FootPlacer.new({"stanceHalfWidth": 0.088, "walkStepHeight": 0.044, "runStepHeight": 0.102})
var physics_control = PhysicsControl.new("underwater_active_ragdoll")
var brain = CharacterBrain.new()
var brain_out := {}          # the brain's last output (breath phase / signal / rate / amp, gaze, focus): the body's pacemaker
var _brain_fresh := false    # stepped during this rig step already
var head_yaw_spring = BM.CritSpring1D.new(0.0)
var head_pitch_spring = BM.CritSpring1D.new(0.0)

var swim_pose = null
var left_wrist_light_pos := Vector3(0, -6.5, 16.5)
var left_wrist_light_dir := Vector3(0, 0, -1)

func apply_impact_impulse(world_dir, intensity := 0.6, kind := "bump") -> void:
	var mag := clampf(intensity, 0.05, 0.65) * (0.24 if kind == "bump" else 0.55)
	impact_energy = minf(1.1, impact_energy + mag)
	physics_control.trigger_hit_reaction("Spine" if kind == "burst" else "All", clampf(mag * 0.65, 0.14, 0.75))
	var lr := 0.0; var ly := 0.0; var lb := -1.0
	if swim_pose != null and world_dir != null:
		var d := BM.nrm(world_dir)
		lr = d.dot(swim_pose.bodyRight); ly = d.dot(swim_pose.bodyAxisY); lb = -d.dot(swim_pose.bodyBack)
	if kind == "splash":
		arm_spring_l.add_impulse(Vector3(-0.55, 0.80, 0.30) * mag)
		arm_spring_r.add_impulse(Vector3(0.55, 0.80, 0.30) * mag)
		leg_spring_l.add_impulse(Vector3(-0.25, -0.55, -0.20) * mag)
		leg_spring_r.add_impulse(Vector3(-0.25, -0.55, 0.20) * mag)
		pitch_spring.add_impulse(-0.55 * mag)
	elif kind == "burst":
		arm_spring_l.add_impulse(Vector3(-0.22, -0.48, -0.15) * mag)
		arm_spring_r.add_impulse(Vector3(0.22, -0.48, -0.15) * mag)
		leg_spring_l.add_impulse(Vector3(0.22, 0.55, -0.10) * mag)
		leg_spring_r.add_impulse(Vector3(0.22, -0.55, 0.10) * mag)
	else:
		arm_spring_l.add_impulse(Vector3(-0.28 - lr * 0.40, 0.18 + ly * 0.38, -0.42 + lb * 0.35) * mag)
		arm_spring_r.add_impulse(Vector3(0.28 - lr * 0.40, 0.18 + ly * 0.38, -0.42 + lb * 0.35) * mag)
		leg_spring_l.add_impulse(Vector3(-0.14, 0.48 - lb * 0.35, -0.16 + lr * 0.30) * mag)
		leg_spring_r.add_impulse(Vector3(-0.14, 0.42 - lb * 0.35, 0.16 + lr * 0.30) * mag)
		pitch_spring.add_impulse((lb * 0.45 - 0.15) * mag)
		roll_spring.add_impulse((-lr * 0.55) * mag)

func trigger_light_button_reach() -> void:
	light_button_timer = light_button_duration

## updateTimers (runtime calls it every step before the mover)
func update_timers(dt: float) -> float:
	physics_control.update(dt)
	if light_button_timer > 0.0: light_button_timer = maxf(0.0, light_button_timer - dt)
	var bp := sin((1.0 - light_button_timer / light_button_duration) * PI) if light_button_timer > 0.0 else 0.0
	light_button_depression = smoothstep(0.15, 0.95, bp)
	return bp

## _pushPointClearOfSurfaces (surf: {floor_height, nearest_surface})
func push_clear(pt: Vector3, radius: float, surf, max_push := 0.55) -> Vector3:
	if surf == null: return pt
	var q_world = surf.get("nearest_surface")
	var q_floor = surf.get("floor_height")
	if q_world == null and q_floor == null: return pt
	var o := pt
	for _pass in 2:
		var moved := false
		if q_world != null:
			var hit: Dictionary = q_world.call(o, radius + 0.03, null)
			var q_solid = surf.get("point_solid")
			if not hit.is_empty() and hit.has("normal") and q_solid != null and q_solid.call(o):
				# FIX (stress B42 at 30 Hz): a point buried deeper than its radius (one long tick sweeping a trailing
				# foot into a wall) was left inside: out along the contact normal past the surface instead
				o += hit.normal * (radius + hit.dist)
				moved = true
			elif not hit.is_empty() and hit.dist < radius and hit.has("normal"):
				o += hit.normal * (radius - hit.dist)
				moved = true
		if q_floor != null:
			var fy: float = q_floor.call(o.x, o.z)
			# FIX (stress B42): with ledges and overhangs a point well below the floor straight above it is under a
			# slab or beside a wall, not sunk into a height-field: lifting it onto the top (0.5 m+) threw the leg round.
			# The ray and the surface push above handle it.
			var under: bool = surf.has("ray") and o.y < fy - 0.12
			if is_finite(fy) and o.y < fy + radius and not under:
				o.y = fy + radius
				moved = true
		if not moved: break
	var d := o - pt
	var dl := d.length()
	if dl > max_push and dl > 1e-5:
		return pt + d * (max_push / dl)
	return o

func solve_noclip_arm(sh: Vector3, target: Vector3, pole: Vector3, surf, o := {}) -> Dictionary:
	var sr: float = o.get("softReach", 0.985)
	var sm: float = o.get("softMargin", 0.04)
	var mf: float = o.get("maxFlexDeg", 138.0)
	var wr: float = o.get("wristRadius", 0.030)
	var er: float = o.get("elbowRadius", 0.048)
	var eff_t := push_clear(target, wr, surf, 0.35)
	var cp := pole
	var ik := BM.two_bone(sh, eff_t, cp, upper_arm_len, forearm_len, sr, sm, mf)
	if surf != null:
		for _pass in 2:
			var adj := false
			var mc := push_clear(ik.mid, er, surf, 0.35)
			var md: Vector3 = mc - ik.mid
			var mw := smoothstep(0.002, 0.018, md.length())
			if mw > 0.001:
				cp += md * (1.85 * mw); adj = true
			var fm: Vector3 = ik.mid.lerp(ik.eff, 0.55)
			var fc := push_clear(fm, wr + 0.008, surf, 0.30)
			var fd := fc - fm
			var fw := smoothstep(0.002, 0.018, fd.length())
			if fw > 0.001:
				eff_t += fd * (0.52 * fw); cp += fd * (1.15 * fw); adj = true
			if not adj: break
			ik = BM.two_bone(sh, eff_t, cp, upper_arm_len, forearm_len, sr, sm, mf)
	return ik

## how far the solved leg's sole plate (or knee) is under the floor beneath it, plus the clearance wanted
## (a "floor" above her hips is a ledge or slab she is passing under or beside, not ground the leg can fold away from)
func _leg_floor_short(solved: Dictionary, get_floor, clear: float) -> float:
	var short := 0.0
	var top: float = solved.ik.root.y - 0.10
	# the floor is sampled once, under the lowest point of the plate (two rays a leg: this runs every swimming tick)
	var low := Vector3(0, INF, 0)
	for e in SOLE_PTS:
		var q: Vector3 = solved.finMat * e
		if q.y < low.y: low = q
	var fy: float = get_floor.call(low.x, low.z)
	if is_finite(fy) and fy < top: short = fy + clear - low.y
	var kq: Vector3 = solved.ik.mid
	var fk: float = get_floor.call(kq.x, kq.z)
	if is_finite(fk) and fk < top: short = maxf(short, fk + SWIM_KNEE_CLEAR - kq.y)
	return short

func solve_noclip_leg(hip: Vector3, raw_ankle: Vector3, side: float, pd: Vector3, pf: Vector3, surf, lo := {}) -> Dictionary:
	var at := raw_ankle
	if surf != null and not thalassa_exact and surf.has("ray"):
		# FIX (stress B42): a leg trailing past a rock edge was pushed out of the nearest face, which can be the far
		# side (under a slab she is rising beside): the foot stays on the hip's side of any surface between them
		var dir := (raw_ankle - hip).normalized()
		var h: Dictionary = surf.ray.call(hip, raw_ankle + dir * 0.06)
		if not h.is_empty():
			at = h.position + h.normal * 0.06
	at = push_clear(at, 0.056, surf, 0.65)
	var solved := BM.leg(hip, at, side, pd, pf, thigh_len, shin_len, lo)
	if surf != null:
		for _pass in 3:
			var tp := Vector3.ZERO
			var max_shift := 0.0
			var ik: Dictionary = solved.ik
			var probes := [[hip.lerp(ik.mid, 0.55), 0.062, 0.65], [ik.mid, 0.058, 0.85], [ik.mid.lerp(ik.eff, 0.55), 0.050, 0.90],
				[ik.eff, 0.054, 1.00], [ik.eff + solved.finDir * 0.135, 0.044, 0.95]]
			for pr in probes:
				var d: Vector3 = push_clear(pr[0], pr[1], surf, 0.65) - pr[0]
				var dm := d.length()
				if dm > 0.003:
					max_shift = maxf(max_shift, dm)
					tp += d * pr[2]
			if max_shift <= 0.004: break
			var pm := tp.length()
			var lim := minf(0.45, max_shift * 1.18)
			if pm > lim and pm > 1e-5: tp *= lim / pm
			at += tp
			solved = BM.leg(hip, at, side, pd, pf, thigh_len, shin_len, lo)
		if not thalassa_exact:
			# FIX (stress J5): the clearance push is recomputed from scratch every tick, so a leg meeting rock could
			# jump 25 cm in one tick. Let the push change by at most NOCLIP_RATE m/s.
			var want := at - raw_ankle
			var prev: Vector3 = noclip_off.get(side, Vector3.ZERO)
			# out of rock at up to 3x the rate (a buried foot is the worse fault; rising past a slab edge the push grows
			# ~9 m/s), back towards the raw pose at the slow rate
			var rate := NOCLIP_RATE * (3.0 if want.length() > prev.length() + 1e-4 else 1.0)
			var off := prev + (want - prev).limit_length(rate * _step_dt)
			noclip_off[side] = off
			if off.distance_to(want) > 0.002:
				solved = BM.leg(hip, raw_ankle + off, side, pd, pf, thigh_len, shin_len, lo)
			if not thalassa_exact and surf.has("ray"):
				# FIX (stress B42 at 30 Hz, found by the swimming sole check): rising past a slab edge the toes went 15 cm
				# into the slab, deeper than the probes' radius, so the nearest-surface probes saw nothing (and the rate limit above
				# held the foot in). Rays from the
				# ankle to the toe tip and the heel find a face it crosses at any depth; the foot comes back out by what is past it.
				for _r in 2:
					var out := Vector3.ZERO
					var fm: Transform3D = solved.finMat
					for tip in [solved.ik.eff + solved.finDir * 0.16, fm * Vector3(0, -0.03, -0.05)]:     # toe tip, heel
						var th: Dictionary = surf.ray.call(solved.ik.eff, tip)
						if not th.is_empty():
							var o: Vector3 = th.normal * ((tip - th.position).dot(-th.normal) + 0.02)
							if o.length() > out.length(): out = o
					if out == Vector3.ZERO: break
					noclip_off[side] = noclip_off.get(side, Vector3.ZERO) + out
					solved = BM.leg(hip, solved.ik.eff + out, side, pd, pf, thigh_len, shin_len, lo)
	return solved

func solve_head(dt: float, chest_pos: Vector3, neck_anchor: Vector3, c_right: Vector3, c_up: Vector3, c_fwd: Vector3, look_dir: Vector3, lim: Dictionary) -> Dictionary:
	var sdt := clampf(dt, 0.0001, 0.05)
	var max_yaw: float = lim.get("maxYaw", 1.04)
	var min_pitch: float = lim.get("minPitch", -0.60)
	var max_pitch: float = lim.get("maxPitch", 0.68)
	var nps: float = lim.get("neckPitchShare", 0.42)
	var ln := BM.nrm(look_dir)
	var lf := ln.dot(c_fwd)
	var lr := ln.dot(c_right)
	var lu := ln.dot(c_up)
	var raw_yaw: float
	if lf >= 0.08:
		raw_yaw = atan2(lr, lf)
	elif lu > 0.70:
		raw_yaw = atan2(lr, maxf(0.28, lu * 0.65))
	else:
		var bu := clampf((0.08 - lf) / 0.65, 0.0, 1.0)
		var ls: float
		if absf(lr) > 0.22: ls = 1.0 if lr >= 0.0 else -1.0
		elif absf(head_yaw_spring.x) > 0.06: ls = signf(head_yaw_spring.x)
		else: ls = 1.0 if lr >= 0.0 else -1.0
		raw_yaw = ls * max_yaw * (1.0 - bu * 0.65)
	var raw_pitch := atan2(lu, maxf(0.05, Vector2(lf, lr).length()))
	var cy_ := clampf(raw_yaw, -max_yaw, max_yaw)
	var cpt := clampf(raw_pitch, min_pitch, max_pitch)
	var plim := (max_pitch if cpt >= 0.0 else absf(min_pitch)) + 1e-4
	var e2 := pow(cy_ / (max_yaw + 1e-4), 2) + pow(cpt / plim, 2)
	if e2 > 1.0:
		var inv := 1.0 / sqrt(e2)
		cy_ *= inv; cpt *= inv
	var hl: float = lim.get("neckHalflife", 0.165)
	var sy: float = head_yaw_spring.step(cy_, hl, sdt)
	var sp: float = head_pitch_spring.step(cpt, hl, sdt)
	var hf := BM.nrm(c_fwd * cos(sy) + c_right * sin(sy))
	var rhx := BM.nrm(c_right * cos(sy) - c_fwd * sin(sy))
	var head_fwd := BM.nrm(hf * cos(sp) + c_up * sin(sp))
	var rhy := BM.nrm(c_up * cos(sp) - hf * sin(sp))
	var roll := clampf(-sy * 0.022 + lim.get("extraRoll", 0.0), -0.075, 0.075)
	var hx := BM.nrm(rhx * cos(roll) + rhy * sin(roll))
	var hy := BM.nrm(hx.cross(head_fwd))
	var hz := -head_fwd
	var np_ := sp * nps
	var ny := sy * 0.38
	var neck_len := maxf(0.085, neck_anchor.distance_to(chest_pos))
	if not thalassa_exact:
		neck_len = NECK_LEN    # FIX (stress J2): the swim anchor sat 2.4 cm further out, stretching the neck 20 %
	var neck_axis := BM.nrm(c_up * cos(np_) + (c_fwd * (-sin(np_) * 0.65) + c_right * (sin(ny) * 0.28)))
	var curved := chest_pos + neck_axis * neck_len
	var head_pos := curved + (hy * -0.008 + head_fwd * (-maxf(0.0, -sp) * 0.012))
	return {"neckPos": curved, "headPos": head_pos, "headMat": BM.basis_xf(head_pos, hx, hy, hz), "headFwd": head_fwd, "neckYaw": sy, "neckPitch": sp}

static func _ff(fh, x: float, z: float) -> float:
	return fh.call(x, z) if fh != null else -INF

## updateSwim. s = the ported SwimmerLocomotion (core/m02_motor/swimmer_locomotion.gd). Returns the pose dictionary.
func update_swim(dt: float, s, _input, total_time: float, env: Dictionary, sense = null, on_stroke_pull = null, on_shore_footstep = null) -> Dictionary:
	if not thalassa_exact and dt > MAX_STEP:
		# FIX (stress B40): a long frame (the rig drawn per frame and the game hitched) was cut to 0.05 s by the step
		# clamps, so the feet's step clocks lost time the body did not: planted feet dragged 9 cm. Catch up in
		# sub-steps instead; the earlier ones see the end state, which is what was drawn anyway.
		var n := ceili(dt / MAX_STEP)
		for i in n - 1:
			_update_swim_step(dt / n, s, _input, total_time - dt * float(n - 1 - i) / n, env, sense, on_stroke_pull, on_shore_footstep)
		dt /= n
	var pose := _update_swim_step(dt, s, _input, total_time, env, sense, on_stroke_pull, on_shore_footstep)
	if not thalassa_exact:
		pose = _skeleton(pose, dt, s, env)
	return pose

## M04 skeleton 0.7: the full bone chain the rig's anchors imply (spine_01..03, clavicles, toes), on top of the solved
## pose. Spine: a Hermite curve from the pelvis to the chest along their up axes, twist and bend shared along it.
## Shoulder girdle: the clavicle lifts and comes forward with the upper arm (scapulohumeral rhythm, ~1 deg of girdle
## per 2 deg of arm past 30 deg), the arm re-solved from the moved shoulder to the same hand. Toes: bend at the ball
## so a planted foot rolling onto its ball keeps its toes on the ground.
var girdle := {"L": Vector3.ZERO, "R": Vector3.ZERO}
var girdle_v := {"L": Vector3.ZERO, "R": Vector3.ZERO}
var ft_r := Vector3.ZERO          # follow-through: the upper body's lag rotation (rotation vector) and its rate
var ft_w := Vector3.ZERO
var ft_v := Vector3.ZERO          # smoothed pelvis velocity, its previous value and the pelvis position last tick
var ft_a := Vector3.ZERO
var ft_p := Vector3.INF
var soft := {}                    # soft arms: per side, the elbow and hand offsets from the shoulder and their rates
var toe_bend := {"L": 0.0, "R": 0.0}
const TOE_LEN := 0.032       # ball to the toe end of the sole plate
const BALL_Y := 0.11          # foot local: the ball of the foot (toe joint), along the foot
const SOLE_Z := -0.046        # foot local: the sole plane

static func _ortho(b: Basis) -> Basis:
	return b.orthonormalized()

## a bone from a to b: +y along it, +z toward ref (the joint's bend side), as the skin binds it
## the ground under a toe tip rises out of the foot's ground plane (a tread or riser ahead, not just the slope it stands on)
static func _rises(gq: float, g_ball: float, q: Vector3, plane_g: float, fn: Vector3, fx: float, fz: float) -> bool:
	if not is_finite(gq) or not is_finite(g_ball): return false
	if not is_finite(plane_g): return gq > g_ball + 0.01
	var plane_y := plane_g - (fn.x * (q.x - fx) + fn.z * (q.z - fz)) / maxf(0.3, fn.y)
	return gq > plane_y + 0.01

## Follow-through (skeleton only, the motor's pose and the tests' joints are untouched): the upper body is a damped
## spring on the pelvis. When the hips speed up, the chest trails them a little; when they stop, it carries on, then
## settles back with one small overshoot. The head counters most of that tilt so the gaze stays level.
const FT_GAIN := 0.016        # rad of lean per m/s2 of pelvis acceleration
const FT_MAX := 0.07          # rad
const FT_W := 9.0             # spring rate (rad/s): ~0.7 s to settle
const FT_Z := 0.55            # damping ratio: one soft overshoot
func _follow_through(skel: Dictionary, dt: float, s) -> void:
	var pp: Vector3 = skel["pelvis"].origin
	if not ft_p.is_finite() or pp.distance_to(ft_p) > 0.5 or dt <= 0.0:
		ft_p = pp; ft_v = Vector3.ZERO; ft_a = Vector3.ZERO; ft_r = Vector3.ZERO; ft_w = Vector3.ZERO
		return
	var v := (pp - ft_p) / dt
	ft_p = pp
	var kv := 1.0 - exp(-dt / 0.06)
	var nv := ft_v.lerp(v, kv)
	var a := (nv - ft_v) / dt
	ft_v = nv
	ft_a = ft_a.lerp(a, 1.0 - exp(-dt / 0.06))
	var up := Vector3.UP
	var a_h := Vector3(ft_a.x, 0.0, ft_a.z)
	if s.ground_walk_blend < 0.5: a_h = ft_a - up * ft_a.dot(up) * 0.5     # swimming: vertical surges count half
	var drive := -up.cross(a_h) * FT_GAIN                                   # the top trails the acceleration
	if drive.length() > FT_MAX: drive = drive.normalized() * FT_MAX
	# semi-implicit spring, sub-stepped so 30 Hz behaves like 120 Hz
	var n := maxi(1, ceili(dt / (1.0 / 120.0)))
	var h := dt / n
	for _i in n:
		ft_w += (-(FT_W * FT_W) * (ft_r - drive) - 2.0 * FT_Z * FT_W * ft_w) * h
		ft_r += ft_w * h
	if ft_r.length() > FT_MAX * 1.3: ft_r = ft_r.normalized() * FT_MAX * 1.3
	var ang := ft_r.length()
	if ang < 1e-5: return
	var axis := ft_r / ang
	var piv: Vector3 = skel["spine_01"].origin
	var parts := {"spine_02": 0.5, "spine_03": 1.0, "neck": 1.0, "head": 1.0,
		"clavicle_l": 1.0, "clavicle_r": 1.0, "upperarm_l": 1.0, "upperarm_r": 1.0,
		"lowerarm_l": 1.0, "lowerarm_r": 1.0, "hand_l": 1.0, "hand_r": 1.0}
	for b in parts:
		if not skel.has(b): continue
		var rb := Basis(axis, ang * parts[b])
		var x: Transform3D = skel[b]
		skel[b] = Transform3D(rb * x.basis, piv + rb * (x.origin - piv))
	# the head keeps most of its own orientation (gaze stays level)
	var hx: Transform3D = skel["head"]
	skel["head"] = Transform3D(Basis(axis, -ang * 0.7) * hx.basis, hx.origin)

## Soft arms (Gary: "too stiff, needs to be softer"; after "Improving ragdolls forever": soft joint limits and a
## pull towards the relaxed neutral body posture). Skeleton only, like the follow-through. Each arm is a light
## active ragdoll: the elbow and the hand are masses on damped springs that chase the animated pose, carried by the
## shoulder (so they lag when the body speeds up, turns or lands, and settle after), with bone lengths kept rigid.
## The elbow's bend has soft limits: it slows into its stops (straight, and fully bent) instead of hitting them.
## A small share of every target is the relaxed pose (upper arm hanging a little forward, elbow bent ~40 deg), so
## nothing is ever held rigidly.
const SOFT_W_ELBOW := 10.0        # spring rate, rad/s
const SOFT_W_HAND := 6.5         # (Gary: elbows looser) the forearm is a loose pendulum on the elbow
const SOFT_Z := 0.45              # damping ratio: loose, a visible overshoot that settles
const SOFT_NEUTRAL := 0.15        # share of the relaxed pose in every target
const SOFT_LIMIT_LO := 0.10       # elbow flexion stops (rad) and the soft zone before them
const SOFT_LIMIT_HI := 2.45
const SOFT_ZONE := 0.35
func _soft_arms(skel: Dictionary, dt: float, s) -> void:
	if dt <= 0.0: return
	var chest: Transform3D = skel["spine_03"]
	var c_up := chest.basis.y.normalized()
	var c_fwd := -chest.basis.x.normalized().cross(c_up)
	for sd in ["l", "r"]:
		var ua: Transform3D = skel["upperarm_" + sd]
		var la: Transform3D = skel["lowerarm_" + sd]
		var hx: Transform3D = skel["hand_" + sd]
		var sh := ua.origin
		var l1 := sh.distance_to(la.origin)
		var l2 := la.origin.distance_to(hx.origin)
		# the relaxed pose, in the chest's frame
		var side := -1.0 if sd == "l" else 1.0
		var n_up := (-c_up * 0.94 + c_fwd * 0.30 + chest.basis.x.normalized() * side * 0.10).normalized()
		var n_el := sh + n_up * l1
		var n_fa := (n_up * cos(0.70) + c_fwd * sin(0.70)).normalized()
		var n_h := n_el + n_fa * l2
		var te := (la.origin - sh).lerp(n_el - sh, SOFT_NEUTRAL)
		var th := (hx.origin - sh).lerp(n_h - sh, SOFT_NEUTRAL)
		var st: Dictionary = soft.get(sd, {})
		if st.is_empty() or sh.distance_to(st.sh) > 0.5:
			st = {"sh": sh, "shv": Vector3.ZERO, "e": te, "ev": Vector3.ZERO, "h": th, "hv": Vector3.ZERO}
			soft[sd] = st
			continue
		var shv: Vector3 = (sh - (st.sh as Vector3)) / dt
		var sha: Vector3 = (shv - (st.shv as Vector3)) / dt
		st.sh = sh; st.shv = shv
		sha = sha.limit_length(60.0)     # (a teleport-sized jolt is not a force)
		var n := maxi(1, ceili(dt / (1.0 / 120.0)))
		var h := dt / n
		var e: Vector3 = st.e; var ev: Vector3 = st.ev
		var hp: Vector3 = st.h; var hv: Vector3 = st.hv
		for _i in n:
			ev += (-(SOFT_W_ELBOW * SOFT_W_ELBOW) * (e - te) - 2.0 * SOFT_Z * SOFT_W_ELBOW * ev - sha) * h
			hv += (-(SOFT_W_HAND * SOFT_W_HAND) * (hp - th) - 2.0 * SOFT_Z * SOFT_W_HAND * hv - sha) * h
			e += ev * h
			hp += hv * h
			# rigid bones: the elbow on its sphere round the shoulder, the hand on its sphere round the elbow
			var ed := e.normalized() * l1
			ev -= e.normalized() * ev.dot(e.normalized()); e = ed
			var fd := hp - e
			if fd.length() < 1e-5: fd = th - te
			hp = e + fd.normalized() * l2
		# soft limits on the elbow's bend: past the start of the zone the bend is eased towards the stop
		var u_dir := e.normalized()
		var f_dir := (hp - e).normalized()
		var flex := acos(clampf(u_dir.dot(f_dir), -1.0, 1.0))
		var lim := flex
		if flex > SOFT_LIMIT_HI - SOFT_ZONE:
			var x := flex - (SOFT_LIMIT_HI - SOFT_ZONE)
			lim = SOFT_LIMIT_HI - SOFT_ZONE + SOFT_ZONE * (1.0 - exp(-x / SOFT_ZONE))
		elif flex < SOFT_LIMIT_LO + SOFT_ZONE:
			var x2 := (SOFT_LIMIT_LO + SOFT_ZONE) - flex
			lim = SOFT_LIMIT_LO + SOFT_ZONE - SOFT_ZONE * (1.0 - exp(-x2 / SOFT_ZONE))
		if absf(lim - flex) > 1e-4:
			var ax := u_dir.cross(f_dir)
			if ax.length() < 1e-5: ax = (te.normalized()).cross((th - te).normalized())
			if ax.length() > 1e-5:
				f_dir = (Basis(ax.normalized(), lim - flex) * f_dir).normalized()
				var hp2 := e + f_dir * l2
				hv += (hp2 - hp) / dt * 0.0     # (position eased, the speed is left to the spring)
				hp = hp2
		st.e = e; st.ev = ev; st.h = hp; st.hv = hv
		# rebuild the bones: each turned by the rotation that takes its animated direction to the soft one
		var E := sh + e
		var H := sh + hp
		var q1 := Quaternion((la.origin - sh).normalized(), e.normalized()) if (la.origin - sh).normalized().dot(e.normalized()) > -0.999 else Quaternion()
		var nu := Transform3D(Basis(q1) * ua.basis, sh)
		var fa0 := (hx.origin - la.origin).normalized()
		var fa_rot := Basis(q1) * fa0
		var q2 := Quaternion(fa_rot.normalized(), (H - E).normalized()) if fa_rot.normalized().dot((H - E).normalized()) > -0.999 else Quaternion()
		var nl := Transform3D(Basis(q2) * Basis(q1) * la.basis, E)
		var nh := Transform3D(Basis(q2) * Basis(q1) * hx.basis, H)
		skel["upperarm_" + sd] = nu
		skel["lowerarm_" + sd] = nl
		skel["hand_" + sd] = nh

static func seg_xf(a: Vector3, b: Vector3, ref: Vector3) -> Transform3D:
	var y := (b - a).normalized()
	var z := ref - y * ref.dot(y)
	if z.length() < 1e-4: z = y.cross(Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.FORWARD)
	z = z.normalized()
	return Transform3D(Basis(y.cross(z), y, z), a)

func _skeleton(pose: Dictionary, dt: float, s, env: Dictionary) -> Dictionary:
	var skel := {}
	var pm: Transform3D = pose.pelvisMat
	var cm: Transform3D = pose.chestMat
	var pb := _ortho(pm.basis)
	var cb := _ortho(cm.basis)
	var p0: Vector3 = pose.pelvisPos
	var p3: Vector3 = pose.chestPos
	var L := p0.distance_to(p3)
	var t0 := pb.y * L
	var t1 := cb.y * L
	var qp := pb.get_rotation_quaternion()
	var qc := cb.get_rotation_quaternion()
	skel["pelvis"] = Transform3D(pb, p0)
	var names := ["spine_01", "spine_02"]
	var us := [0.36, 0.68]
	for i in 2:
		var u: float = us[i]
		var h00 := 2.0 * u * u * u - 3.0 * u * u + 1.0
		var h10 := u * u * u - 2.0 * u * u + u
		var h01 := -2.0 * u * u * u + 3.0 * u * u
		var h11 := u * u * u - u * u
		var pos := p0 * h00 + t0 * h10 + p3 * h01 + t1 * h11
		var tan := (p0 * (6.0 * u * u - 6.0 * u) + t0 * (3.0 * u * u - 4.0 * u + 1.0) + p3 * (-6.0 * u * u + 6.0 * u) + t1 * (3.0 * u * u - 2.0 * u)).normalized()
		var b := Basis(qp.slerp(qc, u))
		var tw := Quaternion(b.y, tan) if b.y.dot(tan) > -0.99 else Quaternion()
		skel[names[i]] = Transform3D(Basis(tw) * b, pos)
	skel["spine_03"] = Transform3D(cb, p3)
	skel["neck"] = Transform3D(_ortho(pose.headMat.basis), pose.neckPos)
	skel["head"] = Transform3D(_ortho(pose.headMat.basis), pose.headMat.origin)
	# shoulder girdle
	var c_up := cb.y
	var c_right := cb.x
	var c_fwd := -cb.x.cross(cb.y)
	var surf = null
	if env.get("nearest_surface") != null and s.ground_walk_blend < 0.15:
		surf = {"floor_height": env.get("floor_height"), "nearest_surface": env.get("nearest_surface")}
	for side in ["L", "R"]:
		var sd := -1.0 if side == "L" else 1.0
		var arm: Dictionary = pose["arm" + side]
		var sh0: Vector3 = pose["shoulder" + side]
		var sc := p3 + c_up * 0.035 + c_right * (sd * 0.018)          # sternoclavicular joint
		var ua: Vector3 = (arm.mid - arm.root).normalized()
		var elev := asin(clampf(ua.dot(c_up), -1.0, 1.0)) + PI * 0.5   # 0 hanging, PI overhead
		var lift := clampf((elev - 0.52) * 0.5, 0.0, 0.62) * 0.55          # the clavicle's share of the girdle's rise
		var reach := clampf(ua.dot(c_fwd), 0.0, 1.0) * 0.30 - clampf(-ua.dot(c_fwd), 0.0, 1.0) * 0.12
		var want := Vector3(lift, reach, 0.0)
		# critically damped (half-life ~60 ms): the girdle follows the arm, a beat behind, never snapping
		var w := 11.5
		var g: Vector3 = girdle[side]
		var gv: Vector3 = girdle_v[side]
		var acc := (want - g) * (w * w) - gv * (2.0 * w)
		gv += acc * dt
		g += gv * dt
		girdle[side] = g; girdle_v[side] = gv
		var cv := sh0 - sc
		var rot := Basis(c_fwd, -sd * g.x) * Basis(c_up, sd * g.y)
		var sh := sc + rot * cv
		var dsh := sh - sh0
		skel["clavicle_" + side.to_lower()] = seg_xf(sc, sh, c_fwd)
		if dsh.length() > 1e-4:
			var pole: Vector3 = arm.mid + (arm.mid - (arm.root + arm.eff) * 0.5).normalized() * 0.3
			var na: Dictionary = solve_noclip_arm(sh, arm.eff, pole, surf, {"softReach": 0.985, "softMargin": 0.04})
			var hm: Transform3D = pose["hand" + side + "Mat"]
			hm.origin += na.eff - arm.eff
			pose["hand" + side + "Mat"] = hm
			pose["arm" + side] = na
			pose["shoulder" + side] = sh
			pose["clavicle" + side] = sc.lerp(sh, 0.45)
		var a2: Dictionary = pose["arm" + side]
		skel["upperarm_" + side.to_lower()] = seg_xf(a2.root, a2.mid, a2.bendAxis)
		skel["lowerarm_" + side.to_lower()] = seg_xf(a2.mid, a2.eff, a2.bendAxis)
		skel["hand_" + side.to_lower()] = Transform3D(_ortho(pose["hand" + side + "Mat"].basis), pose["hand" + side + "Mat"].origin)
	# toes
	var get_floor = env.get("floor_height")
	for side in ["L", "R"]:
		var lg: Dictionary = pose["leg" + side]
		var fm: Transform3D = lg.finMat
		var ball: Vector3 = fm * Vector3(0, BALL_Y, SOLE_Z)
		var want_b := 0.0
		if get_floor != null and s.ground_walk_blend > 0.5:
			# the least bend that keeps the toe end (centre and both corners) out of the ground; the planted sole lift
			# rolls the foot over the ball and leaves the toes to this (it only lifts for toes that a full bend can't clear)
			var g_b: float = get_floor.call(ball.x, ball.z)
			if is_finite(g_b) and ball.y - g_b < 0.03:
				var tips := []
				for x in [0.0, 0.028, -0.028]: tips.append(Vector3(x, TOE_LEN, 0.0))
				for i in 21:
					var th := float(i) * 0.05
					var tbs := fm.basis * Basis(Vector3.RIGHT, th)
					var clear := true
					for tl in tips:
						var q: Vector3 = ball + tbs * tl
						var gq: float = get_floor.call(q.x, q.z)
						if is_finite(gq) and absf(gq - g_b) < 0.06 and q.y < gq - 0.001: clear = false; break
					want_b = th
					if clear: break
		# bends at once as far as the ground needs (the toes never go into it), relaxes smoothly
		var k := 1.0 - exp(-dt / 0.06)
		toe_bend[side] = maxf(want_b, lerpf(toe_bend[side], want_b, k))
		var tb := fm.basis * Basis(Vector3.RIGHT, toe_bend[side])
		var toe := Transform3D(tb, ball)
		lg["toeMat"] = toe
		skel["thigh_" + side.to_lower()] = seg_xf(lg.ik.root, lg.ik.mid, lg.ik.bendAxis)
		skel["calf_" + side.to_lower()] = seg_xf(lg.ik.mid, lg.ik.eff, lg.ik.bendAxis)
		skel["foot_" + side.to_lower()] = Transform3D(_ortho(fm.basis), fm.origin)
		skel["ball_" + side.to_lower()] = Transform3D(_ortho(toe.basis), toe.origin)
	_follow_through(skel, dt, s)
	_soft_arms(skel, dt, s)
	pose["skel"] = skel
	return pose

func _update_swim_step(dt: float, s, _input, total_time: float, env: Dictionary, sense = null, on_stroke_pull = null, on_shore_footstep = null) -> Dictionary:
	_step_dt = clampf(dt, 0.0001, 0.05)
	_brain_fresh = false
	if not _spawned and not thalassa_exact:
		# FIX (stress B38): the body yaw started at Thalassa's spawn yaw 0.12 whatever way she faced, so spawning
		# facing elsewhere swung the first second's pose round through her (crossed legs, an arm in the torso)
		body_yaw = s.yaw
	_spawned = true
	var get_floor = env.get("floor_height")
	var get_normal = env.get("floor_normal")
	var query = env.get("nearest_surface")
	var bp := sin((1.0 - light_button_timer / light_button_duration) * PI) if light_button_timer > 0.0 else 0.0
	light_button_depression = smoothstep(0.15, 0.95, bp)
	impact_energy *= exp(-2.8 * dt)
	var spd: float = s.get_speed()
	var fwd_look := BM.fwd(s.yaw, s.pitch)
	var right_look := BM.right(s.yaw)
	var fwd_horiz := BM.fwd(s.yaw, 0.0)
	var inv_dt := 1.0 / dt if dt > 1e-4 else 0.0
	var raw_acc := Vector3(clampf((s.vel.x - prev_vel.x) * inv_dt, -12, 12), clampf((s.vel.y - prev_vel.y) * inv_dt, -12, 12), clampf((s.vel.z - prev_vel.z) * inv_dt, -12, 12))
	var acc_k := BM.expk(4.2, dt)
	smooth_accel = Vector3(lerpf(smooth_accel.x, raw_acc.x, acc_k), lerpf(smooth_accel.y, raw_acc.y, acc_k), lerpf(smooth_accel.z, raw_acc.z, acc_k))
	var world_accel := smooth_accel
	prev_vel = s.vel
	var raw_yaw_vel := clampf(BM.wrap_pi(s.yaw - prev_yaw) * inv_dt, -3.5, 3.5)
	smooth_yaw_vel = lerpf(smooth_yaw_vel, raw_yaw_vel, BM.expk(5.0, dt))
	var yaw_vel := smooth_yaw_vel
	prev_yaw = s.yaw
	var v_fwd: float = s.vel.dot(fwd_look)
	var v_right: float = s.vel.dot(right_look)
	var v_up: float = s.vel.y
	var fwd_norm := clampf((v_fwd - 0.30) / 4.4, 0.0, 1.0)
	var rev_norm := clampf((-v_fwd - 0.18) / 3.0, 0.0, 1.0)
	var str_norm := clampf(v_right / 3.8, -1.0, 1.0)
	var vert_norm := clampf(v_up / 3.6, -1.0, 1.0)
	var sprint_n := 1.0 if (s.sprinting and v_fwd > 1.8) else 0.0
	var input_mag := clampf(s.input_mag, 0.0, 1.0)
	var raw_glide := clampf((spd - 0.55) / 2.2, 0.0, 1.0) * (1.0 - smoothstep(0.15, 0.55, input_mag)) * (1.0 - rev_norm)
	swim_blend = lerpf(swim_blend, fwd_norm, BM.expk(3.2, dt))
	sprint_blend = lerpf(sprint_blend, sprint_n, BM.expk(3.8, dt))
	reverse_blend = lerpf(reverse_blend, rev_norm, BM.expk(3.6, dt))
	strafe_blend = lerpf(strafe_blend, str_norm, BM.expk(3.6, dt))
	vert_blend = lerpf(vert_blend, vert_norm, BM.expk(3.4, dt))
	glide_blend = lerpf(glide_blend, raw_glide, BM.expk(2.8, dt))
	var yaw_err := BM.wrap_pi(s.yaw - body_yaw)
	body_yaw = BM.wrap_pi(body_yaw + yaw_err * BM.expk(lerpf(3.6, 6.2, maxf(swim_blend, glide_blend)), dt))
	var tread := clampf(s.surface_tread_blend, 0.0, 1.0)
	var water_cur: Vector3 = sense.waterCurrent if (sense != null and sense.get("waterCurrent") != null) else s.water_current
	var str_abs := absf(strafe_blend)
	var active_stroke := clampf(swim_blend * (1.0 - glide_blend * 0.65) + reverse_blend * 0.72 + str_abs * 0.55 + absf(vert_blend) * 0.50 + tread * 0.22, 0.0, 1.15)
	var effort := clampf(maxf(active_stroke, glide_blend * 0.35), 0.0, 1.15)

	var cam_pre: Vector3 = s.get_camera_transform(total_time, false).pos
	var raw_support_y := -INF
	var support_n := Vector3.UP
	if get_floor != null:
		var f_here: float = get_floor.call(cam_pre.x, cam_pre.z)
		var f_aft: float = get_floor.call(cam_pre.x - fwd_horiz.x * 0.85, cam_pre.z - fwd_horiz.z * 0.85)
		if is_finite(f_here):
			raw_support_y = maxf(f_here, f_aft) if is_finite(f_aft) else f_here
			var eps := 0.60
			var hL: float = get_floor.call(cam_pre.x - eps, cam_pre.z)
			var hR: float = get_floor.call(cam_pre.x + eps, cam_pre.z)
			var hD: float = get_floor.call(cam_pre.x, cam_pre.z - eps)
			var hU: float = get_floor.call(cam_pre.x, cam_pre.z + eps)
			if is_finite(hL) and is_finite(hR) and is_finite(hD) and is_finite(hU):
				support_n = BM.nrm(Vector3(hL - hR, 2.0 * eps, hD - hU))
	if query != null:
		var top := cam_pre.y + 0.02
		var under: Dictionary = query.call(Vector3(cam_pre.x - fwd_horiz.x * 0.22, cam_pre.y - 0.62, cam_pre.z - fwd_horiz.z * 0.22), 0.90,
			func(q: Vector3, n: Vector3) -> bool: return n.y > 0.45 and q.y < top)
		if not under.is_empty() and under.has("point") and under.point.y > raw_support_y:
			raw_support_y = under.point.y
			if under.has("normal"): support_n = BM.nrm(under.normal)
	if is_finite(raw_support_y):
		if not _support_y_init or absf(support_y_spring.x - raw_support_y) > 6.0:
			support_y_spring.reset(raw_support_y)
			_support_y_init = true
	var smooth_support_y: float = support_y_spring.step(raw_support_y, 0.20, dt) if is_finite(raw_support_y) else -INF
	var clear_above := (cam_pre.y - smooth_support_y) if is_finite(smooth_support_y) else 99.0
	if not thalassa_exact and s.vel.y < 0.0:
		# FIX (Mac playtest, stress B44): sinking onto the bottom she levelled out only once there (the blend and the
		# spine spring lag ~0.5 s), so she arrived still half upright with her hips at the sand and her legs in it.
		# Judge the clearance she will have 0.9 s on, at the speed she is sinking.
		clear_above += s.vel.y * 0.9
	var raw_near := (1.0 - smoothstep(0.68, 1.95, clear_above)) * (1.0 - tread)
	var near_bottom := clampf(seabed_align_spring.step(raw_near, 0.28, dt), 0.0, 1.0)
	seabed_align_blend = near_bottom

	var brh := BM.right(body_yaw)
	var sfr := brh.cross(support_n)
	var slope_fwd := BM.nrm(sfr) if sfr.length() > 1e-4 else fwd_horiz
	var terrain_pitch := clampf(asin(clampf(slope_fwd.y, -0.58, 0.58)), -0.52, 0.52)
	var vel_pitch := asin(clampf(s.vel.y / spd, -0.975, 0.975)) if (spd > 0.45 and v_fwd > 0.2) else 0.0
	var pure_dive := clampf(-vert_blend, 0.0, 1.0) * (1.0 - swim_blend)
	var pure_rise := clampf(vert_blend, 0.0, 1.0) * (1.0 - swim_blend)
	var look_torso := clampf(s.pitch * 0.22, -0.26, 0.28) * (1.0 - swim_blend * 0.78) * (1.0 - near_bottom * 0.80)
	var base_up := lerpf(1.32, 1.48, tread)
	var open_up := base_up - look_torso * (1.0 - tread * 0.45) + reverse_blend * 0.88 - str_abs * 0.24 - pure_dive * 0.72 + pure_rise * 0.14 + sin(total_time * 0.55) * 0.025
	var seabed_horiz := terrain_pitch + 0.06 + sin(total_time * 0.55) * 0.018
	var upright := lerpf(open_up, seabed_horiz, near_bottom)
	var swim_pitch_goal := lerpf(clampf(vel_pitch, -1.36, 1.32), 0.34, tread)
	var safe_swim_pitch := lerpf(swim_pitch_goal, maxf(swim_pitch_goal, terrain_pitch + 0.05), near_bottom * 0.88)
	var stream_mix := clampf(maxf(swim_blend, glide_blend * 0.92), 0.0, 1.0)
	var target_body_pitch := lerpf(upright, safe_swim_pitch, stream_mix)
	var spine_ctrl: Dictionary = physics_control.get_control("Spine")
	var spine_k := clampf(spine_ctrl.angularStrength / 21.0, 0.35, 2.0)
	var spine_eq := clampf(spine_ctrl.equilibriumWeight / 5.2, 0.35, 2.0)
	var mx := clampf(maxf(effort, maxf(near_bottom, stream_mix)), 0.0, 1.0)
	var pitch_ka := lerpf(13.0, 20.0, mx) * spine_k
	var pitch_ke := lerpf(3.8, 0.3, mx) * spine_eq
	var spine_damp := clampf(spine_ctrl.damping * 0.95, 6.2, 14.0)
	body_pitch = pitch_spring.step(dt, target_body_pitch, pitch_ka, pitch_ke, spine_damp)
	var idle_roll := (sin(total_time * 0.50 + 0.8) * 0.032 + cos(total_time * 0.28) * 0.018) * (1.0 - stream_mix * 0.6)
	var carve_roll := clampf(-yaw_vel * lerpf(0.06, 0.24, stream_mix), -0.34, 0.34)
	var target_roll := clampf(s.roll * 1.25 + strafe_blend * 0.34 + carve_roll + idle_roll, -0.52, 0.52)
	body_roll = roll_spring.step(dt, target_roll, 16.0 * spine_k, 3.0 * spine_eq, spine_damp, 0.0)
	var tempo := 1.0 + sin(total_time * 0.48) * 0.055
	var arm_rate := (lerpf(1.25, 2.65, clampf(active_stroke, 0.0, 1.0)) * (1.0 - glide_blend * 0.45) + sprint_blend * 0.75) * tempo
	var kick_rate := (lerpf(2.15, 4.45, clampf(active_stroke, 0.0, 1.0)) * (1.0 - glide_blend * 0.42) + sprint_blend * 2.15) * (1.0 + sin(total_time * 0.41 + 2.1) * 0.045)
	arm_phase += dt * arm_rate
	kick_phase += dt * kick_rate
	breath_phase += dt * (1.32 + sin(total_time * 0.24) * 0.10)

	var body_axis_y := BM.fwd(body_yaw, body_pitch)
	var raw_right := BM.right(body_yaw)
	var base_back := BM.nrm(raw_right.cross(body_axis_y))
	var body_right := BM.nrm(raw_right * cos(body_roll) + base_back * -sin(body_roll))
	var body_back := BM.nrm(body_right.cross(body_axis_y))
	var body_belly := -body_back
	var spine_dir := -body_axis_y
	var acc_r := world_accel.dot(body_right)
	var acc_y := world_accel.dot(body_axis_y)
	var acc_b := world_accel.dot(body_belly)
	var cur_r := clampf(water_cur.dot(body_right), -2.0, 2.0)
	var cur_y := clampf(water_cur.dot(body_axis_y), -2.0, 2.0)
	var cur_b := clampf(water_cur.dot(body_belly), -2.0, 2.0)
	var cam_anchor: Vector3 = s.get_camera_transform(total_time, false).pos
	var head_up := BM.nrm(right_look.cross(fwd_look))

	var raw_neck := cam_anchor + (Vector3(0, -0.22 + tread * 0.045 - reverse_blend * 0.05, 0) + fwd_horiz * (-0.09 + tread * 0.02 - reverse_blend * 0.06))
	var want_lift := 0.0
	var raw_pelv_y := raw_neck.y + spine_dir.y * 0.470
	if is_finite(smooth_support_y):
		var min_pelv := smooth_support_y + 0.28
		var pelv_judge := raw_pelv_y
		if not thalassa_exact:
			# FIX (Mac playtest, stress B44): this lift keeps her hips off the sand, but through a 0.14 s spring it came
			# late when she sank onto the bottom, and her hips (and legs) went into it. Lift for where the hips will be
			# that spring's lag on, at the speed she is sinking.
			pelv_judge += minf(0.0, s.vel.y) * 0.18
		if pelv_judge < min_pelv: want_lift = clampf(min_pelv - pelv_judge, 0.0, 0.42)
	var whole_lift: float = swim_lift_spring.step(want_lift, 0.14, dt)
	var want_spine := Vector3.ZERO
	if query != null:
		var lifted := Vector3(raw_neck.x, raw_neck.y + whole_lift, raw_neck.z)
		for sp_pt in [lifted + spine_dir * 0.315, lifted + spine_dir * 0.470]:
			var sh_: Dictionary = query.call(sp_pt, 0.20, null)
			if not sh_.is_empty() and sh_.dist < 0.20 and sh_.has("normal"):
				want_spine += sh_.normal * (0.20 - sh_.dist)
		var spl := want_spine.length()
		if spl > 0.24: want_spine *= 0.24 / spl
	var sm_spine: Vector3 = swim_spine_push.step(want_spine, 0.085, dt)
	var neck_pos := Vector3(raw_neck.x + sm_spine.x, raw_neck.y + whole_lift + sm_spine.y, raw_neck.z + sm_spine.z)

	var swim_fluid := clampf(maxf(effort, stream_mix * 0.85), 0.0, 1.15)
	var wave_amp := lerpf(0.022, 0.048, stream_mix) * (1.0 - glide_blend * 0.14) * (1.0 + sprint_blend * 0.22)
	var drift_b := clampf(cur_b * 0.032 - acc_b * 0.012, -0.045, 0.045)
	var w_chest := sin(kick_phase - 0.55) * wave_amp * 0.38 + drift_b * 0.25
	var w_waist := sin(kick_phase - 1.30) * wave_amp * 0.90 + drift_b * 0.65
	var w_pelvis := sin(kick_phase - 2.05) * wave_amp * 1.38 + drift_b * 1.15
	var hip_sway := cos(kick_phase) * lerpf(0.016, 0.034, swim_fluid) * (1.0 - glide_blend * 0.18)
	var carve_lat := clampf(-yaw_vel * lerpf(0.036, 0.082, stream_mix), -0.115, 0.115) + cur_r * 0.042
	var chest_pos := (neck_pos + spine_dir * 0.140) + (body_back * w_chest + body_right * (carve_lat * 0.32 - hip_sway * 0.25))
	var waist_pos := (chest_pos + spine_dir * 0.175) + (body_back * w_waist + body_right * (carve_lat * 0.75 + hip_sway * 0.45))
	var pelvis_pos := (waist_pos + spine_dir * 0.155) + (body_back * w_pelvis + body_right * (carve_lat * 1.15 + hip_sway))
	if not thalassa_exact:
		# FIX (stress J2): Thalassa's swim spine used other segment lengths than her standing body (0.140 / 0.175 /
		# 0.155 against 0.118 / 0.195 / 0.160) and added the sway offsets on top, so the torso stretched up to 21 %.
		# Keep the swim bends, but as a chain of the standing lengths.
		chest_pos = neck_pos + BM.nrm(chest_pos - neck_pos) * NECK_LEN
		waist_pos = chest_pos + BM.nrm(waist_pos - chest_pos) * 0.195
		pelvis_pos = waist_pos + BM.nrm(pelvis_pos - waist_pos) * 0.160
	var sh_l_off := sin(arm_phase * 0.85 + 0.3) * 0.010 + swim_blend * 0.014
	var sh_r_off := sin(arm_phase * 0.85 + 1.1) * 0.010 + swim_blend * 0.014
	var nbp_roll := lerpf(0.036, 0.020, clampf(effort, 0.0, 1.0))
	var shoulder_l := chest_pos + (body_right * -shoulder_half_w + (body_axis_y * (0.044 + sh_l_off) + body_belly * nbp_roll))
	var shoulder_r := chest_pos + (body_right * shoulder_half_w + (body_axis_y * (0.044 + sh_r_off) + body_belly * nbp_roll))
	var clavicle_l := chest_pos.lerp(shoulder_l, 0.45)
	var clavicle_r := chest_pos.lerp(shoulder_r, 0.45)
	var hip_roll := sin(kick_phase) * lerpf(0.024, 0.048, swim_fluid) * (1.0 - glide_blend * 0.15) + clampf(cur_b * 0.018, -0.025, 0.025)
	var hip_yaw := cos(kick_phase) * lerpf(0.012, 0.026, swim_fluid) * (1.0 - glide_blend * 0.15)
	var hip_l := pelvis_pos + (body_right * -hip_half_w + (body_back * hip_roll + body_axis_y * hip_yaw))
	var hip_r := pelvis_pos + (body_right * hip_half_w + (body_back * -hip_roll + body_axis_y * -hip_yaw))
	if not thalassa_exact:
		# FIX (stress J2): Thalassa slid the hip joints sideways for the kick roll, widening the pelvis up to 30 %;
		# turn the offset into a tilt of a rigid pelvis instead (same direction, fixed width)
		hip_l = pelvis_pos + BM.nrm(hip_l - pelvis_pos) * hip_half_w
		hip_r = pelvis_pos + BM.nrm(hip_r - pelvis_pos) * hip_half_w

	var breath_scale := 1.0 + sin(breath_phase) * 0.025
	var chest_axis_y := BM.nrm(neck_pos - waist_pos)
	var chest_x := BM.nrm(chest_axis_y.cross(body_back))
	var chest_z := chest_x.cross(chest_axis_y)
	var chest_mat := BM.basis_xf(chest_pos, chest_x, chest_axis_y, chest_z, breath_scale, 1.0, breath_scale)
	var pelv_axis_y := BM.nrm(waist_pos - pelvis_pos)
	var pelv_twist := sin(kick_phase) * lerpf(0.14, 0.29, swim_fluid) * (1.0 - glide_blend * 0.16) + clampf(-yaw_vel * 0.10 + cur_r * 0.06, -0.22, 0.22)
	var pelv_back_r := BM.nrm(body_back * cos(pelv_twist) + body_right * sin(pelv_twist))
	var pelv_x := BM.nrm(pelv_axis_y.cross(pelv_back_r))
	var pelv_z := pelv_x.cross(pelv_axis_y)
	var pelvis_mat := BM.basis_xf(pelvis_pos, pelv_x, pelv_axis_y, pelv_z)

	var chest_fwd_swim := -chest_z
	var crossing := absf(s.pos.y - s.config.surface_y) < 0.72 and absf(s.vel.y) > 1.15
	var brain_ctx := {
		"mode": "swim", "headPos": cam_anchor, "bodyFwd": chest_fwd_swim, "bodyRight": chest_x, "bodyUp": chest_axis_y,
		"visionFwd": fwd_look, "visionRight": right_look, "visionUp": head_up,
		"cameraFwd": sense.cameraFwd if (sense != null and sense.get("cameraFwd") != null) else fwd_look,
		"bodyBelly": body_belly, "swimAxisY": body_axis_y, "shoulderL": shoulder_l, "shoulderR": shoulder_r,
		"restHandWorldL": chest_pos + (body_right * -0.34 + body_belly * 0.40), "restHandWorldR": chest_pos + (body_right * 0.34 + body_belly * 0.40),
		"desiredLookDir": fwd_look, "speed": spd, "desSpeed": spd, "sprinting": s.sprinting, "btnPhase": bp, "yawRate": yaw_vel,
		"impactShake": impact_energy, "inCriticalTransition": crossing or s.shore_dive_arc_timer > 0.0,
		"objectiveFocus": {"label": "WATER ENTRY", "dir": fwd_look, "holdSec": 0.45} if crossing else null,
		"getFloorHeight": get_floor, "queryNearestSurface": query,
		"colliders": sense.get("colliders") if sense != null else null, "pois": sense.get("pois") if sense != null else null}
	var brain_swim: Dictionary
	if thalassa_exact:
		brain_swim = brain.update(dt, brain_ctx)
	else:
		# ROOT (brain port): ik-rig.js stepped the brain in this swim pose AND again in the walk pose whenever she stood
		# or waded, alternating 'swim' and 'deck_walk' contexts: the breath ran at twice its rate on land, every land idle
		# glance was cancelled by the swim step the next call, the contrapposto spring was pulled back to 0 each tick.
		# One step per rig step now, in the context she is mostly in (ground walk blend 0.5); the other pose reuses it.
		brain_ctx["checkLineOfSight"] = sense.get("checkLineOfSight") if sense != null else null
		brain_ctx["effort"] = clampf(0.45 * active_stroke + 0.55 * sprint_blend, 0.0, 1.0)     # breath drive (see the brain)
		if s.ground_walk_blend >= 0.5 and not brain_out.is_empty():
			brain_swim = brain_out
		else:
			brain_swim = brain.update(dt, brain_ctx)
			_brain_fresh = true
	brain_out = brain_swim

	var ubr_base := fposmod(arm_phase, TAU) / TAU
	if on_stroke_pull != null and swim_blend > 0.28 and prev_ubr < 0.48 and ubr_base >= 0.48:
		on_stroke_pull.call(clampf(swim_blend * (0.7 + sprint_blend * 0.35), 0.25, 1.0))
	prev_ubr = ubr_base
	var surf_env = {"floor_height": get_floor, "nearest_surface": query} if s.ground_walk_blend < 0.15 else null
	if surf_env != null and not thalassa_exact and env.has("point_solid"): surf_env["point_solid"] = env.point_solid; surf_env["ray"] = env.get("ray")
	if surf_env != null and get_floor == null and query == null: surf_env = null

	var solve_arm := func(side: float, override_target = null) -> Dictionary:
		var asym_amp := 0.94 if side < 0 else 1.06
		var asym_lead := 0.0 if side < 0 else 0.032
		var wander_r := sin(total_time * (1.13 if side < 0 else 0.89) + side * 1.4) * 0.022
		var wander_y := cos(total_time * (0.77 if side < 0 else 1.03) + side * 0.7) * 0.020
		var wander_b := sin(total_time * (0.61 if side < 0 else 0.79) + 2.0) * 0.016
		var p_idle := arm_phase * (0.97 if side < 0 else 1.03) + (0.96 if side > 0 else 0.0)
		var p_tread := total_time * 2.35 + (0.55 if side > 0 else 0.0)
		var tread_r := side * (0.33 + sin(p_tread) * 0.115 * asym_amp) + wander_r * 0.5
		var tread_y := -0.15 + sin(p_tread * 2.0) * 0.036 + wander_y * 0.5
		var tread_b := 0.28 + cos(p_tread) * 0.085 + wander_b * 0.5
		var idle_r := lerpf(side * (0.37 + sin(p_idle) * 0.075 * asym_amp) + wander_r, tread_r, tread)
		var idle_y := lerpf(-0.02 + sin(p_idle * 2.0 + 0.35) * 0.042 + wander_y, tread_y, tread)
		var idle_b := lerpf(0.50 + cos(p_idle) * 0.055 + wander_b, tread_b, tread)
		var ubr := fmod(ubr_base + asym_lead, 1.0)
		var sp := sprint_blend
		var br_r: float; var br_y: float; var br_b: float; var pull := 0.0
		var glide_end := lerpf(0.38, 0.48, sp)
		var pull_end := lerpf(0.74, 0.78, sp)
		if ubr < glide_end:
			var k := pow(smoothstep(0.0, glide_end, ubr), 0.82)
			br_r = side * lerpf(0.18, lerpf(0.145, 0.11, sp), k) + wander_r * 0.45
			br_y = lerpf(0.46, lerpf(0.62, 0.68, sp), k) + wander_y * 0.45
			br_b = lerpf(0.08, lerpf(0.05, 0.03, sp), k)
		elif ubr < pull_end:
			var k := pow(clampf((ubr - glide_end) / maxf(0.01, pull_end - glide_end), 0.0, 1.0), 0.78)
			var arc := sin(k * PI)
			br_r = side * (lerpf(0.145, 0.11, sp) + arc * lerpf(0.37, 0.45, sp) * asym_amp + k * 0.16)
			br_y = lerpf(lerpf(0.62, 0.68, sp), lerpf(0.01, -0.07, sp), k) + wander_y * 0.35
			br_b = 0.05 + arc * lerpf(0.14, 0.19, sp)
			pull = arc
		else:
			var k := smoothstep(pull_end, 1.0, ubr)
			br_r = side * lerpf(0.31, 0.18, k) + wander_r * 0.5
			br_y = lerpf(lerpf(0.01, -0.07, sp), 0.46, k)
			br_b = lerpf(0.15, 0.08, k)
		var lr := lerpf(idle_r, br_r, swim_blend)
		var ly := lerpf(idle_y, br_y, swim_blend)
		var lb := lerpf(idle_b, br_b, swim_blend)
		if reverse_blend > 0.02:
			var pr := arm_phase * (1.12 if side < 0 else 1.18) + (0.78 if side > 0 else 0.0)
			lr = lerpf(lr, side * (0.42 + sin(pr) * 0.13 * asym_amp) + wander_r, reverse_blend)
			ly = lerpf(ly, -0.24 + cos(pr) * 0.09 + wander_y, reverse_blend)
			lb = lerpf(lb, 0.22 + sin(pr + 0.45) * 0.09, reverse_blend)
		if str_abs > 0.02:
			var leading := side * strafe_blend > 0.0
			var ps := arm_phase * 1.1 + (0.15 if leading else 1.35)
			var st_r := side * ((0.34 + sin(ps) * 0.09) if leading else (0.26 + cos(ps) * 0.13))
			var st_y := 0.18 + (0.06 if leading else -0.04) + sin(ps) * 0.065
			var st_b := 0.34 + cos(ps) * 0.085
			var sm := str_abs * (1.0 - swim_blend * 0.65)
			lr = lerpf(lr, st_r, sm) - strafe_blend * 0.08
			ly = lerpf(ly, st_y, sm)
			lb = lerpf(lb, st_b, sm)
		if glide_blend > 0.02:
			var gm := glide_blend * (1.0 - reverse_blend)
			lr = lerpf(lr, side * (0.44 + sin(total_time * 0.9 + side) * 0.018), gm)
			ly = lerpf(ly, -0.10 + cos(total_time * 0.7) * 0.02, gm)
			lb = lerpf(lb, 0.14, gm)
		var pure_vert := absf(vert_blend) * (1.0 - swim_blend * 0.75)
		if pure_vert > 0.04:
			var pv := arm_phase * 1.05 + (0.35 if side > 0 else 0.0)
			if vert_blend > 0.0:
				lr = lerpf(lr, side * (0.32 + sin(pv) * 0.14), pure_vert)
				ly = lerpf(ly, 0.04 - cos(pv) * 0.18, pure_vert)
				lb = lerpf(lb, 0.32 + sin(pv) * 0.08, pure_vert)
			else:
				lr = lerpf(lr, side * (0.28 + sin(pv) * 0.12), pure_vert)
				ly = lerpf(ly, 0.24 + cos(pv) * 0.16, pure_vert)
				lb = lerpf(lb, 0.26 + sin(pv) * 0.06, pure_vert)
		if side < 0 and bp > 0.01:
			lr = lerpf(lr, -0.15, bp * 0.85)
			ly = lerpf(ly, 0.29, bp * 0.85)
			lb = lerpf(lb, 0.42, bp * 0.85)
		var arm_spring = arm_spring_l if side < 0 else arm_spring_r
		var ac: Dictionary = physics_control.get_control("LeftArm" if side < 0 else "RightArm")
		var ak := clampf(ac.angularStrength / 42.0, 0.28, 2.2)
		var aeq := clampf(ac.equilibriumWeight / 9.0, 0.30, 2.2)
		var ain: float = ac.inertiaScale
		var eb := clampf(effort + bp, 0.0, 1.0)
		var inertia := Vector3((-acc_r * 0.065 + cur_r * 0.14 - yaw_vel * 0.11) * ain, (-acc_y * 0.060 + cur_y * 0.12) * ain, (-acc_b * 0.065 + cur_b * 0.14 + side * yaw_vel * 0.08) * ain)
		var sim: Vector3 = arm_spring.step(dt, Vector3(lr, ly, lb), lerpf(30.0, 58.0, eb) * ak, lerpf(9.5, 1.8, eb) * aeq,
			lerpf(9.2, 11.4, clampf(effort, 0.0, 1.0)) * sqrt(maxf(0.35, ak)), inertia)
		var sh := shoulder_l if side < 0 else shoulder_r
		var target := chest_pos + (body_right * sim.x + (body_axis_y * sim.y + body_belly * sim.z))
		var touch = brain_swim.touchL if side < 0 else brain_swim.touchR
		var cur_brace := 0.0
		var brace_normal = null
		var brace_mode := "swim_glide"
		if touch != null and touch.weight > 0.01 and touch.get("targetWorld") != null and bp < 0.05:
			var max_soft := (upper_arm_len + forearm_len) * 0.90
			var soft_t: Vector3 = touch.targetWorld
			var dtc := sh.distance_to(soft_t)
			if dtc > max_soft and dtc > 1e-4:
				soft_t = sh + (soft_t - sh) * (max_soft / dtc)
			cur_brace = touch.weight
			brace_normal = touch.get("normalWorld")
			brace_mode = touch.get("mode", "swim_glide")
			target = target.lerp(soft_t, cur_brace)
		if side < 0: brace_l = cur_brace
		else: brace_r = cur_brace
		if override_target != null and bp > 0.01:
			target = target.lerp(override_target, smoothstep(0.0, 0.85, bp))
		var pole := sh + (body_right * (side * (0.50 + sin(total_time * 0.8 + side) * 0.04)) + (body_belly * 0.16 + spine_dir * 0.34))
		if cur_brace > 0.05 and brace_normal != null:
			pole += brace_normal * (cur_brace * 0.16)
		var want_push := Vector3.ZERO
		var hmin := lerpf(0.065, 0.026, cur_brace)
		if query != null:
			var hh: Dictionary = query.call(target, hmin + 0.03, null)
			if not hh.is_empty() and hh.dist < hmin and hh.has("normal"):
				want_push += hh.normal * minf(0.12, hmin - hh.dist)
		if get_floor != null:
			var hfy: float = get_floor.call(target.x, target.z)
			if is_finite(hfy) and target.y < hfy + 0.085:
				want_push.y = maxf(want_push.y, minf(0.14, (hfy + 0.085) - target.y))
		var hpl := want_push.length()
		if hpl > 0.14: want_push *= 0.14 / hpl
		var push_spr = swim_arm_push_l if side < 0 else swim_arm_push_r
		target += push_spr.step(want_push, 0.10, dt)
		var asr := lerpf(0.95, 0.92, cur_brace)
		var asm := lerpf(0.10, 0.05, cur_brace)
		var ik: Dictionary
		if surf_env != null:
			ik = solve_noclip_arm(sh, target, pole, surf_env, {"softReach": asr, "softMargin": asm, "maxFlexDeg": 138.0, "wristRadius": hmin, "elbowRadius": 0.050})
		else:
			ik = BM.two_bone(sh, target, pole, upper_arm_len, forearm_len, asr, asm, 138.0)
		ik.pullFactor = pull
		ik.brace = cur_brace
		ik.braceNormal = brace_normal
		ik.braceMode = brace_mode
		ik.softStress = arm_spring.get_stress()
		return ik

	var arm_l: Dictionary = solve_arm.call(-1.0)
	var fore_l_dir := BM.nrm(arm_l.eff - arm_l.mid)
	var torch_origin: Vector3 = arm_l.mid.lerp(arm_l.eff, 0.74) + body_back * 0.036
	var torch_switch := torch_origin + (fore_l_dir * -0.025 + body_right * 0.04)
	var arm_r: Dictionary = solve_arm.call(1.0, torch_switch if bp > 0.01 else null)

	var solve_leg := func(side: float) -> Dictionary:
		var hip := hip_l if side < 0 else hip_r
		var asym_kick := 0.0 if side < 0 else (PI + 0.24 + sin(total_time * 0.47) * 0.14)
		var ph := kick_phase + asym_kick
		var side_amp := 0.95 if side < 0 else 1.05
		var idle_sway := 1.0 - clampf(stream_mix * 0.80, 0.0, 0.80)
		var base_kick := lerpf(0.22, 0.32, clampf(active_stroke + str_abs * 0.35, 0.0, 1.0)) * (1.0 - glide_blend * 0.34) * (1.0 + sprint_blend * 0.24) * side_amp
		var raw_wave := sin(ph) + sin(ph * 2.0 - 0.55) * 0.12 + cos(total_time * (0.65 if side < 0 else 0.77)) * 0.06 * idle_sway
		var kick_swing := raw_wave * base_kick
		var rec_flex := maxf(0.0, cos(ph - 0.32)) * lerpf(0.115, 0.095, stream_mix) * (1.0 - glide_blend * 0.32) + lerpf(0.052, 0.022, stream_mix)
		var leg_reach := (thigh_len + shin_len) - rec_flex
		var org_lat := sin(ph * 0.5 + side * 0.4) * lerpf(0.016, 0.026, clampf(effort, 0.0, 1.0)) + sin(total_time * (0.55 if side < 0 else 0.49) + side) * 0.012
		var carve_tail := clampf(-yaw_vel * lerpf(0.095, 0.185, stream_mix) + cur_r * 0.085, -0.32, 0.32)
		var lat_trail: float = side * 0.072 - strafe_blend * 0.22 - s.roll * 0.16 + carve_tail + org_lat
		var tread_kick := sin(total_time * 2.8 + (PI if side > 0 else 0.0)) * 0.21 * side_amp
		var idle_hover_b := lerpf(0.18 + kick_swing * 1.15, 0.02 + kick_swing * 0.82, near_bottom)
		var idle_s := lerpf(leg_reach * 0.94, leg_reach * 0.97, maxf(tread, near_bottom))
		var idle_b := lerpf(idle_hover_b, 0.14 + tread_kick, tread)
		var idle_r := lat_trail + tread * (side * 0.045 + cos(total_time * 2.8 + (PI if side > 0 else 0.0)) * 0.042)
		var swim_mix := clampf(maxf(stream_mix * 1.15, near_bottom * 0.88), 0.0, 1.0)
		var ls := lerpf(idle_s, leg_reach, swim_mix)
		var lb := lerpf(idle_b, 0.01 + kick_swing, swim_mix)
		var lr := lerpf(idle_r, lat_trail, swim_mix)
		var rev_ph := kick_phase * 1.12 + (PI + 0.24 if side > 0 else 0.0)
		var rev_s := (thigh_len + shin_len) - (0.065 + maxf(0.0, cos(rev_ph - 0.25)) * 0.095)
		var rev_b := 0.20 + sin(rev_ph) * 0.26 * side_amp
		var rev_r := side * 0.11 + sin(rev_ph * 0.5 + side) * 0.055
		var rev_mix := smoothstep(0.04, 0.80, reverse_blend) * (1.0 - near_bottom * 0.78)
		ls = lerpf(ls, rev_s, rev_mix)
		lb = lerpf(lb, rev_b, rev_mix)
		lr = lerpf(lr, rev_r, rev_mix)
		var leg_spring = leg_spring_l if side < 0 else leg_spring_r
		var lc: Dictionary = physics_control.get_control("LeftLeg" if side < 0 else "RightLeg")
		var lk := clampf(lc.angularStrength / 38.0, 0.30, 2.0)
		var leq := clampf(lc.equilibriumWeight / 8.5, 0.30, 2.0)
		var lin: float = lc.inertiaScale
		var flow := lerpf(1.0, 0.68, glide_blend)
		var float_wave := sin(total_time * 1.15 + side * 1.35) * 0.14 * (1.0 - effort * 0.55)
		var inertia := Vector3((acc_y * 0.11 - cur_y * 0.26) * lin, (-acc_b * 0.24 + cur_b * 0.42 + float_wave) * lin, (-acc_r * 0.22 + cur_r * 0.46 + yaw_vel * 0.34) * lin)
		var sim: Vector3 = leg_spring.step(dt, Vector3(ls, lb, lr), lerpf(22.0, 48.0, clampf(effort, 0.0, 1.0)) * lk * flow,
			lerpf(0.9, 0.25, clampf(maxf(effort, maxf(near_bottom, stream_mix)), 0.0, 1.0)) * leq,
			lerpf(5.0, 7.6, clampf(effort, 0.0, 1.0)) * sqrt(maxf(0.35, lk)), inertia)
		var ankle := hip + (spine_dir * sim.x + (body_belly * sim.y + body_right * sim.z))
		var sole := 0.12
		var ground_contact := 0.0
		var floor_n := Vector3.UP
		var floor_y := -INF
		var want_lift2 := 0.0
		if get_floor != null:
			floor_y = get_floor.call(ankle.x, ankle.z)
			if is_finite(floor_y):
				var eps := 0.40
				var hL: float = get_floor.call(ankle.x - eps, ankle.z)
				var hR: float = get_floor.call(ankle.x + eps, ankle.z)
				var hD: float = get_floor.call(ankle.x, ankle.z - eps)
				var hU: float = get_floor.call(ankle.x, ankle.z + eps)
				if is_finite(hL) and is_finite(hR) and is_finite(hD) and is_finite(hU):
					floor_n = BM.nrm(Vector3(hL - hR, 2.0 * eps, hD - hU))
				var dist := ankle.y - (floor_y + sole)
				if dist < 0.24:
					ground_contact = clampf(1.0 - maxf(0.0, dist) / 0.24, 0.0, 1.0)
					if dist < 0.0: want_lift2 = maxf(want_lift2, -dist)
		if is_finite(smooth_support_y):
			var min_sup := smooth_support_y + sole
			if ankle.y < min_sup: want_lift2 = maxf(want_lift2, min_sup - ankle.y)
		var lift_spr = ankle_lift_spring_l if side < 0 else ankle_lift_spring_r
		var sm_lift: float = lift_spr.step(clampf(want_lift2, 0.0, 0.55), 0.12, dt)
		if sm_lift > 0.002:
			var lifted_y := ankle.y + sm_lift
			var max_leg := (thigh_len + shin_len) * 0.94
			var dy := clampf(lifted_y - hip.y, -max_leg * 0.85, max_leg * 0.22)
			var need_h := sqrt(maxf(0.10, max_leg * max_leg - dy * dy))
			var dx := ankle.x - hip.x
			var dz := ankle.z - hip.z
			var hd := Vector2(dx, dz).length()
			var aft_mix := smoothstep(0.02, 0.22, sm_lift)
			if not thalassa_exact:
				# FIX (stress J5): Thalassa switched this pull-aft on and off at hd = 0.34 m, a 20 cm knee jump
				aft_mix *= 1.0 - smoothstep(0.26, 0.42, hd)
			if hd < (0.42 if not thalassa_exact else 0.34):
				dx = lerpf(dx, -fwd_horiz.x * need_h + body_right.x * (side * 0.08), aft_mix)
				dz = lerpf(dz, -fwd_horiz.z * need_h + body_right.z * (side * 0.08), aft_mix)
			var nh := Vector2(dx, dz).length()
			if nh == 0.0: nh = 1.0
			var ch := minf(nh, need_h)
			ankle = Vector3(hip.x + dx / nh * ch, lifted_y, hip.z + dz / nh * ch)
		var want_fp := Vector3.ZERO
		if query != null:
			var fh: Dictionary = query.call(ankle, 0.14, null)
			if not fh.is_empty() and fh.dist < 0.14 and fh.has("normal"):
				want_fp = fh.normal * minf(0.14, 0.14 - fh.dist)
		var fp_spr = swim_foot_push_l if side < 0 else swim_foot_push_r
		var sm_fp: Vector3 = fp_spr.step(want_fp, 0.10, dt)
		if sm_fp.length() > 0.002:
			ankle += sm_fp
			if is_finite(floor_y) and ankle.y < floor_y + sole:
				ankle.y = floor_y + sole
		if not thalassa_exact:
			# FIX (stress J5): support and seabed pushes switch on abruptly (a ledge found under her) and swept the
			# foot 30 cm in a tick; the ankle may move at most SWIM_ANKLE_RATE m/s relative to the hip
			# measured in the body frame, so a fast turn or pitch of the whole body is not read as ankle motion;
			# the seabed clamp is re-applied after, so the limiter can never hold the foot inside rock (Fable review)
			var w := ankle - hip
			var rel := Vector3(w.dot(body_right), w.dot(body_belly), w.dot(spine_dir))
			var prev_rel: Vector3 = swim_ankle_rel.get(side, rel)
			rel = prev_rel + (rel - prev_rel).limit_length(SWIM_ANKLE_RATE * dt)
			swim_ankle_rel[side] = rel
			ankle = hip + body_right * rel.x + body_belly * rel.y + spine_dir * rel.z
			if is_finite(floor_y) and ankle.y < floor_y + sole:
				ankle.y = floor_y + sole
		var active_ph := lerpf(ph, rev_ph, rev_mix)
		var kick_ankle := -cos(active_ph - 0.42) * lerpf(0.24, 0.40, clampf(effort + stream_mix * 0.30, 0.0, 1.0)) * (1.0 + sprint_blend * 0.20)
		var foot_roll := sin(active_ph * 0.5 + side * 0.7) * 0.14
		var plantar := lerpf(0.32, 0.58, clampf(stream_mix * 1.15, 0.0, 1.0)) + rev_mix * 0.10
		var fin_spring = fin_spring_l if side < 0 else fin_spring_r
		var sim_foot: float = fin_spring.step(dt, plantar + kick_ankle, 42.0, 7.5, 9.2, -acc_b * 0.12)
		var sfr2 := body_right.cross(floor_n)
		var sfw := BM.nrm(sfr2) if sfr2.length() > 1e-4 else fwd_horiz
		var gb := ground_contact * (1.0 - clampf((swim_blend - 0.35) * 1.5, 0.0, 1.0))
		var opts := {"softReach": 0.985, "softMargin": 0.08, "minFlexDeg": 8.0, "maxFlexDeg": 124.0, "maxHipExtDeg": 18.0,
			"maxHipFlexDeg": 112.0, "maxAdductionDeg": 6.5, "maxAbductionDeg": 34.0, "kneeOutBias": 0.08,
			"anklePitchRad": -(0.28 + sim_foot * 0.58), "ankleRollRad": foot_roll * side, "minAnklePitchRad": -0.96,
			"maxAnklePitchRad": 0.44, "groundBlend": gb, "groundFwd": sfw, "groundUp": floor_n}
		var solved: Dictionary
		var nc_saved: Vector3 = noclip_off.get(side, Vector3.ZERO)     # the clearance rate limit steps once a tick
		if surf_env != null:
			solved = solve_noclip_leg(hip, ankle, side, spine_dir, body_belly, surf_env, opts)
		else:
			solved = BM.leg(hip, ankle, side, spine_dir, body_belly, thigh_len, shin_len, opts)
		var fold_live: bool = swim_fold.get(side, Vector2.ZERO).x > 1e-4
		var near_sand := not is_finite(floor_y) or ankle.y - floor_y < 0.55 or minf(solved.ik.mid.y, hip.y) - floor_y < 0.30
		if not thalassa_exact and get_floor != null and (near_sand or fold_live):
			# FIX (Mac playtest, stress B44): settling onto the floor, the pointed feet went 30 cm into the sand. The
			# seabed lift above only keeps the ANKLE 12 cm up, through a lagging spring, and raising the ankle alone
			# can't help once the hips are low: the hip can't extend far enough. A diver near the bottom folds instead
			# (knees bent toward the sand, fins up behind: trim). Measure the solved sole plate and knee against the
			# floor and fold the leg toward that trim pose by the least amount that clears; the fold comes in as fast
			# as the sand does and lets go slowly.
			var fold_need := 0.0
			var trim := hip + spine_dir * 0.40 - body_belly * 0.24 + body_right * (side * 0.06)
			var base := ankle
			# standing on the bottom the plate rests on the sand; sinking, the fold starts early by what 0.12 s of sinking covers
			var clear := lerpf(SWIM_SOLE_CLEAR, 0.004, gb) + maxf(0.0, -s.vel.y) * 0.12 * (1.0 - gb)
			# the search uses the plain leg solve (the rock-clearance passes are costly); the chosen fold gets the full one
			var solve_at := func(f: float) -> Dictionary:
				return BM.leg(hip, base.lerp(trim, f), side, spine_dir, body_belly, thigh_len, shin_len, opts)
			if _leg_floor_short(solved, get_floor, clear) > 0.0005:
				# coarse steps, then halve between the last fold that fails and the first that clears, so the fold
				# moves continuously (1/8 steps alone made the ankle jump)
				var lo_f := 0.0
				var hi_f := -1.0
				for k in range(1, 13):     # past 1 the fold carries on beyond trim (shins near vertical)
					var f := float(k) / 8.0
					if _leg_floor_short(solve_at.call(f), get_floor, clear) <= 0.0005:
						hi_f = f; break
					lo_f = f
				if hi_f < 0.0:
					fold_need = lo_f
				else:
					for _b in 5:
						var mf := (lo_f + hi_f) * 0.5
						if _leg_floor_short(solve_at.call(mf), get_floor, clear) <= 0.0005: hi_f = mf
						else: lo_f = mf
					fold_need = hi_f
			# a critically damped spring carries the fold: quick in (the sinking look-ahead in `clear` covers its lag),
			# slow out, and never a jump in the ankle's speed
			var fs: Vector2 = swim_fold.get(side, Vector2.ZERO)
			var w_f := SWIM_FOLD_W_IN if fold_need > fs.x else SWIM_FOLD_W_OUT
			var n_sub := maxi(1, ceili(dt / 0.004))
			for _i in n_sub:
				var h := dt / n_sub
				fs.y += (w_f * w_f * (fold_need - fs.x) - 2.0 * w_f * fs.y) * h
				fs.x += fs.y * h
			fs.x = clampf(fs.x, 0.0, 1.5)
			swim_fold[side] = fs
			var fold := fs.x
			if fold > 1e-4:
				ankle = base.lerp(trim, fold)
				if surf_env != null:
					noclip_off[side] = nc_saved
					solved = solve_noclip_leg(hip, ankle, side, spine_dir, body_belly, surf_env, opts)
				else:
					solved = BM.leg(hip, ankle, side, spine_dir, body_belly, thigh_len, shin_len, opts)
		solved.ik.softStress = leg_spring.get_stress()
		solved.ik.groundContact = ground_contact
		return {"ik": solved.ik, "finMat": solved.finMat, "finDir": solved.finDir, "groundContact": ground_contact, "floorNormal": floor_n}

	var leg_l: Dictionary = solve_leg.call(-1.0)
	var leg_r: Dictionary = solve_leg.call(1.0)

	var swim_hand := func(ik: Dictionary, side: float) -> Transform3D:
		var fd := BM.nrm(ik.eff - ik.mid)
		var org := sin(total_time * (1.07 if side < 0 else 0.83) + side) * 0.12
		var feather := lerpf(0.25, 0.68, ik.get("pullFactor", 0.0)) + org
		var hy := fd
		var zb := BM.nrm(body_back + body_right * (side * feather))
		if ik.brace > 0.05 and ik.braceNormal != null:
			var rw := smoothstep(0.12, 0.85, ik.brace)
			var n: Vector3 = ik.braceNormal
			if ik.braceMode == "ceiling_touch":
				var cf := BM.nrm(fwd_horiz - n * fwd_horiz.dot(n))
				if cf.length() > 0.1: hy = BM.nrm(hy.lerp(cf, rw * 0.88))
				zb = BM.nrm(zb.lerp(n, rw * 0.94))
			else:
				zb = BM.nrm(zb.lerp(n, rw * 0.90))
		var xa := BM.nrm(hy.cross(zb))
		return BM.basis_xf(ik.eff, xa, hy, xa.cross(hy))
	var hand_l_mat: Transform3D = swim_hand.call(arm_l, -1.0)
	var hand_r_mat: Transform3D = swim_hand.call(arm_r, 1.0)
	var torch_x := BM.nrm(fore_l_dir.cross(body_back))
	var torch_mat := BM.basis_xf(torch_origin, torch_x, fore_l_dir, torch_x.cross(fore_l_dir))
	left_wrist_light_pos = torch_mat * Vector3(0, 0.072, 0)
	left_wrist_light_dir = fore_l_dir

	var head := solve_head(dt, chest_pos, neck_pos, chest_x, chest_axis_y, chest_fwd_swim, brain_swim.gazeDirWorld,
		{"maxYaw": 1.04, "minPitch": -0.58, "maxPitch": lerpf(0.72, 1.08, clampf(swim_blend, 0.0, 1.0)), "neckPitchShare": 0.44,
		"extraRoll": brain_swim.headTiltRad, "neckHalflife": 0.095 if brain_swim.get("objectiveFast", false) else 0.21})
	swim_pose = {
		"mode": "swim", "neckPos": head.neckPos, "chestPos": chest_pos, "waistPos": waist_pos, "pelvisPos": pelvis_pos,
		"clavicleL": clavicle_l, "clavicleR": clavicle_r, "shoulderL": shoulder_l, "shoulderR": shoulder_r, "hipL": hip_l, "hipR": hip_r,
		"bodyRight": body_right, "bodyBack": body_back, "bodyAxisY": body_axis_y,
		"armL": arm_l, "armR": arm_r, "legL": leg_l, "legR": leg_r,
		"chestMat": chest_mat, "pelvisMat": pelvis_mat, "headMat": head.headMat, "handLMat": hand_l_mat, "handRMat": hand_r_mat, "torchMat": torch_mat,
		"headMotion": {"pos": head.headPos, "fwd": head.headFwd, "neckYaw": head.neckYaw, "neckPitch": head.neckPitch},
		"bodyPitch": body_pitch, "swimBlend": swim_blend, "reverseBlend": reverse_blend, "braceL": brace_l, "braceR": brace_r,
		"impactEnergy": impact_energy, "lightButtonReach": bp,
	}
	var gwb := clampf(s.ground_walk_blend, 0.0, 1.0)
	if gwb > 0.005:
		var walk := solve_walk_wade(dt, s, total_time, get_floor, get_normal, query, sense, on_shore_footstep, env.get("ray"), env.get("point_solid"))
		if gwb >= 0.992:
			swim_pose = walk
		else:
			swim_pose = blend_swim_walk(swim_pose, walk, gwb)
	return swim_pose

## ikSolveWorldWalkWadePose
## Foothold search (see solve_walk_wade). Returns the landing spot (xz; y untouched).
func _foothold(from: Vector3, to: Vector3, fyaw: float, floor_here: float, get_floor, get_normal, _ray) -> Vector3:
	var ff := Vector3(-sin(fyaw), 0, -cos(fyaw))
	var fr := Vector3(cos(fyaw), 0, -sin(fyaw))
	var g_from: float = get_floor.call(from.x, from.z)
	if not is_finite(g_from) or absf(g_from - floor_here) > 0.36: g_from = floor_here
	var track := Vector3(to.x - from.x, 0, to.z - from.z)
	var dist := track.length()
	var dir := track / dist if dist > 1e-4 else Vector3.ZERO
	# nearest first: 0, back 3 cm, ahead 3 cm, ... (ahead at most 12 cm past the planner's spot, back to take-off)
	var offs := [0.0]
	for k in range(1, int(ceil(dist / 0.03)) + 1):
		offs.append(-minf(dist, k * 0.03))
		if k * 0.03 <= 0.12: offs.append(k * 0.03)
	for o in offs:
		var c: Vector3 = to + dir * o
		var c2 = _tread_snap(c, ff, get_floor, get_normal)
		if c2 != null and _foot_fits(c2, ff, fr, from, g_from, get_floor, get_normal, _ray):
			return c2
	return Vector3(from.x, to.y, from.z)

## a footprint across a step edge moves onto the nearer tread; null when there is no ground
func _tread_snap(spot: Vector3, ff: Vector3, get_floor, get_normal):
	var heel_p := spot - ff * 0.03
	var toe_p := spot + ff * 0.15
	var gh: float = get_floor.call(heel_p.x, heel_p.z)
	var gt: float = get_floor.call(toe_p.x, toe_p.z)
	if not (is_finite(gh) and is_finite(gt)): return null
	# what the heel's slope predicts at the toe; a step is a jump beyond that (a 15-30 deg ramp is not)
	var nh: Vector3 = get_normal.call(heel_p.x, heel_p.z) if get_normal != null else Vector3.UP
	var slope_k := -(nh.x * ff.x + nh.z * ff.z) / maxf(0.3, nh.y)
	if absf(gt - (gh + slope_k * 0.18)) <= 0.03: return spot
	var a := 0.0
	var b := 0.18
	for _k in 6:     # find the edge along the foot
		var m := (a + b) * 0.5
		var pm := heel_p + ff * m
		if absf(get_floor.call(pm.x, pm.z) - (gh + slope_k * m)) < 0.02: a = m
		else: b = m
	var fwd_shift := b + 0.02           # heel just past the edge
	var back_shift := 0.18 - a + 0.02   # toe just short of it
	return spot + ff * fwd_shift if fwd_shift <= back_shift else spot - ff * back_shift

## the whole footprint (heel, toe, both edges) stands on one walkable plane within a step of the take-off ground, and
## the swing from the take-off spot to it crosses no wall (anything taller than that step)
func _foot_fits(spot: Vector3, ff: Vector3, fr: Vector3, from: Vector3, g_from: float, get_floor, get_normal, _ray) -> bool:
	var gy: float = get_floor.call(spot.x, spot.z)
	if not is_finite(gy): return false
	var n: Vector3 = get_normal.call(spot.x, spot.z) if get_normal != null else Vector3.UP
	if n.y < 0.56: return false
	# a step is a jump in the ground beyond what the slope under the take-off foot carries on to (a long stride up a
	# 30 deg ramp rises 36 cm and is no step)
	var n0: Vector3 = get_normal.call(from.x, from.z) if get_normal != null else Vector3.UP
	if n0.y < 0.56: n0 = Vector3.UP
	var pred0 := g_from - (n0.x * (spot.x - from.x) + n0.z * (spot.z - from.z)) / n0.y
	if absf(gy - pred0) > 0.36 and absf(gy - g_from) > 0.36: return false
	var tips := [spot + ff * (0.168 + FOOT_R), spot - ff * FOOT_R, spot + ff * 0.07 + fr * FOOT_R, spot + ff * 0.07 - fr * FOOT_R]
	for q in tips:
		var gq: float = get_floor.call(q.x, q.z)
		var pred: float = gy - (n.x * (q.x - spot.x) + n.z * (q.z - spot.z)) / n.y
		if not is_finite(gq) or absf(gq - pred) > 0.03: return false
	if _ray != null:
		var y0 := maxf(g_from, gy) + 0.07
		var o := Vector3(from.x, y0, from.z)
		for q in tips:
			var hit: Dictionary = _ray.call(o, Vector3(q.x, y0, q.z))
			if not hit.is_empty() and absf(hit.normal.y) < 0.7: return false
	return true

## the ground a foot stands on at xz, or the body's ground when that is a wall, a drop or too steep to stand on
static func _foot_ground(get_floor, get_normal, p: Vector3, floor_here: float) -> float:
	var g: float = get_floor.call(p.x, p.z)
	if not is_finite(g) or absf(g - floor_here) > 0.36: return floor_here
	if get_normal != null and (get_normal.call(p.x, p.z) as Vector3).y < 0.56: return floor_here
	return g

func solve_walk_wade(dt: float, s, total_time: float, get_floor, get_normal, _query, sense = null, on_footstep = null, _ray = null, _solid = null) -> Dictionary:
	var sdt := clampf(dt, 0.0001, 0.05)
	var yaw: float = s.yaw
	var look_pitch := clampf(s.pitch, -1.12, 1.12)
	var wade_b := clampf(s.wade_blend, 0.0, 1.0)
	var floor_here: float
	var air_offset: float = s.shore_jump_offset
	if is_finite(s.shore_floor_y): floor_here = s.shore_floor_y
	elif get_floor != null: floor_here = get_floor.call(s.pos.x, s.pos.z)
	else: floor_here = s.pos.y - 1.24
	if not thalassa_exact and not is_finite(floor_here):
		floor_here = s.pos.y - 1.24     # FIX (stress BM): no ground under her at all (walked off the world's edge) made the whole pose NaN
	var air_rebase := 0.0
	if not thalassa_exact:
		# FIX (stress J5): follow the floor the way the motor's eye does (18/s, trailing by at most its step_lag), so
		# the pelvis climbs a ledge with the eye instead of snapping 30 cm in one tick
		var lag: float = s.config.get("step_lag", 0.04)
		var gf_prev := ground_follow
		if is_nan(ground_follow) or absf(floor_here - ground_follow) > 1.0:
			ground_follow = floor_here
		else:
			ground_follow = lerpf(ground_follow, floor_here, BM.expk(18.0, sdt))
			if not s.shore_is_airborne:
				ground_follow = clampf(ground_follow, floor_here - lag, floor_here + lag)
			elif not is_nan(gf_prev):
				# ROOT (stress B39, running off a ledge: the pelvis fell 12 cm in a tick against the eye): in the air the
				# smoothed ground under her still moves (towards the floor below the ledge) and her offset from it is
				# re-based to match, so ground + offset stays her height. The body's own height state is measured from
				# that ground too and has to move with it; left to catch up through its springs, it dropped with the ground
				air_rebase = gf_prev - ground_follow
		# airborne, the motor's jump offset is measured from the floor under her right now, which jumps at a ledge
		# edge; re-base it on the smoothed ground so ground + offset stays her continuous height
		if s.shore_is_airborne:
			air_offset = s.shore_jump_offset + (floor_here - ground_follow)
		floor_here = ground_follow
	var ground := Vector3(s.pos.x, floor_here, s.pos.z)
	var fs_cb = null
	if on_footstep != null:
		var surf_y: float = s.config.surface_y
		fs_cb = func(ev: Dictionary) -> void:
			var wd: float = surf_y - ev.pos.y
			var e2 := ev.duplicate()
			e2.waterDepth = wd
			e2.material = "wade" if wd > 0.05 else "sand"
			on_footstep.call(e2)
	# FIX (stress J7): landing spots stay inside the leg's sideways reach (the clamp below is -0.048..0.22 from the hip)
	world_foot_placer.lat_reach = null if thalassa_exact else Vector3(hip_half_w, 0.03, 0.19)
	world_foot_placer.target_filter = null
	if thalassa_exact:
		world_foot_placer.forced = {"L": 0.0, "R": 0.0}
		world_foot_placer.ttl = {"L": INF, "R": INF}
	if not thalassa_exact and _ray != null and get_floor != null:
		# ROOT (stress B37/J6/J7): footholds are chosen on the real ground. Candidates run back from the planner's spot
		# along the foot's own track (take-off -> landing, never towards her centre: that pulled both feet onto the
		# centreline); the first one whose whole footprint lies on one walkable plane, within a step of the ground it
		# leaves from, with no wall between, wins. A footprint across a tread edge moves onto the nearer tread.
		var fh_floor := floor_here
		world_foot_placer.target_filter = func(from: Vector3, to: Vector3, fyaw: float) -> Vector3:
			return _foothold(from, to, fyaw, fh_floor, get_floor, get_normal, _ray)
	var loco: Dictionary = world_foot_placer.update(sdt, {
		"localPos": ground, "velLocal": s.shore_vel_xz, "accelLocal": s.shore_accel_xz, "desiredVelLocal": s.shore_desired_vel_xz,
		"localYaw": yaw, "yawRate": s.shore_yaw_rate, "vesselId": "world_shore", "shipRoll": 0.0, "shipPitch": 0.0, "impactShake": 0.0,
		"isAirborne": s.shore_is_airborne, "jumpOffset": air_offset, "jumpVelY": s.shore_jump_vel_y,
		"jumpAnticipDip": s.shore_jump_anticip * 0.052, "jumpAnticip": s.shore_jump_anticip, "isDiveJump": s.shore_dive_arc_timer > 0.0,
		"justLanded": s.shore_just_landed, "landingImpact": s.shore_landing_impact, "crouchBlend": s.shore_crouch_blend,
		"brakingImpulse": s.shore_braking_impulse, "onFootstep": fs_cb, "jumpRebase": air_rebase})
	var up := Vector3.UP
	var w_fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var w_right := Vector3(cos(yaw), 0, -sin(yaw))
	var body_back := -w_fwd
	var rb: float = loco.runBlend
	var look_fwd := BM.fwd(yaw, look_pitch)
	var look_up := BM.nrm(w_right.cross(look_fwd))
	var des_spd: float = s.shore_desired_vel_xz.length()
	var walk_ctx := {
		"mode": "deck_walk", "headPos": Vector3(ground.x, ground.y + 1.32, ground.z), "bodyFwd": w_fwd, "bodyRight": w_right, "bodyUp": up,
		"visionFwd": look_fwd, "visionRight": w_right, "visionUp": look_up,
		"cameraFwd": sense.cameraFwd if (sense != null and sense.get("cameraFwd") != null) else look_fwd,
		"desiredLookDir": look_fwd, "speed": loco.speed, "desSpeed": des_spd, "yawRate": s.shore_yaw_rate,
		"isAirborne": s.shore_is_airborne, "jumpAnticip": s.shore_jump_anticip, "inCriticalTransition": s.shore_dive_arc_timer > 0.0,
		"objectiveFocus": {"label": "SHORE DIVE", "dir": look_fwd, "holdSec": 0.65} if s.shore_dive_arc_timer > 0.0 else null,
		"getFloorHeight": get_floor, "crouchBlend": s.shore_crouch_blend,
		"colliders": sense.get("colliders") if sense != null else null, "pois": sense.get("pois") if sense != null else null}
	var bo: Dictionary
	if thalassa_exact:
		bo = brain.update(sdt, walk_ctx)
	elif _brain_fresh:
		bo = brain_out     # stepped in the swim pose this rig step (see ROOT there)
	else:
		walk_ctx["checkLineOfSight"] = sense.get("checkLineOfSight") if sense != null else null
		walk_ctx["effort"] = clampf((float(loco.speed) - 0.2) / 3.0 + (0.25 if s.shore_is_airborne else 0.0), 0.0, 1.0)
		bo = brain.update(sdt, walk_ctx)
		_brain_fresh = true
	brain_out = bo
	var pelv_yaw: float = yaw + loco.pelvisYaw
	if not thalassa_exact:
		# ROOT (stress monkey slips): a planted foot can't turn, and the hip rotates only int 0.20 / ext 0.48 rad over
		# it (plus a little ankle). Turning faster than the steps come, the leg solver twisted the planted foot on the
		# ground (ball moving 5-12 cm, ankle still). A body keeps the pelvis with the stance foot and lets the spine take
		# the turn: the pelvis yaw is held inside every planted foot's range and catches up once that foot lifts
		var off := lerpf(pelv_yaw_off, 0.0, BM.expk(9.0, sdt))
		if not s.shore_is_airborne:
			var lo := -INF; var hi := INF
			for sd in [-1.0, 1.0]:
				var fq: Dictionary = loco.footL if sd < 0.0 else loco.footR
				var fo: Dictionary = loco.footR if sd < 0.0 else loco.footL
				if fq.stepping or not fo.stepping: continue     # with both feet down the foot steps (rotation request)
				var d := BM.wrap_pi(pelv_yaw - fq.yaw)     # pelvis yaw from the foot; trn = side * d
				var r_lo := (-0.48 - 0.08) if sd < 0.0 else (-0.20 - 0.08)
				var r_hi := (0.20 + 0.08) if sd < 0.0 else (0.48 + 0.08)
				lo = maxf(lo, r_lo - d); hi = minf(hi, r_hi - d)
			var want := off
			if lo <= hi: want = clampf(off, lo, hi)
			elif is_finite(lo): want = (lo + hi) * 0.5
			# taken up at most 6 rad/s: the range keeps 0.08 rad of ankle twist in hand for it, and a hold that came on
			# in one tick (the other foot lifting) popped the knee (stress B35 at 120 Hz)
			off = move_toward(off, want, 6.0 * sdt)
		pelv_yaw_off = clampf(off, -0.7, 0.7)
		pelv_yaw += pelv_yaw_off
	else:
		pelv_yaw_off = 0.0
	var pelv_fwd := Vector3(-sin(pelv_yaw), 0, -cos(pelv_yaw))
	var pelv_right_base := Vector3(cos(pelv_yaw), 0, -sin(pelv_yaw))
	var pelv_back := -pelv_fwd
	var total_proll := clampf(loco.pelvisRoll + bo.idleHipShift * 1.45, -0.095, 0.095)
	var pelv_right := BM.nrm(pelv_right_base * cos(total_proll) + up * sin(total_proll))
	var twist_yaw: float = yaw + loco.spineTwist + bo.get("torsoCuriosityYaw", 0.0)
	var chest_fwd := Vector3(-sin(twist_yaw), 0, -cos(twist_yaw))
	var chest_right_raw := Vector3(cos(twist_yaw), 0, -sin(twist_yaw))
	var chest_roll := clampf(-total_proll * 0.56 + loco.spineLeanLat * 0.24, -0.070, 0.070)
	var chest_right := BM.nrm(chest_right_raw * cos(chest_roll) + up * sin(chest_roll))
	var chest_back := -chest_fwd
	var look_spine := clampf(-look_pitch * 0.22, -0.20, 0.22)
	var wade_lean := wade_b * clampf(loco.speed / 1.4, 0.0, 1.0) * 0.075
	var lean: float = clampf(loco.spineLeanFwd + bo.anticipationLean + look_spine + wade_lean, -0.20, 0.36)
	var b_cen: float = bo.get("breathCentered", 0.0)
	var b_amp: float = bo.get("breathAmp", 1.0)
	if b_amp == 0.0: b_amp = 1.0
	var hip_h: float = 0.726 + loco.pelvisOffset.y + b_cen * 0.0045 * b_amp
	var hip_lat: float = loco.pelvisOffset.x + bo.idleHipShift
	if not thalassa_exact and get_floor != null:
		# ROOT (stress B37 stairs): the legs carry the pelvis. Its ground is the floor under her centre only while that
		# lies between the grounds her feet stand on (a swinging foot counts from its take-off ground towards its
		# landing ground as it travels). On smooth ground that is the floor itself; on stairs the body rises and sinks
		# with the steps, not as her centre crosses each riser.
		var tgt_dg := 0.0
		if not s.shore_is_airborne:
			var lo := INF
			var hi := -INF
			for fst3 in [loco.footL, loco.footR]:
				var gf := _foot_ground(get_floor, get_normal, fst3.pos, floor_here)
				if fst3.stepping:
					var g0 := _foot_ground(get_floor, get_normal, fst3.from, floor_here)
					var g1 := _foot_ground(get_floor, get_normal, fst3.to, floor_here)
					gf = lerpf(g0, g1, smoothstep(0.0, 1.0, fst3.t))
				lo = minf(lo, gf); hi = maxf(hi, gf)
			tgt_dg = clampf(floor_here, lo, hi) - floor_here
		support_dg = lerpf(support_dg, tgt_dg, BM.expk(14.0, sdt))
		hip_h += support_dg
	if not thalassa_exact and get_floor != null:
		# FIX (stress B37 stairs): the pelvis yields to a planted foot it would otherwise lift off the ground. The eye
		# climbs a stair as soon as her centre crosses the riser, and the trailing leg, still on the step below, was
		# stretched past its length: the foot floated up and dragged. A foot behind her gets up to 7 cm for its heel
		# rising (the toe pivot), so ordinary walking is unchanged.
		var need := 0.0
		if not s.shore_is_airborne:
			var reach := (thigh_len + shin_len) * 0.985
			for side in [-1.0, 1.0]:
				var fst2: Dictionary = loco.footL if side < 0 else loco.footR
				# a swinging foot counts from mid-swing with its landing spot, where the hip will be when it lands:
				# the pelvis is down before the foot is (downhill the front foot lands below her)
				var fp2: Vector3 = fst2.pos
				var w2 := 1.0
				var lead2 := Vector3.ZERO
				if fst2.stepping:
					w2 = smoothstep(0.35, 0.85, fst2.t)
					fp2 = fst2.to
					lead2 = Vector3(s.shore_vel_xz.x, 0, s.shore_vel_xz.y) * ((1.0 - fst2.t) * fst2.dur)
					if w2 <= 0.0: continue
				var g2: float = get_floor.call(fp2.x, fp2.z)
				if not is_finite(g2) or absf(g2 - floor_here) > 0.36: continue
				var hip2: Vector3 = ground + lead2 + up * hip_h + w_right * (side * hip_half_w + hip_lat)
				if fst2.stepping:
					var n2: Vector3 = get_normal.call(fp2.x, fp2.z) if get_normal != null else Vector3.UP
					if n2.y < 0.56: continue     # not a foothold (a wall or a slope too steep): nothing to reach down to
					hip2.y += _foot_ground(get_floor, get_normal, ground + lead2, floor_here) - floor_here
				var dxz := Vector2(hip2.x - fp2.x, hip2.z - fp2.z)
				var horiz := dxz.length()
				if horiz >= reach: continue
				var behind := clampf(-(Vector2(w_fwd.x, w_fwd.z).dot(-dxz)) / 0.2, 0.0, 1.0)
				var max_y := g2 + 0.052 + 0.07 * behind + sqrt(reach * reach - horiz * horiz)
				need = maxf(need, (hip2.y - max_y) * w2)
		need = clampf(need, 0.0, 0.18)
		pelvis_yield = lerpf(pelvis_yield, need, BM.expk(25.0 if need > pelvis_yield else 8.0, sdt))
		hip_h -= pelvis_yield
	var slf: float = loco.spineLeanFwd
	var sll: float = loco.spineLeanLat
	var pelvis_pos := ground + (up * hip_h + (w_right * hip_lat + w_fwd * (slf * 0.05)))
	var contra := -hip_lat * 0.46
	var waist_pos := pelvis_pos + (up * (0.160 * cos(lean * 0.45)) + (w_fwd * (0.160 * sin(lean * 0.45) + slf * 0.05) + w_right * (sll * 0.13 + contra * 0.45)))
	var chest_pos := waist_pos + (up * (0.195 * cos(lean)) + (w_fwd * (0.195 * sin(lean)) + w_right * (sll * 0.18 + contra)))
	var raw_neck := chest_pos + (up * (0.118 * cos(lean * 1.15)) + (w_fwd * (0.118 * sin(lean * 1.15)) + w_right * (sll * 0.05 + contra * 0.18)))
	var clav_lift := 0.042 + b_cen * 0.0068 * b_amp
	var shoulder_l := chest_pos + (chest_right * -shoulder_half_w + up * clav_lift)
	var shoulder_r := chest_pos + (chest_right * shoulder_half_w + up * clav_lift)
	var hip_l := pelvis_pos + pelv_right * -hip_half_w
	var hip_r := pelvis_pos + pelv_right * hip_half_w
	var jmp: Dictionary = loco.jump
	var air_b: float = jmp.airBlend

	var shore_leg := func(side: float) -> Dictionary:
		var hip := hip_l if side < 0 else hip_r
		var fst: Dictionary = loco.footL if side < 0 else loco.footR
		var fx: float = fst.pos.x
		var fz: float = fst.pos.z
		var fgy: float = get_floor.call(fx, fz) if get_floor != null else floor_here
		var fn: Vector3 = get_normal.call(fx, fz) if get_normal != null else s.shore_floor_normal
		if not thalassa_exact and (not is_finite(fgy) or absf(fgy - floor_here) > 0.36 or fn.y < 0.56):
			fn = s.shore_floor_normal
			fgy = floor_here     # FIX (stress J7): ground more than a step above or below her, or too steep to walk (Thalassa's 0.56), is a wall or a drop, not a foothold
		var plane_g := fgy     # the real ground under the foot (the swing floor below may sit higher), for the sole plane test
		if not thalassa_exact and get_floor != null:
			# FIX (stress J5/J7): the swing foot took the floor height at its own position only, so crossing a step
			# edge snapped it 30 cm up or down in one tick. Swing from the start floor towards the landing floor
			# (raised early, never below the ground under the foot), and let it fall smoothly, never jump.
			var key := "L" if side < 0 else "R"
			plane_g = fgy
			if s.shore_is_airborne:
				# in the air the placer's foot height is relative to the floor under her body; the floor under the foot
				# made a foot crossing a ledge edge in the air jump by the ledge height
				fgy = floor_here
			var tgt_floor := fgy
			if fst.stepping:
				var f0: float = get_floor.call(fst.from.x, fst.from.z)
				var f1: float = get_floor.call(fst.to.x, fst.to.z)
				if is_finite(f0) and is_finite(f1) and f1 - f0 < 0.36:     # taller than a step is a wall: don't lift onto it
					var rise := smoothstep(0.05, 0.45, fst.t) if f1 > f0 else smoothstep(0.30, 0.90, fst.t)
					tgt_floor = maxf(fgy, lerpf(f0, f1, rise))
					# ROOT (stress B37 toe in the riser): the swing clears the ground the foot is about to travel over,
					# not only the ground under it now: the upper hull of the ground under the footprint (heel to toe)
					# over the next 20 cm of its path towards the landing spot
					var trk := Vector3(fst.to.x - fx, 0, fst.to.z - fz)
					var left := trk.length()
					var tdir := trk / left if left > 1e-4 else Vector3.ZERO
					var ffw := Vector3(-sin(fst.yaw), 0, -cos(fst.yaw))
					for k in 5:
						var pp := Vector3(fx, 0, fz) + tdir * minf(left, k * 0.05)
						for off in [-0.03, 0.07, 0.17]:
							var g_h: float = get_floor.call(pp.x + ffw.x * off, pp.z + ffw.z * off)
							if is_finite(g_h) and g_h - f0 < 0.36:
								# ROOT (smoothness, ramps): the foot lies along its own ground (groundUp = fn). What it must clear is
								# ground ahead that rises above that plane (a riser, a tread), not the slope it is pitched along:
								# counted level, 37 cm ahead of a foot on a 30 deg ramp is the whole step up, asked for at lift-off
								var qx: float = pp.x + ffw.x * off
								var qz: float = pp.z + ffw.z * off
								g_h = plane_g + maxf(0.0, g_h - (plane_g - (fn.x * (qx - fx) + fn.z * (qz - fz)) / maxf(0.3, fn.y)))
							if is_finite(g_h) and g_h - f0 < 0.36: tgt_floor = maxf(tgt_floor, minf(g_h, maxf(f0, f1) + 0.02 * (1.0 - smoothstep(0.5, 1.0, fst.t))))     # stepping down, the tread being left counts too (toe over its edge); capped, not dropped, at the landing height (dropping a sample as it crossed the cap made the swing floor chatter on a ramp)
			var prev_f: float = swing_floor[key]
			if not fst.stepping or is_nan(prev_f) or not is_finite(tgt_floor):
				swing_floor[key] = tgt_floor
				swing_floor_v[key] = 0.0
			elif tgt_floor >= prev_f:
				# rises at most 3 m/s (the hull looks ahead for it)
				# ROOT (smoothness, 43 000 m/s3 at every lift-off towards higher ground): the rise has a speed of its own,
				# which builds up at 80 m/s2 and eases into the height it is going to; it went 0 -> 3 m/s in one tick
				var v_h: float = minf(minf(3.0, swing_floor_v[key] + 80.0 * dt), sqrt(2.0 * 80.0 * (tgt_floor - prev_f)) + 0.2)
				swing_floor[key] = minf(tgt_floor, prev_f + v_h * dt)
				swing_floor_v[key] = (swing_floor[key] - prev_f) / dt
			else:
				# falls at 1.8 m/s, or faster if that is what reaches the landing ground by touch-down (a swing cut short
				# by the stance leg's reach landed with the floor still a riser up: 13 cm in one tick, stress B37 at 120 Hz)
				var rem_s: float = maxf(dt, (1.0 - fst.t) * fst.get("dur", 0.36))
				# (smoothness) the gap closes as the square of the time left: it reaches the landing ground at touch-down
				# with no speed left, where a fixed rate met the ground at up to 3 m/s
				var kq := clampf((rem_s - dt) / rem_s, 0.0, 1.0)
				swing_floor[key] = maxf(tgt_floor, minf(prev_f - 0.3 * dt, tgt_floor + (prev_f - tgt_floor) * kq * kq))
				swing_floor_v[key] = 0.0
			fgy = swing_floor[key]
		var swing_lift := maxf(0.0, fst.pos.y - floor_here)
		var wade_extra: float = sin(PI * fst.t) * wade_b * 0.036 if fst.stepping else 0.0
		var ankle_y := (fgy if is_finite(fgy) else floor_here) + 0.052 + swing_lift + wade_extra
		var ft := Vector3(fx, ankle_y, fz)
		var rel := ft - hip
		var lat_d := rel.dot(pelv_right_base) * side
		var fwd_d := rel.dot(pelv_fwd)
		var up_d := rel.dot(up)
		var cl_lat := clampf(lat_d, -0.048, 0.22) * side
		var mra := maxf(rb, air_b)
		var cl_fwd := clampf(fwd_d, lerpf(-0.34, -0.45, mra), lerpf(0.36, 0.45, mra))
		var ft_raw := ft
		var clamped := hip + (pelv_right_base * cl_lat + (pelv_fwd * cl_fwd + up * up_d))
		# ROOT (stress J7 slide): a planted foot is a world constant until it lifts; out of the hip's reach box it asks
		# for a step (below, ahead of time) instead of being dragged into the box
		if thalassa_exact or s.shore_is_airborne: ft = clamped
		elif fst.stepping:
			# FIX (stress J5, B14 turning on a 30 deg ramp at 120 Hz): a planted foot outside the reach box stays where
			# it stands (above) and asks for a step; at lift-off it was put into the box in one tick, up to 12 cm away
			# and, on a ramp, onto the higher ground there. The swing takes it into the box over its first quarter
			ft = ft_raw.lerp(clamped, smoothstep(0.0, 0.25, fst.t))
		if not thalassa_exact and fst.stepping and not s.shore_is_airborne and get_floor != null \
				and Vector2(clamped.x - ft_raw.x, clamped.z - ft_raw.z).length() > 0.001:
			# ROOT (stress B12 step down at 30/120 Hz): a long swing held back inside the reach box sat over the tread
			# it was leaving while its height came down to the landing below: the sole went 11 cm into the step. Held
			# back, the foot clears the ground under where it is (heel, middle and toe)
			var cfw := Vector3(-sin(fst.yaw), 0, -cos(fst.yaw))
			for o2 in [-0.03 - FOOT_R, 0.07, 0.17]:
				var gc: float = get_floor.call(ft.x + cfw.x * o2, ft.z + cfw.z * o2)
				if is_finite(gc) and gc - floor_here < 0.36: ft.y = maxf(ft.y, gc + 0.052 + 0.01)
		if not thalassa_exact:
			# FIX (stress J7): a planted foot outside these reach limits was dragged along the ground (skating up to
			# 1.6 m/s in turns) until the foot placer's own, wider emergency distance fired. Ask it to step now.
			var excess := Vector2(clamped.x - ft_raw.x, clamped.z - ft_raw.z).length()
			var fkey := "L" if side < 0 else "R"
			land_age[fkey] = 0.0 if fst.stepping else land_age[fkey] + dt
			# a foot that has just landed yields to the other foot (its request counts a third): stepping it again at
			# once stole the other foot's turn and left that one dragging
			var wgt := 0.33 if (land_age[fkey] < 0.12 and excess <= HARD_MISS) else 1.0     # far out of reach can't wait
			world_foot_placer.forced[fkey] = excess * wgt if (excess > 0.025 and not fst.stepping) else 0.0
			# ROOT (stress J7 drag): ask before the limit, not after it. Where the hip will be in 0.15 s (her velocity),
			# a foot that will be out of reach asks now, while the other is still down and the step can go at once;
			# asked only once out of reach, it waited for the other foot and was dragged meanwhile
			var oth: Dictionary = loco.footR if side < 0 else loco.footL
			if not fst.stepping and not oth.stepping and not s.shore_is_airborne:
				var vh := Vector3(s.shore_vel_xz.x, 0, s.shore_vel_xz.y) * 0.15
				var relp := ft_raw - (hip + vh)
				var lp_ := clampf(relp.dot(pelv_right_base) * side, -0.048, 0.22) * side
				var fp_ := clampf(relp.dot(pelv_fwd), lerpf(-0.34, -0.45, mra), lerpf(0.36, 0.45, mra))
				var cp := hip + vh + pelv_right_base * lp_ + pelv_fwd * fp_
				var ex_p := Vector2(cp.x - ft_raw.x, cp.z - ft_raw.z).length()
				if ex_p > 0.025: world_foot_placer.forced[fkey] = maxf(world_foot_placer.forced[fkey], minf(ex_p, 0.026))
		var rel_yaw := BM.wrap_pi(fst.yaw - pelv_yaw)
		if not thalassa_exact and not fst.stepping:
			# FIX (stress monkey runs): a planted foot turned past the hip's rotation range (int 0.20 / ext 0.48 rad) is
			# twisted about the ankle by the leg solver, sliding heel and ball; ask for a step before it gets there
			var trn := -side * rel_yaw
			if trn > 0.48 * 0.8 or trn < -0.20 * 0.8:
				var fk3 := "L" if side < 0 else "R"
				# past the full range the leg twists the planted foot on the ground: that can't wait for the other foot
				# (above the placer's walking wait threshold, 0.08), as a reach request can
				var past: bool = (trn > 0.48 or trn < -0.20) and absf(s.shore_yaw_rate) > 1.5     # a fast turn
				world_foot_placer.forced[fk3] = maxf(world_foot_placer.forced[fk3], 0.09 if past else 0.026)
		var fwf := Vector3(-sin(fst.yaw), 0, -cos(fst.yaw))
		var spj := fwf - fn * fwf.dot(fn)
		var sfw := BM.nrm(spj) if spj.length() > 1e-4 else fwf
		var boot_fwd := BM.nrm(sfw + fn * clampf(fst.toePitch, -0.62, 0.32))
		var hip_ext := lerpf(lerpf(24.0, 30.0, rb), 46.0, air_b)
		if not thalassa_exact and fst.stepping:
			# (run, heel recovery: the limit is on the line from hip to ankle. With the knee folded 110 deg that line
			# points 40 deg back while the thigh hangs about straight down, so the folded swing leg is given more of it)
			hip_ext = lerpf(hip_ext, maxf(hip_ext, 42.0), loco.get("runGait", 0.0) * clampf(fst.heelKick, 0.0, 1.0))
		var soft_m := 0.012
		if not thalassa_exact:
			# ROOT (run: knee pop, 14.7 m/s against the pelvis at 120 Hz): a running swing starts with the leg at full
			# stretch and its foot beyond reach behind her, the knee locked; the tick the foot came back within reach the
			# knee shot out 12 cm (near full stretch a millimetre of slack is a centimetre of knee). The swinging leg
			# gives sooner: its reach limit is soft over 5 % of its length, not 1.2 % (eased in after lift-off and out
			# again before touch-down and when she leaves the ground, so the planted leg's reach is what it was)
			var sk := "L" if side < 0 else "R"
			var want_soft: float = loco.get("runGait", 0.0) * smoothstep(0.0, 0.12, fst.t) * (1.0 - smoothstep(0.50, 0.85, fst.t)) if (fst.stepping and not s.shore_is_airborne) else 0.0
			swing_soft[sk] = lerpf(swing_soft[sk], want_soft, BM.expk(30.0, sdt))
			soft_m += 0.038 * swing_soft[sk]
		var leg_opts := {
			"preserveDown": true, "desiredYawOffsetRad": rel_yaw, "maxHipExtDeg": hip_ext,
			"maxHipFlexDeg": lerpf(110.0, 124.0, air_b), "maxAdductionDeg": 6.0, "maxAbductionDeg": lerpf(32.0, 38.0, air_b),
			"maxIntRotRad": 0.20, "maxExtRotRad": 0.48, "minFlexDeg": 5.0, "maxFlexDeg": 132.0, "softReach": 0.996, "softMargin": soft_m,
			"kneeOutBias": lerpf(0.07, 0.11, air_b), "kneeLiftBias": fst.heelKick * 0.24 + wade_b * 0.06,
			"minAnklePitchRad": -0.82, "maxAnklePitchRad": 0.48, "maxAnkleYawRad": 0.16, "maxAnkleRollRad": 0.20,
			"groundBlend": jmp.groundFootBlend, "groundFwd": boot_fwd, "groundUp": fn}
		var foot_k := "L" if side < 0 else "R"
		if not thalassa_exact:
			# ROOT (stress B35 knee pop at 120 Hz): a swing cut short by the stance budget touched down with its ankle still
			# 10 cm up (the swing floor over the slope's uphill side); planted, the ankle dropped in one tick. The landed
			# foot settles onto its ground at 4 m/s instead (two to three ticks)
			# (land_drop holds the height the ankle may not go below while it settles; applied after the sole lift, as a
			# floor, so it does not add to the lift that already holds the foot up)
			if last_stepping[foot_k] and not fst.stepping and not s.shore_is_airborne and is_finite(last_ank[foot_k]):
				land_drop[foot_k] = last_ank[foot_k]
			elif fst.stepping or s.shore_is_airborne:
				land_drop[foot_k] = -INF
		var solved := BM.leg(hip, ft, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
		if not thalassa_exact:
			var fk5 := "L" if side < 0 else "R"
			var tl := INF
			if not fst.stepping and not s.shore_is_airborne and s.shore_vel_xz.length() > 0.15:
				var v3 := Vector3(s.shore_vel_xz.x, 0, s.shore_vel_xz.y)
				var run_g: float = loco.get("runGait", 0.0)
				var miss_at := func(tau: float) -> float:
					var hp: Vector3 = hip + v3 * tau
					if get_floor != null:
						var gp: float = get_floor.call(s.pos.x + v3.x * tau, s.pos.z + v3.z * tau)
						if is_finite(gp): hp.y += clampf(gp - floor_here, -0.36, 0.36)
					var ft_t := ft
					if run_g > 0.0:
						# (running, the estimate was of a flat foot under a hip that stays where it is: it gave a stance out 18 cm
						# behind her, where the leg really holds to 30. By then she has come up out of the stance dip to her
						# take-off height, and the trailing foot is up on its ball, heel high: the ankle is higher and further
						# forward than it stood (the placer's push-off pitch for a foot that far behind))
						hp.y += run_g * maxf(0.0, 0.726 - FootPlacer.RUN_KNEE_BEND - hip_h) * minf(1.0, tau / 0.08)
						var pk := clampf(((ft - hp).dot(pelv_fwd) + 0.03) * -2.2, 0.0, 0.62) * run_g
						ft_t = ft + up * (0.11 * sin(pk) - 0.052 * (1.0 - cos(pk))) + pelv_fwd * (0.11 * (1.0 - cos(pk)) + 0.052 * sin(pk))
					var pr2 := BM.leg(hp, ft_t, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
					# ROOT (stress monkey landing slip): the reach box too, not only the leg. Landing in a side step the
					# leading foot leaves the box sideways long before the leg runs out of length; timed by the leg
					# alone the trailing foot went first and the leading one was dragged until it could step
					var rq := ft - hp
					var bl := clampf(rq.dot(pelv_right_base) * side, -0.048, 0.22) * side
					var bf := clampf(rq.dot(pelv_fwd), lerpf(-0.34, -0.45, mra), lerpf(0.36, 0.45, mra))
					var bc := hp + pelv_right_base * bl + pelv_fwd * bf
					var box_ex := Vector2(bc.x - ft.x, bc.z - ft.z).length()
					return maxf(pr2.ik.eff.distance_to(ft_t), box_ex - 0.013)
				var TOL := 0.012
				if miss_at.call(0.0) > TOL: tl = 0.0
				elif miss_at.call(0.48) > TOL:
					var lo := 0.0; var hi := 0.48
					for _i in 5:
						var md := (lo + hi) * 0.5
						if miss_at.call(md) > TOL: hi = md
						else: lo = md
					tl = lo
			world_foot_placer.ttl[fk5] = tl
		if not thalassa_exact and not fst.stepping and not s.shore_is_airborne:
			# (the same look ahead through the leg itself: its length, hip extension and rotation limits)
			var oth2: Dictionary = loco.footR if side < 0 else loco.footL
			if not oth2.stepping:
				var vh2 := Vector3(s.shore_vel_xz.x, 0, s.shore_vel_xz.y) * 0.15
				var pr := BM.leg(hip + vh2, ft, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
				if pr.ik.eff.distance_to(ft) > 0.02:
					var fk4 := "L" if side < 0 else "R"
					world_foot_placer.forced[fk4] = maxf(world_foot_placer.forced[fk4], 0.026)
		if not thalassa_exact and _ray != null:
			# FIX (stress J6): Thalassa's height field had no walls, so a foot could be planted through a wall or a
			# step face. Cast from under the hip to the foot's toe, heel and both edges (plus FOOT_R); a steep surface in
			# the way pushes the foot back out by the overshoot.
			var shift := Vector3.ZERO
			for _pass in 3:
				var push := Vector3.ZERO
				var fo: Vector3 = solved.finMat * Vector3(0, 0.07, -0.016)
				# three origins: under the hip, 22 cm behind it, and the foot's own centre; a ray that starts inside
				# rock sees nothing (standing at the foot of a slope the first is under the slope), so whichever is clear finds it
				var hb := hip - pelv_fwd * 0.22
				var origins := [Vector3(hip.x, fo.y, hip.z), Vector3(hb.x, fo.y, hb.z), fo]
				for e in [Vector3(0, 0.168 + FOOT_R, -0.016), Vector3(0, -FOOT_R, -0.016), Vector3(FOOT_R + 0.02, 0.07, -0.016), Vector3(-FOOT_R - 0.02, 0.07, -0.016)]:
					for o in origins:
						var tip: Vector3 = solved.finMat * e
						var hit: Dictionary = _ray.call(o, tip)
						if hit.is_empty() or absf(hit.normal.y) >= 0.7 or hit.position.y < fgy - 0.02: continue
						# a lip or riser she can stand on top of (within a step, walkable) is ground, not a wall
						var gt: float = get_floor.call(tip.x, tip.z) if get_floor != null else -INF
						var nt: Vector3 = get_normal.call(tip.x, tip.z) if get_normal != null else Vector3.UP
						# (up to 6 cm under that top counts, as the sole lift raises those; a pitched toe tip on a stair tread sits
						# there, and pushing it out of the riser below shoved the planted foot 20 cm back off the step)
						if is_finite(gt) and absf(gt - fgy) < 0.36 and nt.y >= 0.56 and (fst.stepping or tip.y > gt - 0.06) and not (_solid != null and _solid.call(Vector3(tip.x, gt + 0.01, tip.z))): continue
						var nh: Vector3 = hit.normal; nh.y = 0.0
						if nh.length() < 1e-3: continue
						nh = nh.normalized()
						var pv: Vector3 = nh * maxf(0.0, (hit.position - tip).dot(nh))
						if pv.length() > push.length(): push = pv
				# the knee too: walking into a steep rock face the shin leans into it (knee radius 0.04)
				var kd: Vector3 = (solved.ik.mid - hip).normalized()
				for ktip in [solved.ik.mid + kd * 0.05, solved.ik.mid + pelv_fwd * 0.05]:
					var kh: Dictionary = _ray.call(hip, ktip)
					if not kh.is_empty() and absf(kh.normal.y) < 0.7:     # same wall test as the foot: a walkable slope is not a wall
						var knh: Vector3 = kh.normal; knh.y = 0.0
						if knh.length() > 1e-3:
							knh = knh.normalized()
							var kpv: Vector3 = knh * maxf(0.0, (kh.position - ktip).dot(knh)) / maxf(0.3, knh.dot(kh.normal))
							if kpv.length() > push.length(): push = kpv
				if push.length() < 0.002: break
				shift = (shift + push).limit_length(0.40)
				solved = BM.leg(hip, ft + shift, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
			if not fst.stepping and Vector2(shift.x, shift.z).length() > 0.03:
				# a planted foot is not moved more than a slide's worth: it steps out instead
				var fk6 := "L" if side < 0 else "R"
				world_foot_placer.forced[fk6] = maxf(world_foot_placer.forced[fk6], 0.09)
				shift = Vector3.ZERO
				solved = BM.leg(hip, ft, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
			ft += shift
			var same_ground := true
			if get_floor != null:
				var g_a: float = get_floor.call(fst.pos.x, fst.pos.z)
				var g_b: float = get_floor.call(fst.pos.x + shift.x, fst.pos.z + shift.z)
				same_ground = is_finite(g_a) and is_finite(g_b) and absf(g_a - g_b) < 0.03
			if not fst.stepping and same_ground and Vector2(shift.x, shift.z).length() > 0.002:
				# the pushed spot becomes where the foot is planted (the review's root fix): the placer then knows where
				# it stands, so the push is not redone every tick and the foot is not judged out of reach and re-stepped
				var pf_: Variant = world_foot_placer.feet["L" if side < 0 else "R"]
				pf_.planted += Vector3(shift.x, 0, shift.z)
				pf_.cur += Vector3(shift.x, 0, shift.z)
			if shift.length() > 0.002 and get_floor != null:
				# the pushed foot stands on the ground where it now is, not where it was (on a slope the two differ)
				var nfx := fx + shift.x
				var nfz := fz + shift.z
				var g_old: float = get_floor.call(fx, fz)
				var g_new: float = get_floor.call(nfx, nfz)
				var n_new: Vector3 = get_normal.call(nfx, nfz) if get_normal != null else fn
				if is_finite(g_old) and is_finite(g_new) and absf(g_new - floor_here) <= 0.36 and n_new.y >= 0.56:
					var dy := g_new - g_old
					fx = nfx; fz = nfz; fn = n_new; fgy += dy; plane_g += dy
					if absf(dy) > 0.002:
						ft.y += dy
						solved = BM.leg(hip, ft, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
		if not thalassa_exact and get_floor != null:
			# FIX (stress J7): Thalassa pitches the foot about the ankle, so at push-off the toe sinks ~2 cm into the
			# ground. Lift the ankle until the lowest sole point is on the floor (the foot pivots on its toe, heel up).
			# Sole points over ground more than 6 cm off the ankle's ground plane are over a step edge: the wall push handles those.
			# Raising the ankle tilts the shin and with it the foot, so settle in up to four passes.
			# FIX (stress J7 slide): a planted foot also pivots on its contact, not its ankle. Pitching about the ankle
			# swung the ball 5 cm backwards at every push-off; the ball (heel up) or the heel (toe up) is held where it
			# would be with the foot flat, and the ankle moves instead.
			var adj := Vector3.ZERO
			# ROOT (smoothness, jerk 77 000 m/s3 at every lift-off): planted, the ankle is offset so the foot pivots on its
			# ball (heel up); the offset ended the tick the swing began and the ankle jumped 2 cm and back. It is carried
			# into the swing and faded out over its first third
			if fst.stepping and not s.shore_is_airborne and pivot_carry[foot_k].length() > 1e-4:
				adj = pivot_carry[foot_k] * (1.0 - smoothstep(0.0, 0.35, fst.t))
				if adj.length() > 1e-4:
					solved = BM.leg(hip, ft + adj, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
			# (same at take-off into the air: the offset decays over ~0.1 s instead of ending the tick she leaves the ground)
			elif s.shore_is_airborne and pivot_carry[foot_k].length() > 1e-4:
				pivot_carry[foot_k] *= exp(-dt / 0.05)
				adj = pivot_carry[foot_k]
				solved = BM.leg(hip, ft + adj, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
			if fst.stepping or s.shore_is_airborne: plant_fresh[foot_k] = true
			var heel_l := Vector3(0, -0.026, -0.048)
			var ball_l := Vector3(0, 0.11, -0.048)
			var flat_ball := Vector2(fx + sfw.x * ball_l.y, fz + sfw.z * ball_l.y)
			var flat_heel := Vector2(fx + sfw.x * heel_l.y, fz + sfw.z * heel_l.y)
			# ROOT (skeleton: toes roll): a planted foot has a toe joint at the ball. Its toes bend back and lie on the
			# ground (_skeleton toe bend), so the rigid toe tip no longer props the ankle up: the ball is the lowest
			# point it rolls over and the heel lifts higher. A swinging foot keeps the whole sole (the toes clear steps).
			# ROOT (smoothness): the whole swing too. Rigid again from 30 % of the swing, the toe end propped the ankle up
			# over any rising ground until touch-down, where it bent again: the ankle dropped 2-4 cm in the landing tick
			var rolls: bool = not thalassa_exact     # (early swing too: the toes leave the ground last, bent; made rigid at lift-off they pushed the ankle up in one tick)
			# (airborne too: at take-off the toes stay bent as she leaves the ground; rigid again they would push the ankle up 5 cm in a tick)
			var pts: Array = SOLE_PTS_PLANTED + SOLE_PTS_TOE_BENT if rolls else SOLE_PTS
			# (in early swing the rigid toe end still counts where the ground under it rises above the ball's: a
			# tread or riser ahead, which bent toes can't lie on; stress B37)
			var rise_pts: Array = [SOLE_PTS[2], SOLE_PTS[5], SOLE_PTS[6]] if (rolls and fst.stepping) else []
			for _pass in 8:
				var lift := 0.0
				var g_ball := INF
				if not rise_pts.is_empty():
					var bq: Vector3 = solved.finMat * Vector3(0, 0.11, -0.048)
					g_ball = get_floor.call(bq.x, bq.z)
				for sp_ in pts + rise_pts:
					var q: Vector3 = solved.finMat * sp_
					var gq: float = get_floor.call(q.x, q.z)
					if sp_ in rise_pts and sp_.y > 0.13 and not _rises(gq, g_ball, q, plane_g, fn, fx, fz): continue
					# lifted if its ground continues the ankle's ground plane (the toe pitched into the same floor), or if it
					# is at most 6 cm under the ground there (in the air, or with the foothold rejected, the plane is the
					# body's ground, not the foot's). Anything else is a toe in a riser or wall face: the wall push moves it
					# out sideways (lifting would stand her on the step).
					var plane_y := plane_g - (fn.x * (q.x - fx) + fn.z * (q.z - fz)) / maxf(0.3, fn.y)
					if is_finite(gq) and (not is_finite(plane_g) or absf(gq - plane_y) < 0.06 or gq - q.y < 0.06): lift = maxf(lift, gq - q.y)
					# ROOT (stress B37 toe in the riser): a swinging foot clears the ground under its whole sole (a step
					# riser, a tread edge, the uphill side of a slope), not only under its ankle
					# (with a 2.5 cm margin ahead along the travel: the toe reaches a riser between ticks)
					elif is_finite(gq) and fst.stepping and gq - (fgy if is_finite(fgy) else floor_here) < 0.36: lift = maxf(lift, gq + 0.01 - q.y)
					if fst.stepping and is_finite(gq):
						var qa: Vector3 = q + sfw * 0.025
						var ga: float = get_floor.call(qa.x, qa.z)
						# ROOT (smoothness, ramps): only ground that rises above the plane the foot lies along (a riser, a tread).
						# Up a slope the ground 2.5 cm ahead is always higher: every sole point was lifted 2.4 cm + the margin the
						# tick the swing began, and came down again the tick it ended
						if is_finite(ga) and ga > gq and _rises(ga, ga, qa, plane_g, fn, fx, fz) and ga - (fgy if is_finite(fgy) else floor_here) < 0.36: lift = maxf(lift, ga + 0.01 - q.y)
				lift = minf(lift, 0.14 - adj.y)
				var hv := Vector2.ZERO
				if not fst.stepping and not s.shore_is_airborne:
					var hb_: Vector3 = solved.finMat * heel_l
					var bb_: Vector3 = solved.finMat * ball_l
					# ROOT (smoothness, ramps): which of the two is down is judged against the foot's ground, not in world height.
					# Heel up on a 30 deg ramp the foot is about level in the world: the pivot flipped between ball and heel
					# three times a stance, and the ankle jumped 16 mm each time
					var ball_low: bool = (bb_ - hb_).dot(fn) <= 0.0
					var anchor := flat_ball if ball_low else flat_heel
					var cur_c := Vector2(bb_.x, bb_.z) if ball_low else Vector2(hb_.x, hb_.z)
					# ROOT (smoothness): the contact stays where it touched down. The pivot was held where it would be with the
					# foot flat on its plant; landing pitched, the ankle was pulled there in the landing tick (3-20 mm)
					if _pass == 0 and plant_fresh[foot_k]:
						plant_off[foot_k] = (cur_c - anchor).limit_length(0.04) if fn.y < 0.985 else Vector2.ZERO     # (on a slope only: on level ground the flat-foot anchor is already where she touched down, and the held offset made an out-of-reach drag in the random run 5 mm worse)
						plant_fresh[foot_k] = false
					hv = (anchor + plant_off[foot_k] - cur_c).limit_length(0.08 - Vector2(adj.x, adj.z).length())
				if lift <= 0.001 and hv.length() < 0.001: break
				adj += Vector3(hv.x, maxf(0.0, lift), hv.y)
				solved = BM.leg(hip, ft + adj, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
			if fst.stepping and not s.shore_is_airborne:
				# ROOT (stress B12 step down at 120 Hz): the lift above only clears what the leg can deliver. Stepping
				# off a ledge the pelvis comes down (her centre crossed the edge) while the trailing foot is still over
				# the tread: the knee folds to its limit (132), the ankle can't rise any more (hip - 25 cm), the shin
				# lies level and the toe hangs 15 cm under it, through the tread's edge as the hip drags the foot off.
				# A swing foot that can't be lifted clear goes on ahead, along its way to its landing spot, as far as
				# clears it (the knee comes forward and up); only if that does clear it
				var ref_g: float = fgy if is_finite(fgy) else floor_here
				# (judged on the points the lift above judged: rolling, the toes are bent and the rigid toe end only
				# counts over rising ground; judged rigid it pushed the foot ahead 1 cm steps every early swing tick)
				var sunk := func(fm: Transform3D) -> float:
					var worst := 0.0
					var gb := INF
					if not rise_pts.is_empty():
						var bq: Vector3 = fm * Vector3(0, 0.11, -0.048)
						gb = get_floor.call(bq.x, bq.z)
					for sp_ in pts + rise_pts:
						var q: Vector3 = fm * sp_
						var gq: float = get_floor.call(q.x, q.z)
						if sp_ in rise_pts and sp_.y > 0.13 and not _rises(gq, gb, q, plane_g, fn, fx, fz): continue
						if is_finite(gq) and gq - ref_g < 0.36: worst = maxf(worst, gq - q.y)
					return worst
				if sunk.call(solved.finMat) > 0.005:
					var e0: Vector3 = solved.ik.eff
					var go := Vector3(fst.to.x - e0.x, 0, fst.to.z - e0.z)
					if go.length() > 0.01:
						go = go.normalized()
						for k in range(1, 9):
							var tr := BM.leg(hip, e0 + go * (k * 0.01), side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
							if sunk.call(tr.finMat) <= 0.001:
								solved = tr
								break
			# FIX (stress J6/J7): a planted foot the leg can no longer reach (the body climbed away from it) was
			# dragged; step it like a clamped one
			if not fst.stepping and is_finite(land_drop[foot_k]):
				# eased: the gap to where the foot rests closes by e^(-40 t), not at a fixed rate
				var rest_y: float = solved.ik.eff.y
				var hold: float = minf(rest_y + (land_drop[foot_k] - rest_y) * exp(-40.0 * dt), land_drop[foot_k] - 1.2 * dt)     # (at least 1.2 m/s: planted, it may hover only briefly)
				land_drop[foot_k] = hold if hold > rest_y + 0.0005 else -INF
				if hold > rest_y + 0.0005:
					adj.y += minf(hold - rest_y, 0.15)
					solved = BM.leg(hip, ft + adj, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
			var miss: float = solved.ik.eff.distance_to(ft + adj)
			if not fst.stepping and not s.shore_is_airborne: pivot_carry[foot_k] = adj
			var fk2 := "L" if side < 0 else "R"
			if not fst.stepping and miss > 0.03:
				world_foot_placer.forced[fk2] = maxf(world_foot_placer.forced[fk2], miss * (0.33 if (land_age[fk2] < 0.12 and miss <= HARD_MISS) else 1.0))
		last_ank[foot_k] = solved.ik.eff.y
		last_stepping[foot_k] = fst.stepping
		return {"ik": solved.ik, "finMat": solved.finMat, "finDir": solved.finDir}
	var leg_l: Dictionary = shore_leg.call(-1.0)
	var leg_r: Dictionary = shore_leg.call(1.0)

	var shore_arm := func(side: float) -> Dictionary:
		var sh := shoulder_l if side < 0 else shoulder_r
		var sw: Vector3 = loco.armSwingL if side < 0 else loco.armSwingR
		var walk_u := lerpf(-0.435 + sw.y * 0.65, -0.22 + sw.y * 0.45 + sin(total_time * 1.9 + side) * 0.012, wade_b)
		var run_u := -0.265 + sw.y * 0.55
		var walk_f := lerpf(0.048 + sw.z * 0.92, 0.14 + sw.z * 0.72, wade_b)
		var run_f := 0.165 + sw.z * 1.12
		var walk_l := side * (shoulder_half_w + lerpf(0.058, 0.125, wade_b)) + sw.x
		var run_l := side * (shoulder_half_w + 0.042) + sw.x * 1.15
		var target := chest_pos + (chest_right * lerpf(walk_l, run_l, rb) + (up * lerpf(walk_u, run_u, rb) + chest_fwd * lerpf(walk_f, run_f, rb)))
		var jf: float = jmp.elbowFlare
		var pole := sh + (chest_back * lerpf(lerpf(0.45, 0.72, rb), 0.56, jf) + (chest_right * (side * (lerpf(0.16, 0.26, wade_b) + jf * 0.34)) + up * lerpf(lerpf(-0.46, -0.34, wade_b), -0.30, jf)))
		if not thalassa_exact:
			# ROOT (Gary: arms "look like a dance" running): the hand was placed by an offset from the chest that grew
			# with the swing, so at the front of each swing the arm reached out nearly straight at shoulder height and
			# at the back the elbow stuck out sideways. Arms swing from the shoulder with the elbow held bent: the upper
			# arm pendulums fore and aft, the elbow bends more at the front of the swing than at the back, and the
			# forearm points forward and a little across the body. The hand target comes from those angles (forward
			# kinematics), so the two-bone solve returns exactly that arm. Wading keeps its pose.
			var ph := clampf(sw.z / 0.25, -1.0, 1.0)                                          # swing: +1 front, -1 back
			# (critique round 2: the arm must swing through neutral and clearly behind the trunk, in the sagittal
			# plane, mirrored; it swings about the trunk's own axis, not world vertical, or the run's lean puts every
			# position in front)
			var fl := ph * (lerpf(0.32, 0.65, rb) if ph > 0.0 else lerpf(0.40, 0.85, rb))       # shoulder flexion (rad)
			var abd := lerpf(0.06, 0.10, rb)                                                      # out from the side
			var elb := lerpf(lerpf(0.30, 0.50, ph * 0.5 + 0.5), lerpf(0.75, 1.50, ph * 0.5 + 0.5), rb)  # elbow flexion (rad): closes in front, opens well behind (Gary: looser)
			# in the air the jump's lift becomes the arms driving up and forward (still bent), reach and flare open them
			var lift_a := clampf(sw.y, -0.1, 0.45)
			fl = lerpf(fl, clampf(ph * 0.4 + lift_a * 1.6, -0.7, 1.0), air_b)
			elb = lerpf(elb, clampf(1.45 - lift_a * 0.4, 1.2, 1.5), air_b)
			abd = lerpf(abd, 0.12 + jf * 0.6 + absf(sw.x) * 0.8, air_b)
			var trunk_up := (raw_neck - waist_pos).normalized()
			var dn := -trunk_up
			var ua := (Basis(chest_right.normalized(), fl) * dn).normalized()                 # flexion swings it forward (right x down = fwd)
			ua = (Basis(chest_fwd.normalized(), -side * abd) * ua).normalized()                # abduction: out to her side (fwd x down = -right)
			var fwd_perp := (chest_fwd - ua * chest_fwd.dot(ua)).normalized()
			var across := -chest_right * side
			var bend_dir := (fwd_perp + across * lerpf(0.06, 0.14, rb) * maxf(0.0, ph)).normalized()
			bend_dir = (bend_dir - ua * bend_dir.dot(ua)).normalized()
			var fa := (ua * cos(elb) + bend_dir * sin(elb)).normalized()
			var elbow := sh + ua * upper_arm_len
			var fk_target := elbow + fa * forearm_len
			var fk_pole := elbow - bend_dir * 0.3 + chest_right * side * 0.05
			var w_fk := clampf(1.0 - wade_b, 0.0, 1.0)
			target = target.lerp(fk_target, w_fk)
			pole = pole.lerp(fk_pole, w_fk)
		return BM.two_bone(sh, target, pole, upper_arm_len, forearm_len, 0.96, 0.08, 138.0)
	var arm_l: Dictionary = shore_arm.call(-1.0)
	var arm_r: Dictionary = shore_arm.call(1.0)
	var hand := func(ik: Dictionary, side: float, lag: float) -> Transform3D:
		var fd := BM.nrm(ik.eff - ik.mid)
		var hy := BM.nrm(fd + chest_fwd * lag) if absf(lag) > 0.005 else fd
		var zb := BM.nrm(chest_right * (side * 0.85) + chest_back * 0.35)
		var xa := BM.nrm(hy.cross(zb))
		return BM.basis_xf(ik.eff, xa, hy, xa.cross(hy))
	var hand_l_mat: Transform3D = hand.call(arm_l, -1.0, jmp.wristLagL)
	var hand_r_mat: Transform3D = hand.call(arm_r, 1.0, jmp.wristLagR)
	var fore_l := BM.nrm(arm_l.eff - arm_l.mid)
	var torch_o: Vector3 = arm_l.mid.lerp(arm_l.eff, 0.72) + chest_back * 0.035
	var torch_x := BM.nrm(fore_l.cross(chest_back))
	var torch_mat := BM.basis_xf(torch_o, torch_x, fore_l, torch_x.cross(fore_l), 0.85, 0.85, 0.85)
	left_wrist_light_pos = torch_mat * Vector3(0, 0.072, 0)
	left_wrist_light_dir = fore_l
	var breath_scale := 1.0 + b_cen * 0.024 * b_amp
	var cay_b := BM.nrm(raw_neck - waist_pos)
	var cx_b := BM.nrm(cay_b.cross(chest_back))
	var cz := cx_b.cross(cay_b)
	var cx := BM.nrm(cx_b * cos(chest_roll) + cay_b * sin(chest_roll))
	var cay := BM.nrm(cz.cross(cx))
	var chest_mat := BM.basis_xf(chest_pos, cx, cay, cz, breath_scale, 1.0, breath_scale)
	var pay_b := BM.nrm(waist_pos - pelvis_pos)
	var px_b := BM.nrm(pay_b.cross(pelv_back))
	var pz := px_b.cross(pay_b)
	var px := BM.nrm(px_b * cos(total_proll) + pay_b * sin(total_proll))
	var pay := BM.nrm(pz.cross(px))
	var pelvis_mat := BM.basis_xf(pelvis_pos, px, pay, pz)
	var dip: float = jmp.headLookDip
	var gaze: Vector3 = BM.nrm(bo.gazeDirWorld + up * dip) if absf(dip) > 0.004 else bo.gazeDirWorld
	var head := solve_head(sdt, chest_pos, raw_neck, cx_b, cay_b, -cz, gaze,
		{"maxYaw": 0.96, "minPitch": -0.54, "maxPitch": 0.60, "neckPitchShare": 0.42, "extraRoll": bo.headTiltRad,
		"neckHalflife": 0.095 if bo.get("objectiveFast", false) else 0.24})
	return {
		"mode": "shore_wade" if wade_b > 0.12 else "shore_walk", "footCenter": ground,
		"neckPos": head.neckPos, "chestPos": chest_pos, "waistPos": waist_pos, "pelvisPos": pelvis_pos,
		"clavicleL": chest_pos.lerp(shoulder_l, 0.45), "clavicleR": chest_pos.lerp(shoulder_r, 0.45),
		"shoulderL": shoulder_l, "shoulderR": shoulder_r, "hipL": hip_l, "hipR": hip_r,
		"bodyRight": w_right, "bodyBack": body_back, "bodyAxisY": up,
		"armL": arm_l, "armR": arm_r, "legL": leg_l, "legR": leg_r,
		"chestMat": chest_mat, "pelvisMat": pelvis_mat, "headMat": head.headMat, "handLMat": hand_l_mat, "handRMat": hand_r_mat, "torchMat": torch_mat,
		"headMotion": {"pos": head.headPos, "fwd": head.headFwd, "neckYaw": head.neckYaw, "neckPitch": head.neckPitch},
		"locomotion": {"gaitMode": "wade" if wade_b > 0.12 else loco.gaitMode, "speed": loco.speed, "stepCount": loco.stepCount,
			"jumpStyle": jmp.style, "jumpCount": jmp.count},
	}

## ikBlendSwimAndWalkPose (rigid bone lengths: re-solves limbs on the blended anchors)
func blend_swim_walk(sp: Dictionary, wp: Dictionary, t_raw: float) -> Dictionary:
	var t := smoothstep(0.0, 1.0, clampf(t_raw, 0.0, 1.0))
	var pelvis_pos: Vector3 = sp.pelvisPos.lerp(wp.pelvisPos, t)
	var waist_pos: Vector3 = sp.waistPos.lerp(wp.waistPos, t)
	var chest_pos: Vector3 = sp.chestPos.lerp(wp.chestPos, t)
	var neck_pos: Vector3 = sp.neckPos.lerp(wp.neckPos, t)
	var shoulder_l: Vector3 = sp.shoulderL.lerp(wp.shoulderL, t)
	var shoulder_r: Vector3 = sp.shoulderR.lerp(wp.shoulderR, t)
	var hip_l: Vector3 = sp.hipL.lerp(wp.hipL, t)
	var hip_r: Vector3 = sp.hipR.lerp(wp.hipR, t)
	var axis_y := BM.nrm(neck_pos - pelvis_pos)
	var back := BM.nrm(sp.bodyBack.lerp(wp.bodyBack, t))
	var right := BM.nrm(axis_y.cross(back))
	var fwd := BM.nrm(right.cross(axis_y))
	if not thalassa_exact:
		fwd = -fwd    # FIX (stress J4/J3): Thalassa's right x axisY is the back, so its blend chest, pelvis and knees faced backwards
	var ortho_back := -fwd
	var cay := BM.nrm(neck_pos - waist_pos)
	var cx := BM.nrm(cay.cross(ortho_back))
	var cz := cx.cross(cay)
	var pay := BM.nrm(waist_pos - pelvis_pos)
	var px := BM.nrm(pay.cross(ortho_back))
	var pz := px.cross(pay)
	var arm := func(sh: Vector3, a_s: Dictionary, a_w: Dictionary) -> Dictionary:
		var tgt: Vector3 = a_s.eff.lerp(a_w.eff, t)
		var pole: Vector3 = sh + (a_s.mid - a_s.root).lerp(a_w.mid - a_w.root, t)
		return BM.two_bone(sh, tgt, pole, upper_arm_len, forearm_len, 0.96, 0.06, 138.0)
	var arm_l: Dictionary = arm.call(shoulder_l, sp.armL, wp.armL)
	var arm_r: Dictionary = arm.call(shoulder_r, sp.armR, wp.armR)
	var pd := -pay
	var pf := -pz
	var leg := func(hip: Vector3, l_s: Dictionary, l_w: Dictionary, side: float) -> Dictionary:
		var tgt: Vector3 = l_s.ik.eff.lerp(l_w.ik.eff, t)
		if not thalassa_exact and wp.has("footCenter"):
			# FIX (stress J6): the swim legs hang ~1.1 m below the eye, below the ground when she crouches or wades
			# out; the blend never puts an ankle under the ground the walk pose stands on
			tgt.y = maxf(tgt.y, wp.footCenter.y + 0.052)
		var dfs: Vector3 = l_s.get("finDir", pf)
		var dfw: Vector3 = l_w.get("finDir", pf)
		var bopts := {"softReach": 0.992, "softMargin": 0.04, "minFlexDeg": 6.0,
			"maxFlexDeg": 128.0, "kneeOutBias": 0.08, "groundBlend": t, "groundFwd": BM.nrm(dfs.lerp(dfw, t)), "groundUp": Vector3.UP}
		var solved := BM.leg(hip, tgt, side, pd, pf, thigh_len, shin_len, bopts)
		if not thalassa_exact and wp.has("footCenter"):
			# FIX (stress J6): the swim foot is pointed, so while blending to standing its toe dug into the ground
			for _pass in 3:
				var lowest := INF
				for sp_ in SOLE_PTS:
					lowest = minf(lowest, (solved.finMat * sp_).y)
				var lift: float = wp.footCenter.y - lowest
				if lift <= 0.001: break
				tgt.y += lift
				solved = BM.leg(hip, tgt, side, pd, pf, thigh_len, shin_len, bopts)
		return {"ik": solved.ik, "finMat": solved.finMat, "finDir": solved.finDir}
	var leg_l: Dictionary = leg.call(hip_l, sp.legL, wp.legL, -1.0)
	var leg_r: Dictionary = leg.call(hip_r, sp.legR, wp.legR, 1.0)
	var hb := func(ik: Dictionary, side: float) -> Transform3D:
		var fd := BM.nrm(ik.eff - ik.mid)
		var zb := BM.nrm(right * (side * 0.65) + ortho_back * 0.55)
		var xa := BM.nrm(fd.cross(zb))
		return BM.basis_xf(ik.eff, xa, fd, xa.cross(fd))
	var chest_b := Basis(cx, cay, cz)
	var pelvis_b := Basis(px, pay, pz)
	if not thalassa_exact:
		# FIX (stress J9 head, brain port): the blend rebuilt the chest and pelvis frames from the lerped joints, without
		# the walk pose's spine twist, chest roll and hip roll. With the brain those carry the curiosity twist and the
		# contrapposto, so the chest swung up to 0.1 rad in the one tick the blend handed over to the walk pose (gwb
		# 0.992). The frames now turn from the swim pose's to the walk pose's (equal to each at the ends).
		chest_b = Quaternion(_ortho(sp.chestMat.basis)).slerp(Quaternion(_ortho(wp.chestMat.basis)), t)
		pelvis_b = Quaternion(_ortho(sp.pelvisMat.basis)).slerp(Quaternion(_ortho(wp.pelvisMat.basis)), t)
	var head_pos: Vector3 = sp.headMat.origin.lerp(wp.headMat.origin, t)
	var hf := BM.nrm(sp.headMotion.fwd.lerp(wp.headMotion.fwd, t))
	var hx := BM.nrm(hf.cross(Vector3.UP))
	var hy := BM.nrm(hx.cross(hf))
	var out := wp.duplicate()
	out.merge({"mode": "swim_wade_blend", "neckPos": neck_pos, "chestPos": chest_pos, "waistPos": waist_pos, "pelvisPos": pelvis_pos,
		"clavicleL": chest_pos.lerp(shoulder_l, 0.45), "clavicleR": chest_pos.lerp(shoulder_r, 0.45),
		"shoulderL": shoulder_l, "shoulderR": shoulder_r, "hipL": hip_l, "hipR": hip_r,
		"bodyRight": right, "bodyBack": ortho_back, "bodyAxisY": axis_y, "armL": arm_l, "armR": arm_r, "legL": leg_l, "legR": leg_r,
		"chestMat": Transform3D(chest_b, chest_pos), "pelvisMat": Transform3D(pelvis_b, pelvis_pos),
		"headMat": BM.basis_xf(head_pos, hx, hy, -hf), "handLMat": hb.call(arm_l, -1.0), "handRMat": hb.call(arm_r, 1.0),
		"torchMat": sp.torchMat, "headMotion": {"pos": head_pos, "fwd": hf, "neckYaw": 0.0, "neckPitch": 0.0}}, true)
	return out
