## Surface shots 0.1.0 (water surface thread): the sea surface's shot set on tools/lagoon_shots.gd's lagoon (same pieces,
## fish, light and clock). Seen from below: the window straight up, the ceiling and its mirror at 30 deg, the far
## ceiling at the level; from above: low over the water toward the sun and away, and high over it (tile check).
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --script res://tools/surface_shots.gd -- <pieces_dir> <fish.glb> <out_dir> [w h]
## Env as lagoon_shots, plus AO_TIDE=1 (let the tide move the level; default pinned at the mean so frames compare),
## AO_REFR=1 (refraction check: a body at the surface, a post half out, a rock 1.5 m down; shots f1-f4), AO_ISLAND=<dir> (the eroded atoll, world/erosion/handover/godot: edges E S W N x views a s e w u v, blue hole Ha Hu), AO_REEF=1 (the reef drop-off's stress-test matrix: per sector views a s e w d u v (+p in the pass), AO_REEF_SECTORS=0,2 picks sectors; with AO_SEA=Bn that sea over it), AO_SEA=B0..B12 (the open sea at that Beaufort force, no floor: shots o1-o5 over the crests and under the troughs), AO_DRESS (lagoon_shots': adds s8_arch_mirror, the key frame's arch in the ceiling), AO_SEA_T (the waves' clock, s; default 37.0, held), AO_HOUR_THEN (the clock jumps there just before each shot, the eye still), AO_FILM=<frames> (videos: the waves run, frames to <out>/<shot>/, use --fixed-fps 30), AO_SURF_SHOTS (two-character prefixes, e.g. s1,s4; AO_SHOTS
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
	if OS.get_environment("AO_ISLAND") != "":       # the eroded atoll (adapters/godot/island_terrain.gd): the real-ground case
		var isl := IslandTerrain.new(); isl.name = "Island"; root.add_child(isl)
		if not isl.load_grids(OS.get_environment("AO_ISLAND")): push_error("AO_ISLAND: no grids")
		isl.build(y)
		wr.lagoon_radius = 1.0                         # past what is drawn: the deep (the island and its flank are drawn to 1.6 km)
		wr.cam_attr.frustum_far = 2400.0              # so the far platform is drawn, not guessed
		if sea and sea_env.begins_with("B"):
			sea.set_params(SeaSpectrum.beaufort(int(sea_env.substr(1))))
			sea.hold = false; sea.preroll(20.0); sea.hold = true; sea.step_now()
		var D := func(q: Vector2) -> float: return -isl.height(q.x - isl.origin.x, q.y - isl.origin.y)
		# edges: [letter, a point on the platform (Godot x z), outward]; the crest = where the floor passes 6 m going out
		var edges := [["E", Vector2(120.0, -100.0), Vector2(1, 0)], ["S", Vector2(-75.0, 90.0), Vector2(0, 1)],
			["W", Vector2(-200.0, -100.0), Vector2(-1, 0)], ["N", Vector2(150.0, -330.0), Vector2(0.7071, -0.7071)]]
		shots = []
		for e in edges:
			var o: Vector2 = e[2]; var c: Vector2 = e[1]
			while D.call(c) < 6.0 and (c - e[1]).length() < 400.0: c += o
			var out := Vector3(o.x, 0.0, o.y)
			var C := Vector3(c.x, y, c.y)
			var L: String = e[0]
			print("ISLAND EDGE ", L, " crest at ", c, " depth 30 m out ", D.call(c + o * 30.0))
			shots.append([L + "a_island_aerial", C - out * 70.0 + Vector3(0, 45, 0), C + out * 20.0, 60.0])
			shots.append([L + "s_island_surface", C - out * 15.0 + Vector3(0, 1.5, 0), C + out * 200.0 - Vector3(0, 6, 0), 70.0])
			shots.append([L + "e_island_edge", C + out * 1.0 - Vector3(0, 1, 0), C + out * 11.0 - Vector3(0, 1.0 + tan(deg_to_rad(20.0)) * 10.0, 0), 75.0])
			shots.append([L + "w_island_wall10", C + out * 35.0 - Vector3(0, 10, 0), C - Vector3(0, 12, 0), 70.0])
			shots.append([L + "u_island_up50", C + out * 100.0 - Vector3(0, 50, 0), C - out * 10.0, 75.0])
			shots.append([L + "v_island_down", C + out * 2.0 - Vector3(0, 5, 0), C + out * 8.0 - Vector3(0, 15, 0), 75.0])
		var bh := Vector3(35.0, y, -190.0)               # the blue hole on the platform
		shots.append(["Ha_island_bluehole_aerial", bh + Vector3(0, 40, 50), bh, 60.0])
		shots.append(["Hu_island_bluehole_rim", bh + Vector3(0, -2.0, 30.0), bh + Vector3(0, -9.0, 0.0), 75.0])
		print("ISLAND SHOTS ", shots.size())
	elif OS.get_environment("AO_REEF") != "":         # the reef drop-off (adapters/godot/reef_terrain.gd): the stress-test matrix
		# sector 0 (the vertical wall) faces away from the sun; the others follow round the ring (Bathymetry.SECTOR_NAMES)
		wr.reef_sector_deg = rad_to_deg(atan2(away.z, away.x))
		var bt: Bathymetry = wr.bathymetry()
		var reef := ReefTerrain.new(); reef.name = "Reef"; root.add_child(reef); reef.build(bt, y)
		if sea and sea_env.begins_with("B"):         # a stronger sea over the reef (the floor stays)
			sea.set_params(SeaSpectrum.beaufort(int(sea_env.substr(1))))
			sea.hold = false; sea.preroll(20.0); sea.hold = true; sea.step_now()
			print("SEA ", sea_env, " over the reef")
		# per sector k, views named "<k><v>_<sector>_<view>" (AO_SURF_SHOTS keeps two-character prefixes, e.g. 0a,2u):
		#   a aerial 45 m up over the back reef     s at the surface, 1.5 m up, out over the edge
		#   e just under at the crest, over the edge   w 10 m down, 25 m out, back at the wall
		#   d 30 m down, 45 m out, back up the wall    u 60 m down over the slope, up at the reef and the window
		#   v 5 m down above the wall, 60 deg down it  p (sector 4) in the pass, 3 m down, out through it
		var ks := OS.get_environment("AO_REEF_SECTORS").split(",") if OS.get_environment("AO_REEF_SECTORS") != "" else PackedStringArray(["0", "1", "2", "3", "4"])
		shots = []
		for kk in ks:
			var k := int(kk)
			var th := bt.sector_mid(k)
			var wm := bt.wall_m(th)
			var cr := Bathymetry.FLAT_M + Bathymetry.SPUR_OUT * 0.5   # the crest, past the reef flat's inner edge
			var P := func(sx: float, h: float) -> Vector3: var q: Vector2 = bt.at(th, sx); return Vector3(q.x, h, q.y)
			var out := Vector3(cos(th), 0.0, sin(th))
			var nm: String = Bathymetry.SECTOR_NAMES[k].replace(" ", "_").replace("+", "").replace("__", "_")
			var wall_x := cr + wm * 0.5                               # the middle of the wall (m past the reef edge)
			var Dw := func(h: float) -> float: return y - h
			shots.append(["%da_%s_aerial" % [k, nm], P.call(-70.0, y + 45.0), P.call(cr + 20.0, y), 60.0])
			shots.append(["%ds_%s_surface" % [k, nm], P.call(cr - 15.0, y + 1.5), P.call(cr + 200.0, y - 6.0), 70.0])
			shots.append(["%de_%s_edge" % [k, nm], P.call(cr + 1.0, y - 1.0), P.call(cr + 1.0, y - 1.0) + (out + Vector3(0, -tan(deg_to_rad(20.0)), 0)) * 10.0, 75.0])
			shots.append(["%dw_%s_wall10" % [k, nm], P.call(wall_x + 25.0, Dw.call(10.0)), P.call(wall_x, Dw.call(12.0)), 70.0])
			shots.append(["%dd_%s_wall30" % [k, nm], P.call(wall_x + 45.0, Dw.call(30.0)), P.call(wall_x, Dw.call(14.0)), 70.0])
			shots.append(["%du_%s_up60" % [k, nm], P.call(wall_x + 120.0, Dw.call(60.0)), P.call(cr - 10.0, y), 75.0])
			shots.append(["%dv_%s_down" % [k, nm], P.call(cr + 2.0, Dw.call(5.0)), P.call(cr + 2.0, Dw.call(5.0)) + (out * 0.6 + Vector3(0, -1.0, 0)) * 10.0, 75.0])
			if k == Bathymetry.PASS_SECTOR:
				shots.append(["%dp_%s_pass" % [k, nm], P.call(cr - 20.0, Dw.call(3.0)), P.call(cr + 40.0, Dw.call(9.0)), 75.0])
		print("REEF SHOTS ", shots.size())
	elif sea and sea_env.begins_with("B"):
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
	if OS.get_environment("AO_REFR") != "":         # refraction check (Gary 28 Nov: the body doubled from above): a body
		# at the surface, a post half in and half out, a rock 1.5 m down, seen from above at three angles
		var base := Vector3(0.0, y, 10.0)
		var mk := func(m: Mesh, at: Vector3, rot: Vector3, c: Color) -> void:
			var mi := MeshInstance3D.new(); mi.mesh = m; mi.position = at; mi.rotation = rot
			var sm := StandardMaterial3D.new(); sm.albedo_color = c; sm.roughness = 0.6; mi.material_override = sm
			root.add_child(mi)
		var body := CapsuleMesh.new(); body.radius = 0.18; body.height = 1.4
		mk.call(body, base + Vector3(0.0, -0.25, 0.0), Vector3(0, 0, PI * 0.5), Color(0.85, 0.82, 0.78))     # lying at the surface, like the girl swimming
		var post := CylinderMesh.new(); post.top_radius = 0.12; post.bottom_radius = 0.12; post.height = 2.0
		mk.call(post, base + Vector3(2.2, 0.1, 0.5), Vector3.ZERO, Color(0.9, 0.35, 0.2))                   # half in, half out
		var rock := BoxMesh.new(); rock.size = Vector3(1.2, 0.8, 0.9)
		mk.call(rock, base + Vector3(-2.0, -1.5, 1.0), Vector3(0.2, 0.5, 0.1), Color(0.35, 0.38, 0.32))   # 1.5 m down
		shots = [
			["f1_refr_down60", base + Vector3(0, 3.0, 4.0), base + Vector3(0, -0.3, 0), 60.0],
			["f2_refr_down35", base + Vector3(0, 2.2, 6.5), base + Vector3(0, -0.3, 0), 60.0],
			["f3_refr_low", base + Vector3(0.5, 0.9, 7.0), base + Vector3(0, -0.2, 0), 60.0],
			["f4_refr_top", base + Vector3(0.1, 5.0, 0.6), base + Vector3(0, -0.3, 0), 60.0],
		]
	if OS.get_environment("AO_FAR") != "": wr.cam_attr.frustum_far = float(OS.get_environment("AO_FAR"))   # check: the far plane (m)
	if OS.get_environment("AO_SURF_SHOTS") != "":
		var keep := OS.get_environment("AO_SURF_SHOTS").split(",")
		shots = shots.filter(func(sh): return sh[0].substr(0, 2) in keep)
	i = -1
	_next()

var _film := -1                 # AO_FILM: frames left to write for this shot (-1 = not filming)
var _film_n := 0

func _process(d):
	# AO_FILM=<frames> (videos, run with --fixed-fps 30): each shot, once settled, lets the waves run and writes one frame
	# per step to <out>/<shot>/f_0000.png ... (the camera holds still), then moves on
	var film_n := int(OS.get_environment("AO_FILM")) if OS.get_environment("AO_FILM") != "" else 0
	if film_n > 0 and i >= 0 and i < shots.size():
		if _film < 0 and wait == 23:
			_film = film_n; _film_n = 0
			DirAccess.make_dir_recursive_absolute(args[2].path_join(shots[i][0]))
			var fs := root.find_child("FftSea", true, false)
			if fs: fs.hold = false
		if _film >= 0:
			if _film_n > 0: root.get_texture().get_image().save_png(args[2].path_join(shots[i][0]).path_join("f_%04d.png" % (_film_n - 1)))
			_film_n += 1; _film -= 1
			if _film < 0:
				var fs2 := root.find_child("FftSea", true, false)
				if fs2: fs2.hold = true
				print("FILM ", shots[i][0], " ", film_n, " frames"); _next()
			return false
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
