## M02 Player body, Godot adapter 0.2.0: runs the Thalassa-ported motor (core/m02_motor) on a Jolt CharacterBody3D.
## The core is kinematic on the EYE point (as Thalassa). This adapter gives it:
##   floor_height / terrain_normal: a Jolt ray down. While standing the ray starts step_height above the feet, so a
##     ledge up to 0.35 m is stepped onto and anything taller is a wall (Thalassa's height-field had no walls; a
##     1.38 m child does not walk up a 50 cm ledge: kept from 0.1.0 because the T1 step tests demand it).
##   resolve_collisions: CharacterBody3D.move_and_slide with the real shapes (standing capsule 1.38 m, swim sphere
##     r 0.42 at the eye). Thalassa's radius 0.55 sphere does not fit the 1.0 m cave a child can swim through (T5).
##   stand_blocked: grounding is refused while the standing capsule would not fit (low ceilings over shallows).
## Body origin = feet (eye - 1.24 standing, eye - 0.42 swimming); eye_point() is the swimmer's eye, continuous.
extends CharacterBody3D

const Motor := preload("res://core/m02_motor/player_motor.gd")
const WorldQuery := preload("res://adapters/godot/world_query.gd")

var motor = Motor.new()
var step_height := 0.35
var stand_shape := CapsuleShape3D.new()
var swim_shape := SphereShape3D.new()
var col := CollisionShape3D.new()
var swimming_shape := false
var blocked_stand := 0
var last_sense := {}
var step_pops := 0
var started := false
var _env_cache = null
var _t := 0.0
var _dt := 1.0 / 60.0
var _env_dict := {}
var wq = null

func _init() -> void:
	stand_shape.radius = 0.25
	stand_shape.height = 1.38 - step_height   # standing body starts step_height above the feet: ledges below
	swim_shape.radius = 0.42                   # that height are the floor ray's job (stepped onto), not walls
	col.shape = stand_shape
	col.position = Vector3(0, _stand_center(), 0)
	add_child(col)
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	safe_margin = 0.01
	collision_layer = 2
	collision_mask = 1
	_env_dict = {"floor_height": _floor_height, "terrain_normal": _terrain_normal, "local_surface": _local_surface,
		"water_current": _water_current, "resolve_collisions": _resolve, "stand_blocked": _stand_blocked}

func _stand_center() -> float:
	return step_height + (1.38 - step_height) * 0.5

func _eye_off() -> float:
	return 0.42 if swimming_shape else 1.24

func _ray_floor(x: float, z: float) -> Dictionary:
	var s = motor.swimmer
	var top: float = (s.pos.y - 1.24 + step_height + 0.01) if s.shore_grounded else s.pos.y
	if wq == null:
		wq = WorldQuery.new(get_world_3d(), collision_mask)
		wq.exclude = [get_rid()]
	return wq.ray_down(x, z, top, 80.0)

## Standing on dry land, a surface too steep to walk (Thalassa: normal.y < 0.56) is a wall, not a reason to start
## swimming: the floor stays where the feet are and the standing capsule meets the slope. In water the core's own
## release-to-swim applies (wading onto steep rock).
func _steep_wall(h: Dictionary) -> bool:
	var s = motor.swimmer
	return s.shore_grounded and h.normal.y < 0.56 and s.shore_water_depth < 0.3

func _floor_height(x: float, z: float) -> float:
	var h := _ray_floor(x, z)
	if h.is_empty(): return -INF
	return (motor.swimmer.pos.y - 1.24) if _steep_wall(h) else h.position.y

func _terrain_normal(x: float, z: float) -> Vector3:
	var h := _ray_floor(x, z)
	if h.is_empty(): return Vector3.UP
	return Vector3.UP if _steep_wall(h) else h.normal

func _local_surface(p: Vector3) -> Dictionary:
	var lvl: float = _env_cache.level
	return {"enclosed": false, "surface_y": _env_cache.water_y(p.x, p.z, _t) if lvl > -999.0 else lvl}

func _water_current(p: Vector3, _tt: float) -> Vector3:
	return _env_cache.current(p, _t) if _env_cache.level > -999.0 else Vector3.ZERO

func _stand_fits_at(feet: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = stand_shape
	q.transform = Transform3D(Basis(), feet + Vector3(0, _stand_center() + 0.02, 0))
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(q, 1).size() == 0

func _stand_blocked(eye: Vector3, floor_y: float) -> bool:
	var b := not _stand_fits_at(Vector3(eye.x, floor_y, eye.z))
	if b: blocked_stand += 1
	return b

func _set_swim_shape(on: bool) -> void:
	if on == swimming_shape:
		return
	var eye: Vector3 = global_position + Vector3(0, _eye_off(), 0)
	swimming_shape = on
	col.shape = swim_shape if on else stand_shape
	col.position = Vector3(0, swim_shape.radius, 0) if on else Vector3(0, _stand_center(), 0)
	global_position = eye - Vector3(0, _eye_off(), 0)

## env.resolve_collisions: slide the body from where it is to the eye position the core wants.
func _resolve(pos: Vector3, vel: Vector3, _r: float, grounded: bool) -> Dictionary:
	_set_swim_shape(not grounded)
	var cur_eye: Vector3 = global_position + Vector3(0, _eye_off(), 0)
	var motion := pos - cur_eye
	if grounded:
		motion.y = 0.0                  # the core owns standing height (floor + eye); slide only across
	var want := motion / _dt
	velocity = want
	move_and_slide()
	if grounded:
		global_position.y = pos.y - 1.24
	# Thalassa resolveCollisions semantics: remove the velocity going into each contact, keep the rest. (Jolt's own
	# slide velocity can redirect a push against an edge sideways at full speed: fed back, it snowballs.)
	var out_vel := vel
	var impact := 0.0
	for i in get_slide_collision_count():
		var n := get_slide_collision(i).get_normal()
		if grounded:
			n.y = 0.0
			if n.length() < 1e-3: continue
			n = n.normalized()
		var into := out_vel.dot(n)
		if into < 0.0:
			impact = maxf(impact, -into)
			out_vel -= n * into
	return {"pos": global_position + Vector3(0, _eye_off(), 0), "vel": out_vel, "impact": impact}

func tick(dt: float, inp, env, t: float) -> void:
	_env_cache = env; _t = t; _dt = dt
	var s = motor.swimmer
	if not started:
		started = true
		var swim_start: bool = not s.shore_grounded and motor.mode == Motor.Mode.SWIM
		swimming_shape = swim_start     # spawn: the start position is the feet for either shape
		col.shape = swim_shape if swim_start else stand_shape
		col.position = Vector3(0, swim_shape.radius, 0) if swim_start else Vector3(0, _stand_center(), 0)
		s.set_pose(global_position + Vector3(0, _eye_off(), 0), inp.cam_yaw, inp.cam_pitch)
		if env.level > -999.0:
			motor.enable_current(func(p, tt): return env.current(p, t))
	var wy: float = env.water_y(s.pos.x, s.pos.z, t) if env.level > -999.0 else -1000.0
	motor.step(dt, inp, _env_dict, wy)
	# swim branch moved the eye but its collision callback already placed the body; keep them in step
	_set_swim_shape(not s.shore_grounded)
	global_position = s.pos - Vector3(0, _eye_off(), 0)
	velocity = s.vel
	var feet := global_position
	last_sense = {"feet": feet, "on_floor": s.shore_grounded and not s.shore_is_airborne, "floor_normal": s.shore_floor_normal,
		"water_y": wy, "current": _water_current(feet, t), "stand_blocked": false}

func penetrating(margin: float = 0.02) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	if swimming_shape:
		var sp := SphereShape3D.new(); sp.radius = swim_shape.radius - margin
		q.shape = sp
	else:
		var cp := CapsuleShape3D.new(); cp.radius = stand_shape.radius - margin; cp.height = stand_shape.height - 2.0 * margin
		q.shape = cp
	q.transform = Transform3D(Basis(), global_position + col.position)
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(q, 1).size() > 0

## The head point the camera follows (the swimmer's eye: continuous through every mode change).
func eye_point() -> Vector3:
	return motor.swimmer.pos
