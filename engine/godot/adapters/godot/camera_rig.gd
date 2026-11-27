## M03 Camera, Godot adapter 0.2.0: a Camera3D driven by the Thalassa-ported no-cut camera (core/m03_camera/
## nocut_camera.gd). Owns the look angles (Thalassa input.js look rates integrate here, then reach the swimmer through
## the packet's cam_yaw / cam_pitch, which is where Thalassa's swimmer.applyLook puts them).
## The spring arm asks the world through Jolt: floor_height = a ray down, nearest_surface = a sphere overlap.
## Shots: "explore" / "swim" = third person over the shoulder, "first_person" / "observe" = first person
## (the observation camera's own framing arrives with M06; Thalassa observation-camera.js).
extends Camera3D

const Cam := preload("res://core/m03_camera/nocut_camera.gd")
const WorldQuery := preload("res://adapters/godot/world_query.gd")

var core = Cam.new()
var exclude: Array[RID] = []    # bodies the spring arm ignores (the player); handed to the world query
var wq = null
var body = null                 # adapters/godot/player_body.gd (actor frame source)
var shot := "explore"
var yaw := 0.0
var pitch := -0.14
var pitch_limit := 1.42         # Thalassa swimmer pitchLimit
var probe_enabled := true       # tests switch it off to prove the checks catch a camera inside walls
var last := {}
var last_frame := {}
var t := 0.0
var hard_snaps := 0             # kept for the stress report (the Thalassa arm has no hard snap)
var water_gap := 0.2
var water_spring = Cam.Spring1.new()

func request(name: String) -> void:
	shot = name

func _query():
	if wq == null:
		wq = WorldQuery.new(get_world_3d(), 1)
	wq.exclude = exclude
	return wq

func _floor_height(x: float, z: float) -> float:
	var q = _query()
	q.top = last_frame.pos.y if not last_frame.is_empty() else 0.0
	q.depth = 60.0
	return q.floor_height(x, z)

func _nearest_surface(p: Vector3, r: float) -> Dictionary:
	return _query().nearest_surface(p, r)

## Once per physics tick after the player moved. look: rad/s (x = turn right, y = up). Returns the frame plus
## body_alpha (0 when the lens is inside the head) and blend (1 = settled in the requested shot).
func tick(dt: float, _eye: Vector3, look: Vector2, _water_y: float) -> Dictionary:
	t += dt
	yaw = wrapf(yaw - look.x * dt, -PI, PI)
	pitch = clampf(pitch + look.y * dt, -pitch_limit, pitch_limit)
	var tp := not (shot == "first_person" or shot == "observe")
	last_frame = body.motor.swimmer.get_actor_frame(t)
	var env := {}
	if probe_enabled:
		env = {"floor_height": _floor_height, "nearest_surface": _nearest_surface}
	last = core.update_for_actor(dt, last_frame, {"third_person": tp,
		"landing_impact": body.motor.swimmer.shore_landing_impact, "braking_impulse": body.motor.swimmer.shore_braking_impulse}, env)
	var lens: Vector3 = last.pos
	# Water line (kept from M03 0.1.0, not in Thalassa): a lens within water_gap of the surface shows a half-above,
	# half-below frame. Thalassa keeps the lens under the surface only once the swimmer is 0.35 m down; at the surface
	# and in the shallows nothing stops it, so the lens is lifted or dropped off the line toward the eye's side.
	var want_dy := 0.0
	if _water_y > -1e8 and absf(lens.y - _water_y) < water_gap:
		var side := 1.0 if last_frame.pos.y >= _water_y else -1.0
		var to := Vector3(lens.x, _water_y + side * water_gap, lens.z)
		if not probe_enabled or _nearest_surface(to, 0.12).is_empty():
			want_dy = to.y - lens.y
	# a fast critically damped spring on the push: when the eye crosses the surface the lens changes side in about
	# three ticks instead of jumping 2 x water_gap in one (no cut)
	# third person only: in first person the lens is the eye (Thalassa treads with the eye 0.14 m under the surface)
	lens.y += water_spring.step(want_dy * smoothstep(0.25, 0.45, last.third_person_blend), 0.025, dt)
	last.pos = lens
	global_position = lens
	if lens.distance_to(last.look_target) > 0.01:
		look_at(last.look_target, last.up)
	fov = last.fov
	var b: float = last.third_person_blend
	var settled: bool = (b == 1.0) if tp else core._was_rigid_1p     # 1P is settled once the core locks rigid
	var head_d: float = lens.distance_to(last_frame.head_pos)        # final lens (after the water-line push)
	last["body_alpha"] = 0.0 if (not last.show_head or last.hide_self_body or head_d <= 0.25) else 1.0
	last["blend"] = 1.0 if settled else 0.5
	last["fp_pos"] = Cam.actor_frame(last_frame).fp_pos
	return last
