## ActorRig 0.1.0 (adapters/godot; game root thread, 27 Nov 2026): one assembled player actor = the motor's body
## (adapters/godot/player_body.gd, M02), the body rig (core/m04_body/body_rig.gd, M04) and the girl mannequin
## (adapters/godot/mannequin.gd). Architecture review 27 Nov follow-up: "a small ActorRig assembler shared by
## game_root, motion_film and test_body_stress, so tools stop depending on tests/". The wiring is the film tool's
## (tools/motion_film.gd, gameplay thread), unchanged: body.tick -> surface_y at the feet -> WorldQuery top at the eye
## -> body rig update_timers + update_swim -> mannequin.apply. Only this file knows that order; callers give it t
## (from SimClock) and a water object (WaterQuery contract), and read back what the registry needs.
## The rig and the mannequin are the body thread's; this file only calls them.
class_name ActorRig
extends Node3D

const Body := preload("res://adapters/godot/player_body.gd")
const BodyRig := preload("res://core/m04_body/body_rig.gd")
const Mannequin := preload("res://adapters/godot/mannequin.gd")
const WorldQuery := preload("res://adapters/godot/world_query.gd")

@export var with_mannequin := true      # false: motor only (headless stress runs that don't need the pose)
var body: CharacterBody3D
var brig = BodyRig.new()
var mq: Node3D = null
var wq = null
var benv := {}
var pose := {}
var head_visible := true
var capsule := {"centre": Vector3.ZERO, "axis": Vector3.UP, "half_len": 0.44, "radius": 0.25}

func _init() -> void:
	name = "ActorRig"
	body = Body.new(); body.name = "PlayerBody"

func _ready() -> void:
	add_child(body)
	# treading floats her with the head out of the water (eye 8 cm above the waterline, chin at it), not Thalassa's eye 14 cm under
	body.motor.swimmer.config["tread_eye"] = 0.08
	if with_mannequin:
		mq = Mannequin.new(); mq.name = "Mannequin"
		add_child(mq)    # the mannequin poses in world space (global transforms), so where it hangs doesn't matter

## Place the body (feet) before the first tick. swim = start in the water (Motor.Mode.SWIM).
func spawn(feet: Vector3, swim := false) -> void:
	body.position = feet
	if swim: body.motor.mode = body.motor.Mode.SWIM

## One physics tick. inp: an InputPacket (core/m01_input). water: WaterQuery (level, water_y, current). t: SimClock.t.
func tick(dt: float, inp, water, t: float) -> void:
	body.tick(dt, inp, water, t)
	if mq == null: return
	var s = body.motor.swimmer
	var p: Vector3 = body.global_position
	s.config.surface_y = water.water_y(p.x, p.z, t) if water.level > -999.0 else -1000.0
	if wq == null:
		wq = WorldQuery.new(get_world_3d(), 1); wq.exclude.append(body.get_rid()); benv = wq.as_env()
	wq.top = s.pos.y + 0.05      # floor rays start at the eye (from higher up a cave roof reads as floor)
	brig.update_timers(dt)
	pose = brig.update_swim(dt, s, null, t, benv)
	_capsule_from_pose()

## Draw the pose (after the camera decided whether the head shows). alpha: the camera's body_alpha.
func draw(alpha := 1.0) -> void:
	if mq == null or pose.is_empty(): return
	mq.set_alpha(alpha)
	mq.apply(pose, head_visible)

func _capsule_from_pose() -> void:
	## the body as a capsule from the head to the ankles (the fish school's perceived-actor shape, radius 0.25)
	var head: Vector3 = pose.headMat.origin
	var feet: Vector3 = (pose.legL.ik.eff + pose.legR.ik.eff) * 0.5
	var v := head - feet
	var L := v.length()
	capsule.centre = (head + feet) * 0.5
	capsule.axis = v / L if L > 1e-4 else Vector3.UP
	capsule.half_len = maxf(L * 0.5 - capsule.radius + 0.12, 0.0)   # + head radius above the head joint

func eye_point() -> Vector3:
	return body.eye_point()

func centre() -> Vector3:
	return capsule.centre if not pose.is_empty() else body.global_position + Vector3(0, 0.6, 0)

func velocity() -> Vector3:
	return body.motor.swimmer.vel

func mode_name() -> String:
	return body.motor.mode_name()
