## M04 Body, core 0.1.0: GDScript port of Thalassa v20.19 core/procedural-locomotion.js BalanceFootPlacer
## (predictSpringTrajectory included). Planted feet stay locked, alternating capture steps, gravity CoM bounce,
## 5-phase procedural jumps. Shore walking uses it in world space (vessel id "world_shore").
## The jump fields the JS returned with toFixed(3) are rounded the same way here.
extends RefCounted

const BM := preload("res://core/m04_body/body_math.gd")

var config := {
	"gravity": 9.81, "stanceHalfWidth": 0.086, "ankleHeight": 0.052, "hipHeightStand": 0.726,
	"baseTriggerDist": 0.185, "maxTriggerDist": 0.295, "maxReachWalk": 0.285, "maxReachRun": 0.375,
	"emergencyTrailDist": 0.44, "turnTriggerRad": 0.48, "walkStepDur": 0.38, "runStepDur": 0.285,
	"doubleSupportGap": 0.015, "walkStepHeight": 0.040, "runStepHeight": 0.098,
}

class Foot:
	var planted := Vector3(0, -0.85, 0)
	var from := Vector3(0, -0.85, 0)
	var to := Vector3(0, -0.85, 0)
	var cur := Vector3(0, -0.85, 0)
	var yaw := 0.0
	var from_yaw := 0.0
	var to_yaw := 0.0
	var stepping := false
	var t := 1.0
	var dur := 0.32
	var height := 0.036
	var toe_pitch := 0.0
	var heel_kick := 0.0

var initialized := false
var last_vessel_id = null
var feet := {"L": Foot.new(), "R": Foot.new()}
var last_stepped := "R"
var step_count := 0
var support_cooldown := 0.0
var com_y := 0.0
var com_vel_y := 0.0
var run_blend := 0.0
var pelvis_offset_spring = BM.CritSpring3D.new()
var pelvis_yaw_spring = BM.CritSpring1D.new()
var pelvis_roll_spring = BM.CritSpring1D.new()
var spine_lean_fwd_spring = BM.CritSpring1D.new()
var spine_lean_lat_spring = BM.CritSpring1D.new()
var spine_twist_spring = BM.CritSpring1D.new()
var head_yaw_spring = BM.CritSpring1D.new()
var com_shift_lat_spring = BM.CritSpring1D.new()
var arm_swing_spring_l = BM.CritSpring3D.new()
var arm_swing_spring_r = BM.CritSpring3D.new()
var last_gait_mode := "idle"
var stumble_energy := 0.0
var jump := {
	"wasAirborne": false, "airTime": 0.0, "peakVelY": 2.95, "count": 0, "lastLeadSide": 1, "leadSide": -1,
	"style": "standing_spring", "landStyle": "standing_spring", "landLeadSide": -1, "landRecovery": 0.0, "landImpact": 0.0,
	"varTuck": 1.0, "varSplit": 1.0, "varArm": 1.0, "varTwist": 0.0, "varReach": 1.0, "varPhase": 0.0,
	"airBlend": 0.0, "groundFootBlend": 1.0, "elbowFlare": 0.0, "wristLagL": 0.0, "wristLagR": 0.0, "headLookDip": 0.0,
	"launchVelFwd": 0.0, "launchVelRight": 0.0,
}

func _init(cfg := {}) -> void:
	config.merge(cfg, true)

static func trajectory(pos: Vector2, v: Vector2, dv: Vector2, halflife := 0.14, horizons := [0.20, 0.40, 0.60]) -> Array:
	var out := []
	var y := 4.0 * BM.LN2 / maxf(1e-4, halflife)
	for t in horizons:
		var e := exp(-y * t)
		var p := Vector2.ZERO
		var vt := Vector2.ZERO
		for k in 2:
			var dv0: float = v[k] - dv[k]
			p[k] = pos[k] + dv[k] * t + (dv0 / y) * (2.0 - e * (2.0 + y * t))
			vt[k] = dv[k] + dv0 * (1.0 + y * t) * e
		out.append({"t": t, "pos": p, "vel": vt})
	return out

func reset(lp: Vector3, yaw: float, vessel_id = null) -> void:
	var rx := cos(yaw); var rz := -sin(yaw)
	var fx := -sin(yaw); var fz := -cos(yaw)
	var hw: float = config.stanceHalfWidth
	var pts := {"L": Vector3(lp.x - rx * hw + fx * 0.012, lp.y, lp.z - rz * hw + fz * 0.012),
		"R": Vector3(lp.x + rx * hw - fx * 0.012, lp.y, lp.z + rz * hw - fz * 0.012)}
	for k in ["L", "R"]:
		var f: Foot = feet[k]
		f.planted = pts[k]; f.from = pts[k]; f.to = pts[k]; f.cur = pts[k]
		f.yaw = yaw; f.from_yaw = yaw; f.to_yaw = yaw
		f.stepping = false; f.t = 1.0; f.toe_pitch = 0.0; f.heel_kick = 0.0
	com_y = 0.0; com_vel_y = 0.0; run_blend = 0.0
	pelvis_offset_spring.reset(); pelvis_yaw_spring.reset(); pelvis_roll_spring.reset()
	spine_lean_fwd_spring.reset(); spine_lean_lat_spring.reset(); spine_twist_spring.reset()
	head_yaw_spring.reset(yaw); com_shift_lat_spring.reset()
	arm_swing_spring_l.reset(); arm_swing_spring_r.reset()
	support_cooldown = 0.0; stumble_energy = 0.0
	jump.wasAirborne = false; jump.airTime = 0.0; jump.landRecovery = 0.0; jump.landImpact = 0.0
	jump.airBlend = 0.0; jump.groundFootBlend = 1.0; jump.elbowFlare = 0.0
	jump.wristLagL = 0.0; jump.wristLagR = 0.0; jump.headLookDip = 0.0
	initialized = true
	last_vessel_id = vessel_id

func apply_deck_impulse(ax: float, az: float, intensity := 0.4) -> void:
	stumble_energy = clampf(stumble_energy + intensity, 0.0, 1.2)
	spine_lean_lat_spring.impulse(clampf(-ax * 0.14, -1.2, 1.2))
	spine_lean_fwd_spring.impulse(clampf(-az * 0.14, -1.2, 1.2))
	com_vel_y -= 0.24 * intensity

static func _r3(x: float) -> float:
	return roundf(x * 1000.0) / 1000.0

static func _frac(v: float) -> float:
	return v - floorf(v)

## state keys (JS names): localPos (Vector3), velLocal, accelLocal, desiredVelLocal (Vector2 xz), localYaw, yawRate,
## vesselId, shipRoll, shipPitch, impactShake, isAirborne, jumpOffset, jumpVelY, jumpAnticipDip, jumpAnticip,
## isDiveJump, justLanded, landingImpact, crouchBlend, brakingImpulse, onFootstep (Callable or null)
func update(dt: float, s: Dictionary) -> Dictionary:
	var sdt := clampf(dt, 0.0001, 0.05)
	var lp: Vector3 = s.localPos
	var yaw: float = s.get("localYaw", 0.0)
	var vl: Vector2 = s.get("velLocal", Vector2.ZERO)
	var al: Vector2 = s.get("accelLocal", Vector2.ZERO)
	var dvl: Vector2 = s.get("desiredVelLocal", vl)
	var vx := vl.x; var vz := vl.y
	var ax := al.x; var az := al.y
	var dvx := dvl.x; var dvz := dvl.y
	var speed := Vector2(vx, vz).length()
	var des_speed := Vector2(dvx, dvz).length()
	var speed_norm := clampf(speed / 2.35, 0.0, 1.0)
	var is_air: bool = s.get("isAirborne", false)
	var jump_offset: float = s.get("jumpOffset", 0.0)
	var jump_vel_y: float = s.get("jumpVelY", 0.0)
	var anticip_dip: float = s.get("jumpAnticipDip", 0.0)
	var jump_anticip := clampf(s.get("jumpAnticip", anticip_dip / 0.055), 0.0, 1.0)
	var is_dive: bool = s.get("isDiveJump", false)
	var just_landed: bool = s.get("justLanded", false)
	var landing_impact: float = s.get("landingImpact", 0.0)
	var crouch := clampf(s.get("crouchBlend", 0.0), 0.0, 1.0)
	var braking := clampf(s.get("brakingImpulse", 0.0), 0.0, 1.0)
	var on_footstep = s.get("onFootstep", null)
	var yaw_rate: float = s.get("yawRate", 0.0)

	var target_run := smoothstep(1.52, 2.15, speed) * (1.0 - crouch)
	run_blend = lerpf(run_blend, target_run, BM.expk(6.5, sdt))
	var rb := run_blend

	var mfx: float = (feet.L.cur.x + feet.R.cur.x) * 0.5
	var mfz: float = (feet.L.cur.z + feet.R.cur.z) * 0.5
	if not initialized or last_vessel_id != s.get("vesselId") or Vector2(lp.x - mfx, lp.z - mfz).length() > 0.72:
		reset(lp, yaw, s.get("vesselId"))

	if support_cooldown > 0.0: support_cooldown = maxf(0.0, support_cooldown - sdt)
	stumble_energy *= exp(-3.0 * sdt)
	var shake: float = s.get("impactShake", 0.0)
	if shake > 0.22:
		apply_deck_impulse(0.0, -1.2 * shake, shake * 0.28)

	var fwd_x := -sin(yaw); var fwd_z := -cos(yaw)
	var rgt_x := cos(yaw); var rgt_z := -sin(yaw)
	var v_fwd := vx * fwd_x + vz * fwd_z
	var v_right := vx * rgt_x + vz * rgt_z
	var a_fwd := ax * fwd_x + az * fwd_z
	var a_right := ax * rgt_x + az * rgt_z

	var gait := ""
	if is_air: gait = "jump"
	elif crouch > 0.45: gait = "crouch_walk" if speed > 0.12 else "crouch_idle"
	elif rb > 0.45: gait = "sprint"
	elif speed > 0.12: gait = "backpedal" if v_fwd < -0.18 else ("strafe" if absf(v_right) > absf(v_fwd) * 1.15 else "walk")
	else: gait = "turn_in_place" if absf(yaw_rate) > 0.30 else "idle"
	last_gait_mode = gait

	var walk_dur := lerpf(config.walkStepDur + 0.04, config.walkStepDur - 0.015, clampf(speed / 1.35, 0.0, 1.0))
	var planned := lerpf(walk_dur, config.runStepDur, rb)
	var traj := trajectory(Vector2(lp.x, lp.z), Vector2(vx, vz), Vector2(dvx, dvz), 0.14, [planned * 0.50, planned, planned * 1.5])

	var ship_roll: float = s.get("shipRoll", 0.0)
	var ship_pitch: float = s.get("shipPitch", 0.0)
	var max_reach := lerpf(config.maxReachWalk, config.maxReachRun, rb)
	var base_hw := lerpf(config.stanceHalfWidth, 0.064, clampf(absf(v_fwd) / 1.35, 0.0, 1.0)) + crouch * 0.032
	var hw := base_hw + clampf(absf(v_right) * 0.022 + absf(ship_roll) * 0.035, 0.0, 0.034)

	var target_at := func(side: String, rem := 0.0) -> Vector3:
		var sg := -1.0 if side == "L" else 1.0
		var idle_stag := (1.0 - clampf(speed / 0.30, 0.0, 1.0)) * (-sg * 0.010)
		var evx := lerpf(vx, dvx, 0.35)
		var evz := lerpf(vz, dvz, 0.35)
		var ppx := lp.x + evx * rem
		var ppz := lp.z + evz * rem
		var lx := evx * (planned * 0.51) + rgt_x * (-ship_roll * 0.06) + fwd_x * (ship_pitch * 0.04)
		var lz := evz * (planned * 0.51) + rgt_z * (-ship_roll * 0.06) + fwd_z * (ship_pitch * 0.04)
		var ll := Vector2(lx, lz).length()
		if ll > max_reach and ll > 1e-4:
			lx = lx / ll * max_reach; lz = lz / ll * max_reach
		return Vector3(ppx + lx + rgt_x * (sg * hw) + fwd_x * idle_stag, lp.y, ppz + lz + rgt_z * (sg * hw) + fwd_z * idle_stag)

	var ideal_l: Vector3 = target_at.call("L", 0.0)
	var ideal_r: Vector3 = target_at.call("R", 0.0)

	var advance := func(key: String) -> void:
		var f: Foot = feet[key]
		if not f.stepping:
			f.planted.y = lp.y
			f.cur = f.planted
			f.heel_kick = lerpf(f.heel_kick, 0.0, BM.expk(14.0, sdt))
			var trail_fwd := (f.planted.x - lp.x) * fwd_x + (f.planted.z - lp.z) * fwd_z
			var late_peel := clampf((trail_fwd + 0.09) * 0.90, -0.26, 0.0) if (speed > 0.18 and trail_fwd < -0.09) else 0.0
			f.toe_pitch = lerpf(f.toe_pitch, late_peel, BM.expk(11.0, sdt))
			return
		var rem_t := maxf(0.0, (1.0 - f.t) * f.dur)
		if f.t < 0.80:
			var tg: Vector3 = target_at.call(key, rem_t)
			var rk := BM.expk(16.0, sdt)
			f.to.x = lerpf(f.to.x, tg.x, rk)
			f.to.y = lp.y
			f.to.z = lerpf(f.to.z, tg.z, rk)
			f.to_yaw = BM.wrap_pi(f.to_yaw + BM.wrap_pi(yaw - f.to_yaw) * rk)
		else:
			f.to.y = lp.y
		f.t = minf(1.0, f.t + sdt / maxf(0.18, f.dur))
		var u := f.t
		var uh := u * u * u * (u * (u * 6.0 - 15.0) + 10.0)
		var usk := pow(u, lerpf(0.86, 0.74, rb))
		var sl := sin(PI * usk)
		var lift := sl * sl * f.height
		var hk := rb * sin(PI * clampf(u / 0.72, 0.0, 1.0)) * (1.0 - smoothstep(0.55, 0.92, u))
		f.heel_kick = hk
		var kick_back := -hk * 0.068
		var ss := -1.0 if key == "L" else 1.0
		var clear_lat := sl * 0.010 * ss
		f.cur = Vector3(lerpf(f.from.x, f.to.x, uh) + rgt_x * clear_lat + fwd_x * kick_back,
			lerpf(f.from.y, f.to.y, uh) + lift,
			lerpf(f.from.z, f.to.z, uh) + rgt_z * clear_lat + fwd_z * kick_back)
		f.yaw = BM.wrap_pi(f.from_yaw + BM.wrap_pi(f.to_yaw - f.from_yaw) * uh)
		var land_dorsi := lerpf(0.18, 0.08, rb)
		var swing_ankle: float
		if u < 0.44:
			swing_ankle = lerpf(-0.22 - rb * 0.12, 0.0, smoothstep(0.0, 0.44, u))
		else:
			swing_ankle = lerpf(0.0, land_dorsi, smoothstep(0.44, 0.88, u)) * (1.0 - smoothstep(0.88, 1.0, u) * 0.50)
		f.toe_pitch = swing_ankle * (0.28 + 0.72 * clampf(speed / 1.3, 0.0, 1.0))
		if f.t >= 1.0:
			f.stepping = false
			f.planted = Vector3(f.to.x, lp.y, f.to.z)
			f.cur = f.planted
			f.yaw = f.to_yaw
			f.heel_kick = 0.0
			last_stepped = key
			step_count += 1
			support_cooldown = lerpf(config.doubleSupportGap, 0.0, clampf(rb * 1.4, 0.0, 1.0))
			var land_vel := -lerpf(0.10, 0.36, rb) * clampf(speed / 1.2, 0.25, 1.05) * (1.0 - crouch * 0.45)
			com_vel_y = minf(com_vel_y, land_vel)
			if on_footstep != null and not is_air:
				on_footstep.call({"foot": key, "pos": f.planted, "speed": speed, "runBlend": rb, "crouchBlend": crouch, "isLanding": false})

	var j := jump
	if is_air and not j.wasAirborne:
		j.count += 1
		j.airTime = 0.0
		j.peakVelY = maxf(1.8, absf(jump_vel_y) if absf(jump_vel_y) > 0.0 else 2.95)
		j.launchVelFwd = v_fwd
		j.launchVelRight = v_right
		var seed: float = j.count * 1.61803398875 + absf(lp.x * 0.37 + lp.z * 0.53)
		var u1 := _frac(seed * 1.0 + 0.13)
		var u2 := _frac(seed * 1.73205 + 0.41)
		var u3 := _frac(seed * 2.23606 + 0.79)
		var u4 := _frac(seed * 2.64575 + 0.27)
		var u5 := _frac(seed * 3.16227 + 0.63)
		j.varTuck = lerpf(0.84, 1.18, u1)
		j.varSplit = lerpf(0.82, 1.20, u2)
		j.varArm = lerpf(0.85, 1.22, u3)
		j.varTwist = lerpf(-1.0, 1.0, u4)
		j.varReach = lerpf(0.88, 1.15, u5)
		j.varPhase = u2 * TAU
		if speed > 0.30:
			var fl: float = (feet.L.cur.x - lp.x) * fwd_x + (feet.L.cur.z - lp.z) * fwd_z
			var fr: float = (feet.R.cur.x - lp.x) * fwd_x + (feet.R.cur.z - lp.z) * fwd_z
			if feet.L.stepping and not feet.R.stepping: j.leadSide = -1
			elif feet.R.stepping and not feet.L.stepping: j.leadSide = 1
			elif absf(v_right) > absf(v_fwd) * 1.15: j.leadSide = 1 if v_right >= 0.0 else -1
			else: j.leadSide = -1 if fl >= fr else 1
		else:
			j.leadSide = j.lastLeadSide if (j.count % 5 == 0) else -j.lastLeadSide
		j.lastLeadSide = j.leadSide
		if is_dive: j.style = "shore_dive"
		elif speed < 0.35: j.style = ["standing_spring", "standing_tuck", "standing_skip"][(j.count - 1) % 3]
		elif v_fwd < -0.32: j.style = "back_hop"
		elif absf(v_right) > absf(v_fwd) * 1.12: j.style = "side_hop"
		elif rb >= 0.45: j.style = "hurdle_vault" if j.count % 2 == 0 else "broad_bound"
		else: j.style = "skip_bound" if j.count % 2 == 0 else "stride_leap"
		j.landRecovery = 0.0
	j.wasAirborne = is_air
	j.airBlend = lerpf(j.airBlend, 1.0 if is_air else 0.0, BM.expk(14.0 if is_air else 10.0, sdt))
	if j.landRecovery > 0.0:
		j.landRecovery = maxf(0.0, j.landRecovery - sdt * 2.65)

	var air_launch := 0.0; var air_apex := 0.0; var air_desc := 0.0; var air_drift := 0.0
	if is_air:
		j.airTime += sdt
		var vn := clampf(jump_vel_y / maxf(1.8, j.peakVelY), -1.35, 1.15)
		air_launch = exp(-j.airTime * 11.5) * smoothstep(-0.1, 0.45, vn)
		air_apex = exp(-pow(jump_vel_y / 1.48, 2))
		air_desc = smoothstep(0.32, -2.05, jump_vel_y)
		air_drift = sin(j.airTime * 5.0 + j.varPhase)
		var st: String = j.style
		var dive := st == "shore_dive"
		var bound := st in ["broad_bound", "hurdle_vault", "stride_leap", "skip_bound"]
		var side_h := st == "side_hop"
		var back := st == "back_hop"
		var tuck := st == "standing_tuck"
		var skip := st == "standing_skip"
		var side_dir := 1.0 if j.launchVelRight >= 0.0 else -1.0
		var want_gf := 0.14 if dive else lerpf(0.24, 0.94, air_desc)
		j.groundFootBlend = lerpf(j.groundFootBlend, want_gf, BM.expk(11.0, sdt))
		for pair in [["L", -1.0], ["R", 1.0]]:
			var f: Foot = feet[pair[0]]
			var sg: float = pair[1]
			f.stepping = false
			f.t = 1.0
			var lead: bool = sg == j.leadSide
			var flift := 0.08; var ffwd := 0.0; var flat := sg * (hw + 0.016)
			var toe := -0.28; var heel := 0.35; var fyaw := yaw
			if dive:
				var flut := sin(j.airTime * 10.5 + (0.0 if lead else PI)) * 0.04
				flift = (0.24 if lead else 0.20) + flut
				ffwd = (-0.22 if lead else -0.30) * j.varSplit
				flat = sg * (hw * 0.88)
				toe = -0.62; heel = 0.18
			elif bound:
				var hurdle := st == "hurdle_vault"
				var skb := st == "skip_bound"
				var stride: float = (1.0 if (st == "broad_bound" or hurdle) else 0.78) * j.varSplit
				if lead:
					var pl: float = (0.26 if hurdle else (0.21 if skb else 0.22)) * j.varTuck
					var pf: float = (0.24 if hurdle else 0.21) * stride
					flift = lerpf(pl * (0.72 + 0.28 * air_apex), 0.022, air_desc) + air_launch * 0.03
					ffwd = lerpf(pf, 0.115 * j.varReach, air_desc)
					flat = sg * (hw + 0.012 + (0.014 if skb else 0.0))
					toe = lerpf(-0.34, 0.14, air_desc)
					heel = lerpf(0.55, 0.10, air_desc)
				else:
					var tpl: float = (0.18 if skb else 0.15) * j.varTuck
					var tb: float = (-0.27 if st == "broad_bound" else -0.22) * stride
					flift = lerpf(lerpf(tpl, 0.012, air_launch), 0.052, air_desc)
					ffwd = lerpf(lerpf(tb, -0.17, air_launch), -0.075 * j.varReach, air_desc)
					flat = sg * (hw + 0.018)
					toe = lerpf(lerpf(-0.38, -0.58, air_launch), 0.02, air_desc)
					heel = lerpf(lerpf(0.82, 0.24, air_launch), 0.22, air_desc)
			elif side_h:
				if lead:
					flift = lerpf(0.18 * j.varTuck, 0.024, air_desc)
					ffwd = lerpf(0.05, 0.02, air_desc)
					flat = sg * (hw + 0.055 * j.varSplit) + side_dir * 0.045 * (1.0 - air_desc * 0.45)
					toe = lerpf(-0.30, 0.08, air_desc)
					heel = lerpf(0.45, 0.12, air_desc)
					fyaw = BM.wrap_pi(yaw - side_dir * 0.16)
				else:
					flift = lerpf(lerpf(0.21 * j.varTuck, 0.02, air_launch), 0.055, air_desc)
					ffwd = lerpf(-0.06, -0.02, air_desc)
					flat = sg * (hw - 0.012) - side_dir * 0.02
					toe = lerpf(-0.46, 0.02, air_desc)
					heel = lerpf(0.68, 0.18, air_desc)
			elif back:
				flift = lerpf((0.19 if lead else 0.13) * j.varTuck, 0.032 if lead else 0.020, air_desc)
				ffwd = lerpf(0.12 if lead else 0.04, 0.05 if lead else -0.08, air_desc) * j.varSplit
				flat = sg * (hw + 0.024)
				toe = lerpf(-0.26, 0.12, air_desc)
				heel = lerpf(0.36, 0.10, air_desc)
			else:
				var tuck_amp: float = (0.24 if tuck else (0.20 if skip else 0.15)) * j.varTuck
				var split_amp: float = (0.13 if skip else (0.06 if tuck else 0.08)) * j.varSplit
				if lead:
					flift = lerpf(tuck_amp * (0.78 + 0.22 * air_apex), 0.022, air_desc) + air_drift * 0.012
					ffwd = lerpf(split_amp, 0.055 * j.varReach, air_desc)
					flat = sg * (hw + (0.026 if tuck else 0.015))
					toe = lerpf(-0.44 if tuck else -0.34, 0.10, air_desc)
					heel = lerpf(0.78 if tuck else 0.52, 0.10, air_desc)
					fyaw = BM.wrap_pi(yaw + sg * (-0.10 if skip else -0.05))
				else:
					var trl: float = (0.21 if tuck else (0.12 if skip else 0.11)) * j.varTuck
					flift = lerpf(lerpf(trl, 0.008, air_launch), 0.048, air_desc) - air_drift * 0.010
					ffwd = lerpf(lerpf(-split_amp * 1.08, -0.04, air_launch), -0.048 * j.varReach, air_desc)
					flat = sg * (hw + (0.024 if tuck else 0.012))
					toe = lerpf(lerpf(-0.40, -0.54, air_launch), 0.04, air_desc)
					heel = lerpf(lerpf(0.72 if tuck else 0.58, 0.20, air_launch), 0.18, air_desc)
			var tgt := Vector3(lp.x + rgt_x * flat + fwd_x * ffwd, lp.y + jump_offset + flift, lp.z + rgt_z * flat + fwd_z * ffwd)
			var ak := BM.expk(lerpf(11.5, 16.0, maxf(air_launch, air_desc)), sdt)
			f.cur = Vector3(lerpf(f.cur.x, tgt.x, ak), lerpf(f.cur.y, tgt.y, ak), lerpf(f.cur.z, tgt.z, ak))
			f.planted = Vector3(f.cur.x, lp.y, f.cur.z)
			f.yaw = BM.wrap_pi(f.yaw + BM.wrap_pi(fyaw - f.yaw) * BM.expk(10.0, sdt))
			f.toe_pitch = lerpf(f.toe_pitch, toe, BM.expk(11.0, sdt))
			f.heel_kick = lerpf(f.heel_kick, heel, BM.expk(10.0, sdt))
	else:
		j.groundFootBlend = lerpf(j.groundFootBlend, 1.0, BM.expk(14.0, sdt))
		if just_landed:
			j.landRecovery = 1.0
			j.landImpact = clampf(landing_impact, 0.35, 1.0)
			j.landStyle = j.style
			j.landLeadSide = j.leadSide
			for pair in [["L", -1.0], ["R", 1.0]]:
				var f: Foot = feet[pair[0]]
				var sg: float = pair[1]
				f.stepping = false
				f.t = 1.0
				var rx := f.cur.x - lp.x
				var rz := f.cur.z - lp.z
				var cur_lat := (rx * rgt_x + rz * rgt_z) * sg
				var cur_fwd := rx * fwd_x + rz * fwd_z
				var lead: bool = sg == j.leadSide
				var safe_lat := clampf(cur_lat, hw * 0.80, hw + 0.095) * sg
				var cs := clampf(speed / 2.1, 0.0, 1.0)
				var stag := lerpf(0.035, 0.115, cs) if lead else -lerpf(0.030, 0.085, cs)
				var safe_fwd := clampf(lerpf(cur_fwd, stag, 0.35), -0.18, 0.20)
				var pp := Vector3(lp.x + rgt_x * safe_lat + fwd_x * safe_fwd, lp.y, lp.z + rgt_z * safe_lat + fwd_z * safe_fwd)
				f.planted = pp; f.cur = pp
				f.yaw = BM.wrap_pi(yaw + BM.wrap_pi(f.yaw - yaw) * 0.35)
				f.heel_kick = 0.0
				f.toe_pitch = 0.06 if lead else -0.04
			last_stepped = "L" if j.leadSide < 0 else "R"
			support_cooldown = 0.02 if speed > 0.45 else 0.09
			var abs_scale := lerpf(0.95, 1.42, clampf(j.landImpact * 0.65 + rb * 0.35, 0.0, 1.0))
			com_vel_y = minf(com_vel_y, -abs_scale * j.landImpact)
			spine_lean_fwd_spring.impulse(0.65 * j.landImpact)
			if on_footstep != null:
				on_footstep.call({"foot": "BOTH", "pos": lp, "speed": speed, "runBlend": rb, "crouchBlend": crouch, "landingImpact": landing_impact, "isLanding": true})
		advance.call("L")
		advance.call("R")

	var hip_l := Vector2(lp.x - rgt_x * hw, lp.z - rgt_z * hw)
	var hip_r := Vector2(lp.x + rgt_x * hw, lp.z + rgt_z * hw)
	var trail_l: float = Vector2(feet.L.cur.x - hip_l.x, feet.L.cur.z - hip_l.y).length()
	var trail_r: float = Vector2(feet.R.cur.x - hip_r.x, feet.R.cur.z - hip_r.y).length()
	var step_l: bool = feet.L.stepping
	var step_r: bool = feet.R.stepping

	var trigger := func(key: String, urgent := false) -> void:
		var f: Foot = feet[key]
		f.from = f.cur
		f.dur = clampf(planned * 0.88 if urgent else planned, 0.25, 0.46)
		f.to = target_at.call(key, f.dur)
		f.from_yaw = f.yaw
		f.to_yaw = yaw
		f.stepping = true
		f.t = 0.0
		var sd := Vector2(f.to.x - f.from.x, f.to.z - f.from.z).length()
		var bh := lerpf(config.walkStepHeight, config.runStepHeight, rb)
		f.height = clampf(bh + sd * lerpf(0.022, 0.056, rb), 0.032, lerpf(0.055, 0.118, rb))
		if rb > 0.25:
			com_vel_y = maxf(com_vel_y, rb * 0.29)

	if not (step_l and step_r) and not is_air:
		var err_l := Vector2(feet.L.planted.x - ideal_l.x, feet.L.planted.z - ideal_l.z).length()
		var err_r := Vector2(feet.R.planted.x - ideal_r.x, feet.R.planted.z - ideal_r.z).length()
		var yerr_l := absf(BM.wrap_pi(yaw - feet.L.yaw))
		var yerr_r := absf(BM.wrap_pi(yaw - feet.R.yaw))
		var idle := speed < 0.06 and des_speed < 0.06 and absf(yaw_rate) < 0.22
		var trig := 0.22 if idle else lerpf(config.baseTriggerDist, config.maxTriggerDist, speed_norm)
		var emerg := lerpf(config.emergencyTrailDist, 0.48, rb)
		if not step_l and trail_l > emerg and (not step_r or feet.R.t >= 0.72):
			trigger.call("L", true)
		elif not step_r and trail_r > emerg and (not step_l or feet.L.t >= 0.72):
			trigger.call("R", true)
		elif not step_l and not step_r and support_cooldown <= 0.0:
			var nk := "L" if last_stepped == "R" else "R"
			var ok := "R" if nk == "L" else "L"
			var ne := err_l if nk == "L" else err_r
			var ny := yerr_l if nk == "L" else yerr_r
			var oe := err_l if ok == "L" else err_r
			var oy := yerr_l if ok == "L" else yerr_r
			if ne / trig + ny / config.turnTriggerRad >= 1.0:
				trigger.call(nk, false)
			elif oe / (trig * 1.25) + oy / config.turnTriggerRad >= 1.0:
				trigger.call(ok, false)
		elif rb > 0.28:
			if not step_l and step_r and feet.R.t >= 0.80 and last_stepped != "L" and err_l >= trig:
				trigger.call("L", false)
			elif not step_r and step_l and feet.L.t >= 0.80 and last_stepped != "R" and err_r >= trig:
				trigger.call("R", false)

	var move_w := clampf(speed / 0.45, 0.0, 1.0)
	var either: bool = feet.L.stepping or feet.R.stepping
	var grounded_feet := (0 if feet.L.stepping else 1) + (0 if feet.R.stepping else 1)
	var leg_total := 0.680
	var base_hip: float = config.hipHeightStand - config.ankleHeight
	var dmax := minf(0.45, maxf(trail_l, trail_r))
	var max_geom := sqrt(maxf(0.20, (leg_total * 0.994) * (leg_total * 0.994) - dmax * dmax))
	var geom_drop := maxf(0.0, base_hip - max_geom)
	var swing_u: float = feet.L.t if feet.L.stepping else (feet.R.t if feet.R.stepping else 0.0)
	var swing_bell := sin(PI * swing_u) if either else 0.0
	var walk_vault := (1.0 - rb) * swing_bell * 0.011 * move_w
	var target_com := jump_offset if is_air else (walk_vault - rb * 0.024 - crouch * 0.225 - braking * 0.014 - anticip_dip - geom_drop)
	var g: float = config.gravity
	if is_air:
		com_y = lerpf(com_y, jump_offset, BM.expk(24.0, sdt))
		com_vel_y = jump_vel_y
	elif grounded_feet > 0:
		var k_leg := lerpf(102.0, 128.0, rb)
		var c_leg := lerpf(24.0, 22.0, rb)
		var grf := (target_com - com_y) * k_leg - com_vel_y * c_leg + g
		com_vel_y += (grf - g) * sdt
		com_y = clampf(com_y + com_vel_y * sdt, -0.275, 0.024)
	else:
		com_vel_y -= g * sdt
		com_y = clampf(com_y + com_vel_y * sdt, -0.275, 0.038)

	var stance := 1.0 if feet.L.stepping else (-1.0 if feet.R.stepping else 0.0)
	var sway_amp := lerpf(0.018, 0.014, rb)
	var air_side := 0.0
	if is_air:
		air_side = (signf(j.launchVelRight if j.launchVelRight != 0.0 else 1.0) * 0.022) if j.style == "side_hop" else (-j.leadSide * 0.010 * air_apex)
	var com_lat_goal := air_side if is_air else (stance * sway_amp * (0.25 + 0.75 * swing_bell) * move_w)
	var com_lat: float = com_shift_lat_spring.step(com_lat_goal, 0.18, sdt)
	var pelvis_off: Vector3 = pelvis_offset_spring.step(Vector3(com_lat, com_y, 0.0), 0.055 if is_air else 0.095, sdt)
	var air_proll := clampf(j.leadSide * (0.048 * air_apex + 0.025 * air_launch) + j.varTwist * 0.018 * air_apex, -0.09, 0.09) if is_air else 0.0
	var list_goal := air_proll if is_air else (-stance * lerpf(0.040, 0.052, rb) * move_w * swing_bell)
	var pelvis_roll: float = pelvis_roll_spring.step(list_goal, 0.14 if is_air else 0.19, sdt)

	var land_rec: float = j.landRecovery
	var land_env := sin(clampf(land_rec, 0.0, 1.0) * PI * 0.75)
	var anticip_lean := 0.0 if is_air else jump_anticip * 0.135
	var land_lean: float = 0.0 if is_air else land_env * j.landImpact * 0.115
	var air_lean := 0.0
	if is_air:
		if j.style == "shore_dive":
			air_lean = lerpf(0.32, 0.48, smoothstep(0.0, 0.45, j.airTime))
		elif j.style == "back_hop":
			air_lean = lerpf(0.05, 0.14, air_apex) + air_desc * 0.06
		elif j.style in ["broad_bound", "hurdle_vault", "stride_leap", "skip_bound"]:
			air_lean = lerpf(0.08, 0.18, air_apex) * j.varSplit - air_launch * 0.03 + air_desc * 0.05
		else:
			air_lean = -air_launch * 0.065 + (0.11 if j.style == "standing_tuck" else 0.045) * air_apex + air_desc * 0.085
	var max_lean := 0.56 if (is_air and j.style == "shore_dive") else 0.36
	var tgt_lean_fwd := clampf(v_fwd * lerpf(0.032, 0.088, rb) + rb * 0.058 + crouch * 0.17 - braking * 0.10 + anticip_lean + land_lean + air_lean + a_fwd * 0.006 - ship_pitch * 0.34, -0.16, max_lean)
	var air_bank := 0.0
	if is_air:
		air_bank = clampf(-j.launchVelRight * 0.055, -0.14, 0.14) if j.style == "side_hop" else clampf(-j.leadSide * 0.034 * air_apex + j.varTwist * 0.024 * air_apex, -0.11, 0.11)
	var gait_sway := -stance * lerpf(0.016, 0.024, rb) * move_w * swing_bell
	var tgt_lean_lat := clampf((air_bank if is_air else gait_sway) - v_right * 0.024 - a_right * 0.006 - yaw_rate * speed * 0.020 - ship_roll * 0.40, -0.16, 0.16)
	var ffl: float = (feet.L.cur.x - lp.x) * fwd_x + (feet.L.cur.z - lp.z) * fwd_z
	var ffr: float = (feet.R.cur.x - lp.x) * fwd_x + (feet.R.cur.z - lp.z) * fwd_z
	var stride_diff := clampf(ffl - ffr, -0.64, 0.64)
	var air_twist := 0.0
	if is_air:
		air_twist = -j.leadSide * (0.11 if j.style in ["standing_skip", "hurdle_vault"] else 0.06) * air_apex + j.varTwist * 0.055 * air_apex
	var tgt_pyaw := clampf(stride_diff * lerpf(0.20, 0.25, rb) + (-air_twist * 0.65 if is_air else 0.0), -0.22, 0.22)
	var tgt_twist := clampf(-stride_diff * lerpf(0.24, 0.33, rb) + air_twist + yaw_rate * 0.038, -0.28, 0.28)
	var pelvis_yaw: float = pelvis_yaw_spring.step(tgt_pyaw, 0.14 if is_air else 0.19, sdt)
	var spine_lean_fwd: float = spine_lean_fwd_spring.step(tgt_lean_fwd, 0.13 if is_air else 0.20, sdt)
	var spine_lean_lat: float = spine_lean_lat_spring.step(tgt_lean_lat, 0.15 if is_air else 0.20, sdt)
	var spine_twist: float = spine_twist_spring.step(tgt_twist, 0.14 if is_air else 0.19, sdt)

	var swing_mag := lerpf(0.29 * (0.16 + 0.84 * move_w), 0.48, rb)
	var arm_fwd_l := clampf(-stride_diff * swing_mag - a_fwd * 0.003, -0.23, 0.27)
	var arm_fwd_r := clampf(stride_diff * swing_mag - a_fwd * 0.003, -0.23, 0.27)
	var cross_l := maxf(0.0, arm_fwd_l) * lerpf(0.08, 0.18, rb)
	var cross_r := -maxf(0.0, arm_fwd_r) * lerpf(0.08, 0.18, rb)
	var lw_l := maxf(0.0, arm_fwd_l) * 0.15 + absf(arm_fwd_l) * 0.04
	var lw_r := maxf(0.0, arm_fwd_r) * 0.15 + absf(arm_fwd_r) * 0.04
	var lr_l := 0.12 + maxf(0.0, arm_fwd_l) * 0.32
	var lr_r := 0.12 + maxf(0.0, arm_fwd_r) * 0.32

	var air_arm := func(side: float) -> Vector3:
		if not is_air:
			var asym := 1.15 if side == -j.landLeadSide else 0.88
			var land_lat: float = side * land_env * j.landImpact * 0.072 * asym
			var land_lift: float = -land_env * j.landImpact * 0.048 + (0.025 * land_rec if land_rec > 0.55 else 0.0)
			var land_fwd: float = land_env * j.landImpact * (0.055 if side == -j.landLeadSide else -0.025)
			return Vector3(side * jump_anticip * 0.038 + land_lat + side * crouch * 0.032,
				-jump_anticip * 0.045 + land_lift + crouch * 0.045,
				-jump_anticip * 0.185 + land_fwd + crouch * 0.08)
		var opp: bool = side == -j.leadSide
		var asym_arm := 1.0 if opp else -1.0
		var va: float = j.varArm
		if j.style == "shore_dive":
			return Vector3(side * 0.045, 0.36 + air_launch * 0.08, 0.34 + air_desc * 0.06)
		var dfl := air_desc * 0.135 * va
		var dflat := air_desc * 0.072 * va
		var drift := air_drift * 0.018 * asym_arm
		if j.style in ["broad_bound", "hurdle_vault", "stride_leap", "skip_bound"]:
			var drive := 1.0 if j.style in ["broad_bound", "hurdle_vault"] else 0.80
			var lift: float = (0.25 if opp else 0.14) * drive * va + air_launch * 0.06 + dfl + drift
			var fw: float = (0.22 if opp else -0.10) * drive * j.varSplit * (1.0 - air_desc * 0.45) + air_desc * 0.07
			return Vector3(side * ((0.065 if opp else 0.135) * va + dflat), lift, fw)
		if j.style == "side_hop":
			var sdir := 1.0 if j.launchVelRight >= 0.0 else -1.0
			var counter := side == -sdir
			return Vector3(side * ((0.18 if counter else 0.09) * va + dflat), (0.24 if counter else 0.13) * va + dfl, (0.08 if counter else 0.03) + drift)
		if j.style == "back_hop":
			return Vector3(side * (0.12 * va + dflat), (0.18 if opp else 0.14) * va + dfl, 0.16 + (0.05 if opp else -0.02))
		var tk: bool = j.style == "standing_tuck"
		var sk: bool = j.style == "standing_skip"
		var base_lift: float = (0.24 if tk else (0.22 if sk else 0.17)) * va
		var asym_lift := (0.075 if sk else 0.042) if opp else -0.025
		var lift2: float = base_lift + asym_lift + air_launch * 0.06 + dfl + drift
		var lat2: float = side * ((0.145 if tk else 0.105) * va + (-0.015 if opp else 0.028) + dflat)
		var fw2: float = ((0.16 if opp else -0.07) if sk else (0.10 if opp else 0.02)) * j.varSplit + air_launch * 0.04
		return Vector3(lat2, lift2, fw2)

	var off_l: Vector3 = air_arm.call(-1.0)
	var off_r: Vector3 = air_arm.call(1.0)
	var gas := 0.22 if is_air else 1.0
	var tgt_l := Vector3(-0.010 + cross_l * gas - absf(spine_lean_lat) * 0.04 + off_l.x, lerpf(lw_l, lr_l, rb) * gas + off_l.y, arm_fwd_l * gas + off_l.z)
	var tgt_r := Vector3(0.010 + cross_r * gas + absf(spine_lean_lat) * 0.04 + off_r.x, lerpf(lw_r, lr_r, rb) * gas + off_r.y, arm_fwd_r * gas + off_r.z)
	var arm_hl := 0.115 if is_air else (0.065 if jump_anticip > 0.05 else (0.11 if land_rec > 0.1 else lerpf(0.20, 0.13, rb)))
	var arm_swing_l: Vector3 = arm_swing_spring_l.step(tgt_l, arm_hl, sdt)
	var arm_swing_r: Vector3 = arm_swing_spring_r.step(tgt_r, arm_hl, sdt)
	var tgt_flare: float = clampf(0.18 + air_apex * 0.14 + air_desc * 0.16, 0.0, 0.45) if is_air else land_env * j.landImpact * 0.16
	var tgt_wl: float
	var tgt_wr: float
	if is_air:
		tgt_wl = clampf(-jump_vel_y * 0.095 + (0.06 if j.leadSide > 0 else -0.04) * air_apex, -0.28, 0.28)
		tgt_wr = clampf(-jump_vel_y * 0.095 + (0.06 if j.leadSide < 0 else -0.04) * air_apex, -0.28, 0.28)
	else:
		tgt_wl = -jump_anticip * 0.12 - land_env * j.landImpact * 0.16
		tgt_wr = tgt_wl
	var tgt_dip: float
	if is_air:
		tgt_dip = -0.18 if j.style == "shore_dive" else clampf(air_launch * 0.075 - air_desc * 0.115, -0.14, 0.09)
	else:
		tgt_dip = -land_env * j.landImpact * 0.065
	j.elbowFlare = lerpf(j.elbowFlare, tgt_flare, BM.expk(10.0, sdt))
	j.wristLagL = lerpf(j.wristLagL, tgt_wl, BM.expk(10.5, sdt))
	j.wristLagR = lerpf(j.wristLagR, tgt_wr, BM.expk(10.5, sdt))
	j.headLookDip = lerpf(j.headLookDip, tgt_dip, BM.expk(8.5, sdt))

	var fl_: Foot = feet.L
	var fr_: Foot = feet.R
	return {
		"gaitMode": gait, "runBlend": rb, "speed": speed, "speedNorm": speed_norm, "vFwd": v_fwd, "vRight": v_right,
		"trajectory": traj,
		"footL": {"pos": fl_.cur, "yaw": fl_.yaw, "stepping": fl_.stepping, "t": fl_.t, "toePitch": fl_.toe_pitch, "heelKick": fl_.heel_kick},
		"footR": {"pos": fr_.cur, "yaw": fr_.yaw, "stepping": fr_.stepping, "t": fr_.t, "toePitch": fr_.toe_pitch, "heelKick": fr_.heel_kick},
		"pelvisOffset": pelvis_off, "pelvisYaw": pelvis_yaw, "pelvisRoll": pelvis_roll,
		"spineLeanFwd": spine_lean_fwd, "spineLeanLat": spine_lean_lat, "spineTwist": spine_twist,
		"armSwingL": arm_swing_l, "armSwingR": arm_swing_r, "comY": com_y, "comVelY": com_vel_y,
		"stepCount": step_count, "stumbleEnergy": stumble_energy,
		"jump": {"isAirborne": is_air, "style": j.style, "leadSide": j.leadSide, "airTime": _r3(j.airTime),
			"airBlend": _r3(j.airBlend), "groundFootBlend": _r3(j.groundFootBlend), "landRecovery": _r3(j.landRecovery),
			"elbowFlare": _r3(j.elbowFlare), "wristLagL": _r3(j.wristLagL), "wristLagR": _r3(j.wristLagR),
			"headLookDip": _r3(j.headLookDip), "count": j.count},
	}
