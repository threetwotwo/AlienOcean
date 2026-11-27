## M01 Input, core 0.1.0 (engine-agnostic logic: no Input singleton, no nodes).
## One InputPacket per physics tick. The adapter fills it from the device; scripts and monkey runs fill it directly.
## Axes are already shaped (radial deadzone + response curve) by shape_stick().
## Camera yaw/pitch ride along so movement can be camera-relative without the motor knowing the camera.
extends RefCounted

var move := Vector2.ZERO      # x = right, y = forward, length <= 1
var look := Vector2.ZERO      # rad/s requested look rate (adapter scales by sensitivity)
var thrust := 0.0             # R2 analog 0..1 (sprint / boost)
var ascend := false           # Cross held
var descend := false          # L2 past 0.5 (dive / crouch)
var descend_amount := 0.0     # L2 analog 0..1 (Thalassa: analog dive)
var jump_pressed := false     # Cross went down this tick
var interact_pressed := false # Square went down this tick
var cam_yaw := 0.0            # camera heading (rad), 0 = looking down -Z
var cam_pitch := 0.0          # camera pitch (rad), + = looking up

const DEADZONE := 0.11   # Thalassa input.js shapeRadialStick defaults
const CURVE := 1.45

## Radial deadzone with rescale, then a power curve on magnitude. Keeps direction exact.
static func shape_stick(raw: Vector2, deadzone: float = DEADZONE, curve: float = CURVE) -> Vector2:
	var m := raw.length()
	if m <= deadzone or is_nan(m):
		return Vector2.ZERO
	var t := clampf((m - deadzone) / (1.0 - deadzone), 0.0, 1.0)
	return (raw / m * pow(t, curve)).clamp(Vector2(-1, -1), Vector2(1, 1))

## Thalassa progressive trigger: 5 % deadzone, curve 1.3.
static func shape_trigger(v: float) -> float:
	if v <= 0.05: return 0.0
	return pow(clampf((v - 0.05) / 0.95, 0.0, 1.0), 1.30)

func copy():
	var p = get_script().new()
	p.move = move; p.look = look; p.thrust = thrust; p.ascend = ascend; p.descend = descend
	p.descend_amount = descend_amount; p.jump_pressed = jump_pressed; p.interact_pressed = interact_pressed
	p.cam_yaw = cam_yaw; p.cam_pitch = cam_pitch
	return p
