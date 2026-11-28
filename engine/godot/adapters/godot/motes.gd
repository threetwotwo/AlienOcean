## Motes 0.2.0 (look thread, 28 Nov 2026): marine snow around the eye under water, PORTED from the Unreal lagoon (ocean_v34
## MOTES_PP_HLSL, v19 walk, v16 shapes; look/marine_snow.gdshader). One full-screen quad drawn after the underwater view; this
## node only moves the cloud: `drift` = where the water has carried it since start, as the Unreal OceanWorld plugin pushed Drift
## (its mean current + MoteSway, the swell's orbit at the eye's depth; Thalassa's particles.js does the same: current + swell).
## The calm lagoon has no current map yet (LagoonWaterField.current is zero), so the mean drift is a stand-in: CURRENT m/s along
## the lagoon wind (SeaSpectrum.LAGOON, 30 deg), about 1% of a 2.5 m/s wind. The swell orbit: LAGOON swell Hs 0.03 m, Tp 12 s
## over 4 m (linear wave theory, the shallow-water orbit: wide and flat). AO_MOTES=0 in the shot tool turns them off.
class_name Motes
extends MeshInstance3D

const CURRENT := 0.025                    # m/s, stand-in mean drift (see above)
const SWELL_HS := 0.03                    # m (SeaSpectrum.LAGOON swell_hs)
const SWELL_TP := 12.0                    # s (swell_tp)
const SWELL_DEG := 40.0                   # heading (swell_deg)
const WIND_DEG := 30.0                    # (wind_deg)
const DEPTH := LagoonWaterField.SURFACE_Y # m, the lagoon's mean depth (sand at y 0)

@export var density := 20.0               # Unreal MoteDensity (v21)
var _t := 0.0
var _k := 0.0                             # swell wavenumber, rad/m

func _init(dens := 20.0) -> void:
	name = "Motes"; density = dens
	var qm := QuadMesh.new(); qm.size = Vector2(1, 1)
	mesh = qm
	var mat := ShaderMaterial.new(); mat.shader = load("res://look/marine_snow.gdshader")
	mat.set_shader_parameter("density", density)
	mat.render_priority = 1          # after the underwater view quad (it repaints the whole screen)
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	extra_cull_margin = 16384.0     # the quad is placed in the shader, over the whole screen
	layers = 1 << 3                 # the eye's own layer (the sea floor map's captures skip it)
	# the swell's wavenumber from the dispersion relation w^2 = g k tanh(k h) (a few Newton steps)
	var w := TAU / SWELL_TP
	_k = w / sqrt(9.81 * DEPTH)
	for i in 8:
		var th := tanh(_k * DEPTH)
		var f := 9.81 * _k * th - w * w
		var df := 9.81 * (th + _k * DEPTH * (1.0 - th * th))
		_k -= f / df

func drift_at(t: float, z: float) -> Vector3:
	## the water's displacement at time t for an eye z m under the surface (Godot axes, y up)
	var wd := deg_to_rad(WIND_DEG); var sd := deg_to_rad(SWELL_DEG)
	var mean := Vector3(cos(wd), 0.0, sin(wd)) * CURRENT * t
	var a := 0.5 * SWELL_HS; var w := TAU / SWELL_TP
	var zz := clampf(z, 0.0, DEPTH)
	var sh := sinh(_k * DEPTH)
	var hor := a * cosh(_k * (DEPTH - zz)) / sh
	var ver := a * sinh(_k * (DEPTH - zz)) / sh
	var ph := w * t
	return mean + Vector3(cos(sd), 0.0, sin(sd)) * hor * cos(ph) + Vector3(0.0, ver * sin(ph), 0.0)

func _process(dt: float) -> void:
	_t += dt
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var z := 2.0
	if cam: z = LagoonWaterField.SURFACE_Y - cam.global_position.y
	(material_override as ShaderMaterial).set_shader_parameter("drift", drift_at(_t, z))
