## Lagoon water optics 0.1.0: the Unreal-era lagoon water's physics, ported (Water surface + Lighting threads,
## lagoonwater v66-v89 PHYS_CODE / UNDER_PHYS, distilled in lagoonwater/surface/model/under_model.py, 13 Nov 2026).
## Per colour band (R, G, B): absorption a, scattering b, backscatter share bb, Henyey-Greenstein g, sky share.
## LOOK_SET = Gary's card A "white sand, blue far water" (14 Nov 00:04Z): Cdom 0.03, ScatK 0.40, GlowK 2.50.
## Engine-agnostic: adapters/godot/world_root.gd pushes these to every shader as global uniforms (water_*).
class_name WaterOptics
extends RefCounted

const A0 := Vector3(0.35, 0.06, 0.025)      # pure water + particles, 1/m
const B0 := Vector3(0.0433, 0.05, 0.06)     # scattering, 1/m
const BB := 0.019                            # backscatter share
const G := 0.9                               # forward peak
const CDOM_RGB := Vector3(0.05, 0.21, 0.76)  # CDOM absorption per unit at 440 nm, band means
const N_WATER := 1.333
const SAND := Color(0.55, 0.52, 0.45)        # the model's sand albedo
const LOOK_SET := {"cdom": 0.03, "scat_k": 0.40, "glow_k": 2.50}
const FRESNEL_SUN := 0.97                    # share of light through a calm surface (sun high)
const FRESNEL_SKY := 0.934                   # diffuse sky through a flat surface

static func absorb(cdom := LOOK_SET.cdom) -> Vector3:
	return A0 + cdom * CDOM_RGB

static func scatter(scat_k := LOOK_SET.scat_k) -> Vector3:
	return B0 * scat_k

static func refract_sun(sun_dir_up: Vector3) -> Vector3:
	## direction toward the sun as seen under a flat surface (y up); straight up if the sun is down
	if sun_dir_up.y <= 0.0:
		return Vector3.UP
	var horiz := Vector3(sun_dir_up.x, 0.0, sun_dir_up.z)
	var sin_i := horiz.length()
	var sin_t := sin_i / N_WATER
	var h := horiz.normalized() * sin_t if sin_i > 1e-6 else Vector3.ZERO
	return Vector3(h.x, sqrt(1.0 - sin_t * sin_t), h.z)
