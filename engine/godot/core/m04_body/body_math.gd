## M04 Body, core 0.1.0: shared math for the body rig, ported from Thalassa v20.19
## core/math.js (getForward/getRight/wrapPi/expK, M4.fromBasis/fromSegment), core/procedural-locomotion.js
## (critSpringDamper1D, CritSpring1D/3D, Inertializer3D) and core/ik-solvers.js (SoftJointSpring1D/3D,
## TwoBoneIKSolver, AnatomicalLegSolver). JS [x,y,z] arrays become Vector3; JS column-major M4 becomes Transform3D
## (columns = basis x/y/z, origin = m[12..14]).
extends RefCounted

const LN2 := 0.6931471805599453

static func fwd(yaw: float, pitch: float) -> Vector3:
	var cp := cos(pitch)
	return Vector3(-sin(yaw) * cp, sin(pitch), -cos(yaw) * cp)

static func right(yaw: float) -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))

static func wrap_pi(a: float) -> float:
	a = fmod(a + PI, TAU)
	if a < 0.0: a += TAU
	return a - PI

static func expk(rate: float, dt: float) -> float:
	return 1.0 - exp(-maxf(0.0, rate * dt))

static func nrm(v: Vector3) -> Vector3:
	var l := v.length()
	return v / l if l > 0.0 else v

## M4.fromBasis
static func basis_xf(o: Vector3, x: Vector3, y: Vector3, z: Vector3, sx := 1.0, sy := 1.0, sz := 1.0) -> Transform3D:
	return Transform3D(Basis(x * sx, y * sy, z * sz), o)

## M4.fromSegment: unit-Y mesh stretched from a to b, radius scales rx / rz
static func segment_xf(a: Vector3, b: Vector3, rx: float, rz: float, ref_axis = null) -> Transform3D:
	var d := b - a
	var l := d.length()
	if l < 1e-5:
		return Transform3D(Basis(Vector3(rx, 0, 0), Vector3(0, 0.001, 0), Vector3(0, 0, rz)), a)
	var y := d / l
	var rf: Vector3 = ref_axis if ref_axis != null else (Vector3.UP if absf(y.y) < 0.9 else Vector3.RIGHT)
	var x := y.cross(rf)
	var xl := x.length()
	if xl < 1e-5:
		x = nrm(y.cross(Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.BACK))
	else:
		x = x / xl
	return basis_xf(a, x, y, x.cross(y), rx, l, rz)

## critSpringDamper1D -> [x, v]
static func crit(x: float, v: float, goal: float, vgoal: float, halflife: float, dt: float) -> Vector2:
	return Crit.step(x, v, goal, vgoal, halflife, dt)

class Crit:
	static func step(x: float, v: float, goal: float, vgoal: float, halflife: float, dt: float) -> Vector2:
		var y := 4.0 * 0.6931471805599453 / maxf(1e-4, halflife)
		var j0 := x - goal
		var j1 := v + j0 * y
		var e := exp(-y * dt)
		return Vector2(e * (j0 + j1 * dt) + goal, e * (v - j1 * y * dt) + vgoal * (1.0 - e))

class CritSpring1D:
	var x := 0.0
	var v := 0.0
	func _init(initial := 0.0) -> void: x = initial
	func reset(val := 0.0, vel := 0.0) -> void: x = val; v = vel
	func impulse(dv: float) -> void: v += dv
	func step(target: float, halflife: float, dt: float, vgoal := 0.0) -> float:
		var r := Crit.step(x, v, target, vgoal, halflife, dt)
		x = r.x; v = r.y
		return x

class CritSpring3D:
	var x := Vector3.ZERO
	var v := Vector3.ZERO
	func _init(initial := Vector3.ZERO) -> void: x = initial
	func reset(p := Vector3.ZERO, vel := Vector3.ZERO) -> void: x = p; v = vel
	func impulse(i: Vector3) -> void: v += i
	func step(target: Vector3, halflife: float, dt: float) -> Vector3:
		for i in 3:
			var r := Crit.step(x[i], v[i], target[i], 0.0, halflife, dt)
			x[i] = r.x; v[i] = r.y
		return x

class Inertializer3D:
	var halflife := 0.09
	var off := Vector3.ZERO
	var vel := Vector3.ZERO
	func _init(hl := 0.09) -> void: halflife = hl
	func trigger(prev_pos: Vector3, prev_vel, next_pos: Vector3, next_vel = Vector3.ZERO) -> void:
		off = prev_pos - next_pos
		vel = (prev_vel if prev_vel != null else Vector3.ZERO) - (next_vel if next_vel != null else Vector3.ZERO)
	func evaluate(target: Vector3, dt: float) -> Vector3:
		var o := Vector3.ZERO
		for i in 3:
			var r := Crit.step(off[i], vel[i], 0.0, 0.0, halflife, dt)
			off[i] = r.x; vel[i] = r.y
			o[i] = target[i] + r.x
		return o

## SoftJointSpring1D: drive + neutral-posture pull, soft tendon margins, hard clamp
class SoftJoint1D:
	var val := 0.0
	var vel := 0.0
	var lo := 0.0
	var hi := 0.0
	var margin := 0.0
	var neutral := 0.0
	var soft_stress := 0.0
	func _init(initial: float, mn: float, mx: float, mg: float, nt: float) -> void:
		val = initial; lo = mn; hi = mx; margin = mg; neutral = nt
	func add_impulse(dv: float) -> void: vel += dv
	func step(dt: float, target: float, k_anim: float, k_equil: float, damping: float, ext := 0.0) -> float:
		var steps := 2 if dt > 0.022 else 1
		var h := dt / steps
		for _s in steps:
			var acc := (target - val) * k_anim + (neutral - val) * k_equil - vel * damping + ext
			var hs := hi - margin
			var ls := lo + margin
			var stress := 0.0
			if val > hs:
				var u := clampf((val - hs) / maxf(1e-4, margin), 0.0, 1.5)
				stress = clampf(u, 0.0, 1.0)
				acc -= u * u * (k_anim * 1.45 + 18.0) * margin
				if vel > 0.0: acc -= vel * (10.0 + u * u * 34.0)
			elif val < ls:
				var u := clampf((ls - val) / maxf(1e-4, margin), 0.0, 1.5)
				stress = clampf(u, 0.0, 1.0)
				acc += u * u * (k_anim * 1.45 + 18.0) * margin
				if vel < 0.0: acc -= vel * (10.0 + u * u * 34.0)
			soft_stress = stress
			vel += acc * h
			val += vel * h
			if val > hi:
				val = hi
				if vel > 0.0: vel *= 0.15
			elif val < lo:
				val = lo
				if vel < 0.0: vel *= 0.15
		return val

class SoftJoint3D:
	var x: SoftJoint1D
	var y: SoftJoint1D
	var z: SoftJoint1D
	func _init(n: Vector3, mn: Vector3, mx: Vector3, mg: Vector3) -> void:
		x = SoftJoint1D.new(n.x, mn.x, mx.x, mg.x, n.x)
		y = SoftJoint1D.new(n.y, mn.y, mx.y, mg.y, n.y)
		z = SoftJoint1D.new(n.z, mn.z, mx.z, mg.z, n.z)
	func add_impulse(i: Vector3) -> void:
		x.add_impulse(i.x); y.add_impulse(i.y); z.add_impulse(i.z)
	func step(dt: float, t: Vector3, ka: float, ke: float, d: float, ext := Vector3.ZERO) -> Vector3:
		return Vector3(x.step(dt, t.x, ka, ke, d, ext.x), y.step(dt, t.y, ka, ke, d, ext.y), z.step(dt, t.z, ka, ke, d, ext.z))
	func get_stress() -> float:
		return maxf(x.soft_stress, maxf(y.soft_stress, z.soft_stress))

## TwoBoneIKSolver.solve -> {root, mid, eff, bendAxis, dir, len1, len2, dist, rawDist, jointFlexDeg, reached, err}
static func two_bone(root: Vector3, target: Vector3, pole: Vector3, l1: float, l2: float, soft_reach := 0.996,
		soft_margin := 0.0, max_flex_deg := 142.0, min_flex_deg := 0.0) -> Dictionary:
	var to_t := target - root
	var draw := to_t.length()
	var total := l1 + l2
	var max_d := total * soft_reach
	if min_flex_deg > 0.01:
		var mfr := clampf(min_flex_deg, 0.0, 40.0) * PI / 180.0
		max_d = minf(max_d, sqrt(maxf(1e-4, l1 * l1 + l2 * l2 - 2.0 * l1 * l2 * cos(PI - mfr))))
	var min_int := (180.0 - clampf(max_flex_deg, 60.0, 175.0)) * PI / 180.0
	var flex_min := sqrt(maxf(1e-4, l1 * l1 + l2 * l2 - 2.0 * l1 * l2 * cos(min_int)))
	var min_d := maxf(absf(l1 - l2) + 0.015, flex_min)
	var d: float
	if soft_margin > 0.001:
		var hr := total * soft_margin
		var lr := total * soft_margin * 0.55
		var hk := max_d - hr
		var lk := min_d + lr
		if draw > hk:
			d = hk + hr * (1.0 - exp(-(draw - hk) / maxf(1e-4, hr)))
		elif draw < lk:
			d = lk - lr * (1.0 - exp(-(lk - draw) / maxf(1e-4, lr)))
		else:
			d = draw
		d = clampf(d, min_d, max_d)
	else:
		d = clampf(draw, min_d, max_d)
	var dir := to_t / draw if draw > 1e-5 else Vector3(0, -1, 0)
	var eff := root + dir * d
	var to_p := pole - root
	var proj := to_p - dir * to_p.dot(dir)
	var pl := proj.length()
	var bend: Vector3
	if pl > 1e-5:
		bend = proj / pl
	else:
		bend = nrm(dir.cross(Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT))
	var cos_a := clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0)
	var sin_a := sqrt(maxf(0.0, 1.0 - cos_a * cos_a))
	var mid := root + dir * (l1 * cos_a) + bend * (l1 * sin_a)
	var cos_k := clampf((l1 * l1 + l2 * l2 - d * d) / (2.0 * l1 * l2), -1.0, 1.0)
	return {"root": root, "mid": mid, "eff": eff, "bendAxis": bend, "dir": dir, "len1": l1, "len2": l2,
		"dist": d, "rawDist": draw, "jointFlexDeg": (PI - acos(cos_k)) * 180.0 / PI,
		"reached": draw <= max_d + 1e-4, "err": eff.distance_to(target)}

## AnatomicalLegSolver.solve -> {ik, finMat, finDir, finX, finZ, shinDir, kneeRight, anatFwd}
static func leg(hip: Vector3, raw_target: Vector3, side: float, pelv_down: Vector3, pelv_fwd: Vector3,
		thigh: float, shin: float, o := {}) -> Dictionary:
	var pd := nrm(pelv_down)
	var fp := pelv_fwd - pd * pelv_fwd.dot(pd)
	var pf := nrm(fp) if fp.length() > 1e-4 else nrm(pd.cross(Vector3.UP if absf(pd.y) < 0.9 else Vector3.RIGHT))
	var pr := nrm(pd.cross(pf))
	var max_ext: float = o.get("maxHipExtDeg", 20.0) * PI / 180.0
	var max_flex: float = o.get("maxHipFlexDeg", 112.0) * PI / 180.0
	var max_add: float = o.get("maxAdductionDeg", 6.5) * PI / 180.0
	var max_abd: float = o.get("maxAbductionDeg", 36.0) * PI / 180.0
	var max_int_rot: float = o.get("maxIntRotRad", 0.20)
	var max_ext_rot: float = o.get("maxExtRotRad", 0.48)
	var min_flex_deg: float = o.get("minFlexDeg", 5.0)
	var max_flex_deg: float = o.get("maxFlexDeg", 128.0)
	var soft_reach: float = o.get("softReach", 0.990)
	var soft_margin: float = o.get("softMargin", 0.04)
	var preserve_down: bool = o.get("preserveDown", false)
	var rel := raw_target - hip
	var rd := rel.dot(pd)
	var rf := rel.dot(pf)
	var rl := rel.dot(pr) * side
	var rlen := Vector3(rd, rf, rl).length()
	if rlen < 1e-4:
		rd = 0.55; rf = 0.05; rl = 0.02
		rlen = Vector3(rd, rf, rl).length()
	var ct: Vector3
	var sag: float
	if preserve_down:
		rd = maxf(rd, 0.14)
		rf = clampf(rf, -rd * tan(max_ext), rd * tan(minf(max_flex, 68.0 * PI / 180.0)))
		var sm := Vector2(rd, rf).length()
		rl = clampf(rl, -sm * tan(max_add), sm * tan(max_abd))
		ct = hip + pd * rd + pf * rf + pr * (rl * side)
		sag = atan2(rf, rd)
	else:
		var lat := clampf(asin(clampf(rl / rlen, -1.0, 1.0)), -max_add, max_abd)
		var est := clampf(rlen, absf(thigh - shin) + 0.05, thigh + shin)
		var ea := acos(clampf((thigh * thigh + est * est - shin * shin) / (2.0 * thigh * est), -1.0, 1.0))
		var ems := minf(max_flex, 124.0 * PI / 180.0 - ea * 0.85)
		sag = clampf(atan2(rf, rd), -max_ext, maxf(0.35, ems))
		var cl := cos(lat)
		ct = hip + (pd * (cl * cos(sag)) + pf * (cl * sin(sag)) + pr * (sin(lat) * side)) * rlen
	var rel_yaw := wrap_pi(o.get("desiredYawOffsetRad", 0.0))
	var turn := clampf(-side * rel_yaw, -max_int_rot, max_ext_rot)
	var co := cos(turn)
	var so := sin(turn)
	var anat := nrm(pf * co + pr * (side * so))
	var kob: float = o.get("kneeOutBias", 0.08)
	var tfade := 1.0 - clampf(maxf(0.0, turn) / maxf(0.1, max_ext_rot), 0.0, 1.0)
	var pole_lat := maxf(-0.02, so + kob * tfade)
	var anti_up: float = maxf(0.0, sin(sag) - 0.25) * 0.50 + o.get("kneeLiftBias", 0.0)
	var pole_dir := nrm(pf * co + (pr * (side * pole_lat) + pd * -anti_up))
	var ik := two_bone(hip, ct, hip + pole_dir * 0.70, thigh, shin, soft_reach, soft_margin, max_flex_deg, min_flex_deg)
	var shin_dir := nrm(ik.eff - ik.mid)
	var krr: Vector3 = shin_dir.cross(ik.bendAxis)
	var kr := nrm(krr) if krr.length() > 1e-4 else pr
	if kr.dot(pr) < 0.0: kr = -kr
	var shin_fwd := nrm(kr.cross(shin_dir))
	var min_ap: float = o.get("minAnklePitchRad", -0.96)
	var max_ap: float = o.get("maxAnklePitchRad", 0.48)
	var max_ay: float = o.get("maxAnkleYawRad", 0.14)
	var max_ar: float = o.get("maxAnkleRollRad", 0.22)
	var pitch := clampf(o.get("anklePitchRad", 0.0), min_ap, max_ap)
	var yaw := clampf(o.get("ankleYawRad", 0.0), -max_ay, max_ay)
	var roll := clampf(o.get("ankleRollRad", 0.0), -max_ar, max_ar)
	var gb := clampf(o.get("groundBlend", 0.0), 0.0, 1.0)
	if gb > 0.005:
		var gf: Vector3 = nrm(o.groundFwd) if o.get("groundFwd") != null else anat
		if gf.dot(anat) < 0.72: gf = anat
		var gu: Vector3 = nrm(o.groundUp) if o.get("groundUp") != null else -pd
		var gff := gf.dot(shin_fwd)
		var gfd := gf.dot(shin_dir)
		var gfr := gf.dot(kr)
		pitch = lerpf(pitch, clampf(atan2(-gfd, maxf(0.18, gff)), min_ap, max_ap), gb)
		yaw = lerpf(yaw, clampf(atan2(gfr, maxf(0.25, gff)), -max_ay, max_ay), gb)
		roll = lerpf(roll, clampf(asin(clampf(gu.dot(kr), -1.0, 1.0)), -max_ar, max_ar), gb)
	var bf := nrm(shin_fwd * cos(yaw) + kr * sin(yaw))
	var br := nrm(bf.cross(-shin_dir))
	var cp := cos(pitch)
	var sp := sin(pitch)
	var fin_dir := nrm(bf * cp + shin_dir * -sp)
	var fzb := nrm(shin_dir * -cp + bf * -sp)
	var fin_x := nrm(br * cos(roll) + fzb * sin(roll))
	var fin_z := nrm(fin_x.cross(fin_dir))
	return {"ik": ik, "finMat": basis_xf(ik.eff, fin_x, fin_dir, fin_z), "finDir": fin_dir, "finX": fin_x, "finZ": fin_z,
		"shinDir": shin_dir, "kneeRight": kr, "anatFwd": anat}
