## Lagoon water optics 0.2.0 (0.2.0, 28 Nov: the open ocean's water and the deep Rrs, optics()): the Unreal-era lagoon water's physics, ported (Water surface + Lighting threads,
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

# The open ocean's water (28 Nov, water surface thread): the Unreal open-water tank's (openocean_tank v374) OPTICS at
# its default chlorophyll 0.05 mg/m3 (tools/oo_optics.py, per linear RGB band): absorption, scattering (molecular +
# particles), backscattering, and the deep water's remote-sensing reflectance with Raman light (RRS_RAMAN, v342).
const OCEAN := {"a": Vector3(0.1898, 0.055209, 0.017822), "b": Vector3(0.040668, 0.044752, 0.053661),
	"bb": Vector3(0.0010962, 0.0015088, 0.002867), "rrs": Vector3(2.0e-5, 0.0011846, 0.0097397)}

static func rrs_deep(a: Vector3, bb: Vector3) -> Vector3:
	## a deep water's remote-sensing reflectance (/sr, above the surface) from its absorption and backscattering:
	## Gordon et al. 1988 / Lee et al. 2002 (rrs = 0.0949 u + 0.0794 u^2, u = bb / (a + bb); Rrs = 0.52 rrs / (1 - 1.7 rrs))
	var out := Vector3.ZERO
	for i in 3:
		var u := bb[i] / maxf(a[i] + bb[i], 1e-9)
		var r := 0.0949 * u + 0.0794 * u * u
		out[i] = 0.52 * r / (1.0 - 1.7 * r)
	return out

static func optics(cdom: float, scat_k: float, ocean := 0.0, full_ocean := false) -> Dictionary:
	## the water now: the lagoon's (LOOK_SET levers, backscatter BB of its scattering, deep Rrs from Gordon) blended
	## toward the open ocean's by `ocean` (0 lagoon .. 1 open ocean), so a swim from one to the other is seamless
	var a := absorb(cdom); var b := scatter(scat_k); var bb := b * BB
	## For now only the deep colour (rrs) follows the ocean: the ocean's own a / b under the water read milky grey-blue
	## with the lagoon's single-scatter glow (its particles scatter flat across the bands; shots blue3 o4, 28 Nov), and
	## the under-water look is Gary-approved, so a / b / bb stay the lagoon's until that look is decided (full_ocean).
	var t := clampf(ocean, 0.0, 1.0)
	var rr := rrs_deep(a, bb).lerp(OCEAN.rrs, t)
	var tw := t if full_ocean else 0.0
	return {"a": a.lerp(OCEAN.a, tw), "b": b.lerp(OCEAN.b, tw), "bb": bb.lerp(OCEAN.bb, tw), "rrs": rr}

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
