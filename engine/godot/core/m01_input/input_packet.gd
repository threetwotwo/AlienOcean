## M01 Input, core 0.1.0 (engine-agnostic logic: no Input singleton, no nodes).
## One InputPacket per physics tick. The adapter fills it from the device; scripts and monkey runs fill it directly.
## Axes are already shaped (radial deadzone + response curve) by shape_stick().
## Camera yaw/pitch ride along so movement can be camera-relative without the motor knowing the camera.
extends RefCounted

var move := Vector2.ZERO      # x = right, y = forward, length <= 1
var look := Vector2.ZERO      # rad/s requested look rate (adapter scales by sensitivity)
var thrust := 0.0             # R2 analog 0..1 (sprint / boost)
var ascend := false           # Cross held
var descend := false          # Circle held (crouch on land)
var jump_pressed := false     # Cross went down this tick
var interact_pressed := false # Square went down this tick
var cam_yaw := 0.0            # camera heading (rad), 0 = looking down -Z
var cam_pitch := 0.0          # camera pitch (rad), + = looking up

const DEADZONE := 0.12
const CURVE := 1.6

## Radial deadzone with rescale, then a power curve on magnitude. Keeps direction exact.
static func shape_stick(raw: Vector2) -> Vector2:
	var m := raw.length()
	if m <= DEADZONE or is_nan(m):
		return Vector2.ZERO
	var t := clampf((m - DEADZONE) / (1.0 - DEADZONE), 0.0, 1.0)
	return raw / m * pow(t, CURVE)

func copy():
	var p = get_script().new()
	p.move = move; p.look = look; p.thrust = thrust; p.ascend = ascend; p.descend = descend
	p.jump_pressed = jump_pressed; p.interact_pressed = interact_pressed
	p.cam_yaw = cam_yaw; p.cam_pitch = cam_pitch
	return p
