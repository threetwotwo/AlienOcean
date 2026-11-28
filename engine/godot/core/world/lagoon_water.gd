## Lagoon water 0.2.0 (core/world, the WaterQuery contract; engine thread 0.1.0, water surface thread 0.2.0): the water
## gameplay reads (shape: level, water_y(x, z, t), current(p, t)). It must return what the renderer draws.
## 0.2.0: the level follows the tide (core/world/tide.gd: the two moons and the sun, the lagoon's gain 0.67 = Gary's
## "calm it to about a third"): mean SURFACE_Y 2.4 since 28 Nov (key frame v7c; Unreal saved 4.0), tide about +-0.4 m at springs.
## Call set_clock(hours) when the world clock moves (WorldRoot.apply does). The drawn waves (adapters/godot/fft_sea.gd,
## the Unreal FFT sea: Hs 0.056 m in the calm lagoon, crests within about +-0.1 m) join it through `waves`: any object
## with height_at(x, z) -> m about the still level (FftSea reads its height back from the GPU; WorldRoot.make_surface
## wires it), so swimming and floating line up with each drawn crest. Without one, water_y is the still level.
class_name LagoonWaterField
extends RefCounted

const SURFACE_Y := 2.4        # the mean level (tide 0): key frame v7c's 2.4 m over the sand (Gary 28 Nov 06:29Z "Lagoon 2.4 m deep everywhere"; was Unreal's 4.0)
var gain: float = Tide.GAIN.calm_lagoon
var tide := 0.0               # m above the mean, now
var level := SURFACE_Y        # the still water now (mean + tide)
var waves: Object = null      # height_at(x, z) -> m about the still level (FftSea), or null = still water

func set_clock(hours: float) -> void:
	tide = Tide.height(hours, gain)
	level = SURFACE_Y + tide

func water_y(x: float, z: float, _t: float) -> float:
	## the drawn surface at (x, z) now (t is the contract's; the waves answer for the frame being drawn)
	return level + (waves.height_at(x, z) if waves else 0.0)

func current(_p: Vector3, _t: float) -> Vector3:
	return Vector3.ZERO      # the calm lagoon has no current map yet (open water's comes later)
