## M01 Look filter, core 0.2.0: Thalassa v20.19 input.js right-stick look (dual-zone precision + outer-zone turn
## boost + asymmetric accel/stop filter). Engine-agnostic; one per player. Returns look rate in rad/s.
extends RefCounted

const Table := preload("res://core/m01_input/action_table.gd")
const Packet := preload("res://core/m01_input/input_packet.gd")

var sensitivity := 1.0
var invert_y := false
var yaw_vel := 0.0
var pitch_vel := 0.0
var outer_boost := 0.0

static func _k(hz: float, dt: float) -> float:
	return 1.0 - exp(-maxf(0.0, hz * dt))

## raw: right stick with +x right, +y up (already sign-fixed by the adapter). photo_zoom > 0 = in the viewfinder.
func step(raw: Vector2, dt: float, photo_zoom: float = 0.0) -> Vector2:
	var sdt := clampf(dt, 0.0001, 0.05)
	var raw_mag := raw.length()
	var r := Packet.shape_stick(raw, Table.MOVE_DEADZONE, Table.LOOK_EXPONENT)
	var photo := photo_zoom > 0.0
	var outer_goal := 1.0 if (not photo and raw_mag > 0.82) else 0.0
	outer_boost = lerpf(outer_boost, outer_goal, _k(5.5 if outer_goal > 0.5 else 16.0, sdt))
	var boost := lerpf(1.0, Table.LOOK_BOOST_MAX, outer_boost)
	var photo_scale := 0.52 / sqrt(maxf(1.0, photo_zoom)) if photo else 1.0
	var spd := Table.LOOK_SPEED * sensitivity * boost * photo_scale
	var tgt_yaw := r.x * spd                                   # + = turn right (Thalassa yawDelta sign flipped
	var tgt_pitch := r.y * spd * Table.LOOK_PITCH_SCALE * (-1.0 if invert_y else 1.0)  # to this project's look.x)
	var yhz := Table.LOOK_STOP_HZ if absf(tgt_yaw) < absf(yaw_vel) else Table.LOOK_ACCEL_HZ
	var phz := Table.LOOK_STOP_HZ if absf(tgt_pitch) < absf(pitch_vel) else Table.LOOK_ACCEL_HZ
	yaw_vel = lerpf(yaw_vel, tgt_yaw, _k(yhz, sdt))
	pitch_vel = lerpf(pitch_vel, tgt_pitch, _k(phz, sdt))
	if absf(yaw_vel) < 1e-4: yaw_vel = 0.0
	if absf(pitch_vel) < 1e-4: pitch_vel = 0.0
	return Vector2(yaw_vel, pitch_vel)

func reset() -> void:
	yaw_vel = 0.0; pitch_vel = 0.0; outer_boost = 0.0
