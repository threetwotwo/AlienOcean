## Lagoon water 0.2.0 (core/world, the WaterQuery contract; engine thread 0.1.0, water surface thread 0.2.0): the water
## gameplay reads (shape: level, water_y(x, z, t), current(p, t)). It must return what the renderer draws.
## 0.2.0: the level follows the tide (core/world/tide.gd: the two moons and the sun, the lagoon's gain 0.67 = Gary's
## "calm it to about a third"): mean SURFACE_Y 4.0 (Unreal's saved SurfaceZ 400 cm), about 3.6 to 4.4 m at springs.
## Call set_clock(hours) when the world clock moves (WorldRoot.apply does). The drawn waves (adapters/godot/fft_sea.gd,
## the Unreal FFT sea: Hs 0.056 m in the calm lagoon, crests within about +-0.1 m) are not in water_y yet; they join it
## when the sea's height is read back to the CPU (next step), so swimming and floating line up with each crest.
class_name LagoonWaterField
extends RefCounted

const SURFACE_Y := 4.0        # the mean level (tide 0)
var gain: float = Tide.GAIN.calm_lagoon
var tide := 0.0               # m above the mean, now
var level := SURFACE_Y        # the still water now (mean + tide)

func set_clock(hours: float) -> void:
	tide = Tide.height(hours, gain)
	level = SURFACE_Y + tide

func water_y(_x: float, _z: float, _t: float) -> float:
	return level

func current(_p: Vector3, _t: float) -> Vector3:
	return Vector3.ZERO      # the calm lagoon has no current map yet (open water's comes later)
