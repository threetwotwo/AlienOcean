## M04 ride pose 0.1.0 (rest-ride thread, 28 Nov 2026): port of Thalassa v20.19 core/ik-poses-world.js
## ikSolveCreatureRidePose ("gentle megafauna hitchhiking"): a GRIP model. The hands reach for and hold the creature's
## grab points (dorsal fin flanks, pectoral fin leading edges, the back / shell rim) through latch, ride and release;
## the body hangs from the grips in a gimballed, horizon-damped frame (trail, hover, heave, lateral drift, a travelling
## spine wave), the legs trail in the wake, the head stays level. The grips come from the blockout creature
## stand-in's markers (blockout/blockout_rider.gd, Thalassa getCreatureGripWorld slots) instead of Thalassa meshes.
## Classes (Thalassa's per-kind flags): "fin" = dolphin dorsal (both flanks, centred, streamlined), "flank" = whale
## shark dorsal / tail (tilted along one flank), "side" = pectoral fin leading edge, "top" = manta chevron, turtle
## rim, humpback hump. The humpback (not in Thalassa) takes the whale shark's amplitudes.
## Differences, each marked FIX / ADAPT where it happens:
## - FIX palm: Thalassa offsets the wrist 2.6-4.4 cm behind the grip per creature along the grip tangent, then turns
##   the hand off that tangent: the palm missed the grip by up to 1 cm. One palm (the mannequin's, 4 cm along the
##   hand), the wrist placed back from the grip along the hand's own final direction;
## - ADAPT surface: the creature's live surface (Thalassa queryCreatureSurface) is the stand-in's body (its swimming
##   ellipsoid sections and the manta's wings), joined with the world's;
## - the brain is not asked here (the swim pose kept live underneath already steps it once a tick).
extends RefCounted

const BM := preload("res://core/m04_body/body_math.gd")
const PALM := 0.040            # wrist to palm centre along the hand (the mannequin's palm pad)

var rig
var gimbal_roll = BM.CritSpring1D.new()
var gimbal_pitch = BM.CritSpring1D.new()
var drift_lat = BM.CritSpring1D.new()
var heave = BM.CritSpring1D.new()
var trail = BM.CritSpring1D.new()
var head_yaw = BM.CritSpring1D.new()
var head_pitch = BM.CritSpring1D.new()
var head_roll = BM.CritSpring1D.new()
var grip_inert_l = BM.Inertializer3D.new(0.17)
var grip_inert_r = BM.Inertializer3D.new(0.17)
var hand_loc_l = BM.CritSpring3D.new()
var hand_loc_r = BM.CritSpring3D.new()
var pole_loc_l = BM.CritSpring3D.new()
var pole_loc_r = BM.CritSpring3D.new()
var key := ""
var prev_yaw := NAN
var yaw_rate := 0.0
var last_grips := {}

func _init(r) -> void:
	rig = r

## Thalassa resetRideSprings + the grip inertializers' capture from the swim pose's hands (startCreatureRide)
func begin(swim_pose, sv: Vector3, grip_l: Vector3, grip_r: Vector3) -> void:
	for sp in [head_yaw, head_pitch, gimbal_roll, gimbal_pitch, drift_lat, heave, trail, head_roll]:
		sp.reset(0.0, 0.0)
	if swim_pose != null:
		grip_inert_l.trigger(swim_pose.armL.eff, sv, grip_l)
		grip_inert_r.trigger(swim_pose.armR.eff, sv, grip_r)
	key = ""
	prev_yaw = NAN
	yaw_rate = 0.0

static func quintic(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)

# ---------------------------------------------------------------- the creature's live surface (ADAPT surface)
## Signed distance to the stand-in's body near p: {dist, normal, point} (dist < 0 inside), {} when far.
static func creature_surface(rd, p: Vector3, r: float) -> Dictionary:
	return rd.surface(p, r) if rd.has_method("surface") else {}

## The no-clip env for the ride: the world's surfaces and the creature's, nearest first.
static func ride_env(rd, env: Dictionary) -> Dictionary:
	var wq = env.get("nearest_surface")
	var solid = env.get("point_solid")
	var near := func(p: Vector3, r: float, filter = null) -> Dictionary:
		var a: Dictionary = wq.call(p, r, filter) if wq != null else {}
		var b := creature_surface(rd, p, r)
		if not b.is_empty() and b.dist > r: b = {}
		if a.is_empty(): return b
		if b.is_empty(): return a
		return b if b.dist < a.dist else a
	var inside := func(p: Vector3) -> bool:
		if solid != null and solid.call(p): return true
		var b := creature_surface(rd, p, 0.0)
		return not b.is_empty() and b.dist < 0.0
	return {"floor_height": env.get("floor_height"), "nearest_surface": near, "point_solid": inside}

# ---------------------------------------------------------------- grips
## Thalassa getCreatureGripWorld: {pos, normal, tangentFwd} per hand. The position is the stand-in's marker; the
## palm normal and finger direction are Thalassa's per-kind socket vectors (creature right / up / back axes).
static func grip(rd, sl: String, cls: String, side: int, ride_side: int) -> Dictionary:
	var tf: Transform3D = rd.global_transform
	var R := tf.basis.x.normalized()
	var U := tf.basis.y.normalized()
	var B := tf.basis.z.normalized()
	var part := "hand_l" if side < 0 else "hand_r"
	var nm := part if sl == "saddle" else "%s_%s" % [sl, part]
	var pos: Vector3 = rd.marker(nm).origin
	var nl := Vector3(0, 1, 0)
	var tl := Vector3(0, 0, -1)
	match cls:
		"fin":
			nl = Vector3(side * 0.96, 0.20, -0.14); tl = Vector3(-side * 0.08, 0.14, -0.99)
		"side":
			var fs := -1.0 if sl.ends_with("left") else 1.0
			nl = Vector3(fs * 0.14, 0.84, -0.52); tl = Vector3(fs * 0.06, -0.52, -0.85)
		"flank":
			var upper := side * ride_side < 0
			nl = Vector3(ride_side * (0.44 if upper else 0.76), 0.16, -0.88 if upper else -0.63)
			tl = Vector3(-ride_side * (0.86 if upper else 0.56), 0.22, -0.46 if upper else -0.80)
	var n := (R * nl.x + U * nl.y + B * nl.z).normalized()
	var tr := (R * tl.x + U * tl.y + B * tl.z).normalized()
	var tf_ := (tr - n * tr.dot(n)).normalized()
	return {"pos": pos, "normal": n, "tangentFwd": tf_}

# ---------------------------------------------------------------- the pose
## act: core/m02_motor/body_act.gd (phase latch / ride / release, u(), rider, slot, slot_class, ride_side, anchor).
## s: the swimmer (eye, yaw, pitch). env: the world no-clip env. Returns the pose dictionary.
func solve(dt: float, act, s, total_time: float, env: Dictionary) -> Dictionary:
	var sdt := clampf(dt, 0.0001, 0.05)
	var rd = act.rider
	var species := String(rd.species)
	var sl: String = act.slot
	var cls: String = act.slot_class
	var tf: Transform3D = rd.global_transform
	var c_fwd := -tf.basis.z.normalized()
	var c_right := tf.basis.x.normalized()
	var c_up := tf.basis.y.normalized()
	var is_manta := species == "manta"
	var is_dolphin := cls == "fin"
	var is_whale := species == "whale_shark" or species == "humpback"
	var is_tail := is_whale and sl == "tail"
	var is_vfin := cls == "fin" or cls == "flank"
	var is_side := cls == "side"
	var is_flank := cls == "flank"
	var phase: String = act.phase
	var pt: float = act.u()
	var release_w := quintic(pt) if phase == "release" else 0.0
	var latch_w := quintic(pt) if phase == "latch" else (1.0 - release_w if phase == "release" else 1.0)
	var surf := ride_env(rd, env)
	var cv: Vector3 = rd.velocity
	var c_spd := cv.length()
	var spd_n := clampf(c_spd / 5.2, 0.28, 1.25)
	var omega: float = rd.omega if rd.omega > 0.0 else 1.9
	var wing_ph: float = omega * rd.t
	var heave_amp := 0.062 if is_dolphin else (0.048 if is_manta else (0.022 if is_whale else 0.028))
	var wave_pitch_amp := 0.058 if is_dolphin else (0.048 if is_manta else (0.020 if is_whale else 0.032))
	var c_roll := asin(clampf(c_right.y, -1.0, 1.0))
	var c_pitch := asin(clampf(c_fwd.y, -1.0, 1.0))
	var c_yaw := atan2(-c_fwd.x, -c_fwd.z)
	if is_finite(prev_yaw) and sdt > 1e-4:
		yaw_rate = lerpf(yaw_rate, clampf(wrapf(c_yaw - prev_yaw, -PI, PI) / sdt, -3.0, 3.0), BM.expk(10.0, sdt))
	prev_yaw = c_yaw

	# 1. gimbal suspension
	var fin_side := (-1.0 if sl.ends_with("left") else 1.0) if is_side else 0.0
	var ride_side: float = act.ride_side
	var flank_tilt := 0.92 if is_tail else (0.86 if is_flank else 0.0)
	var fin_side_tilt := 0.0
	if is_side: fin_side_tilt = -fin_side * 0.16 * (1.0 - release_w)
	elif is_flank: fin_side_tilt = -ride_side * flank_tilt * (1.0 - release_w)
	var want_roll := clampf(-c_roll * 0.44 + fin_side_tilt + sin(wing_ph * 0.5) * 0.024, -1.18, 1.18)
	var sm_roll: float = gimbal_roll.step(want_roll, 0.24, sdt)
	var base_pitch := -0.04 if is_flank else (-0.05 if is_side else -0.07)
	var want_pitch := clampf(base_pitch + release_w * 0.22 + sin(wing_ph - 0.65) * wave_pitch_amp - c_pitch * 0.12, -0.20, 0.24)
	var sm_pitch: float = gimbal_pitch.step(want_pitch, 0.24, sdt)
	var want_drift := clampf(-yaw_rate * (0.22 if is_dolphin else (0.20 if is_manta else 0.11)) * spd_n, -0.28, 0.28)
	var sm_drift: float = drift_lat.step(want_drift, 0.20 if is_tail else 0.26, sdt)
	var sm_heave: float = heave.step(sin(wing_ph - 0.78) * heave_amp * spd_n + cos(total_time * 1.35) * 0.010, 0.22, sdt)
	var base_trail := 0.31 if is_flank else (0.34 if is_dolphin else (0.34 if is_side else 0.43))
	var sm_trail: float = trail.step(base_trail - sin(wing_ph - 0.35) * (0.018 if is_dolphin else (0.016 if is_manta else 0.010)), 0.20, sdt)
	var rolled_up := (c_up * cos(sm_roll) + c_right * -sin(sm_roll)).normalized()
	var body_axis_y := (c_fwd * cos(sm_pitch) + rolled_up * sin(sm_pitch)).normalized()
	var body_right := body_axis_y.cross(rolled_up).normalized()
	var body_back := body_right.cross(body_axis_y).normalized()
	var spine_down := -body_axis_y
	var gl := grip(rd, sl, cls, -1, act.ride_side)
	var gr := grip(rd, sl, cls, 1, act.ride_side)
	last_grips = {"L": gl, "R": gr}
	var grip_mid: Vector3 = (gl.pos + gr.pos) * 0.5

	# 2. chest suspension, arm-reach envelope, spine wave
	var release_lift := release_w * 0.56
	var base_hover := -0.02 if is_flank else (0.08 if is_dolphin else (0.18 if is_side else (0.27 if is_manta else 0.30)))
	var min_hover := -0.06 if is_flank else (0.04 if is_dolphin else (0.14 if is_side else 0.20))
	var hover_n := (c_up * 0.985 + c_right * (fin_side * 0.17)).normalized() if is_side else c_up
	var stand_off := ride_side * ((0.23 if is_tail else 0.25) + release_w * 0.26) if is_flank else (fin_side * 0.03 if is_side else 0.0)
	var raw_chest: Vector3 = grip_mid + c_fwd * -sm_trail + hover_n * (maxf(min_hover, base_hover + sm_heave * (0.45 if is_dolphin else 1.0)) + release_lift) \
		+ c_right * (sm_drift * 0.22 + stand_off)
	var chest_anchor: Vector3 = raw_chest
	# FIX: Thalassa clamps the chest into the arms' reach only while riding, so the chest popped as the latch ended and
	# the release began; the clamp is faded in with the latch and out with the release
	var reach: float = rig.upper_arm_len + rig.forearm_len
	var gc := chest_anchor - grip_mid
	var gd := gc.length()
	if gd > 1e-4 and (gd < reach * 0.46 or gd > reach * 0.84):
		chest_anchor = chest_anchor.lerp(grip_mid + gc * (clampf(gd, reach * 0.46, reach * 0.84) / gd), latch_w)
	# ADAPT (wide or offset grips, larger creatures): each shoulder between the folded arm (128 deg) and 0.9 of the
	# reach from its own grip, not only the chest from their middle
	for _it in 3:
		for g in [[gl.pos, -1.0], [gr.pos, 1.0]]:
			var shp: Vector3 = chest_anchor + body_right * (g[1] * rig.shoulder_half_w) + body_axis_y * 0.036
			var to: Vector3 = (g[0] as Vector3) - shp
			var dl := to.length()
			if dl < 1e-4: continue
			var want := clampf(dl, reach * 0.50, reach * 0.90)
			chest_anchor += to / dl * (dl - want) * latch_w
	chest_anchor = rig.push_clear(chest_anchor, 0.135, surf, 0.55)     # last: the reach never pushes her into the creature
	var chest_pos: Vector3 = chest_anchor
	if phase == "latch":
		chest_pos = rig.push_clear((s.pos - Vector3(0, 0.14, 0)).lerp(chest_anchor, latch_w), 0.125, surf, 0.55)
	var waist_wave := sin(wing_ph - 1.38) * (0.056 if is_dolphin else (0.044 if is_manta else (0.020 if is_whale else 0.026))) * spd_n
	var pelvis_wave := sin(wing_ph - 2.05) * (0.095 if is_dolphin else (0.078 if is_manta else (0.036 if is_whale else 0.046))) * spd_n
	# FIX spine (as the rest poses): Thalassa's 0.175 / 0.155 ride spine against the standing 0.195 / 0.160
	var raw_waist := chest_pos + spine_down * 0.195 + body_back * (0.032 + waist_wave) + body_right * (sm_drift * 0.40 + cos(wing_ph * 0.5) * 0.015)
	var cl_waist: Vector3 = rig.push_clear(raw_waist, 0.115, surf, 0.55)
	var waist_pos: Vector3 = chest_pos + (cl_waist - chest_pos).normalized() * 0.195
	var raw_pelvis := waist_pos + spine_down * 0.160 + body_back * (0.044 + pelvis_wave) + body_right * (sm_drift * 0.68 + cos(wing_ph * 0.5 - 0.5) * 0.024)
	var cl_pelvis: Vector3 = rig.push_clear(raw_pelvis, 0.125, surf, 0.55)
	var pelvis_pos: Vector3 = waist_pos + (cl_pelvis - waist_pos).normalized() * 0.160
	var neck_anchor := chest_pos + body_axis_y * 0.146 + body_back * 0.032
	var sh_breath := sin(wing_ph - 0.4) * 0.008
	var shoulder_l: Vector3 = chest_pos + body_right * -rig.shoulder_half_w + body_axis_y * (0.036 + sh_breath) + body_back * 0.006
	var shoulder_r: Vector3 = chest_pos + body_right * rig.shoulder_half_w + body_axis_y * (0.036 - sh_breath) + body_back * 0.006
	var chest_axis_y := (neck_anchor - waist_pos).normalized()
	var chest_x := chest_axis_y.cross(body_back).normalized()
	var chest_z := chest_x.cross(chest_axis_y).normalized()
	var chest_mat := BM.basis_xf(chest_pos, chest_x, chest_axis_y, chest_z)
	var pelv_axis_y := (waist_pos - pelvis_pos).normalized()
	var pelv_roll := clampf(-sm_drift * 0.62 + sin(wing_ph * 0.5) * 0.07, -0.20, 0.20)
	var pelv_back0 := (body_back * cos(pelv_roll) + body_right * sin(pelv_roll)).normalized()
	var pelv_x := pelv_axis_y.cross(pelv_back0).normalized()
	var pelv_z := pelv_x.cross(pelv_axis_y).normalized()
	var pelvis_mat := BM.basis_xf(pelvis_pos, pelv_x, pelv_axis_y, pelv_z)
	var hip_l: Vector3 = pelvis_pos + pelv_x * -rig.hip_half_w
	var hip_r: Vector3 = pelvis_pos + pelv_x * rig.hip_half_w

	# 3. horizon-stabilised prone head (third person: between the creature's heading and her look)
	var look_fwd := BM.fwd(s.yaw, clampf(s.pitch, -0.78, 0.96))
	var gaze := (c_fwd.lerp(look_fwd, 0.55)).normalized()
	var ref_fwd := (chest_axis_y * 0.96 + chest_z * -0.22).normalized()
	var ref_right := chest_x
	var ref_up := ref_right.cross(ref_fwd).normalized()
	var g_f := gaze.dot(ref_fwd)
	var g_r := gaze.dot(ref_right)
	var g_u := gaze.dot(ref_up)
	var max_yaw := 0.82
	var r_yaw := atan2(g_r, g_f) if g_f >= 0.12 else (signf(g_r) * max_yaw if absf(g_r) > 0.18 else signf(head_yaw.x if head_yaw.x != 0.0 else 1.0) * 0.45)
	var r_pitch := atan2(g_u, maxf(0.18, Vector2(maxf(0.0, g_f), g_r).length()))
	r_yaw = clampf(r_yaw, -max_yaw, max_yaw)
	r_pitch = clampf(r_pitch, -0.44, 0.42)
	# FIX (stress J4): prone, Thalassa's full 0.42 lift on top of the 13 deg reference tilts the face 101 deg off the
	# chest's front (more when turned); the lift is capped where the face would pass 97 deg (the neck's extension)
	var belly := -chest_z
	var ca_ := cos(r_yaw) * belly.dot(ref_fwd)
	var cb_ := -belly.dot(ref_up)
	var rr := Vector2(ca_, cb_).length()
	if rr > 1e-4:
		var p_max := acos(clampf(-0.122 / rr, -1.0, 1.0)) - atan2(cb_, ca_)
		r_pitch = minf(r_pitch, p_max)
	var sm_y: float = head_yaw.step(r_yaw, 0.15, sdt)
	var sm_p: float = head_pitch.step(r_pitch, 0.15, sdt)
	var h_horiz := (ref_fwd * cos(sm_y) + ref_right * sin(sm_y)).normalized()
	var h_right0 := (ref_right * cos(sm_y) - ref_fwd * sin(sm_y)).normalized()
	var head_fwd := (h_horiz * cos(sm_p) + ref_up * sin(sm_p)).normalized()
	var h_up0 := (ref_up * cos(sm_p) - h_horiz * sin(sm_p)).normalized()
	var wu_r := Vector3.UP.dot(h_right0)
	var wu_u := maxf(0.25, Vector3.UP.dot(h_up0))
	var max_level := 0.72 if is_flank else 0.38
	var level_roll := clampf(atan2(wu_r, wu_u) * (0.78 if is_flank else 0.68), -max_level, max_level)
	var sm_hr: float = head_roll.step(clampf(level_roll - sm_y * 0.035, -(max_level + 0.04), max_level + 0.04), 0.18, sdt)
	var head_x := (h_right0 * cos(sm_hr) + h_up0 * sin(sm_hr)).normalized()
	var head_y := head_x.cross(head_fwd).normalized()
	var neck_pos: Vector3 = rig.push_clear(chest_pos + chest_axis_y * 0.146 + chest_z * (0.032 + maxf(0.0, sm_p) * 0.022) + chest_x * (sin(sm_y) * 0.018), 0.095, surf, 0.35)
	# FIX (stress J2): the neck kept at the standing 0.118 from the chest (Thalassa's ride neck is 0.15 out)
	neck_pos = chest_pos + (neck_pos - chest_pos).normalized() * rig.NECK_LEN
	var head_pos: Vector3 = neck_pos + head_y * -0.008 + head_fwd * -0.004
	var head_mat := BM.basis_xf(head_pos, head_x, head_y, -head_fwd)

	# 4. hands on the grips (Thalassa: surface-tangent, latch reach arc, release peel)
	var release_l: Vector3 = shoulder_l + c_fwd * 0.26 + chest_x * -0.24 + chest_z * 0.16
	var release_r: Vector3 = shoulder_r + c_fwd * 0.26 + chest_x * 0.24 + chest_z * 0.16
	var flat_blend := 1.0
	if phase == "release": flat_blend = 1.0 - quintic(pt / 0.65)
	elif phase == "latch": flat_blend = quintic((pt - 0.35) / 0.55)
	var hand_y_l := _hand_dir(gl, -1, chest_x, is_dolphin)
	var hand_y_r := _hand_dir(gr, 1, chest_x, is_dolphin)
	# FIX palm: the wrist sits PALM back from the grip along the hand's own direction, so the palm is on the grip
	var wrist_l: Vector3 = gl.pos - hand_y_l * PALM
	var wrist_r: Vector3 = gr.pos - hand_y_r * PALM
	var tgt_l := wrist_l
	var tgt_r := wrist_r
	if phase == "latch":
		var gw := quintic((pt - 0.18) / 0.72)
		var arc := sin(gw * PI) * 0.085
		var app_l: Vector3 = shoulder_l + c_fwd * 0.34 + chest_x * -0.22 + chest_z * 0.08
		var app_r: Vector3 = shoulder_r + c_fwd * 0.34 + chest_x * 0.22 + chest_z * 0.08
		tgt_l = app_l.lerp(wrist_l, gw) + gl.normal * arc
		tgt_r = app_r.lerp(wrist_r, gw) + gr.normal * arc
	elif phase == "release":
		var pw := quintic(pt / 0.78)
		var parc := sin(pw * PI) * 0.075
		tgt_l = wrist_l.lerp(release_l, pw) + gl.normal * parc
		tgt_r = wrist_r.lerp(release_r, pw) + gr.normal * parc
	var inert_l: Vector3 = grip_inert_l.evaluate(tgt_l, sdt)
	var inert_r: Vector3 = grip_inert_r.evaluate(tgt_r, sdt)
	# creature-local anti-twitch springs (no world-space lag, wave jitter filtered)
	var to_loc := func(w: Vector3) -> Vector3:
		var d := w - tf.origin
		return Vector3(d.dot(c_right), d.dot(c_up), d.dot(c_fwd))
	var from_loc := func(l: Vector3) -> Vector3: return tf.origin + c_right * l.x + c_up * l.y + c_fwd * l.z
	var flare := (0.30 if is_dolphin else (0.24 if is_vfin else 0.28)) + sin(wing_ph - 0.5) * 0.018
	var pole_d := -0.10 if is_dolphin else (-0.14 if is_vfin else 0.06)
	var raw_pole_l: Vector3 = shoulder_l + chest_x * -flare + chest_z * (pole_d - sm_heave * 0.16) + spine_down * 0.36
	var raw_pole_r: Vector3 = shoulder_r + chest_x * flare + chest_z * (pole_d - sm_heave * 0.16) + spine_down * 0.36
	# FIX: Thalassa springs the hand's creature-local position, which lags the grip as the body's wave moves it (up to
	# 4 cm on a 20 m whale shark); here the spring works on the hand's offset from its grip, so the hand rides the grip
	var ggl: Vector3 = to_loc.call(gl.pos)
	var ggr: Vector3 = to_loc.call(gr.pos)
	var lhl: Vector3 = to_loc.call(inert_l) - ggl
	var lhr: Vector3 = to_loc.call(inert_r) - ggr
	var lpl: Vector3 = to_loc.call(raw_pole_l)
	var lpr: Vector3 = to_loc.call(raw_pole_r)
	var k := "%s_%d_%s" % [species, rd.get_instance_id(), sl]
	if key != k:
		key = k
		hand_loc_l.reset(lhl); hand_loc_r.reset(lhr); pole_loc_l.reset(lpl); pole_loc_r.reset(lpr)
	var hhl := 0.026 if is_dolphin else 0.045
	var phl := 0.105 if is_dolphin else 0.075
	var hand_l: Vector3 = from_loc.call(hand_loc_l.step(lhl, hhl, sdt) + ggl)
	var hand_r: Vector3 = from_loc.call(hand_loc_r.step(lhr, hhl, sdt) + ggr)
	var pole_l: Vector3 = from_loc.call(pole_loc_l.step(lpl, phl, sdt))
	var pole_r: Vector3 = from_loc.call(pole_loc_r.step(lpr, phl, sdt))
	pole_l = _out_pole(shoulder_l, pole_l, -1.0, chest_x)
	pole_r = _out_pole(shoulder_r, pole_r, 1.0, chest_x)
	# FIX: Thalassa drops the arms' no-clip while riding, so the elbow jumped where the latch ended and the release
	# began (on the whale shark's fin, 14-19 m/s); it stays on
	var wr := 0.014 if is_dolphin else 0.030
	var pin_w := 1.0
	if phase == "latch": pin_w = quintic((pt - 0.18) / 0.72)
	elif phase == "release": pin_w = 1.0 - quintic(pt / 0.78)
	var arm_l: Dictionary = rig.solve_noclip_arm(shoulder_l, hand_l, pole_l, surf, {"softReach": 0.965, "softMargin": 0.07, "maxFlexDeg": 128.0, "wristRadius": wr, "elbowRadius": 0.052, "pinW": pin_w})
	var arm_r: Dictionary = rig.solve_noclip_arm(shoulder_r, hand_r, pole_r, surf, {"softReach": 0.965, "softMargin": 0.07, "maxFlexDeg": 128.0, "wristRadius": wr, "elbowRadius": 0.052, "pinW": pin_w})
	var hand_l_mat := _hand_mat(arm_l, hand_y_l, gl, -1, flat_blend, chest_x, chest_z, is_dolphin)
	var hand_r_mat := _hand_mat(arm_r, hand_y_r, gr, 1, flat_blend, chest_x, chest_z, is_dolphin)

	# 5. legs trailing in the wake, softly pointed feet
	var wake_ph := wing_ph - 1.55
	var pelv_down := -pelv_axis_y
	var pelv_belly := -pelv_z
	var legs := {}
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hip: Vector3 = hip_l if side < 0.0 else hip_r
		var sph := wake_ph + (0.92 if side > 0.0 else 0.0)
		var wake_amp := 0.25 if is_dolphin else (0.23 if is_manta else (0.18 if is_whale else 0.20))
		var wake := (sin(sph) * 0.78 + sin(sph * 0.52 + 1.15) * 0.28) * wake_amp * maxf(0.45, spd_n)
		var lat_wave := cos(sph * 0.68) * 0.068 + sin(sph * 0.36 + side * 0.8) * 0.036
		var lat := side * 0.105 + lat_wave + sm_drift * 1.95
		var ext: float = (rig.thigh_len + rig.shin_len) * 0.955
		var raw_ankle: Vector3 = hip + pelv_down * ext + pelv_z * ((0.12 if is_flank else 0.19) + wake) + pelv_x * lat
		var lag := sin(sph - 0.85) * 0.75 + sin(sph * 0.52 + 0.30) * 0.25
		var solved: Dictionary = rig.solve_noclip_leg(hip, raw_ankle, side, pelv_down, pelv_belly, surf, {
			"softReach": 0.985, "softMargin": 0.07, "minFlexDeg": 11.0, "maxFlexDeg": 84.0,
			"maxHipExtDeg": 18.0, "maxHipFlexDeg": 74.0, "maxAdductionDeg": 5.5, "maxAbductionDeg": 32.0, "kneeOutBias": 0.08,
			"anklePitchRad": -(0.88 + lag * 0.28 + spd_n * 0.14), "ankleRollRad": side * 0.09 + sm_drift * 0.48 + cos(sph - 0.55) * 0.16,
			"ankleYawRad": -side * 0.06 + sin(sph * 0.64 - 0.70) * 0.13,
			"minAnklePitchRad": -1.30, "maxAnklePitchRad": 0.25, "maxAnkleRollRad": 0.30, "maxAnkleYawRad": 0.24})
		legs[i] = {"ik": solved.ik, "finMat": solved.finMat, "finDir": solved.finDir}

	var fore: Vector3 = (arm_l.eff - arm_l.mid).normalized()
	var to: Vector3 = arm_l.mid.lerp(arm_l.eff, 0.72) + chest_z * 0.036
	var tx := fore.cross(chest_z).normalized()
	return {
		"mode": "ride_" + phase, "ridingCreature": species, "rideSlot": sl,
		"neckPos": neck_pos, "chestPos": chest_pos, "waistPos": waist_pos, "pelvisPos": pelvis_pos,
		"clavicleL": chest_pos.lerp(shoulder_l, 0.45), "clavicleR": chest_pos.lerp(shoulder_r, 0.45),
		"shoulderL": shoulder_l, "shoulderR": shoulder_r, "hipL": hip_l, "hipR": hip_r,
		"bodyRight": chest_x, "bodyBack": chest_z, "bodyAxisY": chest_axis_y,
		"armL": arm_l, "armR": arm_r, "legL": legs[0], "legR": legs[1],
		"chestMat": chest_mat, "pelvisMat": pelvis_mat, "headMat": head_mat, "handLMat": hand_l_mat, "handRMat": hand_r_mat,
		"torchMat": BM.basis_xf(to, tx, fore, tx.cross(fore)),
		"headMotion": {"pos": head_pos, "fwd": head_fwd, "neckYaw": sm_y, "neckPitch": sm_p},
		"bodyPitch": 0.0, "swimBlend": 1.0, "reverseBlend": 0.0, "braceL": 1.0, "braceR": 1.0, "impactEnergy": 0.0,
		"lightButtonReach": 0.0, "holdW": latch_w * (1.0 - release_w),
		"grips": {"L": gl.pos, "R": gr.pos}, "palm": PALM,
	}

## The hand's finger direction on the grip (Thalassa buildRideHand rawTan / flatDir)
static func _hand_dir(g: Dictionary, side: int, chest_x: Vector3, dolphin: bool) -> Vector3:
	var raw: Vector3 = g.tangentFwd if dolphin else (g.tangentFwd * 0.94 + chest_x * (-side * 0.22)).normalized()
	var n: Vector3 = g.normal
	return (raw - n * raw.dot(n)).normalized()

static func _out_pole(sh: Vector3, pole: Vector3, side: float, chest_x: Vector3) -> Vector3:
	var od := (pole - sh).dot(chest_x) * side
	return pole + chest_x * (side * (0.16 - od)) if od < 0.16 else pole

## Thalassa buildRideHand: flat on the grip, fingers along it (blended from the forearm while reaching / peeling)
static func _hand_mat(ik: Dictionary, flat_dir: Vector3, g: Dictionary, side: int, flat_blend: float, chest_x: Vector3, chest_z: Vector3, dolphin: bool) -> Transform3D:
	var fore: Vector3 = (ik.eff - ik.mid).normalized()
	var hy := fore.lerp(flat_dir, flat_blend).normalized()
	var n: Vector3 = g.normal
	var zb := (n * 0.98 + chest_z * 0.06).normalized() if dolphin else (n * 0.96 + chest_x * (side * 0.14)).normalized()
	var xa := hy.cross(zb).normalized()
	return BM.basis_xf(ik.eff, xa, hy, xa.cross(hy))
