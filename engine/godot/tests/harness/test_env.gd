## M23 Harness, test environment 0.1.0: analytic water (IWaterQuery stand-in until the look side's water field lands).
## water_y: still level or a sum of 3 long-crested waves (Beaufort-4-like: about 0.5 m amplitude, 5-7 s periods).
## current: constant field inside an axis-aligned box, zero outside.
extends RefCounted

var level := 0.0
var wave_amp := 0.0          # total amplitude (m); 0 = still water
var current_vec := Vector3.ZERO
var current_box := AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))

const WAVES := [ [1.0, 5.0, Vector2(1, 0)], [0.6, 6.3, Vector2(0.8, 0.6)], [0.35, 7.1, Vector2(0.2, 1)] ]

func water_y(x: float, z: float, t: float) -> float:
	if wave_amp <= 0.0:
		return level
	var y := 0.0
	var norm := 0.0
	for w in WAVES:
		var k: float = TAU / (9.81 * w[1] * w[1] / TAU)   # deep-water wavenumber from period
		var d: Vector2 = w[2].normalized()
		y += w[0] * sin(k * (d.x * x + d.y * z) - TAU / w[1] * t)
		norm += w[0]
	return level + y / norm * wave_amp

func current(p: Vector3, _t: float) -> Vector3:
	return current_vec if current_box.has_point(p) else Vector3.ZERO
