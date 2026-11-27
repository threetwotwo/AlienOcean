## M02 Player motor, core 0.1.0 (engine-agnostic logic: no nodes, no physics server).
## Decides the traversal mode and the velocity the body WANTS this tick. The adapter moves the body
## (Jolt via CharacterBody3D) and reports back what happened through Sense.
## Modes: WALK, WADE, SWIM, TREAD (at the surface), FALL. Rate independent: every blend uses exp(-k dt).
## Reference constants: Thalassa v20.19 core/swimmer-physics.js (cruise 3.4, sprint 5.0, walk 1.38, jog 2.45,
## wade hysteresis 1.04/1.14). Child body: 1.38 m tall, eye 1.24 m.
extends RefCounted

enum Mode { WALK, WADE, SWIM, TREAD, FALL }
const MODE_NAMES := ["WALK", "WADE", "SWIM", "TREAD", "FALL"]

# --- tuning (data; a record can override any of these through configure()) ---
var height := 1.38
var eye_height := 1.24
var walk_speed := 1.38
var jog_speed := 2.45
var crouch_speed := 0.82
var cruise_speed := 3.4
var sprint_speed := 5.0
var ground_accel_k := 10.0     # 1/s, how fast ground velocity reaches the target
var air_accel_k := 1.5
var swim_accel_k := 3.0
var swim_coast_k := 1.2        # drag when no input in water
var gravity := 9.81
var jump_speed := 3.15
var wade_enter := 0.55         # water depth over the feet (m) where walking becomes wading
var wade_exit := 0.45
var swim_enter := 1.14         # depth where wading becomes swimming
var swim_exit := 1.04
var airborne_swim_depth := 0.7   # no ground + water over this depth = floating (chest band of a 1.38 m child)
var tread_band := 0.25         # eye within this of the surface counts as treading
var surface_hold_k := 6.0      # how firmly treading holds the eye at the surface
var buoyancy_rise := 0.25      # m/s gentle rise when idle in water (neutral-plus)
var float_time := 0.5         # s afloat (no ground) before wading turns into swimming
var coyote_time := 0.15        # s off the ground still counted as grounded (slopes, wave bob, small hops)
var max_speed := {Mode.WALK: 3.0, Mode.WADE: 2.6, Mode.SWIM: 6.0, Mode.TREAD: 3.0, Mode.FALL: 30.0}

var mode: int = Mode.WALK
var velocity := Vector3.ZERO
var facing_yaw := 0.0
var mode_time := 0.0
var transitions := 0
var air_time := 0.0

func configure(rec: Dictionary) -> void:
	for k in rec:
		if k in self:
			set(k, rec[k])

## Sense: what the body found this tick. feet = body base position; water_y = surface height at the body;
## current = water velocity at the body (m/s).
static func sense(feet: Vector3, on_floor: bool, floor_normal: Vector3, water_y: float, current: Vector3) -> Dictionary:
	return {"feet": feet, "on_floor": on_floor, "floor_normal": floor_normal, "water_y": water_y, "current": current}

func depth(s: Dictionary) -> float:
	return s.water_y - s.feet.y

func _next_mode(s: Dictionary, inp) -> int:
	var d := depth(s)
	var g: bool = s.on_floor or (air_time < coyote_time and velocity.y < 0.5)
	var eye_depth: float = s.water_y - (s.feet.y + eye_height)
	match mode:
		Mode.WALK, Mode.FALL:
			# airborne in water past the chest band: she is floating, not wading (wading needs ground under her)
			if d > swim_enter or (not g and d > airborne_swim_depth):
				return Mode.SWIM
			if not g:
				return Mode.FALL
			if d > wade_enter:
				return Mode.WADE
			return Mode.WALK if g else Mode.FALL
		Mode.WADE:
			# wading only becomes swimming past swim_enter, or after floating off the ground for float_time above
			# swim_exit (keeps the 1.04/1.14 hysteresis intact while bobbing in chest-deep water)
			if d > swim_enter or (air_time > float_time and d > swim_exit + 0.05):
				return Mode.SWIM
			if d < wade_exit:
				return Mode.WALK if g else Mode.FALL
			return Mode.WADE
		Mode.SWIM, Mode.TREAD:
			if s.get("stand_blocked", false):
				pass   # no room for the standing body here (cave, overhang): keep swimming
			elif g and d < swim_exit:
				return Mode.WADE if d > wade_exit else Mode.WALK
			elif d < 0.0:
				return Mode.FALL   # left the water (e.g. wave dropped away)
			var diving: bool = inp.descend or (inp.move.y > 0.2 and inp.cam_pitch < -0.35)
			if absf(eye_depth) < tread_band and not diving:
				return Mode.TREAD
			if mode == Mode.TREAD and eye_depth < tread_band * 1.6 and not diving:
				return Mode.TREAD   # hysteresis
			return Mode.SWIM
	return mode

static func _exp_blend(cur: Vector3, target: Vector3, k: float, dt: float) -> Vector3:
	return target + (cur - target) * exp(-k * dt)

## One tick. Returns the velocity the adapter should apply this tick.
func step(dt: float, inp, s: Dictionary) -> Vector3:
	air_time = 0.0 if s.on_floor else air_time + dt
	var nm := _next_mode(s, inp)
	if nm != mode:
		mode = nm; mode_time = 0.0; transitions += 1
	mode_time += dt
	var fwd := Vector3(-sin(inp.cam_yaw), 0.0, -cos(inp.cam_yaw))
	var right := Vector3(cos(inp.cam_yaw), 0.0, -sin(inp.cam_yaw))
	match mode:
		Mode.WALK, Mode.WADE, Mode.FALL:
			var spd: float = crouch_speed if inp.descend else lerpf(walk_speed, jog_speed, clampf((inp.move.length() - 0.6) / 0.4, 0.0, 1.0))
			spd = maxf(spd, lerpf(walk_speed, jog_speed, inp.thrust)) if not inp.descend else spd
			if mode == Mode.WADE:
				var t := clampf((depth(s) - wade_exit) / (swim_enter - wade_exit), 0.0, 1.0)
				spd *= lerpf(0.85, 0.55, t)
			var wish: Vector3 = (right * inp.move.x + fwd * inp.move.y)
			var target_h: Vector3 = wish * spd
			var hv := Vector3(velocity.x, 0.0, velocity.z)
			var k := ground_accel_k if s.on_floor else air_accel_k
			hv = _exp_blend(hv, target_h, k, dt)
			var vy := velocity.y
			if s.on_floor:
				vy = minf(vy, 0.0)
				if inp.jump_pressed and mode == Mode.WALK:
					vy = jump_speed
			vy -= gravity * dt * (0.35 if mode == Mode.WADE else 1.0)
			if mode == Mode.WADE:
				hv += Vector3(s.current.x, 0.0, s.current.z) * (1.0 - exp(-0.8 * dt))
			velocity = Vector3(hv.x, vy, hv.z)
		Mode.SWIM, Mode.TREAD:
			var cp := cos(inp.cam_pitch)
			var look_fwd := Vector3(-sin(inp.cam_yaw) * cp, sin(inp.cam_pitch), -cos(inp.cam_yaw) * cp)
			var up: float = (1.0 if inp.ascend else 0.0) - (1.0 if inp.descend else 0.0)
			var wish3: Vector3 = right * inp.move.x + look_fwd * inp.move.y + Vector3.UP * up
			if wish3.length() > 1.0:
				wish3 = wish3.normalized()
			var spd3: float = lerpf(cruise_speed, sprint_speed, inp.thrust)
			var rel: Vector3 = velocity - s.current
			var target: Vector3 = wish3 * spd3
			var k3 := swim_accel_k if wish3.length() > 0.05 else swim_coast_k
			rel = _exp_blend(rel, target, k3, dt)
			if wish3.length() <= 0.05:
				rel.y = lerpf(rel.y, buoyancy_rise, 1.0 - exp(-1.0 * dt))
			velocity = rel + s.current
			if mode == Mode.TREAD:
				var eye_y: float = s.feet.y + eye_height
				var err: float = (s.water_y - 0.05) - eye_y
				if up <= 0.0 or err < 0.0:
					velocity.y = _exp_blend(Vector3(0, velocity.y, 0), Vector3(0, err * surface_hold_k, 0), 8.0, dt).y
	# speed cap (I10 guard is in the harness; this cap is the declared limit, not a hidden clamp)
	var cap: float = max_speed[mode] + s.current.length()
	if velocity.length() > cap:
		velocity = velocity.normalized() * cap
	var hvel := Vector2(velocity.x, velocity.z)
	if hvel.length() > 0.2:
		var target_yaw := atan2(-velocity.x, -velocity.z)
		facing_yaw = lerp_angle(facing_yaw, target_yaw, 1.0 - exp(-8.0 * dt))
	return velocity

## Adapter reports the velocity that actually happened after collision (slides, stops).
func post_move(actual_velocity: Vector3) -> void:
	velocity = actual_velocity

func mode_name() -> String:
	return MODE_NAMES[mode]
