## Marine snow drift (look thread, 28 Nov 2026): adapters/godot/motes.gd moves the ported Unreal marine snow (look/marine_snow.gdshader)
## with the water, as the Unreal OceanWorld plugin pushed Drift (mean current + the swell's orbit at the eye's depth).
## Checks: MS1 the swell's wavenumber solves w^2 = g k tanh(k h); MS2 at the surface the orbit's vertical reach is Hs / 2, at the floor 0;
## MS3 the horizontal reach is a cosh(k (h - z)) / sinh(k h) (linear theory) and wider than the vertical (shallow water); MS4 after
## 100 s the mean drift is CURRENT x 100 s along the wind; MS5 the shader takes the Unreal v21 density (20 / m3).
## Run: godot --headless --path . --script res://tests/test_marine_snow.gd [-- --fault]   (exit 0 = pass; --fault flips the orbit's depth)
extends SceneTree

func _init():
	var fault := "--fault" in OS.get_cmdline_user_args()
	var ok := true
	var m := Motes.new()
	var w := TAU / Motes.SWELL_TP
	var k: float = m._k
	var res := w * w - 9.81 * k * tanh(k * Motes.DEPTH)
	print("MS1 swell k ", snappedf(k, 1e-5), " rad/m (wavelength ", snappedf(TAU / k, 0.1), " m), residual ", res)
	if absf(res) > 1e-6: ok = false; print("FAIL MS1 dispersion")
	var a := 0.5 * Motes.SWELL_HS
	var vmax := 0.0; var vfloor := 0.0; var hmax := 0.0
	for i in 400:
		var t := i * Motes.SWELL_TP / 400.0
		var zs := (Motes.DEPTH if fault else 0.0)
		vmax = maxf(vmax, absf(m.drift_at(t, zs).y))
		vfloor = maxf(vfloor, absf(m.drift_at(t, Motes.DEPTH).y))
		var hv := m.drift_at(t, 2.0) - Vector3(cos(deg_to_rad(Motes.WIND_DEG)), 0, sin(deg_to_rad(Motes.WIND_DEG))) * Motes.CURRENT * t
		hmax = maxf(hmax, Vector2(hv.x, hv.z).length())
	print("MS2 vertical reach at the surface ", snappedf(vmax, 1e-5), " m (Hs/2 ", a, "), at the floor ", snappedf(vfloor, 1e-6))
	if absf(vmax - a) > 1e-4 or vfloor > 1e-6: ok = false; print("FAIL MS2 vertical orbit")
	var hexp := a * cosh(k * (Motes.DEPTH - 2.0)) / sinh(k * Motes.DEPTH)
	print("MS3 horizontal reach 2 m down ", snappedf(hmax, 1e-5), " m (theory ", snappedf(hexp, 1e-5), ")")
	if absf(hmax - hexp) > 2e-4 or hmax <= a: ok = false; print("FAIL MS3 horizontal orbit")
	var dm := m.drift_at(100.0 * Motes.SWELL_TP / Motes.SWELL_TP * 1.0, 2.0)
	var mean := Vector3(cos(deg_to_rad(Motes.WIND_DEG)), 0, sin(deg_to_rad(Motes.WIND_DEG))) * Motes.CURRENT * 100.0
	print("MS4 drift after 100 s ", dm, " (mean ", mean, ")")
	if (dm - mean).length() > hexp + a + 1e-4: ok = false; print("FAIL MS4 mean drift")
	var dens = (m.material_override as ShaderMaterial).get_shader_parameter("density")
	print("MS5 density ", dens, " / m3")
	if absf(float(dens) - 20.0) > 1e-6: ok = false; print("FAIL MS5 density")
	m.free()
	print("PASS marine snow" if ok else "FAIL marine snow")
	quit(0 if ok else 1)
