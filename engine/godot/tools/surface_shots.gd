## Surface shots 0.1.0 (water surface thread): the sea surface's shot set on tools/lagoon_shots.gd's lagoon (same pieces,
## fish, light and clock). Seen from below: the window straight up, the ceiling and its mirror at 30 deg, the far
## ceiling at the level; from above: low over the water toward the sun and away, and high over it (tile check).
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --script res://tools/surface_shots.gd -- <pieces_dir> <fish.glb> <out_dir> [w h]
## Env as lagoon_shots, plus AO_TIDE=1 (let the tide move the level; default pinned at the mean so frames compare),
## AO_SEA=B0..B12 (the open sea at that Beaufort force, no floor: shots o1-o5 over the crests and under the troughs), AO_DRESS (lagoon_shots': adds s8_arch_mirror, the key frame's arch in the ceiling), AO_SEA_T (the waves' clock, s; default 37.0, held), AO_HOUR_THEN (the clock jumps there just before each shot, the eye still), AO_SURF_SHOTS (two-character prefixes, e.g. s1,s4; AO_SHOTS
## filters lagoon_shots' own list and must stay unset here).
extends "res://tools/lagoon_shots.gd"

func _setup():
	await super._setup()
	if "tide_on" in wr: wr.tide_on = OS.get_environment("AO_TIDE") == "1"
	var sea := root.find_child("FftSea", true, false)
	if sea:
		sea.hold = true
		sea.time_s = float(OS.get_environment("AO_SEA_T")) if OS.get_environment("AO_SEA_T") != "" else 37.0
		sea.step_now()
	var y := WATER_Y
	var sun := WorldRoot.to_godot(SkyClock.sky_state(wr.hours).sun.dir)
	var away := -Vector3(sun.x, 0.0, sun.z).normalized() if Vector2(sun.x, sun.z).length() > 1e-3 else Vector3.FORWARD
	var p := Vector3(0.0, y - 2.0, 6.0)
	shots = [
		["s1_window_up", p, p + Vector3(0.05, 10.0, -0.3), 90.0],
		["s2_ceiling_30", p, p + (away + Vector3(0, tan(deg_to_rad(30.0)), 0)) * 10.0, 75.0],
		["s3_ceiling_level", Vector3(0.0, y - 1.2, 14.0), Vector3(0.0, y - 0.6, -30.0), 70.0],
		["s4_above_low_sun", Vector3(0.0, y + 1.5, 16.0), Vector3(0.0, y + 1.5, 16.0) - away * 10.0 + Vector3(0, -3.5, 0), 70.0],
		["s5_above_low_away", Vector3(0.0, y + 1.5, -4.0), Vector3(0.0, y + 1.5, -4.0) + away * 10.0 + Vector3(0, -3.0, 0), 70.0],
		["s6_above_high", Vector3(0.0, y + 20.0, 30.0), Vector3(0.0, y, 0.0), 60.0],
		["s7_reef_mirror", Vector3(-6.0, 1.4, 3.0), Vector3(2.0, 2.4, -12.0), 65.0],
	]
	for n in root.find_children("*", "Node3D", true, false):   # with AO_DRESS: the key frame's arch, mirrored in the ceiling
		if n is DressCell:
			var cc: Array = n.cam("key_arch")
			var e: Vector3 = cc[0] + Vector3(0, 0.3, 0)
			var f: Vector3 = (cc[1] - cc[0]); f.y = 0.0
			shots.append(["s8_arch_mirror", e, e + f.normalized() * 10.0 + Vector3(0, tan(deg_to_rad(22.0)) * 10.0, 0), 70.0])
			break
	var sea_env := OS.get_environment("AO_SEA")      # the stress test: lagoon (default) or B0 .. B12 (the open sea at that force)
	if sea and sea_env.begins_with("B"):
		var force := int(sea_env.substr(1))
		sea.set_params(SeaSpectrum.beaufort(force))
		var pre := float(OS.get_environment("AO_PREROLL")) if OS.get_environment("AO_PREROLL") != "" else 20.0
		sea.hold = false; sea.preroll(pre); sea.hold = true; sea.step_now()   # the foam's history, then held
		wr.floor_y = -4000.0                          # open water: no floor under the mirror
		wr.water_type = float(OS.get_environment("AO_WATER_TYPE")) if OS.get_environment("AO_WATER_TYPE") != "" else 1.0   # the open ocean's water
		var hs: float = sea.moments.hs
		var e := y + 2.0 + 1.0 * hs                    # the eye over the crests
		var dn := y - 4.0 - 0.8 * hs                   # and under the troughs
		shots = [
			["o1_above_sun", Vector3(0, e, 0), Vector3(0, e, 0) - away * 40.0 + Vector3(0, -4.0 - 0.3 * hs, 0), 70.0],
			["o2_above_away", Vector3(0, e, 0), Vector3(0, e, 0) + away * 40.0 + Vector3(0, -4.0 - 0.3 * hs, 0), 70.0],
			["o3_above_high", Vector3(0, y + 30.0 + 3.0 * hs, 40.0 + 4.0 * hs), Vector3(0, y, 0), 60.0],
			["o4_under_up", Vector3(0, dn, 0), Vector3(0, dn, 0) + (away + Vector3(0, tan(deg_to_rad(35.0)), 0)) * 10.0, 75.0],
			["o5_under_window", Vector3(0, dn, 0), Vector3(0, dn, 0) + Vector3(0.05, 10.0, -0.3), 90.0],
		]
		print("SEA ", sea_env, " ", SeaSpectrum.BEAUFORT[force][2], " Hs ", hs)
	if OS.get_environment("AO_SURF_SHOTS") != "":
		var keep := OS.get_environment("AO_SURF_SHOTS").split(",")
		shots = shots.filter(func(sh): return sh[0].substr(0, 2) in keep)
	i = -1
	_next()

func _process(d):
	# AO_HOUR_THEN (check): the clock jumps to this hour 6 frames before each shot, without the eye moving (as the test
	# level's hour slider does), so whatever was captured under the old light must follow
	if OS.get_environment("AO_HOUR_THEN") != "" and wait == 18:
		wr.hours = float(OS.get_environment("AO_HOUR_THEN")); print("HOUR THEN ", wr.hours, " ", wr.apply(cam.global_position.y).get("under", "?"))
	if OS.get_environment("AO_DUMP_FLOOR") != "" and wait == 20:   # the sea floor map, for checks
		var fm := root.find_child("SeaFloorMap", true, false)
		if fm:
			var ia: Image = fm._vp_alb.get_texture().get_image(); var ih: Image = fm._vp_h.get_texture().get_image()
			var sa := Color(0, 0, 0, 0); var hmin := INF; var hmax := -INF; var hit := 0; var n := 0
			for y in range(0, ia.get_height(), 8):
				for x in range(0, ia.get_width(), 8):
					sa += ia.get_pixel(x, y); n += 1
					var h := ih.get_pixel(x, y)
					if h.a > 0.5: hit += 1; hmin = minf(hmin, h.r / h.g); hmax = maxf(hmax, h.r / h.g)
			print("FLOOR MAP ", shots[i][0], " albedo mean ", sa / n,  " height ", hmin, " .. ", hmax, " hit ", float(hit) / n)
			var ic := ia.duplicate(); ic.convert(Image.FORMAT_RGBA8); ic.save_png(args[2].path_join("floor_albedo.png"))
	return super._process(d)
