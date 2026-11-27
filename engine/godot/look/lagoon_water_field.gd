## Lagoon water field 0.1.0 (engine thread): the water query gameplay reads (same shape as M23's test_env:
## level, water_y(x, z, t), current(p, t)). It must return what the renderer draws.
## Now: still surface at Unreal's saved SurfaceZ 400 cm (tide 0); the drawn surface 0.2.0 tilts normals only, no
## displacement, so water_y = level everywhere. Coming with the surface port: the tide (from the two moons, Unreal's
## OceanWorld tide model, TideGain 0.67 = Gary's "calm it to about a third") and the waves; the renderer and this
## field will then share one height function so swimming and floating line up with the picture.
class_name LagoonWaterField
extends RefCounted

const SURFACE_Y := 4.0
var level := SURFACE_Y

func water_y(_x: float, _z: float, _t: float) -> float:
	return level

func current(_p: Vector3, _t: float) -> Vector3:
	return Vector3.ZERO      # the calm lagoon has no current map yet (open water's comes later)
