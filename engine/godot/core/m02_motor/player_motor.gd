## M02 Player motor, core 0.2.0: Thalassa v20.19 player mover (core/mover.js createThalassaPlayerMover, the
## Swimming / Wading / ShoreWalking modes) around the ported SwimmerLocomotion. Engine-agnostic.
## Deck walking, piloting, moonpool and creature modes arrive with M09 / M05 (they need vessels and creatures).
## The Godot adapter supplies env (floor via Jolt rays, collisions via CharacterBody3D) and reads swimmer.pos (eye).
## Packet -> Thalassa input: forward/right = left stick, up = Cross or L1 (+1) minus L2 analog, boost = R2 / L3 latch,
## jumpHeld = Cross (Thalassa input.js mapping).
## Look: the camera (M03) owns yaw/pitch; the swimmer follows them with smoothing 0 (Thalassa's crisp setting).
extends RefCounted

const Swimmer := preload("res://core/m02_motor/swimmer_locomotion.gd")
const Layers := preload("res://core/m02_motor/layered_moves.gd")
const BodyAct := preload("res://core/m02_motor/body_act.gd")

enum Mode { WALK, WADE, SWIM, TREAD, FALL, REST, RIDE }
const MODE_NAMES := ["WALK", "WADE", "SWIM", "TREAD", "FALL", "REST", "RIDE"]

var swimmer = Swimmer.new()
## Resting and riding (core/m02_motor/body_act.gd): request_rest / request_ride start one; while it holds her the
## swimmer is not integrated. The rig reads it as swimmer.act.
var act = BodyAct.new()
var layers = Layers.new()
var transitions := 0
var mode_time := 0.0
var total_time := 0.0
var surface_y := 0.0
var _mode_cache: int = Mode.WALK
var _boost_prev := false
var sync := {"movement_mode": "ShoreWalking", "position": Vector3.ZERO, "velocity": Vector3.ZERO, "surface_y": 0.0}
# speed caps for the stress invariant I10 (Thalassa soft caps: swim (5.0 + 0.45 dive + 1.35 slip) x 1.24, burst,
# breach 5.8 m/s up, 15.5 m/s2 above-water gravity; shore jog 2.45 + running dive 1.45 + jump 3.15)
var max_speed := {Mode.WALK: 5.0, Mode.WADE: 5.0, Mode.SWIM: 9.5, Mode.TREAD: 9.5, Mode.FALL: 30.0, Mode.REST: 2.0, Mode.RIDE: 9.5}
var swim_enter: float:
	get: return swimmer.config.wade_exit_depth
var facing_yaw: float:
	get: return swimmer.yaw
var height := 1.38
var eye_height: float:
	get: return swimmer.config.eye_height

var mode: int:
	get: return _mode_cache
	set(v):
		# test/spawn hook: start swimming (Thalassa: not shore-grounded) or standing
		if v == Mode.SWIM or v == Mode.TREAD:
			swimmer.shore_grounded = false
		_mode_cache = v

func _init() -> void:
	swimmer.act = act

func enable_current(get_current: Callable) -> void:
	layers.queue(Layers.ocean_current(get_current))

## resolveThalassaMoverMode for the shore/swim family.
func mover_mode_name() -> String:
	if swimmer.shore_grounded:
		return "Wading" if swimmer.wade_blend > 0.10 else "ShoreWalking"
	return "Swimming"

func _classify() -> int:
	var s = swimmer
	if act.holding():
		return Mode.RIDE if act.kind == "ride" else Mode.REST
	if s.shore_grounded:
		if s.shore_is_airborne: return Mode.FALL
		return Mode.WADE if s.wade_blend > 0.10 else Mode.WALK
	# labels only (Thalassa has one Swimming mode); hysteresis so a label never flickers on a threshold
	var was := _mode_cache
	var fall_line := surface_y + (0.15 if was == Mode.FALL else 0.28)
	if s.pos.y > fall_line:          # treading holds the eye at surface - 0.14, never this high
		return Mode.FALL          # breach arc or a drop on land: the above-water branch (gravity 15.5)
	var tread_line := 0.35 if was == Mode.TREAD else 0.65
	return Mode.TREAD if s.surface_tread_blend > tread_line else Mode.SWIM

func mode_name() -> String:
	return MODE_NAMES[_mode_cache]

func input_from_packet(k) -> Dictionary:
	var boost: bool = k.thrust > 0.28                        # Thalassa: R2 raw past 0.28 (or the L3 latch)
	var dive: float = maxf(k.descend_amount, 1.0 if k.descend else 0.0)   # L2 analog dive / crouch
	var d := {"forward": k.move.y, "right": k.move.x, "up": clampf((1.0 if k.ascend else 0.0) - dive, -1.0, 1.0),
		"boost": boost, "boost_just_pressed": boost and not _boost_prev, "jump_held": k.ascend or k.jump_pressed,
		"yaw_delta": wrapf(k.cam_yaw - swimmer.target_yaw, -PI, PI), "pitch_delta": k.cam_pitch - swimmer.target_pitch,
		"smoothing": 0.0}
	_boost_prev = boost
	return d

## One tick (Thalassa MoverComponent.step for the swim/shore family). env: see swimmer_locomotion.gd.
func step(dt: float, k, env: Dictionary, water_y: float) -> void:
	total_time += dt
	surface_y = water_y
	sync.surface_y = water_y
	var mm := mover_mode_name()
	sync.movement_mode = mm
	sync.position = swimmer.pos
	var inp := input_from_packet(k)
	if act.step(dt, swimmer, inp):
		# held (seated, lying, riding): the act placed the eye; no layers, no integration, no collisions
		sync.position = swimmer.pos
		sync.velocity = swimmer.vel
		_set_mode(_classify(), dt)
		return
	var prop: Dictionary = layers.evaluate(dt, mm, sync, {"total_time": total_time})
	if prop.override_velocity != null:
		swimmer.vel = prop.override_velocity
	elif not swimmer.shore_grounded:
		swimmer.vel += prop.layered_delta_vel
	swimmer.update(dt, inp, env)
	sync.position = swimmer.pos
	sync.velocity = swimmer.vel
	_set_mode(_classify(), dt)

func _set_mode(m: int, dt: float) -> void:
	mode_time += dt
	if m != _mode_cache:
		transitions += 1
		mode_time = 0.0
	_mode_cache = m

## Sit (stool / bench) or lie (bunk) at the given markers; see body_act.gd. false (act.refused says why) when refused.
func request_rest(spec: Dictionary) -> bool:
	return act.request_rest(spec, swimmer)

## Latch onto a creature stand-in (marker(), slots(), velocity, LENGTH, species); false when out of reach etc.
func request_ride(rider) -> bool:
	return act.request_ride(rider, swimmer)
