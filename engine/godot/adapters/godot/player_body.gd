## M02 Player motor, Godot adapter 0.1.0. Moves a CharacterBody3D (Jolt) with the velocity the core asks for.
## - Grounded motion on land/wading, floating motion in water (all contacts are walls).
## - Two collision shapes: standing capsule (1.38 m) and a swim sphere (r 0.42). Swapping to standing only
##   happens when the capsule fits; otherwise the core is told (sense.stand_blocked) and keeps swimming.
## - Step-up for ledges up to step_height (Godot has no built-in stair step).
extends CharacterBody3D

const Motor := preload("res://core/m02_motor/player_motor.gd")

var motor = Motor.new()
var step_height := 0.35
var stand_shape := CapsuleShape3D.new()
var swim_shape := SphereShape3D.new()
var col := CollisionShape3D.new()
var swimming_shape := false
var blocked_stand := 0          # ticks the stand-up was refused for lack of room
var last_sense := {}
var step_pops := 0
var eye_h := 1.24               # head height above the feet; eases between standing and swimming (no camera jump)
var eye_speed := 2.5            # m/s
var ticked := false

func _init() -> void:
	stand_shape.radius = 0.25
	stand_shape.height = motor.height
	swim_shape.radius = 0.42
	col.shape = stand_shape
	col.position = Vector3(0, motor.height * 0.5, 0)
	add_child(col)
	floor_max_angle = deg_to_rad(40.0)
	floor_snap_length = 0.3
	safe_margin = 0.01
	collision_layer = 2
	collision_mask = 1

func _stand_fits() -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = stand_shape
	q.transform = Transform3D(Basis(), global_position + Vector3(0, motor.height * 0.5 + 0.02, 0))
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(q, 1).size() == 0

func _set_swim_shape(on: bool) -> void:
	if on == swimming_shape:
		return
	col.shape = swim_shape if on else stand_shape
	col.position = Vector3(0, swim_shape.radius, 0) if on else Vector3(0, motor.height * 0.5, 0)
	swimming_shape = on

## One physics tick. env must provide water_y(x, z, t) and current(p, t).
func tick(dt: float, inp, env, t: float) -> void:
	var feet := global_position
	var grounded := is_on_floor()
	var gn := get_floor_normal() if grounded else Vector3.UP
	if motion_mode == CharacterBody3D.MOTION_MODE_FLOATING:
		# floating bodies never report a floor: probe for one under the feet
		var rq := PhysicsRayQueryParameters3D.create(feet + Vector3(0, 0.1, 0), feet + Vector3(0, -0.15, 0), collision_mask, [get_rid()])
		var hit := get_world_3d().direct_space_state.intersect_ray(rq)
		grounded = not hit.is_empty() and hit.normal.angle_to(Vector3.UP) <= floor_max_angle
		if grounded:
			gn = hit.normal
	var s: Dictionary = Motor.sense(feet, grounded, gn,
		env.water_y(feet.x, feet.z, t), env.current(feet, t))
	s["stand_blocked"] = swimming_shape and not _stand_fits()
	if s.stand_blocked:
		blocked_stand += 1
	last_sense = s
	var v: Vector3 = motor.step(dt, inp, s)
	var in_water: bool = motor.mode == Motor.Mode.SWIM or motor.mode == Motor.Mode.TREAD
	_set_swim_shape(in_water)
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING if in_water else CharacterBody3D.MOTION_MODE_GROUNDED
	velocity = v
	var before := global_position
	var was_grounded := grounded
	move_and_slide()
	if not in_water and was_grounded:
		var want := Vector2(v.x, v.z).length() * dt
		var got := Vector2(global_position.x - before.x, global_position.z - before.z).length()
		if want > 0.002 and got < want * 0.5:
			_try_step_up(before, v, dt)
	motor.post_move(velocity)
	eye_h = move_toward(eye_h, 0.55 if swimming_shape else 1.24, eye_speed * dt if ticked else 10.0)
	ticked = true

func _try_step_up(before: Vector3, v: Vector3, dt: float) -> void:
	# Lift onto a ledge up to step_height: probe ahead by at least the capsule radius (so the down-probe lands on
	# the ledge top, not its edge), then commit only this tick's forward motion at the ledge height.
	var h := Vector3(v.x, 0, v.z) * dt
	if h.length() < 0.0005:
		return
	var dir := h.normalized()
	var probe := dir * maxf(h.length(), stand_shape.radius + 0.06)
	var from := Transform3D(global_basis, before)
	if test_move(from, Vector3(0, step_height, 0)):
		return
	var up_t := from.translated(Vector3(0, step_height, 0))
	if test_move(up_t, probe):
		return
	# smallest forward distance whose down-probe lands on a walkable top (keeps the visual pop small)
	for d in [h.length(), 0.08, 0.16, probe.length()]:
		if d > probe.length() + 1e-4:
			continue
		var off: Vector3 = dir * float(d)
		var col_res := KinematicCollision3D.new()
		if not test_move(up_t.translated(off), Vector3(0, -step_height - 0.05, 0), col_res):
			continue
		if col_res.get_normal().angle_to(Vector3.UP) > floor_max_angle:
			continue
		var land_y: float = up_t.origin.y + col_res.get_travel().y
		if land_y <= before.y + 0.01:
			continue
		global_position = Vector3(before.x + off.x, land_y + 0.005, before.z + off.z)
		step_pops += 1
		return

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

## The head point the camera follows (1P lens sits here). Continuous even when the collision shape swaps.
func eye_point() -> Vector3:
	return global_position + Vector3(0, eye_h, 0)
