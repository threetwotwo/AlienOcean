## Sea stress 0.1.0 (water surface thread, 28 Nov 2026): the Unreal open-water tank's big-wave stress test
## (openocean tools/oo_stress.py), run on the Godot sea itself (the GPU's own cascades, read back), not on an offline
## copy. For each Beaufort force of the open sea (SeaSpectrum.beaufort) and for the calm lagoon:
##   - wave height: Hs of the drawn sea against the spectrum's and the WMO's probable height; highest crest, deepest trough;
##   - folding: the share of the sea where the choppy surface turns inside out (Jacobian < 0 over cascades 0-2, what
##     the mesh draws near the eye): loops and torn triangles. Must be 0;
##   - breaking: the share under the whitecap threshold (SeaSpectrum.foam_jt, cascades 0-1) against Brumer's p_b
##     (what the foam step will light);
##   - the peak wavelength (it must fit the largest cascade).
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --script res://tools/sea_stress.gd [-- --json out.json]
extends SceneTree

const NPT := 6000
var sea: FftSea
var cases := []
var ci := -1
var frame := 0
var rows := []
var out_json := ""

func _init():
	var a := OS.get_cmdline_user_args()
	if a.size() >= 2 and a[0] == "--json": out_json = a[1]
	cases.append(["lagoon", SeaSpectrum.LAGOON, -1])
	var only := OS.get_environment("AO_FORCES")      # e.g. 4,8,12 (default: all 0-12)
	for f in 13:
		if only == "" or str(f) in only.split(","): cases.append(["B%d" % f, SeaSpectrum.beaufort(f), f])
	sea = FftSea.new(); sea.hold = true; sea.time_s = 123.4
	root.add_child(sea)
	print("case    U m/s  Hs drawn/spec/WMO m   crest/trough m  peak m  fold %   breaking % (drawn/Brumer)  J thr")

func _process(_dt):
	frame += 1
	if not sea.ready_ok:
		if frame > 60: print("no RenderingDevice"); quit(1)
		return false
	if ci >= 0 and frame == 6:
		var pre := float(OS.get_environment("AO_PREROLL")) if OS.get_environment("AO_PREROLL") != "" else 12.0
		sea.hold = false; sea.preroll(pre, 1.0 / 15.0); sea.hold = true
	if ci < 0 or frame >= 10:
		if ci >= 0: _measure()
		ci += 1
		if ci >= cases.size():
			if out_json != "":
				var f := FileAccess.open(out_json, FileAccess.WRITE); f.store_string(JSON.stringify(rows, "  ")); f.close()
			quit(0)
			return false
		sea.set_params(cases[ci][1]); sea.step_now(); frame = 0
	return false

func _bil(f: PackedFloat32Array, X: Vector2, L: float) -> Vector4:
	var u := X / L * 256.0 - Vector2(0.5, 0.5)
	var x0 := floori(u.x); var y0 := floori(u.y); var fx := u.x - x0; var fy := u.y - y0
	var r := Vector4.ZERO
	for dy in 2:
		for dx in 2:
			var i := (posmod(y0 + dy, 256) * 256 + posmod(x0 + dx, 256)) * 4
			r += (fx if dx else 1.0 - fx) * (fy if dy else 1.0 - fy) * Vector4(f[i], f[i + 1], f[i + 2], f[i + 3])
	return r

func _measure() -> void:
	var nm: String = cases[ci][0]; var p: Dictionary = cases[ci][1]; var force: int = cases[ci][2]
	var d := SeaSpectrum.derive(p)
	var L := [sea.patch.x, sea.patch.y, sea.patch.z, sea.patch.w]
	var disp := []; var der := []
	for c in 4: disp.append(sea.read_layer("disp", c)); der.append(sea.read_layer("deriv", c))
	var rng := RandomNumberGenerator.new(); rng.seed = 11
	var s := 0.0; var s2 := 0.0; var hi := -INF; var lo := INF; var fold := 0; var brk := 0
	var U: float = d.U
	var jt := SeaSpectrum.foam_jt(U)
	var ext: float = L[0]
	for k in NPT:
		var X := Vector2(rng.randf() * ext, rng.randf() * ext)
		var z := 0.0; var jxx := 1.0; var jyy := 1.0; var jxy := 0.0
		var jxx01 := 1.0; var jyy01 := 1.0; var jxy01 := 0.0
		for c in 4:
			var a := _bil(disp[c], X, L[c]); z += a.z
			if c < 3:
				var g := _bil(der[c], X, L[c])
				jxx += g.z; jyy += g.w; jxy += a.w
				if c < 2: jxx01 += g.z; jyy01 += g.w; jxy01 += a.w
		s += z; s2 += z * z; hi = maxf(hi, z); lo = minf(lo, z)
		if jxx * jyy - jxy * jxy < 0.0: fold += 1
		if jxx01 * jyy01 - jxy01 * jxy01 < jt: brk += 1
	var mean := s / NPT
	var hs := 4.0 * sqrt(maxf(s2 / NPT - mean * mean, 0.0))
	var hs_spec: float = sea.moments.hs
	var tp := TAU / float(d.wp)
	var pb := SeaSpectrum.breaking_share(U, tp)
	var wmo: float = SeaSpectrum.WMO_HS.get(force, -1.0)
	var lam := TAU / float(d.kp)
	var fm := sea.read_foam()
	var fc := 0.0; var fr := 0.0; var nf := 0
	for k in range(0, fm.size(), 4 * 7):
		fc += 1.0 if fm[k] > 0.5 else 0.0; fr += 1.0 if fm[k + 1] > 0.5 else 0.0; nf += 1
	var wb := minf(7.38e-4 * pow(maxf(U - 4.23, 0.0), 1.42), 0.1)
	var row := {"case": nm, "foam_cover": fc / nf, "fresh_cover": fr / nf, "brumer_wb": wb, "U": U, "hs": hs, "hs_spec": hs_spec, "wmo": wmo, "crest": hi, "trough": lo, "peak_m": lam,
		"fold": float(fold) / NPT, "breaking": float(brk) / NPT, "brumer_pb": pb, "jt": jt, "largest_cascade": L[0]}
	rows.append(row)
	print("%-6s %6.1f   %6.2f / %5.2f / %5s   %6.2f / %6.2f  %6.0f  %6.3f   %6.2f / %6.2f              %.3f   foam %5.2f%% (Brumer W_B %5.2f%%) fresh %5.2f%%" % [nm, U, hs,
		hs_spec, ("%.1f" % wmo) if wmo >= 0.0 else "-", hi, lo, lam, 100.0 * fold / NPT, 100.0 * brk / NPT, 100.0 * pb, jt,
		100.0 * fc / nf, 100.0 * wb, 100.0 * fr / nf])
