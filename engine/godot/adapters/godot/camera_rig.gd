## M03 Camera, Godot adapter 0.1.0: a Camera3D driven by the camera director core.
## The probe is a sphere sweep against world geometry (layer 1) that ignores the player.
extends Camera3D

const Director := preload("res://core/m03_camera/camera_director.gd")

var director = Director.new()
var exclude: Array[RID] = []
var last := {}
var probe_enabled := true   # tests switch it off to prove the checks catch a camera inside walls

func probe(from: Vector3, to: Vector3, r: float) -> float:
	if not probe_enabled:
		return 1.0
	var motion := to - from
	if motion.length() < 1e-5:
		return 1.0
	var q := PhysicsShapeQueryParameters3D.new()
	var sp := SphereShape3D.new(); sp.radius = r
	q.shape = sp
	q.transform = Transform3D(Basis(), from)
	q.motion = motion
	q.collision_mask = 1
	q.exclude = exclude
	var res := get_world_3d().direct_space_state.cast_motion(q)
	return res[0] if res.size() > 0 else 1.0

func overlap(pos: Vector3, r: float) -> bool:
	if not probe_enabled:
		return false
	var q := PhysicsShapeQueryParameters3D.new()
	var sp := SphereShape3D.new(); sp.radius = r
	q.shape = sp
	q.transform = Transform3D(Basis(), pos)
	q.collision_mask = 1
	q.exclude = exclude
	return get_world_3d().direct_space_state.intersect_shape(q, 1).size() > 0

## Call once per physics tick after the player moved. Returns the director's frame.
func tick(dt: float, eye: Vector3, look: Vector2, water_y: float) -> Dictionary:
	last = director.update(dt, {"eye": eye}, look, probe, water_y, overlap)
	global_position = last.pos
	rotation = Vector3(last.pitch, last.yaw, 0.0)
	fov = last.fov
	return last
