## M02 Swimmer locomotion, core 0.2.0: GDScript port of Gary's Thalassa v20.19 core/swimmer-physics.js
## (SwimmerLocomotion / Swimmer6DOF). Logic, tuning and behaviour are kept line for line; only the language and the
## seams changed. pos is the EYE point (as in Thalassa). Engine-agnostic: the adapter hands in an env dictionary of
## Callables (all optional, Thalassa's NULL_ENV defaults apply when missing):
##   floor_height(x, z) -> float (or -INF)      terrain_normal(x, z) -> Vector3
##   local_surface(pos) -> {enclosed: bool, surface_y: float} or {}   water_current(pos, t) -> Vector3
##   resolve_collisions(pos, vel, radius, grounded) -> {pos, vel, impact}   on_splash(pos, impact, into_water)
## Input dictionary (Thalassa's ensureInput): forward, right, up (-1..1), yaw_delta, pitch_delta (rad this tick),
## smoothing (0..1), boost, boost_just_pressed, jump_held.
## Differences from the JS, each on purpose:
##   - Math.random in the sprint trail is not ported (events only; core stays deterministic for replay tests).
##   - Shore jump jitter uses the same deterministic sin(count * 2.39996) as the JS.
##   - two robustness guards for geometry Thalassa never had (world edges, ledges over the surface): release from
##     shore walking when no floor is found; air-branch horizontal speed soft-capped like the swim branch.
##   - optional env.stand_blocked(eye, floor_y): grounding waits while a standing body would not fit (low ceiling).
##   - local_surface may also give the live wave height in open water (the JS uses a flat surfaceY there).
##     With no local_surface the behaviour is the JS's exactly (checked by tests/golden_swimmer).
extends RefCounted

const LN2 := 0.6931471805599453

var config := {
	"radius": 0.55, "cruise_speed": 3.4, "sprint_speed": 5.0, "steer_rate": 4.8, "sprint_steer_rate": 6.0,
	"reversal_boost": 3.6, "brake_drag": 4.8, "burst_impulse": 1.25, "burst_cooldown": 0.72,
	"carve_redirect": 0.62, "glide_pulse_amp": 0.0, "coast_drag": 2.35, "dive_lift_bonus": 0.45,
	"has_surface": true, "surface_y": 0.0, "sway_scale": 0.85, "classic_drag": false, "pitch_limit": 1.42,
	"base_fov": 74.0, "sprint_fov": 80.5,
	"walk_speed": 1.38, "jog_speed": 2.45, "crouch_speed": 0.82, "wade_min_speed_scale": 0.64,
	"step_lag": 0.04, "walk_off_drop": 0.36, "eye_height": 1.24, "crouch_eye_drop": 0.30, "jump_gravity": 9.81, "jump_speed": 3.15,
	"wade_enter_depth": 1.04, "wade_exit_depth": 1.14,
	"thalassa_exact": false,   # true: the JS exactly (golden test); false: the FIX lines below run
}

var pos := Vector3(0, -6.5, 16.5)
var vel := Vector3.ZERO
var yaw := 0.12
var pitch := -0.14
var roll := 0.0
var target_yaw := 0.12
var target_pitch := -0.14
var fov := 74.0
var was_underwater := true
var swim_phase := 0.0
var splash_cooldown := 0.0
var sprint_burst_cd := 0.0
var plunge_dip := 0.0
var plunge_dip_vel := 0.0
var sprinting := false
var last_lateral_slip := 0.0
var diver_bump_cd := 0.0
var dive_momentum := 0.0
var slipstream_timer := 0.0
var glide_ratio := 0.0
var input_mag := 0.0
var turn_rate_smooth := 0.0
var surface_tread_blend := 0.0
var water_current := Vector3.ZERO
var surface_clock := 0.0
# shoreline swim <-> wade <-> walk (no button press)
var shore_grounded := false
var ground_walk_blend := 0.0
var wade_blend := 0.0
var shore_water_depth := 12.0
var shore_floor_y := -INF
var shore_floor_normal := Vector3.UP
var shore_vel_xz := Vector2.ZERO
var shore_accel_xz := Vector2.ZERO
var shore_desired_vel_xz := Vector2.ZERO
var climb_scale := 1.0     # speed scale while climbing or descending (stairs, steep ramps)
var shore_jump_offset := 0.0
var shore_air_lag := 0.0
var shore_jump_vel_y := 0.0
var shore_is_airborne := false
var shore_jump_queued := false
var shore_jump_pending_dive := false
var shore_jump_anticip_timer := 0.0
var shore_jump_anticip := 0.0
var shore_jump_count := 0
var shore_just_landed := false
var shore_landing_impact := 0.0
var shore_crouch_blend := 0.0
var shore_braking_impulse := 0.0
var shore_dive_arc_timer := 0.0
var shore_prev_jump_held := false
var shore_yaw_rate := 0.0
var shore_prev_speed := 0.0
var shore_bob_phase := 0.0
var last_bump := 0.0

func _init(cfg: Dictionary = {}) -> void:
	for k in cfg:
		config[k] = cfg[k]
	fov = config.base_fov

static func exp_k(k: float, dt: float) -> float:
	return 1.0 - exp(-k * dt)

static func smoothstep01(a: float, b: float, x: float) -> float:
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

## Thalassa math.js conventions: yaw 0 looks down -z, positive pitch looks up.
static func forward(y: float, p: float) -> Vector3:
	return Vector3(-sin(y) * cos(p), sin(p), -cos(y) * cos(p))

static func right_of(y: float) -> Vector3:
	return Vector3(cos(y), 0.0, -sin(y))

func set_pose(p: Vector3, y: float, pt: float) -> void:
	pos = p; yaw = y; pitch = pt; target_yaw = y; target_pitch = pt; roll = 0.0
	shore_grounded = false; ground_walk_blend = 0.0; wade_blend = 0.0; shore_is_airborne = false
	shore_jump_queued = false; shore_jump_pending_dive = false; shore_jump_anticip_timer = 0.0
	shore_jump_anticip = 0.0; shore_jump_offset = 0.0; shore_jump_vel_y = 0.0; shore_dive_arc_timer = 0.0

func apply_look(yaw_delta: float, pitch_delta: float) -> void:
	target_yaw += yaw_delta
	target_pitch = clampf(target_pitch + pitch_delta, -config.pitch_limit, config.pitch_limit)

func get_speed() -> float:
	return vel.length()

func apply_slipstream_boost(dir: Vector3 = Vector3.ZERO, amount: float = 1.65) -> void:
	var d := dir if dir.length() > 0.01 else forward(yaw, pitch)
	vel += d.normalized() * amount
	slipstream_timer = maxf(slipstream_timer, 0.78)
	dive_momentum = clampf(dive_momentum + 0.35, 0.0, 1.0)

static func _in(inp: Dictionary, k: String, dflt = 0.0):
	return inp.get(k, dflt)

func _floor_y(env: Dictionary, x: float, z: float) -> float:
	return env.floor_height.call(x, z) if env.has("floor_height") else -INF

func _splash(env: Dictionary, p: Vector3, impact: float, into: bool) -> void:
	if env.has("on_splash"):
		env.on_splash.call(p, impact, into)

func _resolve(env: Dictionary, r: float, grounded: bool) -> float:
	if not env.has("resolve_collisions"):
		return 0.0
	var res: Dictionary = env.resolve_collisions.call(pos, vel, r, grounded)
	pos = res.pos; vel = res.vel
	return res.get("impact", 0.0)

func update(dt: float, inp: Dictionary = {}, env: Dictionary = {}) -> void:
	var sdt := clampf(dt, 0.0001, 0.05)
	var c := config
	var in_fwd: float = _in(inp, "forward"); var in_right: float = _in(inp, "right"); var in_up: float = _in(inp, "up")
	var in_boost: bool = _in(inp, "boost", false); var jump_held: bool = _in(inp, "jump_held", false)
	apply_look(_in(inp, "yaw_delta"), _in(inp, "pitch_delta"))
	var smoothing: float = _in(inp, "smoothing", 0.35)
	if smoothing <= 0.01:
		yaw = target_yaw; pitch = target_pitch
	else:
		var lk := exp_k(lerpf(52.0, 14.0, smoothing), sdt)
		yaw += (target_yaw - yaw) * lk
		pitch += (target_pitch - pitch) * lk

	var prev_yaw_step := yaw
	surface_clock += sdt
	sprint_burst_cd = maxf(0.0, sprint_burst_cd - sdt)
	slipstream_timer = maxf(0.0, slipstream_timer - sdt)
	shore_dive_arc_timer = maxf(0.0, shore_dive_arc_timer - sdt)
	var local: Dictionary = env.local_surface.call(pos) if env.has("local_surface") else {}
	var enclosed: bool = local.get("enclosed", false) and is_finite(local.get("surface_y", NAN))
	var surf_y: float = local.surface_y if enclosed else (local.get("surface_y", c.surface_y) if not local.is_empty() else c.surface_y)

	var raw_floor_y := _floor_y(env, pos.x, pos.z)
	var has_floor := is_finite(raw_floor_y)
	var raw_floor_n: Vector3 = env.terrain_normal.call(pos.x, pos.z) if (has_floor and env.has("terrain_normal")) else Vector3.UP
	shore_floor_y = raw_floor_y
	shore_floor_normal = raw_floor_n
	var water_depth: float = (surf_y - raw_floor_y) if (c.has_surface and has_floor) else INF
	shore_water_depth = water_depth
	var slope_walkable := shore_floor_normal.y >= 0.56
	var raw_shore_yaw_rate := clampf(wrapf(yaw - prev_yaw_step, -PI, PI) / sdt, -10.0, 10.0) if sdt > 1e-4 else 0.0
	shore_yaw_rate = lerpf(shore_yaw_rate, raw_shore_yaw_rate, exp_k(14.0, sdt))

	var wants_swim_dive := (in_up < -0.1 and water_depth > 0.52) or (in_fwd > 0.1 and pitch < -0.34 and water_depth > 0.68)
	var jump_just_pressed := jump_held and not shore_prev_jump_held
	shore_prev_jump_held = jump_held

	# 1. automatic swim -> wade / walk grounding
	if not enclosed and not shore_grounded and c.has_surface and has_floor and slope_walkable and shore_dive_arc_timer <= 0.0:
		var feet_near_floor: bool = pos.y <= raw_floor_y + c.eye_height + 0.44
		var room: bool = not (env.has("stand_blocked") and env.stand_blocked.call(pos, raw_floor_y))   # adapter addition
		if water_depth <= c.wade_enter_depth and feet_near_floor and not wants_swim_dive and room:
			shore_grounded = true
			shore_vel_xz = Vector2(vel.x, vel.z); shore_accel_xz = Vector2.ZERO; shore_desired_vel_xz = Vector2(vel.x, vel.z)
			var above_eye: float = pos.y - (raw_floor_y + c.eye_height)
			if above_eye > 0.08 and vel.y > -4.0:
				shore_jump_offset = above_eye; shore_jump_vel_y = vel.y; shore_is_airborne = true
			else:
				shore_jump_offset = 0.0; shore_jump_vel_y = 0.0; shore_is_airborne = false
			shore_just_landed = false; shore_landing_impact = 0.0; shore_crouch_blend = 0.0; shore_braking_impulse = 0.0

	# 2. automatic walk / wade -> swim release
	if shore_grounded:
		var dive_into_water := shore_dive_arc_timer > 0.0 and water_depth > 0.68 and (pos.y < surf_y - 0.10 or not shore_is_airborne)
		var push_off := water_depth > 0.80 and jump_just_pressed and not shore_is_airborne
		var walk_too_deep: bool = water_depth > c.wade_exit_depth and not shore_is_airborne
		var submerge := water_depth > 0.70 and wants_swim_dive and not shore_is_airborne
		# not has_floor: walked off the end of the world geometry (Thalassa's terrain is an endless height field)
		if dive_into_water or push_off or walk_too_deep or submerge or not slope_walkable or not has_floor:
			shore_grounded = false; shore_is_airborne = false; shore_jump_offset = 0.0
			var fwd_release := forward(yaw, pitch)
			vel.x = shore_vel_xz.x
			vel.y = minf(-1.6, shore_jump_vel_y) if dive_into_water else (1.45 if push_off else (-1.1 if submerge else vel.y))
			vel.z = shore_vel_xz.y
			if dive_into_water:
				apply_slipstream_boost(fwd_release, 1.35)
				_splash(env, pos, 3.4, true)

	ground_walk_blend = lerpf(ground_walk_blend, 1.0 if shore_grounded else 0.0, exp_k(7.0 if shore_grounded else 5.8, sdt))
	if ground_walk_blend < 0.004: ground_walk_blend = 0.0
	var target_wade := clampf(water_depth / 0.96, 0.0, 1.0) if (shore_grounded and water_depth > 0.04) else 0.0
	wade_blend = lerpf(wade_blend, target_wade, exp_k(6.5, sdt))
	if wade_blend < 0.004: wade_blend = 0.0

	# 3. grounded beach / shoreline walk and wade
	if shore_grounded:
		_update_shore(sdt, c, env, inp, in_fwd, in_right, in_up, in_boost, jump_just_pressed, water_depth, raw_floor_y, surf_y)
		return
	_update_swim(sdt, c, env, inp, in_fwd, in_right, in_up, in_boost, jump_held, enclosed, surf_y)

func _update_shore(sdt: float, c: Dictionary, env: Dictionary, inp: Dictionary, in_fwd: float, in_right: float, in_up: float,
		in_boost: bool, jump_just_pressed: bool, water_depth: float, raw_floor_y: float, surf_y: float) -> void:
	surface_tread_blend = lerpf(surface_tread_blend, 0.0, exp_k(8.0, sdt))
	glide_ratio = lerpf(glide_ratio, 0.0, exp_k(8.0, sdt))
	dive_momentum = maxf(0.0, dive_momentum - sdt * 2.0)
	var fwd_h := forward(yaw, 0.0)
	var right_h := right_of(yaw)
	var m := Vector2(fwd_h.x * in_fwd + right_h.x * in_right, fwd_h.z * in_fwd + right_h.z * in_right)
	var ml := m.length()
	if ml > 1e-4: m /= ml
	input_mag = lerpf(input_mag, 1.0 if ml > 0.05 else 0.0, exp_k(6.0, sdt))
	var want_crouch := not shore_is_airborne and in_up < -0.5 and water_depth <= 0.68
	shore_crouch_blend = lerpf(shore_crouch_blend, 1.0 if want_crouch else 0.0, exp_k(10.5, sdt))
	if shore_crouch_blend < 0.004: shore_crouch_blend = 0.0
	var depth_speed_scale: float = lerpf(1.0, c.wade_min_speed_scale, smoothstep01(0.06, 0.98, water_depth))
	var base_spd: float = (c.crouch_speed if want_crouch else (c.jog_speed if in_boost else c.walk_speed)) * depth_speed_scale
	var target_spd := base_spd * clampf(ml, 0.0, 1.0) if ml > 0.05 else 0.0
	if not c.thalassa_exact and not shore_is_airborne and target_spd > 0.05:
		# FIX (body stress B37 stairs): legs climb at a limited rate. Thalassa walked a flight at flat-ground speed
		# (1.38 m/s up 0.17/0.28 stairs = 0.84 m/s of climb), more than two treads per step; a 1.38 m child climbs
		# about 0.40 m/s walking and 0.70 m/s running (stair-gait studies: ~0.5 m/s cadence-limited for adults).
		# The grade is the floor rise over the 0.6 m ahead along her heading, up or down.
		var fy0 := _floor_y(env, pos.x - m.x * 0.1, pos.z - m.y * 0.1)
		var fy1 := _floor_y(env, pos.x + m.x * 0.5, pos.z + m.y * 0.5)
		var grade := absf(fy1 - fy0) / 0.6 if (is_finite(fy0) and is_finite(fy1) and absf(fy1 - fy0) < 0.6) else 0.0
		var vmax: float = lerpf(c.get("climb_rate_walk", 0.40), c.get("climb_rate_run", 0.70), clampf((base_spd - c.walk_speed) / maxf(0.01, c.jog_speed - c.walk_speed), 0.0, 1.0))
		var want_k := minf(1.0, vmax / maxf(1e-3, target_spd * grade))
		climb_scale = lerpf(climb_scale, want_k, exp_k(4.0 if want_k < climb_scale else 2.5, sdt))
		target_spd *= climb_scale
	else:
		climb_scale = lerpf(climb_scale, 1.0, exp_k(2.5, sdt))
	var des := m * target_spd
	shore_desired_vel_xz = des
	var prev_v := shore_vel_xz
	var hl := lerpf(0.135, 0.21, wade_blend) if target_spd > 0.05 else lerpf(0.125, 0.16, wade_blend)
	var kv := 1.0 - exp((-LN2 * sdt) / maxf(1e-4, hl))
	shore_vel_xz = prev_v.lerp(des, kv)
	if target_spd < 0.01 and shore_vel_xz.length() < 0.03:
		shore_vel_xz = Vector2.ZERO

	# anticipation-coiled jump / running dive-in
	shore_just_landed = false
	shore_landing_impact = maxf(0.0, shore_landing_impact - sdt * 4.5)
	var was_air := shore_is_airborne
	if jump_just_pressed and not shore_is_airborne and not shore_jump_queued:
		var ahead_floor := _floor_y(env, pos.x + fwd_h.x * 3.0, pos.z + fwd_h.z * 3.0) if env.has("floor_height") else raw_floor_y
		var diving_into_sea := in_boost and in_fwd > 0.1 and (water_depth > 0.22 or (is_finite(ahead_floor) and ahead_floor < surf_y - 0.55))
		shore_jump_queued = true
		shore_jump_pending_dive = diving_into_sea
		shore_jump_anticip_timer = 0.042 if diving_into_sea else 0.072
	if shore_jump_queued:
		shore_jump_anticip_timer -= sdt
		var dur_ant := 0.042 if shore_jump_pending_dive else 0.072
		shore_jump_anticip = sin(clampf(1.0 - shore_jump_anticip_timer / dur_ant, 0.0, 1.0) * PI)
		if shore_jump_anticip_timer <= 0.0:
			shore_jump_queued = false; shore_jump_anticip = 0.0; shore_jump_count += 1; shore_is_airborne = true
			var v_jit := 1.0 + sin(shore_jump_count * 2.39996) * 0.03
			if shore_jump_pending_dive:
				shore_dive_arc_timer = 0.85; shore_jump_vel_y = 2.65
				shore_vel_xz += Vector2(fwd_h.x, fwd_h.z) * 1.45
				_splash(env, pos, 2.2, false)
			else:
				shore_jump_vel_y = c.jump_speed * v_jit * lerpf(1.0, 0.78, wade_blend) * (1.0 - shore_crouch_blend * 0.15)
				# FIX: Thalassa cut the crouch to 40% at take-off, an 18 cm eye pop in one tick from a crouch; it now
				# unwinds at its own 10.5/s while airborne (stress monkey runs: pelvis 0.21 m against the eye)
				if c.thalassa_exact: shore_crouch_blend *= 0.4
			shore_jump_pending_dive = false
	else:
		shore_jump_anticip = lerpf(shore_jump_anticip, 0.0, exp_k(18.0, sdt))

	if shore_is_airborne:
		shore_jump_vel_y -= c.jump_gravity * sdt
		shore_jump_offset += shore_jump_vel_y * sdt
		if shore_jump_offset <= 0.0:
			var imp_vel := absf(shore_jump_vel_y)
			shore_jump_offset = 0.0; shore_jump_vel_y = 0.0; shore_is_airborne = false; shore_just_landed = true
			shore_landing_impact = clampf(imp_vel / 3.4, 0.28, 1.0)
			if water_depth > 0.08: _splash(env, pos, clampf(imp_vel * 0.7, 1.4, 3.8), true)

	pos.x += shore_vel_xz.x * sdt
	pos.z += shore_vel_xz.y * sdt
	var new_floor := _floor_y(env, pos.x, pos.z) if env.has("floor_height") else raw_floor_y
	var eff_floor := new_floor if is_finite(new_floor) else raw_floor_y
	# FIX: in the air the jump offset is height above the floor under her; when that floor changes (off a ledge, over
	# a step) re-base it so the eye stays on its arc (Thalassa's height-field had no ledges: the eye dropped/rose by
	# the floor step in one tick, 0.32 m off a 30 cm step)
	if shore_is_airborne and not c.thalassa_exact and is_finite(eff_floor) and is_finite(shore_floor_y):
		shore_jump_offset += shore_floor_y - eff_floor
		if shore_jump_offset <= 0.0:
			var imp2 := absf(shore_jump_vel_y)
			shore_jump_offset = 0.0; shore_jump_vel_y = 0.0; shore_is_airborne = false; shore_just_landed = true
			shore_landing_impact = clampf(imp2 / 3.4, 0.28, 1.0)
	shore_floor_y = eff_floor
	if env.has("terrain_normal"):
		shore_floor_normal = env.terrain_normal.call(pos.x, pos.z)
	var ant_dip := shore_jump_anticip * 0.052
	if not shore_is_airborne and not c.thalassa_exact and is_finite(eff_floor):
		# walking off a drop deeper than a step falls under gravity (Thalassa eased the eye down at 18/s, 13 cm in the
		# first tick off a 50 cm ledge, faster than a fall, and the body never left the ground)
		var drop: float = pos.y - (eff_floor + c.eye_height - shore_crouch_blend * c.crouch_eye_drop)
		if drop > c.walk_off_drop:
			shore_is_airborne = true; shore_jump_vel_y = 0.0; shore_jump_offset = drop
	var target_eye_y: float = eff_floor + c.eye_height - shore_crouch_blend * c.crouch_eye_drop + shore_jump_offset - ant_dip
	if shore_is_airborne:
		# FIX: on the ground the eye trails its target at 18/s, in the air Thalassa set it outright: at take-off the
		# trail (up to 16 cm rising out of a crouch) vanished in one tick. The trail now keeps closing at the same rate.
		if c.thalassa_exact: shore_air_lag = 0.0
		elif not was_air: shore_air_lag = maxf(0.0, target_eye_y - pos.y)
		else: shore_air_lag *= 1.0 - exp_k(18.0, sdt)
		var air_min: float = eff_floor + c.eye_height - 0.1
		if not c.thalassa_exact: air_min -= shore_crouch_blend * c.crouch_eye_drop + shore_air_lag   # the floor clamp popped a crouched take-off up 14 cm
		pos.y = maxf(air_min, target_eye_y - shore_air_lag)
	else:
		shore_air_lag = 0.0
		pos.y = lerpf(pos.y, target_eye_y, exp_k(18.0, sdt))
	vel = Vector3(shore_vel_xz.x, shore_jump_vel_y if shore_is_airborne else 0.0, shore_vel_xz.y)
	# slide against rocks and hulls without overriding the standing eye height
	var saved_y := pos.y
	_resolve(env, c.radius * 0.72, true)
	# step_lag: how far the eye may trail the standing height (Thalassa 0.04 m; the Godot adapter raises it so a
	# 30 cm ledge is climbed over ~0.15 s by the 18/s follow above instead of snapping up in one tick)
	pos.y = maxf(saved_y, eff_floor + c.eye_height - shore_crouch_blend * c.crouch_eye_drop + shore_jump_offset - c.step_lag)
	shore_vel_xz = Vector2(vel.x, vel.z)
	if sdt > 1e-4:
		var raw_a := ((shore_vel_xz - prev_v) / sdt).clamp(Vector2(-18, -18), Vector2(18, 18))
		shore_accel_xz = shore_accel_xz.lerp(raw_a, exp_k(12.0, sdt))
	var shore_spd := shore_vel_xz.length()
	var decel_r := (shore_prev_speed - shore_spd) / sdt if sdt > 1e-4 else 0.0
	if not shore_is_airborne and target_spd < 0.05 and shore_prev_speed > 1.35 and decel_r > 2.2:
		shore_braking_impulse = maxf(shore_braking_impulse, clampf((shore_prev_speed - 1.0) / 1.6, 0.25, 1.0))
	else:
		shore_braking_impulse = maxf(0.0, shore_braking_impulse - sdt * 3.8)
	shore_prev_speed = shore_spd
	if shore_spd > 0.16 and not shore_is_airborne:
		shore_bob_phase += sdt * (4.1 + shore_spd * 1.45)
	sprinting = in_boost and shore_spd > 1.6
	was_underwater = pos.y < surf_y - 0.1
	last_lateral_slip = absf(vel.x * right_h.x + vel.z * right_h.z)
	roll = lerpf(roll, 0.0, exp_k(8.0, sdt))
	fov = lerpf(fov, lerpf(c.base_fov - 1.5, c.base_fov + 2.5, clampf(shore_spd / 2.6, 0.0, 1.0)), exp_k(6.5, sdt))

func _update_swim(sdt: float, c: Dictionary, env: Dictionary, inp: Dictionary, in_fwd: float, in_right: float, in_up: float,
		in_boost: bool, jump_held: bool, enclosed: bool, surf_y: float) -> void:
	var swell := 0.0
	if c.has_surface:
		swell = sin(surface_clock * 1.45 + pos.x * 0.18) * (0.014 if enclosed else 0.032) + cos(surface_clock * 0.92 + pos.z * 0.14) * (0.010 if enclosed else 0.022)
	# Thalassa treads with the eye 14 cm under the waterline: the head never breaks the surface (Gary's Mac run, 28 Nov:
	# "girl can't breach the water surface"). The game sets tread_eye so she floats with her head out; the goldens keep -0.14.
	var tread_y := surf_y - (0.10 if enclosed else -float(c.get("tread_eye", -0.14))) + swell
	var wants_dive := in_up < -0.1 or (in_fwd > 0.1 and pitch < -0.26)
	var in_band: bool = c.has_surface and pos.y >= surf_y - 0.56 and pos.y <= surf_y + (0.45 if enclosed else 0.28)
	var treading := in_band and not wants_dive and (enclosed or not jump_held)
	var underwater: bool = (not c.has_surface) or pos.y < surf_y - 0.15 or treading
	surface_tread_blend = lerpf(surface_tread_blend, 1.0 if treading else 0.0, exp_k(6.5 if treading else 8.0, sdt))
	if surface_tread_blend < 0.004: surface_tread_blend = 0.0

	var fwd := forward(yaw, pitch)
	var right := right_of(yaw)
	var fwd_h := forward(yaw, 0.0)
	var eff_up := 0.0 if (enclosed and pos.y >= surf_y - 0.22 and in_up > 0.0) else in_up
	var a := Vector3(
		lerpf(fwd.x, fwd_h.x, surface_tread_blend) * in_fwd + right.x * in_right,
		fwd.y * (1.0 - surface_tread_blend) * in_fwd + eff_up,
		lerpf(fwd.z, fwd_h.z, surface_tread_blend) * in_fwd + right.z * in_right)
	var al := a.length()
	var has_input := al > 0.05
	input_mag = lerpf(input_mag, clampf(al, 0.0, 1.0) if has_input else 0.0, exp_k(5.5, sdt))
	if al > 1.0: a /= al
	var spr := in_boost and has_input and underwater
	sprinting = spr

	# dive-to-pullout flow energy (dolphin arc)
	var dive_rate := 0.0
	if underwater and has_input and not c.classic_drag and in_fwd > 0.1 and pitch < -0.22:
		dive_rate = clampf((-pitch - 0.22) / 0.85, 0.0, 1.0) * (0.95 if spr else 0.65)
	if dive_rate > 0.0:
		dive_momentum = clampf(dive_momentum + dive_rate * sdt * 0.95, 0.0, 1.0)
	else:
		dive_momentum = maxf(0.0, dive_momentum - (0.58 if (has_input and in_fwd > 0.1) else 1.45) * sdt)
	var base_max: float = c.sprint_speed if spr else c.cruise_speed
	var dive_bonus: float = dive_momentum * c.dive_lift_bonus if (not c.classic_drag and in_fwd > 0.1) else 0.0
	var slip_bonus := clampf(slipstream_timer / 0.78, 0.0, 1.0) * 1.35 if slipstream_timer > 0.0 else 0.0
	var glide_pulse := 1.0
	if has_input and not c.classic_drag and in_fwd > 0.1:
		glide_pulse = 1.0 + sin(swim_phase * 0.5) * c.glide_pulse_amp * (1.15 if spr else 0.85)
	var max_spd := (base_max + dive_bonus + slip_bonus) * glide_pulse

	if underwater:
		if c.classic_drag:
			vel += a * (38.0 if spr else 27.0) * sdt
			vel *= exp(-3.45 * sdt)
			var spd := get_speed()
			if spd > base_max:
				vel *= lerpf(spd, base_max, clampf(sdt * 8.0, 0.0, 1.0)) / spd
		elif has_input:
			var throttle := minf(al, 1.0)
			var dir := a / throttle
			var tv := dir * max_spd * throttle
			# flipper-kick burst on the sprint press
			if _in(inp, "boost_just_pressed", false) and c.burst_impulse > 0.05 and sprint_burst_cd <= 0.0:
				vel += dir * c.burst_impulse
				sprint_burst_cd = c.burst_cooldown
			# hydrodynamic carve-turn: cross-axis speed redirected into the new heading
			var cur_spd := get_speed()
			var v_dot := vel.dot(dir)
			var opposing := clampf(-v_dot / cur_spd, 0.0, 1.0) if cur_spd > 0.2 else 0.0
			if cur_spd > 0.6 and opposing < 0.15 and c.carve_redirect > 0.01:
				var carve_k := exp_k(c.carve_redirect * 8.5, sdt)
				var aligned := lerpf(maxf(0.0, v_dot), cur_spd, carve_k)
				var perp := vel - dir * v_dot
				vel = dir * aligned + perp * (1.0 - carve_k * 0.65)
			var rate: float = (c.sprint_steer_rate if spr else c.steer_rate) + opposing * c.reversal_boost
			vel += (tv - vel) * exp_k(rate, sdt)
			var new_spd := get_speed()
			var soft_cap := (base_max + dive_bonus + slip_bonus) * 1.24
			if new_spd > soft_cap:
				vel *= lerpf(new_spd, soft_cap, exp_k(10.0, sdt)) / new_spd
			glide_ratio = lerpf(glide_ratio, 0.0, exp_k(8.0, sdt))
		else:
			# speed-adaptive glide-out: fast coasts glide, slow hover brakes crisply (hatch and dock precision)
			var cur := get_speed()
			var glide_blend := clampf((cur - c.cruise_speed * 0.45) / maxf(0.5, c.sprint_speed * 0.55), 0.0, 1.0)
			var eff_drag: float = lerpf(c.brake_drag, c.coast_drag, glide_blend * 0.85)
			glide_ratio = lerpf(glide_ratio, glide_blend, exp_k(6.5, sdt))
			vel *= exp(-eff_drag * sdt)
			if get_speed() < 0.04: vel = Vector3.ZERO
		# buoyant treading: holds the head at the waterline with a wave bob
		if treading:
			vel.y += ((tread_y - pos.y) * 16.5 - vel.y * 5.8) * sdt
		if has_input:
			swim_phase += sdt * (10.6 if spr else 6.2)
	else:
		# above water: buoyant arc, gravity plunge, dolphin breach
		vel.x += a.x * (4.5 if enclosed else 10.0) * sdt
		vel.z += a.z * (4.5 if enclosed else 10.0) * sdt
		vel.y -= 15.5 * sdt
		if not enclosed and pos.y < surf_y + 0.35 and jump_held:
			vel.y = maxf(vel.y, 5.8)
		var air_drag := exp(-0.8 * sdt)
		vel.x *= air_drag; vel.z *= air_drag
		# airtime is brief in Thalassa's open sea; held under a ledge at the surface it is not, and 10 m/s2 with 0.8
		# drag would run to 12.5 m/s. Same soft cap as the swim branch.
		var hz := Vector2(vel.x, vel.z)
		var air_cap: float = c.sprint_speed * 1.24
		if hz.length() > air_cap:
			hz *= lerpf(hz.length(), air_cap, exp_k(10.0, sdt)) / hz.length()
			vel.x = hz.x; vel.z = hz.y

	pos += vel * sdt
	if enclosed and pos.y > surf_y + 0.08:
		pos.y = lerpf(pos.y, surf_y + 0.04, exp_k(18.0, sdt))
		if vel.y > 0.0: vel.y = 0.0

	# surface crossing splash + plunge camera dip spring
	splash_cooldown = maxf(0.0, splash_cooldown - sdt)
	var now_under: bool = (not c.has_surface) or pos.y < surf_y - 0.1
	if c.has_surface and now_under != was_underwater and splash_cooldown <= 0.0:
		var impact := absf(vel.y)
		if impact > 1.2:
			splash_cooldown = 0.4
			if now_under:
				plunge_dip_vel -= clampf(impact * 0.14, 0.25, 1.2)
				if impact > 3.2 and not c.classic_drag:
					apply_slipstream_boost(fwd, clampf((impact - 2.6) * 0.32, 0.45, 1.45))
			_splash(env, pos, impact, now_under)
	was_underwater = now_under
	plunge_dip_vel += (-48.0 * plunge_dip - 11.5 * plunge_dip_vel) * sdt
	plunge_dip = clampf(plunge_dip + plunge_dip_vel * sdt, -0.35, 0.2)

	diver_bump_cd = maxf(0.0, diver_bump_cd - sdt)
	var norm_imp := _resolve(env, c.radius, false)
	last_bump = 0.0
	if norm_imp > 1.35 and diver_bump_cd <= 0.0:
		diver_bump_cd = 0.78
		last_bump = clampf((norm_imp - 1.1) / 5.0, 0.16, 0.75)
	last_lateral_slip = absf(vel.x * right.x + vel.z * right.z)

	# ocean current cross-flow feel
	var wc: Vector3 = env.water_current.call(pos, surface_clock) if env.has("water_current") else water_current
	water_current = water_current.lerp(wc, exp_k(6.0, sdt))
	var cur_lat := water_current.x * right.x + water_current.z * right.z
	var current_roll: float = clampf(cur_lat * 0.026, -0.042, 0.042) * c.sway_scale
	var spd_n := clampf(get_speed() / 12.0, 0.0, 1.0)
	var raw_turn := clampf(-float(_in(inp, "yaw_delta")) / sdt, -3.0, 3.0) if sdt > 1e-4 else 0.0
	turn_rate_smooth = lerpf(turn_rate_smooth, raw_turn, exp_k(6.0, sdt))
	var turn_roll: float = turn_rate_smooth * lerpf(0.012, 0.032, spd_n) * c.sway_scale
	var kick_roll: float = cos(swim_phase * 0.5) * spd_n * (0.016 if spr else 0.008) * c.sway_scale
	var target_roll: float = clampf(in_right * 0.045 * c.sway_scale + turn_roll + kick_roll + current_roll, -0.15, 0.15)
	roll = lerpf(roll, target_roll, exp_k(4.8, sdt))
	var flow_fov := clampf(dive_momentum * 1.4 + (1.8 if slipstream_timer > 0.0 else 0.0), 0.0, 2.8)
	var target_fov: float = (c.sprint_fov if spr else lerpf(c.base_fov, c.base_fov + 2.5, spd_n)) + flow_fov
	fov = lerpf(fov, target_fov, exp_k(7.5, sdt))

## Thalassa getCameraTransform: first-person eye with heave, surge, stroke bob, plunge dip and walk bob.
func get_camera_transform(total_time: float = 0.0, idle_menu: bool = false) -> Dictionary:
	var p := pos
	var y := yaw
	var pt := pitch
	var r := roll
	if idle_menu:
		y = 0.22 + sin(total_time * 0.28) * 0.14
		pt = -0.14 + cos(total_time * 0.36) * 0.04
		r = sin(total_time * 0.45) * 0.014
	else:
		var sw: float = config.sway_scale
		var spd_n := clampf(get_speed() / 12.0, 0.0, 1.0)
		var idle_n := 1.0 - clampf(spd_n * 1.15, 0.0, 1.0)
		var depth: float = maxf(0.0, config.surface_y - pos.y) if config.has_surface else 12.0
		var chop := clampf(1.0 - depth / 3.5, 0.0, 1.0) if config.has_surface else 0.0
		var amp := (0.85 + chop * 0.75) * sw
		var heave := (sin(total_time * 1.12) * 0.048 + sin(total_time * 0.59 + 1.4) * 0.028) * (0.35 + 0.65 * idle_n) * amp
		var surge_r := (sin(total_time * 0.73 + 0.6) * 0.036 + cos(total_time * 0.41) * 0.020) * idle_n * amp
		var surge_f := cos(total_time * 0.52 + 2.1) * 0.026 * idle_n * amp
		var rt := right_of(y)
		var fw := forward(y, 0.0)
		var bob := sin(swim_phase) * spd_n * (0.095 if sprinting else 0.065) * sw
		var gwb := clampf(ground_walk_blend, 0.0, 1.0)
		var uw := 1.0 - gwb
		var walk_bob_y := (sin(shore_bob_phase * 2.0) * 0.015 * clampf(shore_prev_speed / 2.6, 0.0, 1.0) if shore_prev_speed > 0.2 else 0.0) - shore_landing_impact * 0.055
		var walk_bob_r := cos(shore_bob_phase) * 0.008 * clampf(shore_prev_speed / 2.6, 0.0, 1.0) if shore_prev_speed > 0.2 else 0.0
		p += (rt * surge_r + fw * surge_f) * uw
		p.y += (bob + heave + plunge_dip * sw) * uw + walk_bob_y * gwb
		var idle_pitch := (sin(total_time * 0.68 + 0.9) * 0.011 + cos(total_time * 0.37) * 0.006) * (0.25 + 0.75 * idle_n) * amp * uw
		var idle_roll := (sin(total_time * 0.54 + 2.2) * 0.016 + cos(total_time * 0.89) * 0.007) * (0.25 + 0.75 * idle_n) * amp * uw
		pt = clampf(pt + cos(swim_phase) * spd_n * 0.008 * sw * uw + idle_pitch, -1.45, 1.45)
		r += idle_roll + walk_bob_r * gwb
	return {"pos": p, "yaw": y, "pitch": pt, "roll": r, "fov": fov}

## Thalassa getActorFrame: the generic frame any camera tracks (camera profile numbers kept as tuned).
func get_actor_frame(total_time: float = 0.0, idle_menu: bool = false) -> Dictionary:
	var cam := get_camera_transform(total_time, idle_menu)
	return {"id": "swimmer", "kind": "swimmer", "pos": pos, "fp_pos": cam.pos, "head_pos": pos, "vel": vel,
		"speed": get_speed(), "max_speed": config.sprint_speed, "yaw": cam.yaw, "pitch": cam.pitch, "roll": cam.roll,
		"fov": cam.fov, "radius": config.radius, "is_boosting": sprinting,
		"keep_under_surface": config.has_surface and pos.y < config.surface_y - 0.35 and ground_walk_blend < 0.20,
		"surface_ceiling_y": config.surface_y - 0.30, "floor_margin": 0.44,
		"camera_profile": {"dist": 1.38, "dist_speed_add": 0.24, "dist_boost_add": 0.14, "shoulder_x": 0.24,
			"shoulder_y": 0.11, "look_ahead": 6.2, "ots_fov": config.base_fov, "ots_fov_speed_add": 3.5,
			"fp_fov_cap": 82.0, "ots_roll_scale": 0.32, "ots_level_up": 0.85, "carve_lead_scale": 0.16,
			"head_hide_dist": 0.34}}
