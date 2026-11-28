## M04 rest poses 0.1.0 (rest-ride thread, 28 Nov 2026): port of Thalassa v20.19 core/ik-poses-interior.js
## ikSolvePelagosRestPose: 'stool' (poised seated: Thalassa's lab stool), 'chair' (here the bench) and 'bunk'
## (reclined on the mattress, head on the pillow, with the analytical pillow occiput clearance guard), breathing in
## each, live head look. The vessel-local numbers are kept; the seat / bed is placed from blockout markers instead of
## vessel stations (Thalassa local (x, y - seat top, z) = marker local; -Z forward, +Y up).
## Differences, each marked FIX / ADAPT where it happens:
## - FIX spine: Thalassa's hard-coded vessel points stretch the spine 20-47 % past the standing body (pelvis-waist
##   0.196 / 0.200 m against 0.160, chest-neck 0.135 / 0.173 against 0.118): the directions are kept, the standing
##   segment lengths used (the stress test holds every span to the standing pose);
## - ADAPT feet: the stand-in stool has no footrest ring (Thalassa's feet rest on one 0.14 m up) and the girl's lower
##   leg is shorter than a 0.45 m seat is high: her feet hang where the shin falls, on the floor when it is low enough;
## - ADAPT arms: no armrests on the bench (Thalassa's chair hands rest on them): the stool's relaxed hands-on-thighs;
## - ADAPT duck: under a low bunk the seated torso pitches forward until the skull clears (Thalassa's bunks are tall);
## - FIX pillow guard: Thalassa lifts the head and neck by different amounts (the neck stretches); here the upper body
##   is inclined about the waist as one piece until the occiput clears, so no span changes;
## - head springs: each pose keeps its own (Thalassa shares one), so a blend between two live poses steps each once.
extends RefCounted

const BM := preload("res://core/m04_body/body_math.gd")

const PELVIS_W := 0.160       # standing spans (Thalassa solve_walk_wade), see FIX spine
const WAIST_C := 0.195
const PELV_UP := 0.075        # pelvis above the seat top (Thalassa stool: -0.295 against the cushion top -0.37)
const THIGH_DROP := 0.14      # rad: seated thigh slope down from the hip when the feet hang
const SHIN_FWD := 0.21        # rad: hanging shin forward of vertical
const ANKLE_UP := 0.052       # ankle above the sole (the walk pose's)
# bunk pillow: the stand-in's pillow box (blockout bunk 0.32 along the bed x 0.55 across), centred on the pillow marker
const PILLOW_HALF := Vector2(0.275, 0.16)
const SKULL_PROBES := [Vector3(0.0, 0.065, 0.098), Vector3(0.0, 0.120, 0.112), Vector3(0.0, 0.175, 0.106),
	Vector3(0.0, 0.228, 0.030), Vector3(-0.098, 0.118, 0.020), Vector3(0.098, 0.118, 0.020)]

var rig
var lean_x = BM.CritSpring1D.new()      # Thalassa helmLeanXSpring / helmLeanZSpring (here driven by hits)
var lean_z = BM.CritSpring1D.new()
var seat_head := [BM.CritSpring1D.new(), BM.CritSpring1D.new()]
var lie_head := [BM.CritSpring1D.new(), BM.CritSpring1D.new()]
var incline := 0.0            # pillow guard: upper body raised about the waist (rad), held while lying
var duck = BM.CritSpring1D.new()
var duck_init := false

func _init(r) -> void:
	rig = r

## A hit while seated or lying sways the trunk (Thalassa's vessel-motion lean springs).
func impulse(lr: float, lb: float, mag: float) -> void:
	lean_x.v += clampf(-lr * mag * 0.9, -0.5, 0.5)
	lean_z.v += clampf(lb * mag * 0.7, -0.4, 0.4)

func reset_lie() -> void:
	incline = 0.0

func _head(springs: Array, dt: float, chest: Vector3, neck: Vector3, cx: Vector3, cy: Vector3, cf: Vector3, look: Vector3, lim: Dictionary) -> Dictionary:
	var hy = rig.head_yaw_spring
	var hp = rig.head_pitch_spring
	rig.head_yaw_spring = springs[0]
	rig.head_pitch_spring = springs[1]
	var h: Dictionary = rig.solve_head(dt, chest, neck, cx, cy, cf, look, lim)
	rig.head_yaw_spring = hy
	rig.head_pitch_spring = hp
	return h

static func _ortho(t: Transform3D) -> Transform3D:
	return Transform3D(t.basis.orthonormalized(), t.origin)

func _lean(sdt: float) -> Vector2:
	# Thalassa: lean targets from the vessel's yaw rate / roll / pitch (none here), half-life 0.16 s, +-0.065 rad
	var lx: float = lean_x.step(0.0, 0.16, sdt)
	var lz: float = lean_z.step(0.0, 0.16, sdt)
	return Vector2(clampf(lx, -0.13, 0.13), clampf(lz, -0.09, 0.09))

## Where the seated feet go: hanging from the knee just past the seat edge, or on the floor when it is that high.
func seat_foot(seat: Transform3D, kind: String, side: float, floor_y: float) -> Vector3:
	var so := _ortho(seat)
	var pz := 0.02 if kind != "bench" else -0.01
	var hip := so * Vector3(side * rig.hip_half_w, PELV_UP, pz)
	var f := -so.basis.z
	var up := so.basis.y
	var knee: Vector3 = hip + (f * cos(THIGH_DROP) - up * sin(THIGH_DROP)) * rig.thigh_len
	var ank: Vector3 = knee + (f * sin(SHIN_FWD) - up * cos(SHIN_FWD)) * rig.shin_len * 0.97
	ank += so.basis.x * side * 0.05     # Thalassa stool feet 0.135 out (hips 0.088)
	if is_finite(floor_y) and ank.y < floor_y + ANKLE_UP:
		ank.y = floor_y + ANKLE_UP
	return ank

## The seated pose (stool and bench edge: Thalassa 'stool'; bench: Thalassa 'chair'). o: feet [L, R] (world ankle
## targets, default seat_foot), foot_ground [l, r] (1 = flat on the floor), look_yaw, look_pitch, duck (rad),
## swivel (rad), env (for the duck test).
func solve_seat(dt: float, seat: Transform3D, kind: String, t: float, o := {}) -> Dictionary:
	var sdt := clampf(dt, 0.0001, 0.05)
	var is_stool := kind != "bench"
	var breath := sin(t * 1.42) * 0.0045
	var ln := _lean(sdt)
	var so := _ortho(seat)
	var sw: float = o.get("swivel", 0.0)
	if absf(sw) > 1e-5: so.basis = Basis(so.basis.y, sw) * so.basis
	var X := so.basis.x
	var Y := so.basis.y
	var F := -so.basis.z
	var pz := 0.02 if is_stool else -0.01
	var pelvis_t := so * Vector3(0.0, PELV_UP, pz)
	var waist_t := so * Vector3(ln.x * 0.45, PELV_UP + 0.195 + breath * 0.5, pz + (-0.02 if is_stool else 0.01) + ln.y * 0.4)
	var chest_t := so * Vector3(ln.x * 0.85, PELV_UP + 0.425 + breath, pz + (-0.06 if is_stool else -0.04) + ln.y * 0.8)
	var neck_t := so * Vector3(ln.x, PELV_UP + 0.560 + breath, pz + (-0.07 if is_stool else -0.06) + ln.y)
	# FIX spine: Thalassa's directions, the standing lengths
	var pelvis := pelvis_t
	var waist := pelvis + (waist_t - pelvis_t).normalized() * PELVIS_W
	var chest := waist + (chest_t - waist_t).normalized() * WAIST_C
	var neck_a: Vector3 = chest + (neck_t - chest_t).normalized() * rig.NECK_LEN
	# ADAPT duck: pitch the trunk forward about the hips (her right axis); the spine bends, the pelvis keeps its tilt
	var waist0 := waist
	var dk: float = o.get("duck", 0.0)
	if dk > 1e-4:
		var rb := Basis(X, -dk)
		waist = pelvis + rb * (waist - pelvis)
		chest = pelvis + rb * (chest - pelvis)
		neck_a = pelvis + rb * (neck_a - pelvis)
	var body_right := X
	var body_axis_y := Y
	var body_back := -F
	var cay := (neck_a - waist).normalized()
	var cx := cay.cross(body_back).normalized()
	var cz := cx.cross(cay)
	var chest_mat := BM.basis_xf(chest, cx, cay, cz)
	var pay := (waist0 - pelvis).normalized()
	var px := pay.cross(body_back).normalized()
	var pzv := px.cross(pay)
	var pelvis_mat := BM.basis_xf(pelvis, px, pay, pzv)
	var shoulder_l: Vector3 = chest - cx * rig.shoulder_half_w
	var shoulder_r: Vector3 = chest + cx * rig.shoulder_half_w
	var hip_l: Vector3 = pelvis - body_right * rig.hip_half_w
	var hip_r: Vector3 = pelvis + body_right * rig.hip_half_w
	# arms: Thalassa stool swivelled away from its bench (stoolBenchBlend 0): hands resting on the thighs
	var arms := {}
	for side in [-1.0, 1.0]:
		var sh: Vector3 = shoulder_l if side < 0.0 else shoulder_r
		var h := so * Vector3(side * 0.165, 0.145 + breath * 0.6, -0.24)
		var pl := so * Vector3(side * 0.28, 0.11, 0.02)
		var ik := BM.two_bone(sh, h, pl, rig.upper_arm_len, rig.forearm_len, 0.990, 0.04, 136.0)
		var fd: Vector3 = (ik.eff - ik.mid).normalized()
		var zb: Vector3 = (body_axis_y * 0.85 + body_right * (side * 0.35)).normalized()
		var xa := fd.cross(zb).normalized()
		arms[side] = {"ik": ik, "mat": BM.basis_xf(ik.eff, xa, fd, xa.cross(fd))}
	# legs
	var feet: Array = o.get("feet", [])
	var fg: Array = o.get("foot_ground", [1.0, 1.0])
	var legs := {}
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hip: Vector3 = hip_l if side < 0.0 else hip_r
		var foot: Vector3 = feet[i] if feet.size() == 2 else seat_foot(seat, kind, side, o.get("floor_y", -INF))
		var g: float = fg[i]
		var solved := BM.leg(hip, foot, side, -body_axis_y, F, rig.thigh_len, rig.shin_len, {
			"softReach": 0.992, "softMargin": 0.04, "minFlexDeg": 14.0, "maxFlexDeg": 124.0,
			"maxHipExtDeg": 16.0, "maxHipFlexDeg": 112.0, "kneeOutBias": 0.08, "kneeLiftBias": 0.20,
			"groundBlend": lerpf(0.55, 1.0, g), "groundFwd": F, "groundUp": body_axis_y, "anklePitchRad": lerpf(-0.30, 0.0, g)})
		legs[i] = {"ik": solved.ik, "finMat": solved.finMat, "finDir": solved.finDir}
	# head: Thalassa seated free look
	var ly: float = o.get("look_yaw", 0.0)
	var lp: float = o.get("look_pitch", -0.05)
	var look := ((F * cos(ly) - X * sin(ly)) * cos(lp) + Y * sin(lp)).normalized()
	var head := _head(seat_head, sdt, chest, neck_a, cx, cay, -cz, look,
		{"maxYaw": 1.12, "minPitch": -0.62, "maxPitch": 0.72, "neckPitchShare": 0.36, "neckHalflife": 0.11})
	return _pack("rest_sit", kind, head, chest, waist, pelvis, shoulder_l, shoulder_r, hip_l, hip_r, body_right, body_back,
		body_axis_y, arms, legs, chest_mat, pelvis_mat, so * Vector3(0, 0, 0))

## How far to pitch the seated trunk forward so the skull clears what is above (a low bunk). env: nearest_surface.
## Smoothed (half-life 0.25 s) so a change of seat or ceiling never snaps.
func duck_for(dt: float, seat: Transform3D, env: Dictionary) -> float:
	var q = env.get("nearest_surface")
	var need := 0.0
	if q != null:
		var so := _ortho(seat)
		var pelvis := so * Vector3(0, PELV_UP, 0.02)
		var X := so.basis.x
		var a := 0.0
		while a <= 1.0:
			var rb := Basis(X, -a)
			var skull: Vector3 = pelvis + rb * (so.basis.y * 0.66 - so.basis.z * 0.05)
			var hit: Dictionary = q.call(skull, 0.15, null)
			if hit.is_empty() or hit.dist > 0.13:
				break
			a += 0.05
		need = minf(a, 1.0)
	if not duck_init:
		duck.reset(need)
		duck_init = true
	return maxf(0.0, duck.step(need, 0.25, clampf(dt, 0.0001, 0.05)))

## The lying pose (Thalassa 'bunk'). lie: mattress top centre, -Z toward the pillow, +Y up; pillow: pillow top centre.
## o: look_yaw (roll the head left / right), look_pitch.
func solve_lie(dt: float, lie: Transform3D, pillow: Transform3D, t: float, o := {}) -> Dictionary:
	var sdt := clampf(dt, 0.0001, 0.05)
	var breath := sin(t * 1.15) * 0.0075
	var ln := _lean(sdt)
	var lo := _ortho(lie)
	var P := func(x: float, y: float, z: float) -> Vector3: return lo * Vector3(x, y, z)
	var pelv_t: Vector3 = P.call(-0.04, 0.090, -0.08)
	var waist_t: Vector3 = P.call(-0.04 + ln.x * 0.12, 0.104 + breath * 0.4, -0.28)
	var chest_t: Vector3 = P.call(-0.04 + ln.x * 0.20, 0.148 + breath, -0.50)
	var neck_t: Vector3 = P.call(-0.04 + ln.x * 0.24, 0.214 + breath * 0.6, -0.66)
	var U := lo.basis.y
	var Lx := lo.basis.x                # her left
	var pelvis := pelv_t
	var waist := pelvis + (waist_t - pelv_t).normalized() * PELVIS_W
	var rb := Basis(Lx, incline)        # pillow guard incline (raises the upper body)
	var chest := waist + rb * (chest_t - waist_t).normalized() * WAIST_C
	var neck_a: Vector3 = chest + rb * (neck_t - chest_t).normalized() * rig.NECK_LEN
	var spine := (neck_a - pelvis).normalized()
	var right := U.cross(spine).normalized()
	var belly := spine.cross(right).normalized()
	var body_back := -belly
	var cay := (neck_a - waist).normalized()
	var cx := cay.cross(body_back).normalized()
	var cz := cx.cross(cay)
	# head: roll left / right with the look, pitch toward the feet / the headboard
	var ly: float = o.get("look_yaw", 0.0)
	var lp: float = o.get("look_pitch", 0.0)
	var look := ((belly * cos(ly) - right * sin(ly)) * cos(lp) + spine * sin(lp)).normalized()
	var head := _head(lie_head, sdt, chest, neck_a, cx, cay, -cz, look,
		{"maxYaw": 1.15, "minPitch": -0.34, "maxPitch": 0.56, "neckPitchShare": 0.28, "neckHalflife": 0.11})
	# FIX pillow guard (Thalassa: analytical pillow-surface occiput clearance): raise the upper body about the waist
	var pen := _pillow_pen(head.headMat, lo, pillow)
	if pen.x > 0.0005:
		var da: float = pen.x / maxf(0.15, pen.y) * 1.05
		incline += da
		var r2 := Basis(Lx, da)
		chest = waist + r2 * (chest - waist)
		neck_a = waist + r2 * (neck_a - waist)
		var hm: Transform3D = head.headMat
		head.headMat = Transform3D(r2 * hm.basis, waist + r2 * (hm.origin - waist))
		head.neckPos = waist + r2 * (head.neckPos - waist)
		head.headPos = waist + r2 * (head.headPos - waist)
		head.headFwd = r2 * head.headFwd
		cay = (neck_a - waist).normalized()
		cx = cay.cross(body_back).normalized()
		cz = cx.cross(cay)
	var chest_mat := BM.basis_xf(chest, cx, cay, cz)
	var pay := (waist - pelvis).normalized()
	var px := pay.cross(body_back).normalized()
	var pelvis_mat := BM.basis_xf(pelvis, px, pay, px.cross(pay))
	var shoulder_l: Vector3 = chest - right * rig.shoulder_half_w + belly * 0.008
	var shoulder_r: Vector3 = chest + right * rig.shoulder_half_w + belly * 0.008
	var hip_l: Vector3 = pelvis - right * rig.hip_half_w
	var hip_r: Vector3 = pelvis + right * rig.hip_half_w
	# calm arms flat on the mattress beside the hips (her left hand on the +x side)
	var arms := {}
	for side in [-1.0, 1.0]:
		var sh: Vector3 = shoulder_l if side < 0.0 else shoulder_r
		var h: Vector3 = P.call(0.21, 0.048, -0.10) if side < 0.0 else P.call(-0.26, 0.048, -0.14)
		var pl: Vector3 = P.call(0.28, 0.065, -0.40) if side < 0.0 else P.call(-0.30, 0.065, -0.42)
		var ik := BM.two_bone(sh, h, pl, rig.upper_arm_len, rig.forearm_len, 0.985, 0.05, 136.0)
		var fd: Vector3 = (ik.eff - ik.mid).normalized()
		var zb: Vector3 = (belly * 0.85 + right * (side * 0.32)).normalized()
		var xa := fd.cross(zb).normalized()
		arms[side] = {"ik": ik, "mat": BM.basis_xf(ik.eff, xa, fd, xa.cross(fd))}
	# relaxed legs along the mattress, soft knee bend
	var legs := {}
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hip: Vector3 = hip_l if side < 0.0 else hip_r
		var foot: Vector3 = P.call(-0.04 + (0.11 if side < 0.0 else -0.12), 0.062, 0.58 if side < 0.0 else 0.52)
		var solved := BM.leg(hip, foot, side, -spine, belly, rig.thigh_len, rig.shin_len, {
			"softReach": 0.990, "softMargin": 0.05, "minFlexDeg": 8.0, "maxFlexDeg": 112.0,
			"maxHipExtDeg": 14.0, "maxHipFlexDeg": 102.0, "kneeOutBias": 0.08, "kneeLiftBias": 0.09, "anklePitchRad": -0.24})
		legs[i] = {"ik": solved.ik, "finMat": solved.finMat, "finDir": solved.finDir}
	return _pack("rest_lie", "bunk", head, chest, waist, pelvis, shoulder_l, shoulder_r, hip_l, hip_r, right, body_back,
		spine, arms, legs, chest_mat, pelvis_mat, P.call(-0.04, 0.06, 0.56))

## Deepest skull probe under the pillow / mattress surface (x) and its distance from the waist along the bed (y).
func _pillow_pen(head_mat: Transform3D, lo: Transform3D, pillow: Transform3D) -> Vector2:
	var inv := lo.affine_inverse()
	var pq := inv * pillow.origin
	var worst := Vector2(0.0, 0.3)
	for pr in SKULL_PROBES:
		var q: Vector3 = inv * (head_mat * pr)
		var surf := 0.008
		if absf(q.x - pq.x) < PILLOW_HALF.x + 0.02 and absf(q.z - pq.z) < PILLOW_HALF.y + 0.02:
			surf = pq.y + 0.008
		if q.y < surf and surf - q.y > worst.x:
			worst = Vector2(surf - q.y, absf(q.z - (-0.28)))
	return worst

func _pack(mode: String, kind: String, head: Dictionary, chest: Vector3, waist: Vector3, pelvis: Vector3, shl: Vector3, shr: Vector3,
		hl: Vector3, hr: Vector3, right: Vector3, back: Vector3, axis_y: Vector3, arms: Dictionary, legs: Dictionary,
		chest_mat: Transform3D, pelvis_mat: Transform3D, foot_center: Vector3) -> Dictionary:
	var al: Dictionary = arms[-1.0].ik
	var fore: Vector3 = (al.eff - al.mid).normalized()
	var to: Vector3 = al.mid.lerp(al.eff, 0.58) + axis_y * 0.036
	var tx := fore.cross(axis_y).normalized()
	if tx.length() < 0.5: tx = right
	return {"mode": mode, "restKind": kind, "footCenter": foot_center,
		"neckPos": head.neckPos, "chestPos": chest, "waistPos": waist, "pelvisPos": pelvis,
		"clavicleL": chest.lerp(shl, 0.45), "clavicleR": chest.lerp(shr, 0.45),
		"shoulderL": shl, "shoulderR": shr, "hipL": hl, "hipR": hr,
		"bodyRight": right, "bodyBack": back, "bodyAxisY": axis_y,
		"armL": al, "armR": arms[1.0].ik, "legL": legs[0], "legR": legs[1],
		"chestMat": chest_mat, "pelvisMat": pelvis_mat, "headMat": head.headMat,
		"handLMat": arms[-1.0].mat, "handRMat": arms[1.0].mat, "torchMat": BM.basis_xf(to, tx, fore, tx.cross(fore)),
		"headMotion": {"pos": head.headPos, "fwd": head.headFwd, "neckYaw": head.neckYaw, "neckPitch": head.neckPitch},
		"holdW": 1.0}
