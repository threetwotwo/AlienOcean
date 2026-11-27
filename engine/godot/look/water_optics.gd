## Lagoon water optics 0.1.0: the Unreal-era lagoon water's physics, ported (Water surface + Lighting threads,
## lagoonwater v66-v89 PHYS_CODE / UNDER_PHYS, distilled in lagoonwater/surface/model/under_model.py, 13 Nov 2026).
## Per colour band (R, G, B): absorption a, scattering b, backscatter share bb, Henyey-Greenstein g, sky share.
## LOOK_SET = Gary's card A "white sand, blue far water" (14 Nov 00:04Z): Cdom 0.03, ScatK 0.40, GlowK 2.50.
## Pushed to every shader as global uniforms (water_*), so seabed, fish and the underwater view share one water.
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

static func push_globals(water_y: float, floor_y: float, sun_up_air: Vector3, beam_h_lux: float, sky_lux: float, exposure: float) -> void:
	## writes the shared water uniforms; call when the clock or the exposure changes
	var a := absorb(); var b := scatter()
	var tr := refract_sun(sun_up_air)
	var muw := tr.y
	var rs := RenderingServer
	rs.global_shader_parameter_set("water_y", water_y)
	rs.global_shader_parameter_set("water_floor_y", floor_y)
	rs.global_shader_parameter_set("water_a", a)
	rs.global_shader_parameter_set("water_b", b)
	rs.global_shader_parameter_set("water_kd", (a + BB * b) / muw)
	rs.global_shader_parameter_set("water_ku", (a + BB * b) / 0.75)
	rs.global_shader_parameter_set("water_sun_w", tr)
	rs.global_shader_parameter_set("water_es0", beam_h_lux * FRESNEL_SUN)     # horizontal lux of the sun just under
	rs.global_shader_parameter_set("water_ek0", sky_lux * FRESNEL_SKY)        # horizontal lux of the sky just under
	rs.global_shader_parameter_set("water_exposure", exposure)
	rs.global_shader_parameter_set("water_glow_k", LOOK_SET.glow_k)
	rs.global_shader_parameter_set("water_sand", SAND)
	rs.global_shader_parameter_set("water_sky_nits", sky_lux / PI)     # clear sky as a uniform dome (stand-in until the sky port)

static func declare_globals() -> void:
	## global uniforms must exist before shaders compile (headless scripts can't rely on project.godot entries)
	var rs := RenderingServer
	var defs := {"water_y": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 5.0], "water_floor_y": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
		"water_a": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO], "water_b": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO],
		"water_kd": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO], "water_ku": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO],
		"water_sun_w": [RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.UP], "water_es0": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
		"water_ek0": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0], "water_exposure": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 1.0],
		"water_glow_k": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 1.0], "water_zref": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 2.0], "water_sky_nits": [RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0], "water_sand": [RenderingServer.GLOBAL_VAR_TYPE_COLOR, Color.WHITE]}
	if Engine.has_meta("water_globals"): return
	for k in defs:
		rs.global_shader_parameter_add(k, defs[k][0], defs[k][1])
	Engine.set_meta("water_globals", true)
