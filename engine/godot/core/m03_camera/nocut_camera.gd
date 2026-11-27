## M03 No-cut camera, core 0.2.0: GDScript port of Gary's Thalassa v20.19 core/cinematic-camera.js
## (NoCutCinematicCamera.updateForActor + Living Observer + binary-refined spring arm) and the critically damped
## springs from procedural-locomotion.js. One continuous camera: third person over the shoulder <-> first person by
## blending toward the eye (thirdPerson flag, morphRate 9/s), anchor-relative springs (no lag at speed), rigid lock
## once in first person. Logic and tuning line for line; checked against the JS by tests/test_golden_camera.gd.
## env (all optional): floor_height(x, z) -> float, colliders: Array of {x, y, z, r}, nearest_surface(p, r) -> {dist}.
## Not ported here: the multi-vessel orchestrator update() (helm, Pelagos exterior, rides): arrives with M09.
extends RefCounted

const LN2 := 0.6931471805599453

class Spring1:
	var x := 0.0
	var v := 0.0
	func _init(i: float = 0.0) -> void: x = i
	func reset(val: float = 0.0, vel: float = 0.0) -> void: x = val; v = vel
	func impulse(dv: float) -> void: v += dv
	func step(goal: float, halflife: float, dt: float, v_goal: float = 0.0) -> float:
		var h := maxf(1e-4, halflife)
		var y := (4.0 * 0.6931471805599453) / h
		var j0 := x - goal
		var j1 := v + j0 * y
		var e := exp(-y * dt)
		x = e * (j0 + j1 * dt) + goal
		v = e * (v - j1 * y * dt) + v_goal * (1.0 - e)
		return x

class Spring3:
	var sx := Spring1.new(); var sy := Spring1.new(); var sz := Spring1.new()
	func _init(i: Vector3 = Vector3.ZERO) -> void: reset(i)
	var x: Vector3:
		get: return Vector3(sx.x, sy.x, sz.x)
		set(p): sx.x = p.x; sy.x = p.y; sz.x = p.z
	var v: Vector3:
		get: return Vector3(sx.v, sy.v, sz.v)
		set(p): sx.v = p.x; sy.v = p.y; sz.v = p.z
	func reset(p: Vector3 = Vector3.ZERO, vel: Vector3 = Vector3.ZERO) -> void:
		sx.reset(p.x, vel.x); sy.reset(p.y, vel.y); sz.reset(p.z, vel.z)
	func step(goal: Vector3, halflife: float, dt: float) -> Vector3:
		return Vector3(sx.step(goal.x, halflife, dt), sy.step(goal.y, halflife, dt), sz.step(goal.z, halflife, dt))

var config := {
	"offset_halflife": 0.068, "look_offset_halflife": 0.042, "up_halflife": 0.11, "fov_halflife": 0.14,
	"roll_halflife": 0.11, "transition_offset_halflife": 0.072, "morph_rate": 9.0,
	"response_scale": 1.0, "observer_subtlety": 1.0, "ots_dist_scale": 1.0,
}

var initialized := false
var offset_spring := Spring3.new()
var look_offset_spring := Spring3.new(Vector3(0, 0, -5.2))
var up_spring := Spring3.new(Vector3.UP)
var fov_spring := Spring1.new(74.0)
var roll_spring := Spring1.new()
var arm_spring := Spring1.new(1.0)
var carve_lead_spring := Spring1.new()
var _last_anchor_pos = null
var _last_anchor_key = null
var _was_rigid_1p := false
# Living Observer
var observer_breath_phase := 0.27
var observer_still_time := 0.0
var stillness_spring := Spring1.new()
var lead_room_spring := Spring1.new()
var shared_focus_spring := Spring1.new()
var shared_focus_dir_spr := Spring3.new()
var head_gaze_yaw_spr := Spring1.new()
var head_gaze_pitch_spr := Spring1.new()
var head_pos_y_spr := Spring1.new()
var head_pos_lat_spr := Spring1.new()
var landing_settle_spring := Spring1.new()
var _prev_landing_impact := 0.0
var _prev_base_yaw = null
var _prev_base_pitch = null
var _smooth_yaw_rate := 0.0
var _smooth_pitch_rate := 0.0

var pos := Vector3(0, -6.5, 16.5)
var look := Vector3(0, -6.5, 11.0)
var up := Vector3.UP
var fov := 74.0
var roll := 0.0
var third_person_blend := 1.0
var arm_pull := 1.0
var enclosure_factor := 0.0
var head_dist := 1.4
var show_head := true
var hide_self_body := false
var active_shot := "swim_ots"
var last_mode := "swim"
var cut_count := 0

static func exp_k(rate: float, dt: float) -> float:
	return 1.0 - exp(-maxf(0.0, rate * dt))

static func forward(y: float, p: float) -> Vector3:
	return Vector3(-sin(y) * cos(p), sin(p), -cos(y) * cos(p))

static func right_of(y: float) -> Vector3:
	return Vector3(cos(y), 0.0, -sin(y))

static func _norm(v: Vector3) -> Vector3:
	var l := v.length()
	return v / (l if l > 0.0 else 1.0)

static func soft_min_bound(val: float, min_val: float, knee: float = 0.16) -> float:
	var d := val - min_val
	if d >= knee: return val
	if d <= -knee: return min_val
	var u := (d + knee) / (2.0 * knee)
	return min_val + knee * u * u

static func soft_max_bound(val: float, max_val: float, knee: float = 0.16) -> float:
	return -soft_min_bound(-val, -max_val, knee)

const DEFAULT_PROFILE := {"dist": 1.38, "dist_speed_add": 0.24, "dist_boost_add": 0.14, "shoulder_x": 0.24,
	"shoulder_y": 0.11, "look_ahead": 6.2, "ots_fov": 74.0, "ots_fov_speed_add": 3.5, "fp_fov_cap": 84.0,
	"ots_roll_scale": 0.32, "ots_level_up": 0.85, "carve_lead_scale": 0.14, "head_hide_dist": 0.25}

## contracts.js createActorFrame: fills fwd / right / up and defaults.
static func actor_frame(spec: Dictionary) -> Dictionary:
	var f := spec.duplicate()
	var y: float = spec.get("yaw", 0.0); var p: float = spec.get("pitch", 0.0); var r: float = spec.get("roll", 0.0)
	f.pos = spec.get("pos", Vector3.ZERO); f.vel = spec.get("vel", Vector3.ZERO)
	f.yaw = y; f.pitch = p; f.roll = r
	var fwd: Vector3 = _norm(spec.fwd) if spec.has("fwd") else forward(y, p)
	var raw_r: Vector3 = _norm(spec.right) if spec.has("right") else right_of(y)
	var base_up := _norm(raw_r.cross(fwd))
	var u: Vector3 = _norm(spec.up) if spec.has("up") else _norm(base_up * cos(r) + raw_r * sin(r))
	f.fwd = fwd; f.up = u; f.right = _norm(fwd.cross(u))
	f.speed = spec.get("speed", f.vel.length())
	f.fp_pos = spec.get("fp_pos", f.pos); f.head_pos = spec.get("head_pos", f.fp_pos)
	var ms: float = spec.get("max_speed", 6.2)
	f.max_speed = ms if ms > 0.1 else 6.2
	f.fov = spec.get("fov", 74.0); f.radius = spec.get("radius", 1.0); f.is_boosting = spec.get("is_boosting", false)
	f.keep_under_surface = spec.get("keep_under_surface", false); f.surface_ceiling_y = spec.get("surface_ceiling_y", -0.30)
	f.floor_margin = spec.get("floor_margin", 0.44)
	var prof := DEFAULT_PROFILE.duplicate()
	prof.merge(spec.get("camera_profile", {}), true)
	f.camera_profile = prof
	f.kind = spec.get("kind", "generic"); f.id = spec.get("id", "actor")
	return f

func _step_living_observer(dt: float, o: Dictionary) -> Dictionary:
	var sdt := clampf(dt, 0.0001, 0.05)
	observer_breath_phase = fmod(observer_breath_phase + 0.21 * sdt, 1.0)
	var bp := observer_breath_phase
	var raw_breath := (0.5 - 0.5 * cos(PI * (bp / 0.40))) if bp < 0.40 else (0.5 + 0.5 * cos(PI * pow((bp - 0.40) / 0.60, 0.88)))
	var bc := (raw_breath - 0.5) * 2.0
	var b_amp := 1.0
	var speed: float = o.get("speed", 0.0)
	var abs_yaw_r := absf(o.get("yaw_rate", 0.0))
	var abs_pitch_r := absf(o.get("pitch_rate", 0.0))
	var lat_vel: float = o.get("lat_vel", 0.0)
	var a3p := clampf(third_person_blend, 0.0, 1.0)
	if speed < 0.12 and abs_yaw_r < 0.14 and abs_pitch_r < 0.14 and a3p > 0.5:
		observer_still_time = minf(12.0, observer_still_time + sdt)
	else:
		observer_still_time = maxf(0.0, observer_still_time - sdt * 5.0)
	var still_goal := clampf((observer_still_time - 2.2) / 3.4, 0.0, 1.0)
	var stillness := stillness_spring.step(still_goal, 0.22 if still_goal < stillness_spring.x else 0.72, sdt)
	var lead_room := lead_room_spring.step(clampf(lat_vel * 0.028, -0.065, 0.065) * a3p, 0.34, sdt)
	var land_imp: float = o.get("landing_impact", 0.0)
	if land_imp > _prev_landing_impact + 0.18:
		landing_settle_spring.impulse(-0.075 * clampf(land_imp, 0.3, 1.0))
	_prev_landing_impact = land_imp
	var brake_dip: float = -o.get("braking_impulse", 0.0) * 0.004
	var landing_settle := clampf(landing_settle_spring.step(brake_dip, 0.14, sdt), -0.012, 0.006)
	# head-motion sync (needs M04 head solver; zero until then, exactly as the JS without headMotion)
	var head_sync_yaw := head_gaze_yaw_spr.step(0.0, 0.24 if 0.0 < absf(head_gaze_yaw_spr.x) else 0.38, sdt)
	var head_sync_pitch := head_gaze_pitch_spr.step(0.0, 0.24 if 0.0 < absf(head_gaze_pitch_spr.x) else 0.38, sdt)
	var head_sync_y := head_pos_y_spr.step(0.0, 0.22, sdt)
	var head_sync_lat := head_pos_lat_spr.step(0.0, 0.28, sdt)
	var shared_mag := clampf(Vector2(head_sync_yaw, head_sync_pitch).length() / 0.050, 0.0, 1.0)
	var shared := shared_focus_spring.step(shared_mag, 0.28, sdt)
	var base_right: Vector3 = o.get("base_right", Vector3.ZERO); var base_up: Vector3 = o.get("base_up", Vector3.ZERO)
	var raw_nudge := base_right * head_sync_yaw + base_up * head_sync_pitch
	var focus_nudge := shared_focus_dir_spr.step(raw_nudge, 0.18, sdt)
	var s: float = clampf(config.observer_subtlety, 0.0, 1.5)
	var breath_y := (bc * 0.0074 * b_amp * 1.0 * a3p + head_sync_y) * s
	var head_look_x := clampf(head_sync_yaw * 0.58, -0.030, 0.030)
	var breath_x := (sin(bp * PI * 2.0) * 0.0024 * b_amp * a3p + head_sync_lat + head_look_x) * s
	var breath_roll := bc * 0.0018 * b_amp * a3p * s
	return {"breath_x": breath_x, "breath_y": breath_y, "breath_roll": breath_roll, "stillness": stillness * s,
		"lead_room": lead_room * s, "shared": shared * s, "focus_nudge": focus_nudge * s, "landing_settle": landing_settle * s}

## Binary-refined spring-arm probe: 10 coarse steps + 5 bisections; blocked = floor margin, surface ceiling,
## collider spheres, or the nearest surface within 0.34 m (the Godot adapter answers that one with Jolt).
func _probe_arm(anchor: Vector3, desired: Vector3, env: Dictionary, keep_under: bool, ceiling_y: float) -> Dictionary:
	var d := desired - anchor
	if d.length() < 0.05: return {"safe_t": 1.0, "enclosure": 0.0}
	var has_floor := env.has("floor_height")
	var cols: Array = env.get("colliders", [])
	var has_surf := env.has("nearest_surface")
	if not has_floor and cols.is_empty() and not has_surf and not keep_under: return {"safe_t": 1.0, "enclosure": 0.0}
	var blocked := func(t: float) -> bool:
		var p := anchor + d * t
		if has_floor:
			var fy: float = env.floor_height.call(p.x, p.z)
			if is_finite(fy) and p.y < fy + 0.46: return true
		if keep_under and p.y > ceiling_y: return true
		for c in cols:
			if p.distance_to(Vector3(c.x, c.y, c.z)) < c.r + 0.50: return true
		if has_surf:
			var hit: Dictionary = env.nearest_surface.call(p, 0.34)
			if not hit.is_empty() and hit.dist < 0.34: return true
		return false
	var safe_t := 1.0
	var close_hits := 0.0
	for s in range(1, 11):
		var t := s / 10.0
		var p := anchor + d * t
		for c in cols:
			if p.distance_to(Vector3(c.x, c.y, c.z)) < c.r + 2.1: close_hits += 0.22
		if blocked.call(t):
			var lo := (s - 1) / 10.0
			var hi := t
			for i in 5:
				var mid := (lo + hi) * 0.5
				if blocked.call(mid): hi = mid
				else: lo = mid
			safe_t = maxf(0.14, lo - 0.015)
			close_hits += 1.2
			break
	return {"safe_t": safe_t, "enclosure": clampf(close_hits / 3.2, 0.0, 1.0)}

func _step_arm_pull(desired: float, sdt: float, retract_hl: float = 0.026, recover_hl: float = 0.088) -> float:
	var hl := retract_hl if desired < arm_pull else recover_hl
	arm_pull = clampf(arm_spring.step(desired, hl, sdt), 0.12, 1.0)
	return arm_pull

func _integrate(sdt: float, anchor: Vector3, t_pos: Vector3, t_look: Vector3, t_up: Vector3, t_fov: float, t_roll: float,
		rigid_1p: bool, transitioning: bool, key: String) -> Dictionary:
	var c := config
	var t_off := t_pos - anchor
	var t_look_off := t_look - anchor
	if not initialized or pos.distance_to(t_pos) > 36.0:
		offset_spring.reset(t_off); look_offset_spring.reset(t_look_off); up_spring.reset(t_up)
		fov_spring.reset(t_fov); roll_spring.reset(t_roll)
		pos = t_pos; look = t_look; up = _norm(t_up); fov = t_fov; roll = t_roll
		_last_anchor_pos = anchor; _last_anchor_key = key; initialized = true
	elif _last_anchor_key != key or (_last_anchor_pos != null and anchor.distance_to(_last_anchor_pos) > 3.0):
		offset_spring.x = pos - anchor; offset_spring.v = offset_spring.v * 0.25
		look_offset_spring.x = look - anchor; look_offset_spring.v = look_offset_spring.v * 0.25
		_last_anchor_pos = anchor; _last_anchor_key = key
	else:
		_last_anchor_pos = anchor
	var off_err := offset_spring.x.distance_to(t_off)
	var look_err := look_offset_spring.x.distance_to(t_look_off)
	var can_lock := rigid_1p and not transitioning and off_err < 0.045 and (_was_rigid_1p or look_err < 0.28)
	_was_rigid_1p = can_lock
	if can_lock:
		offset_spring.reset(t_off); look_offset_spring.reset(t_look_off)
		var nu := _norm(t_up)
		up_spring.reset(nu); roll_spring.reset(t_roll)
		pos = t_pos; look = t_look; up = nu
		fov = fov_spring.step(t_fov, c.fov_halflife, sdt)
		roll = t_roll
	else:
		var resp_inv: float = 1.0 / clampf(c.response_scale, 0.5, 2.0)
		var off_hl: float = (c.transition_offset_halflife if transitioning else c.offset_halflife) * resp_inv
		var look_hl: float = (0.030 if transitioning else c.look_offset_halflife) * resp_inv
		pos = anchor + offset_spring.step(t_off, off_hl, sdt)
		look = anchor + look_offset_spring.step(t_look_off, look_hl, sdt)
		up = _norm(up_spring.step(t_up, c.up_halflife, sdt))
		fov = fov_spring.step(t_fov, c.fov_halflife, sdt)
		roll = roll_spring.step(t_roll, c.roll_halflife, sdt)
	var view := _norm(look - pos)
	return {"yaw": atan2(-view.x, -view.z), "pitch": clampf(asin(clampf(view.y, -0.99, 0.99)), -1.48, 1.48)}

## updateForActor. opts: third_person (bool), snap_first_person_on_mode_switch, yaw_rate, landing_impact,
## braking_impulse. Returns {pos, look_target, up, fov, roll, yaw, pitch, show_head, hide_self_body, third_person_blend,
## arm_pull, active_shot}.
func update_for_actor(dt: float, raw_frame: Dictionary, opts: Dictionary = {}, env: Dictionary = {}) -> Dictionary:
	var sdt := clampf(dt, 0.0001, 0.05)
	var f := actor_frame(raw_frame)
	var c := config
	var prof: Dictionary = f.camera_profile
	var want_tp := 1.0 if opts.get("third_person", false) else 0.0
	var mode_key := "%s:%s" % [f.kind, f.id]
	var mode_changed := last_mode != mode_key
	if opts.get("snap_first_person_on_mode_switch", false) and want_tp == 0.0 and mode_changed:
		third_person_blend = 0.0
	else:
		third_person_blend = lerpf(third_person_blend, want_tp, exp_k(c.morph_rate, sdt))
		if absf(third_person_blend - want_tp) < 0.002: third_person_blend = want_tp
	var fp_pos: Vector3 = f.fp_pos
	var fp_look: Vector3 = fp_pos + f.fwd * 5.2
	var anchor: Vector3 = f.pos
	var spd_n := clampf(f.speed / maxf(0.1, f.max_speed), 0.0, 1.0)
	var raw_yaw_rate: float = clampf(wrapf(f.yaw - _prev_base_yaw, -PI, PI) / sdt, -8.0, 8.0) if (_prev_base_yaw != null and not mode_changed) else opts.get("yaw_rate", 0.0)
	var raw_pitch_rate: float = clampf((f.pitch - _prev_base_pitch) / sdt, -8.0, 8.0) if (_prev_base_pitch != null and not mode_changed) else 0.0
	_prev_base_yaw = f.yaw; _prev_base_pitch = f.pitch
	_smooth_yaw_rate = lerpf(_smooth_yaw_rate, raw_yaw_rate, exp_k(18.0, sdt))
	_smooth_pitch_rate = lerpf(_smooth_pitch_rate, raw_pitch_rate, exp_k(18.0, sdt))
	var lat_vel: float = f.vel.dot(f.right)
	var obs := _step_living_observer(sdt, {"speed": f.speed, "yaw_rate": opts.get("yaw_rate", _smooth_yaw_rate),
		"pitch_rate": _smooth_pitch_rate, "lat_vel": lat_vel, "base_right": f.right, "base_up": f.up,
		"landing_impact": opts.get("landing_impact", 0.0), "braking_impulse": opts.get("braking_impulse", 0.0)})
	var breath_x: float = obs.breath_x
	var breath_y: float = obs.breath_y + obs.landing_settle
	var strafe_shift: float = clampf(lat_vel * 0.020, -0.08, 0.08) + obs.lead_room * 0.15
	var carve_lead := carve_lead_spring.step(clampf(lat_vel * prof.carve_lead_scale, -0.38, 0.38), 0.11, sdt)
	var fwd_cam := forward(f.yaw, clampf(f.pitch * 0.94, -1.25, 1.18))
	var steep := clampf((absf(f.pitch) - 0.45) / 0.75, 0.0, 1.0)
	var shoulder_y: float = prof.shoulder_y * lerpf(1.0, 0.42, steep)
	var dist_mul: float = clampf(c.ots_dist_scale, 0.75, 1.45)
	var dyn_dist: float = (prof.dist + spd_n * prof.dist_speed_add + (prof.dist_boost_add if f.is_boosting else 0.0)) * dist_mul - obs.stillness * 0.036
	var pivot: Vector3 = f.pos - Vector3(0, 0.02, 0)
	var raw_ots: Vector3 = pivot - fwd_cam * dyn_dist + f.right * (prof.shoulder_x + strafe_shift + breath_x) + f.up * (shoulder_y + breath_y)
	var pr := _probe_arm(pivot, raw_ots, env, f.keep_under_surface, f.surface_ceiling_y)
	_step_arm_pull(pr.safe_t, sdt, 0.055, 0.18)
	enclosure_factor = lerpf(enclosure_factor, pr.enclosure, exp_k(7.5, sdt))
	var ots_pos := pivot + (raw_ots - pivot) * arm_pull
	if env.has("floor_height"):
		var fy: float = env.floor_height.call(ots_pos.x, ots_pos.z)
		if is_finite(fy): ots_pos.y = soft_min_bound(ots_pos.y, fy + f.floor_margin, 0.16)
	if f.keep_under_surface:
		ots_pos.y = soft_max_bound(ots_pos.y, f.surface_ceiling_y, 0.14)
	var la: float = prof.look_ahead
	var side: Vector3 = f.right * (0.05 + carve_lead)
	side.y = 0.0                                  # the JS leads sideways in x/z only
	var ots_look: Vector3 = pivot + f.fwd * la + side + obs.focus_nudge * la
	ots_look.y -= 0.02
	var b := third_person_blend
	var rigid := b < 0.005
	var t_pos := fp_pos.lerp(ots_pos, b)
	var t_look := fp_look.lerp(ots_look, b)
	var lvl: float = prof.ots_level_up
	var t_up := Vector3(lerpf(f.up.x, 0.0, b * lvl), lerpf(f.up.y, 1.0, b * lvl), lerpf(f.up.z, 0.0, b * lvl))
	var safe_fov: float = minf(prof.fp_fov_cap, f.fov)
	var ots_fov: float = prof.ots_fov + spd_n * prof.ots_fov_speed_add + (2.5 if f.is_boosting else 0.0) - enclosure_factor * 1.8 - obs.stillness * 0.55
	var t_fov := lerpf(safe_fov, ots_fov, b)
	var t_roll := lerpf(f.roll, f.roll * prof.ots_roll_scale + obs.breath_roll, b)
	active_shot = "%s_%s" % [f.kind, "ots" if b > 0.15 else "1p"]
	last_mode = mode_key
	var ang := _integrate(sdt, anchor, t_pos, t_look, t_up, t_fov, t_roll, rigid, mode_changed, mode_key)
	head_dist = pos.distance_to(f.head_pos)
	show_head = third_person_blend > 0.18 and head_dist > minf(0.25, prof.head_hide_dist)
	hide_self_body = third_person_blend > 0.18 and head_dist <= 0.23
	return {"pos": pos, "look_target": look, "up": up, "fov": fov, "roll": roll, "yaw": ang.yaw, "pitch": ang.pitch,
		"show_head": show_head, "hide_self_body": hide_self_body, "third_person_blend": third_person_blend,
		"arm_pull": arm_pull, "active_shot": active_shot}
