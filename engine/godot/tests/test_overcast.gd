## Overcast (look thread, 28 Nov 2026): WorldRoot.sky_overcast (cloud cover N 0..1) splits the clock's light by Kasten & Czeplak
## (1980): ground light G = G_clear (1 - 0.75 N^3.4), diffuse share f0 -> 1 as N^2. The sky's dome blends to the CIE overcast deck at
## the same ground light (look/sky_overcast.gdshaderinc), so the deck's zenith nits x 7 pi / 9 must equal the cloudy sky light.
## Checks: OC1 N = 0 changes nothing; OC2 N = 1 leaves 25 % of the light, all of it sky (beam 0, sun intensity 0); OC3 half cover
## matches the formula; OC4 beam share and sky light move the right way at every step; OC5 the globals and the deck's light agree.
## Run: godot --headless --path . --script res://tests/test_overcast.gd [-- --fault]   (exit 0 = pass; --fault drops the deck's 7/9)
extends SceneTree

func _init():
	var fault := "--fault" in OS.get_cmdline_user_args()
	var ok := true
	var clear := SkyClock.sky_state(12.0)
	var lit: float = clear.total - SkyClock.NIGHT_SKY_LUX
	var f0: float = (clear.skylux - SkyClock.NIGHT_SKY_LUX) / lit
	var s0 := SkyClock.overcast(clear, 0.0)
	print("OC1 clear total ", snappedf(s0.total, 0.1), " sky ", snappedf(s0.skylux, 0.1), " beam_k ", s0.oc_beam_k, "  f0 ", snappedf(f0, 1e-3))
	if absf(s0.total - clear.total) > 1e-6 or absf(s0.skylux - clear.skylux) > 1e-6 or s0.oc_beam_k != 1.0: ok = false; print("FAIL OC1 no cloud changes the light")
	var s1 := SkyClock.overcast(clear, 1.0)
	print("OC2 overcast total/clear ", snappedf((s1.total - SkyClock.NIGHT_SKY_LUX) / lit, 1e-4), " diffuse share ", snappedf((s1.skylux - SkyClock.NIGHT_SKY_LUX) / (s1.total - SkyClock.NIGHT_SKY_LUX), 1e-4), " beam_k ", s1.oc_beam_k)
	if absf((s1.total - SkyClock.NIGHT_SKY_LUX) / lit - 0.25) > 1e-6 or absf(s1.skylux - s1.total) > 1e-6 or s1.oc_beam_k != 0.0: ok = false; print("FAIL OC2 full cover")
	var sh := SkyClock.overcast(clear, 0.5)
	var g := 1.0 - 0.75 * pow(0.5, 3.4); var f := f0 + (1.0 - f0) * 0.25
	if absf(sh.total - (lit * g + SkyClock.NIGHT_SKY_LUX)) > 1e-3 or absf(sh.skylux - (lit * g * f + SkyClock.NIGHT_SKY_LUX)) > 1e-3: ok = false; print("FAIL OC3 half cover formula")
	var prev_b := 2.0; var prev_g := INF
	for i in 11:
		var si := SkyClock.overcast(clear, i / 10.0)
		if si.oc_beam_k > prev_b + 1e-9 or si.total > prev_g + 1e-9: ok = false; print("FAIL OC4 not monotonic at N=", i / 10.0)
		prev_b = si.oc_beam_k; prev_g = si.total
	# through WorldRoot: the globals, the sun's light and the deck's ground light
	var wr := WorldRoot.new(); root.add_child(wr)
	wr.hours = 12.0; wr.tide_on = false
	var cam := Camera3D.new(); root.add_child(cam); wr.attach_camera(cam)
	wr.apply(wr.water.level + 1.5); var sun_clear := wr.light.light_intensity_lux
	wr.sky_overcast = 1.0; wr.apply(wr.water.level + 1.5)
	var oc: float = wr.last.overcast     # what apply() pushed as the globals sky_overcast / sky_oc_zenith
	var lz: float = wr.last.oc_zenith
	var deck_e := lz * 7.0 * PI / (9.0 if not fault else 7.0)
	var want: float = wr.state.skylux - SkyClock.NIGHT_SKY_LUX
	print("OC5 global ", oc, "  deck ground light ", snappedf(deck_e, 0.1), " vs sky ", snappedf(want, 0.1), "  sun lux ", snappedf(sun_clear, 1.0), " -> ", wr.light.light_intensity_lux)
	if oc != 1.0 or absf(deck_e - want) / want > 1e-4 or wr.light.light_intensity_lux > 1e-6 or float(wr.sky_mat.get_shader_parameter("sky_oc_beam")) != 0.0: ok = false; print("FAIL OC5 WorldRoot overcast")
	print("PASS overcast" if ok else "FAIL overcast")
	quit(0 if ok else 1)
