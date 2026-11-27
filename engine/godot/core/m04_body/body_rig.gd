## M04 Body, core 0.1.0: GDScript port of Thalassa v20.19 core/ik-rig.js DiverBodyRig (free swim, shore walk/wade
## and the swim <-> walk blend from core/ik-poses-world.js). 1.38 m girl, NASA neutral-body-posture springs, soft
## joint limits, breaststroke + flutter kick, foot placement on land, anatomical head, no-clip limbs.
## Differences from the JS (each written down):
## - the brain is pluggable (quiet_brain.gd until character-brain.js is ported);
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

## true = reproduce Thalassa v20.19 exactly, bugs included (the golden test sets it). false = with the fixes the body
## stress test (tests/test_body_stress.gd) forced; each one is marked FIX and listed in CHANGELOG.md.
var thalassa_exact := false
var ground_follow := NAN
var noclip_off := {}
var _step_dt := 1.0 / 60.0
const NOCLIP_RATE := 3.0
const SWIM_ANKLE_RATE := 6.0
var swim_ankle_rel := {}
var swing_floor := {"L": NAN, "R": NAN}
const FOOT_R := 0.035       # foot half-width used for wall clearance
const NECK_LEN := 0.118      # chest to skull base, Thalassa's standing value
var stature_m := 1.38
var upper_arm_len := 0.245
var forearm_len := 0.228
var thigh_len := 0.345
var shin_len := 0.335
var shoulder_half_w := 0.132
var hip_half_w := 0.088

var body_yaw := 0.12
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
var brain = QuietBrain.new()
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
			if not hit.is_empty() and hit.dist < radius and hit.has("normal"):
				o += hit.normal * (radius - hit.dist)
				moved = true
		if q_floor != null:
			var fy: float = q_floor.call(o.x, o.z)
			if is_finite(fy) and o.y < fy + radius:
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

func solve_noclip_leg(hip: Vector3, raw_ankle: Vector3, side: float, pd: Vector3, pf: Vector3, surf, lo := {}) -> Dictionary:
	var at := push_clear(raw_ankle, 0.056, surf, 0.65)
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
			var off := prev + (want - prev).limit_length(NOCLIP_RATE * _step_dt)
			noclip_off[side] = off
			if off.distance_to(want) > 0.002:
				solved = BM.leg(hip, raw_ankle + off, side, pd, pf, thigh_len, shin_len, lo)
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
	_step_dt = clampf(dt, 0.0001, 0.05)
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
		if raw_pelv_y < min_pelv: want_lift = clampf(min_pelv - raw_pelv_y, 0.0, 0.42)
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
	var brain_swim: Dictionary = brain.update(dt, {
		"mode": "swim", "headPos": cam_anchor, "bodyFwd": chest_fwd_swim, "bodyRight": chest_x, "bodyUp": chest_axis_y,
		"visionFwd": fwd_look, "visionRight": right_look, "visionUp": head_up,
		"cameraFwd": sense.cameraFwd if (sense != null and sense.get("cameraFwd") != null) else fwd_look,
		"bodyBelly": body_belly, "swimAxisY": body_axis_y, "shoulderL": shoulder_l, "shoulderR": shoulder_r,
		"restHandWorldL": chest_pos + (body_right * -0.34 + body_belly * 0.40), "restHandWorldR": chest_pos + (body_right * 0.34 + body_belly * 0.40),
		"desiredLookDir": fwd_look, "speed": spd, "desSpeed": spd, "sprinting": s.sprinting, "btnPhase": bp, "yawRate": yaw_vel,
		"impactShake": impact_energy, "inCriticalTransition": crossing or s.shore_dive_arc_timer > 0.0,
		"objectiveFocus": {"label": "WATER ENTRY", "dir": fwd_look, "holdSec": 0.45} if crossing else null,
		"getFloorHeight": get_floor, "queryNearestSurface": query,
		"colliders": sense.get("colliders") if sense != null else null, "pois": sense.get("pois") if sense != null else null})

	var ubr_base := fposmod(arm_phase, TAU) / TAU
	if on_stroke_pull != null and swim_blend > 0.28 and prev_ubr < 0.48 and ubr_base >= 0.48:
		on_stroke_pull.call(clampf(swim_blend * (0.7 + sprint_blend * 0.35), 0.25, 1.0))
	prev_ubr = ubr_base
	var surf_env = {"floor_height": get_floor, "nearest_surface": query} if s.ground_walk_blend < 0.15 else null
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
			var rel := ankle - hip
			var prev_rel: Vector3 = swim_ankle_rel.get(side, rel)
			rel = prev_rel + (rel - prev_rel).limit_length(SWIM_ANKLE_RATE * dt)
			swim_ankle_rel[side] = rel
			ankle = hip + rel
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
		if surf_env != null:
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
		"extraRoll": brain_swim.headTiltRad, "neckHalflife": 0.095 if brain_swim.get("objectiveFocusActive", false) else 0.21})
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
		var walk := solve_walk_wade(dt, s, total_time, get_floor, get_normal, query, sense, on_shore_footstep, env.get("ray"))
		if gwb >= 0.992:
			swim_pose = walk
		else:
			swim_pose = blend_swim_walk(swim_pose, walk, gwb)
	return swim_pose

## ikSolveWorldWalkWadePose
func solve_walk_wade(dt: float, s, total_time: float, get_floor, get_normal, _query, sense = null, on_footstep = null, _ray = null) -> Dictionary:
	var sdt := clampf(dt, 0.0001, 0.05)
	var yaw: float = s.yaw
	var look_pitch := clampf(s.pitch, -1.12, 1.12)
	var wade_b := clampf(s.wade_blend, 0.0, 1.0)
	var floor_here: float
	if is_finite(s.shore_floor_y): floor_here = s.shore_floor_y
	elif get_floor != null: floor_here = get_floor.call(s.pos.x, s.pos.z)
	else: floor_here = s.pos.y - 1.24
	if not thalassa_exact:
		# FIX (stress J5): follow the floor the way the motor's eye does (18/s, trailing by at most its step_lag), so
		# the pelvis climbs a ledge with the eye instead of snapping 30 cm in one tick
		var lag: float = s.config.get("step_lag", 0.04)
		if is_nan(ground_follow) or absf(floor_here - ground_follow) > 1.0:
			ground_follow = floor_here
		else:
			ground_follow = lerpf(ground_follow, floor_here, BM.expk(18.0, sdt))
			ground_follow = clampf(ground_follow, floor_here - lag, floor_here + lag)
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
	if not thalassa_exact and _ray != null and get_floor != null:
		# FIX (stress J6/J7): give the foot placer eyes. A landing spot whose foot (heel to toe, plus FOOT_R) would
		# cross a steep surface, or whose ground is more than a step above or below her, is pulled back towards her.
		world_foot_placer.target_filter = func(lp: Vector3, to: Vector3, fyaw: float) -> Vector3:
			var ff := Vector3(-sin(fyaw), 0, -cos(fyaw))
			var spot := to
			for _i in 4:
				var y0: float = lp.y + 0.07
				var o := Vector3(lp.x, y0, lp.z)
				var bad := 0.0
				for tip in [spot + ff * (0.168 + FOOT_R), spot - ff * FOOT_R]:
					var t3 := Vector3(tip.x, y0, tip.z)
					var hit: Dictionary = _ray.call(o, t3)
					if not hit.is_empty() and absf(hit.normal.y) < 0.7:
						# a riser she can step up (ground beyond it within a step, walkable) is not a wall
						var gt: float = get_floor.call(tip.x, tip.z)
						var nt: Vector3 = get_normal.call(tip.x, tip.z) if get_normal != null else Vector3.UP
						if not (is_finite(gt) and gt - lp.y < 0.36 and nt.y >= 0.56):
							bad = maxf(bad, hit.position.distance_to(t3) + 0.01)
				var gy: float = get_floor.call(spot.x, spot.z)
				var gn: Vector3 = get_normal.call(spot.x, spot.z) if get_normal != null else Vector3.UP
				if is_finite(gy) and (absf(gy - lp.y) > 0.36 or gn.y < 0.56):
					bad = maxf(bad, 0.06)
				if bad <= 0.0: break
				var back := Vector3(lp.x - spot.x, 0, lp.z - spot.z)
				if back.length() < 0.02: break
				spot += back.normalized() * minf(bad, back.length())
			return spot
	var loco: Dictionary = world_foot_placer.update(sdt, {
		"localPos": ground, "velLocal": s.shore_vel_xz, "accelLocal": s.shore_accel_xz, "desiredVelLocal": s.shore_desired_vel_xz,
		"localYaw": yaw, "yawRate": s.shore_yaw_rate, "vesselId": "world_shore", "shipRoll": 0.0, "shipPitch": 0.0, "impactShake": 0.0,
		"isAirborne": s.shore_is_airborne, "jumpOffset": s.shore_jump_offset, "jumpVelY": s.shore_jump_vel_y,
		"jumpAnticipDip": s.shore_jump_anticip * 0.052, "jumpAnticip": s.shore_jump_anticip, "isDiveJump": s.shore_dive_arc_timer > 0.0,
		"justLanded": s.shore_just_landed, "landingImpact": s.shore_landing_impact, "crouchBlend": s.shore_crouch_blend,
		"brakingImpulse": s.shore_braking_impulse, "onFootstep": fs_cb})
	var up := Vector3.UP
	var w_fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	var w_right := Vector3(cos(yaw), 0, -sin(yaw))
	var body_back := -w_fwd
	var rb: float = loco.runBlend
	var look_fwd := BM.fwd(yaw, look_pitch)
	var look_up := BM.nrm(w_right.cross(look_fwd))
	var des_spd: float = s.shore_desired_vel_xz.length()
	var bo: Dictionary = brain.update(sdt, {
		"mode": "deck_walk", "headPos": Vector3(ground.x, ground.y + 1.32, ground.z), "bodyFwd": w_fwd, "bodyRight": w_right, "bodyUp": up,
		"visionFwd": look_fwd, "visionRight": w_right, "visionUp": look_up,
		"cameraFwd": sense.cameraFwd if (sense != null and sense.get("cameraFwd") != null) else look_fwd,
		"desiredLookDir": look_fwd, "speed": loco.speed, "desSpeed": des_spd, "yawRate": s.shore_yaw_rate,
		"isAirborne": s.shore_is_airborne, "jumpAnticip": s.shore_jump_anticip, "inCriticalTransition": s.shore_dive_arc_timer > 0.0,
		"objectiveFocus": {"label": "SHORE DIVE", "dir": look_fwd, "holdSec": 0.65} if s.shore_dive_arc_timer > 0.0 else null,
		"getFloorHeight": get_floor, "crouchBlend": s.shore_crouch_blend,
		"colliders": sense.get("colliders") if sense != null else null, "pois": sense.get("pois") if sense != null else null})
	var pelv_yaw: float = yaw + loco.pelvisYaw
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
		if not thalassa_exact and is_finite(fgy) and (absf(fgy - floor_here) > 0.36 or fn.y < 0.56):
			fn = s.shore_floor_normal
			fgy = floor_here     # FIX (stress J7): ground more than a step above or below her, or too steep to walk (Thalassa's 0.56), is a wall or a drop, not a foothold
		if not thalassa_exact and get_floor != null:
			# FIX (stress J5/J7): the swing foot took the floor height at its own position only, so crossing a step
			# edge snapped it 30 cm up or down in one tick. Swing from the start floor towards the landing floor
			# (raised early, never below the ground under the foot), and let it fall smoothly, never jump.
			var key := "L" if side < 0 else "R"
			var tgt_floor := fgy
			if fst.stepping:
				var f0: float = get_floor.call(fst.from.x, fst.from.z)
				var f1: float = get_floor.call(fst.to.x, fst.to.z)
				if is_finite(f0) and is_finite(f1) and f1 - f0 < 0.36:     # taller than a step is a wall: don't lift onto it
					var rise := smoothstep(0.05, 0.45, fst.t) if f1 > f0 else smoothstep(0.30, 0.90, fst.t)
					tgt_floor = maxf(fgy, lerpf(f0, f1, rise))
			var prev_f: float = swing_floor[key]
			if not fst.stepping or is_nan(prev_f) or tgt_floor >= prev_f or not is_finite(tgt_floor):
				swing_floor[key] = tgt_floor
			else:
				swing_floor[key] = maxf(tgt_floor, prev_f - 1.8 * dt)     # falls at most 1.8 m/s
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
		ft = hip + (pelv_right_base * cl_lat + (pelv_fwd * cl_fwd + up * up_d))
		if not thalassa_exact:
			# FIX (stress J7): a planted foot outside these reach limits was dragged along the ground (skating up to
			# 1.6 m/s in turns) until the foot placer's own, wider emergency distance fired. Ask it to step now.
			var excess := Vector2(ft.x - ft_raw.x, ft.z - ft_raw.z).length()
			world_foot_placer.forced["L" if side < 0 else "R"] = excess > 0.025 and not fst.stepping
		var rel_yaw := BM.wrap_pi(fst.yaw - pelv_yaw)
		var fwf := Vector3(-sin(fst.yaw), 0, -cos(fst.yaw))
		var spj := fwf - fn * fwf.dot(fn)
		var sfw := BM.nrm(spj) if spj.length() > 1e-4 else fwf
		var boot_fwd := BM.nrm(sfw + fn * clampf(fst.toePitch, -0.62, 0.32))
		var leg_opts := {
			"preserveDown": true, "desiredYawOffsetRad": rel_yaw, "maxHipExtDeg": lerpf(lerpf(24.0, 30.0, rb), 46.0, air_b),
			"maxHipFlexDeg": lerpf(110.0, 124.0, air_b), "maxAdductionDeg": 6.0, "maxAbductionDeg": lerpf(32.0, 38.0, air_b),
			"maxIntRotRad": 0.20, "maxExtRotRad": 0.48, "minFlexDeg": 5.0, "maxFlexDeg": 132.0, "softReach": 0.996, "softMargin": 0.012,
			"kneeOutBias": lerpf(0.07, 0.11, air_b), "kneeLiftBias": fst.heelKick * 0.24 + wade_b * 0.06,
			"minAnklePitchRad": -0.82, "maxAnklePitchRad": 0.48, "maxAnkleYawRad": 0.16, "maxAnkleRollRad": 0.20,
			"groundBlend": jmp.groundFootBlend, "groundFwd": boot_fwd, "groundUp": fn}
		var solved := BM.leg(hip, ft, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
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
						var nh: Vector3 = hit.normal; nh.y = 0.0
						if nh.length() < 1e-3: continue
						nh = nh.normalized()
						var pv: Vector3 = nh * maxf(0.0, (hit.position - tip).dot(nh))
						if pv.length() > push.length(): push = pv
				# the knee too: walking into a steep rock face the shin leans into it (knee radius 0.04)
				var kd: Vector3 = (solved.ik.mid - hip).normalized()
				for ktip in [solved.ik.mid + kd * 0.05, solved.ik.mid + pelv_fwd * 0.05]:
					var kh: Dictionary = _ray.call(hip, ktip)
					if not kh.is_empty() and absf(kh.normal.y) < 0.9:
						var knh: Vector3 = kh.normal; knh.y = 0.0
						if knh.length() > 1e-3:
							knh = knh.normalized()
							var kpv: Vector3 = knh * maxf(0.0, (kh.position - ktip).dot(knh)) / maxf(0.3, knh.dot(kh.normal))
							if kpv.length() > push.length(): push = kpv
				if push.length() < 0.002: break
				shift = (shift + push).limit_length(0.40)
				solved = BM.leg(hip, ft + shift, side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
			ft += shift
		if not thalassa_exact and get_floor != null:
			# FIX (stress J7): Thalassa pitches the foot about the ankle, so at push-off the toe sinks ~2 cm into the
			# ground. Lift the ankle until the lowest sole point is on the floor (the foot pivots on its toe, heel up).
			# Sole points over ground more than 6 cm off the ankle's ground plane are over a step edge: the wall push handles those.
			# Raising the ankle tilts the shin and with it the foot, so settle in up to three passes.
			var total_lift := 0.0
			for _pass in 4:
				var lift := 0.0
				for fy_ in [0.0, 0.08, 0.16]:
					var q: Vector3 = solved.finMat * Vector3(0, fy_, -0.046)
					var gq: float = get_floor.call(q.x, q.z)
					var plane_y := fgy - (fn.x * (q.x - fx) + fn.z * (q.z - fz)) / maxf(0.3, fn.y)
					if is_finite(gq) and (not is_finite(fgy) or absf(gq - plane_y) < 0.06): lift = maxf(lift, gq - q.y)
				lift = minf(lift, 0.14 - total_lift)
				if lift <= 0.001: break
				total_lift += lift
				solved = BM.leg(hip, ft + Vector3(0, total_lift, 0), side, Vector3.DOWN, pelv_fwd, thigh_len, shin_len, leg_opts)
			# FIX (stress J6/J7): a planted foot the leg can no longer reach (the body climbed away from it) was
			# dragged; step it like a clamped one
			if not fst.stepping and solved.ik.eff.distance_to(ft + Vector3(0, total_lift, 0)) > 0.03:
				world_foot_placer.forced["L" if side < 0 else "R"] = true
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
		"neckHalflife": 0.095 if bo.get("objectiveFocusActive", false) else 0.24})
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
				for fy_ in [0.0, 0.08, 0.16]:
					lowest = minf(lowest, (solved.finMat * Vector3(0, fy_, -0.046)).y)
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
	var head_pos: Vector3 = sp.headMat.origin.lerp(wp.headMat.origin, t)
	var hf := BM.nrm(sp.headMotion.fwd.lerp(wp.headMotion.fwd, t))
	var hx := BM.nrm(hf.cross(Vector3.UP))
	var hy := BM.nrm(hx.cross(hf))
	var out := wp.duplicate()
	out.merge({"mode": "swim_wade_blend", "neckPos": neck_pos, "chestPos": chest_pos, "waistPos": waist_pos, "pelvisPos": pelvis_pos,
		"clavicleL": chest_pos.lerp(shoulder_l, 0.45), "clavicleR": chest_pos.lerp(shoulder_r, 0.45),
		"shoulderL": shoulder_l, "shoulderR": shoulder_r, "hipL": hip_l, "hipR": hip_r,
		"bodyRight": right, "bodyBack": ortho_back, "bodyAxisY": axis_y, "armL": arm_l, "armR": arm_r, "legL": leg_l, "legR": leg_r,
		"chestMat": BM.basis_xf(chest_pos, cx, cay, cz), "pelvisMat": BM.basis_xf(pelvis_pos, px, pay, pz),
		"headMat": BM.basis_xf(head_pos, hx, hy, -hf), "handLMat": hb.call(arm_l, -1.0), "handRMat": hb.call(arm_r, 1.0),
		"torchMat": sp.torchMat, "headMotion": {"pos": head_pos, "fwd": hf, "neckYaw": 0.0, "neckPitch": 0.0}}, true)
	return out
