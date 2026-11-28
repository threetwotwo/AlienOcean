## GI light field (look thread, 28 Nov 2026): under water, the sky Godot's GI reads (look/sky.gdshader under_*) must be the water's
## own light field: upper hemisphere x pi = the sky's light through the water at z_ref (Ek), lower hemisphere x pi = the sand's
## bounce (Eu), so SDFGI's escaping rays light an open floor exactly as the analytic fill (w_fill) does. Above water too (the GI
## lights the sand seen through the surface), with the sun's GI share cut to what enters the water.
## Checks: under_k on/off with the eye; Ek matches WaterOptics on the CPU; 0 < Eu < the light entering the water (at noon the sunlit
## sand's Eu is ~2.4x the sky's Ek: the sun's beam is a light, not in Ek); SDFGI default on; screen quads kept out of GI.
## Run: godot --headless --path . --script res://tests/test_gi_light_field.gd [-- --fault]   (exit 0 = pass; --fault plants a wrong Ek)
extends SceneTree

func _init():
	var fault := "--fault" in OS.get_cmdline_user_args()
	var ok := true
	var wr := WorldRoot.new(); root.add_child(wr)
	wr.hours = 12.0; wr.tide_on = false
	var cam := Camera3D.new(); root.add_child(cam); wr.attach_camera(cam)
	wr.apply(wr.water.level - 2.0)   # eye 2 m under
	var m := wr.sky_mat
	var down: Vector3 = m.get_shader_parameter("under_down")
	var up: Vector3 = m.get_shader_parameter("under_up")
	if fault: down *= 1.5
	# Ek(z_ref) on the CPU, independently of WorldRoot.apply
	var a := WaterOptics.absorb(wr.cdom); var b := WaterOptics.scatter(wr.scat_k)
	var ku: Vector3 = wr._art_k((a + WaterOptics.BB * b) / 0.75)
	var st := SkyClock.sky_state(12.0)
	var ek: Vector3 = Vector3(exp(-ku.x * wr.z_ref), exp(-ku.y * wr.z_ref), exp(-ku.z * wr.z_ref)) * st.skylux * WaterOptics.FRESNEL_SKY * wr.sky_fill_k
	var err: float = (down * PI - ek).length() / ek.length()
	print("GI1 under_k ", m.get_shader_parameter("under_k"), "  Ek rel err ", snappedf(err, 1e-5), "  Eu/Ek ", snappedf((up * PI).length() / ek.length(), 1e-3))
	if float(m.get_shader_parameter("under_k")) != 1.0 or err > 1e-4: ok = false; print("FAIL GI1 the under-water sky is not the water's light field")
	var arrive: float = st.total   # all the light on level ground above the water
	if (up * PI).x <= 0.0 or (up * PI).length() >= arrive * sqrt(3.0): ok = false; print("FAIL GI2 the sand returns more light than reaches the water")
	if not wr.env.sdfgi_enabled: ok = false; print("FAIL GI3 SDFGI is not on by default")
	var q := cam.get_node("UnderwaterView") as GeometryInstance3D
	if q.gi_mode != GeometryInstance3D.GI_MODE_DISABLED: ok = false; print("FAIL GI4 the underwater screen quad would enter the GI")
	wr.apply(wr.water.level + 1.5)   # eye above
	# above water the GI still lights the sand under the surface: its sky stays the water's light field, and the sun reaches
	# the GI only as the share that enters the water (no full air sun on the sand below)
	print("GI5 above: under_k ", m.get_shader_parameter("under_k"), "  sun indirect ", snappedf(wr.light.light_indirect_energy, 1e-3))
	if float(m.get_shader_parameter("under_k")) != 1.0: ok = false; print("FAIL GI5 the GI reads the air sky above water")
	if wr.light.light_indirect_energy >= 1.0 or wr.light.light_indirect_energy <= 0.0: ok = false; print("FAIL GI6 the GI takes the full air sun above water")
	print("PASS GI light field" if ok else "FAIL GI light field")
	quit(0 if ok else 1)
