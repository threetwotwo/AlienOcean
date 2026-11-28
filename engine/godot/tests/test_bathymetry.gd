## Bathymetry (water surface thread, 28 Nov 2026): the reef drop-off's stress-test world must hold the shapes it claims.
##  B1 each sector's wall, measured down a radial line at the sector's middle (and +-0.2 sector either side), has its
##     steepest slope between 3 and 25 m deep within 6 deg of the sector's own (atan(1.5 x 28.8 / run)): 86, 60, 30,
##     10, 45 deg. Planted fault (--fault): each sector measured at the next one's angle (a sector table off by one) must fail.
##  B2 no seam: depth just either side of the angle wrap (atan2 = +-pi) within 5 cm, at every radius out to 1.6 km.
##  B3 the pass: at its middle the reef flat is PASS_D deep (+-0.15 m); at every other sector's middle REEF_FLAT_D (+-0.3).
##  B4 past the wall and the grooves the floor only falls, and it reaches the ocean's depth (+-1 %) by 2.4 km.
##  B5 the lagoon: lagoon_d everywhere inside 0.64 x the radius (the back reef starts BACK_M inside the wandering edge).
##  B6 the water's mirror (look/sea_bathy.gdshaderinc) carries the same sector runs, pass and constants.
## Run: godot --headless --path . --script res://tests/test_bathymetry.gd [-- --fault]
extends SceneTree

var bad := 0

func _ok(name: String, ok: bool, msg: String) -> void:
	print(("PASS " if ok else "FAIL ") + name + " " + msg)
	if not ok: bad += 1

func _max_slope_deg(b: Bathymetry, th: float, d_lo: float, d_hi: float) -> float:
	var mx := 0.0
	var prev := b.depth(b.at(th, 0.0).x, b.at(th, 0.0).y)
	var ds := 0.1
	var sx := ds
	while sx < 400.0:
		var q := b.at(th, sx)
		var h := b.depth(q.x, q.y)
		var mid := 0.5 * (h + prev)
		if mid > d_lo and mid < d_hi: mx = maxf(mx, rad_to_deg(atan((h - prev) / ds)))
		prev = h; sx += ds
	return mx

func _init():
	var fault := "--fault" in OS.get_cmdline_user_args()
	var b := Bathymetry.new()
	b.radius = 150.0; b.lagoon_d = 4.0; b.ocean_depth = 1000.0; b.sector_deg = 37.0
	var runs: Array = Bathymetry.SECTOR_WALL_M
	var ns := runs.size()
	# B1
	for k in ns:
		var exp_deg := rad_to_deg(atan(1.5 * (Bathymetry.WALL_D - Bathymetry.REEF_FLAT_D) / float(runs[k])))
		var got := []
		for f in [-0.2, 0.0, 0.2]:
			got.append(_max_slope_deg(b, b.sector_mid(k + (1 if fault else 0)) + f * TAU / ns, 3.0, 25.0))
		got.sort()
		var med: float = got[1]
		_ok("B1", absf(med - exp_deg) < 6.0, "%s: steepest %.1f deg (want %.1f)" % [Bathymetry.SECTOR_NAMES[k], med, exp_deg])
	# B2
	var worst := 0.0
	var r := 10.0
	while r < 1600.0:
		var a := b.centre + Vector2(cos(PI - 1e-5), sin(PI - 1e-5)) * r
		var c := b.centre + Vector2(cos(-PI + 1e-5), sin(-PI + 1e-5)) * r
		worst = maxf(worst, absf(b.depth(a.x, a.y) - b.depth(c.x, c.y)))
		r += 0.5
	_ok("B2", worst < 0.05, "seam at the angle wrap: %.4f m" % worst)
	# B3
	for k in ns:
		var q := b.at(b.sector_mid(k), Bathymetry.FLAT_M * 0.5)
		var h := b.depth(q.x, q.y)
		var w := Bathymetry.PASS_D if k == Bathymetry.PASS_SECTOR else Bathymetry.REEF_FLAT_D
		_ok("B3", absf(h - w) < (0.15 if k == Bathymetry.PASS_SECTOR else 0.3), "%s: reef flat %.2f m (want %.2f)" % [Bathymetry.SECTOR_NAMES[k], h, w])
	# B4
	var rises := 0
	var far := 0.0
	for j in 72:
		var th := TAU * j / 72.0
		var wm := b.wall_m(th)
		var sx := Bathymetry.FLAT_M + Bathymetry.SPUR_OUT + wm + 60.0
		var q0 := b.at(th, sx)
		var prev := b.depth(q0.x, q0.y)
		while sx < 2400.0:
			sx += 2.0
			var q := b.at(th, sx)
			var h := b.depth(q.x, q.y)
			if h < prev - 1e-4: rises += 1
			prev = h
		far = maxf(far, absf(prev - b.ocean_depth) / b.ocean_depth)
	_ok("B4", rises == 0 and far < 0.01, "past the wall: %d rises, the far floor off the ocean's depth by %.2f %%" % [rises, far * 100.0])
	# B5
	var off := 0.0
	for j in 360:
		for rr in [0.0, 30.0, 60.0, 90.0, 96.0]:
			var q: Vector2 = b.centre + Vector2(cos(TAU * j / 360.0), sin(TAU * j / 360.0)) * float(rr)
			off = maxf(off, absf(b.depth(q.x, q.y) - b.lagoon_d))
	_ok("B5", off < 1e-4, "lagoon floor off by %.5f m" % off)
	# B6
	var src := FileAccess.get_file_as_string("res://look/sea_bathy.gdshaderinc")
	var arr := "float[%d](%s)" % [ns, ", ".join(runs.map(func(v): return "%.1f" % v))]
	var need := [arr, "PASS_W = %.1f" % Bathymetry.PASS_W, "PASS_D = %.1f" % Bathymetry.PASS_D, "SLOPE_M = %.1f" % Bathymetry.SLOPE_M,
		"WALL_D = %.1f" % Bathymetry.WALL_D, "FLAT_M = %.1f" % Bathymetry.FLAT_M, "* %.1f / %d.0" % [Bathymetry.PASS_SECTOR, ns],
		"SLOPE_M + 2.0 * wm", "% " + str(ns)]
	var miss := need.filter(func(t): return src.find(t) < 0)
	_ok("B6", miss.is_empty(), "the water's mirror matches" if miss.is_empty() else "the water's mirror lacks " + str(miss))
	print("BATHYMETRY ", "ALL PASS" if bad == 0 else "%d FAIL" % bad)
	quit(1 if bad > 0 else 0)
