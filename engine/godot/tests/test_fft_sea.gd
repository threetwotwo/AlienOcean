## FFT sea (water surface thread): the Godot port of the Unreal lagoon's FFT sea must match its source.
##  S1 SeaSpectrum.derive / spectrum / band moments vs the Python (tools/make_caustic_waves.py = v98's derive and
##     spectrum, unchanged) -> tests/data/sea_spectrum_ref.json, to 1e-4 relative.
##  S2 the self test wave: one wave (3, 5) in cascade 0 must come out of the four FFT passes as exp(2 pi i (3x + 5y)/256)
##     (v98's own check of its FFT), max error 1e-3.
##  S3 Parseval: the drawn height variance of each cascade within the spread a random sea gives: 0.5 .. 2 x the
##     spectrum summed over the cascade's own FFT grid (sum psi dk^2: the 250 m cascade holds the narrow swell on a
##     handful of grid points, so the continuous band integral is not its expectation), where it carries > 1e-6 m^2;
##     Hs within 25 % of 4 sqrt(continuous band sum).
##  S4 planted fault: a sea drawn with the wrong slick (calm_k 4 instead of 16) must FAIL S3 for the 2.56 m cascade.
##  S5 height read back (FftSea.height_at, what LagoonWaterField.water_y adds): at 300 drawn points (a still point X
##     moved by its push, X + D(X), as the vertex shader places it) the height must be D(X).z of cascades 0-2 from a
##     direct GPU read, within 2 mm; planted fault: the island y axis not flipped (Godot z = -y) must miss.
## Needs the renderer (compute): xvfb-run -a godot --path . --rendering-driver vulkan --script res://tests/test_fft_sea.gd
extends SceneTree

var sea: FftSea
var frame := 0
var bad := 0
var stage := 0

func _rel(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol * maxf(absf(b), 1e-30)

func _init():
	var ref = JSON.parse_string(FileAccess.get_file_as_string("res://tests/data/sea_spectrum_ref.json"))
	var p := SeaSpectrum.LAGOON.duplicate()
	var d := SeaSpectrum.derive(p)
	for k in ref.derive:
		if not _rel(d[k], ref.derive[k], 1e-4): bad += 1; print("S1 MISMATCH derive ", k, " ", d[k], " want ", ref.derive[k])
	for i in ref.k.size():
		var s := SeaSpectrum.spectrum(ref.k[i][0], ref.k[i][1], d)
		if not _rel(s, ref.spectrum[i], 1e-4): bad += 1; print("S1 MISMATCH spectrum ", ref.k[i], " ", s, " want ", ref.spectrum[i])
	var mo := SeaSpectrum.moments(d)
	for c in 4:
		for j in 4:
			if not _rel(mo.per[c][j], ref.per[c][j], 1e-3) and absf(ref.per[c][j]) > 1e-12:
				bad += 1; print("S1 MISMATCH band ", c, " ", j, " ", mo.per[c][j], " want ", ref.per[c][j])
	print("S1 spectrum vs Python: ", "PASS" if bad == 0 else "FAIL")
	sea = FftSea.new(); sea.self_test = true; sea.hold = true
	root.add_child(sea)

func _process(_dt):
	frame += 1
	if not sea.ready_ok:
		if frame > 60: print("FFT sea: no RenderingDevice -> FAIL"); quit(1)
		return false
	if frame < 4: return false
	if stage == 0:
		var a := sea.read_layer("a", 0)
		var err := 0.0
		for y in 256:
			for x in 256:
				var ph := TAU * (3.0 * x + 5.0 * y) / 256.0
				var i := (y * 256 + x) * 4
				err = maxf(err, maxf(absf(a[i] - cos(ph)), absf(a[i + 1] - sin(ph))))
		print("S2 self test wave: max error %s -> %s" % [str(err), "PASS" if err < 1e-3 else "FAIL"])
		if err >= 1e-3: bad += 1
		sea.self_test = false; sea.time_s = 123.4; sea.step_now(); stage = 1; frame = 0
		return false
	if stage == 1 or stage == 2:
		var fails := _parseval(stage == 1)
		if stage == 1:
			if fails > 0: bad += 1
			var q := SeaSpectrum.LAGOON.duplicate(); q.calm_k = 4.0
			sea.set_params(q); sea.step_now(); stage = 2; frame = 0
			return false
		print("S4 planted fault (slick calm_k 4): %s" % ("caught -> PASS" if fails > 0 else "NOT caught -> FAIL"))
		if fails == 0: bad += 1
		sea.set_params(SeaSpectrum.LAGOON.duplicate()); sea.time_s = 77.0; sea.step_now(); stage = 3; frame = 0
		return false
	if stage == 3:
		if not sea.has_height() or frame < 8: return false
		bad += _height_check()
		print("FFT sea: %s" % ("PASS" if bad == 0 else "FAIL"))
		quit(0 if bad == 0 else 1)
	return false

func _bilin(f: PackedFloat32Array, X: Vector2, L: float) -> Vector3:
	var u := X / L * 256.0 - Vector2(0.5, 0.5)
	var x0 := floori(u.x); var y0 := floori(u.y); var fx := u.x - x0; var fy := u.y - y0
	var r := Vector3.ZERO
	for dy in 2:
		for dx in 2:
			var i := (posmod(y0 + dy, 256) * 256 + posmod(x0 + dx, 256)) * 4
			r += (fx if dx else 1.0 - fx) * (fy if dy else 1.0 - fy) * Vector3(f[i], f[i + 1], f[i + 2])
	return r

func _height_check() -> int:
	var f0 := sea.read_layer("disp", 0); var f1 := sea.read_layer("disp", 1); var f2 := sea.read_layer("disp", 2)
	var rng := RandomNumberGenerator.new(); rng.seed = 5
	var err := 0.0; var err_flip := 0.0; var s2 := 0.0
	for k in 300:
		var X := Vector2(rng.randf_range(-400.0, 400.0), rng.randf_range(-400.0, 400.0))
		var D := _bilin(f0, X, sea.patch.x) + _bilin(f1, X, sea.patch.y) + _bilin(f2, X, sea.patch.z)
		var w := X + Vector2(D.x, D.y)
		err = maxf(err, absf(sea.height_at(w.x, -w.y) - D.z))
		err_flip = maxf(err_flip, absf(sea.height_at(w.x, w.y) - D.z))
		s2 += D.z * D.z
	var rms := sqrt(s2 / 300.0)
	var ok := err < 0.002 and rms > 0.005
	print("S5 height read back: max error %.5f m (crest rms %.4f m) -> %s" % [err, rms, "PASS" if ok else "FAIL"])
	var caught := err_flip > 0.01
	print("S5 planted fault (y axis not flipped): max error %.4f m -> %s" % [err_flip, "caught -> PASS" if caught else "NOT caught -> FAIL"])
	return (0 if ok else 1) + (0 if caught else 1)

func _parseval(report: bool) -> int:
	var mo := SeaSpectrum.moments(SeaSpectrum.derive(SeaSpectrum.LAGOON))
	var fails := 0; var tot := 0.0; var want := 0.0
	for c in 4:
		var f := sea.read_layer("disp", c)
		var s := 0.0; var s2 := 0.0
		for i in range(0, f.size(), 4): s += f[i + 2]; s2 += f[i + 2] * f[i + 2]
		var n := f.size() / 4.0
		var v := s2 / n - (s / n) * (s / n)
		var w := _grid_var(c)
		tot += v; want += mo.per[c].x
		var ok := w < 1e-6 or (v > 0.5 * w and v < 2.0 * w)
		if not ok: fails += 1
		if report: print("S3 cascade %d: height var %s m^2, spectrum %s -> %s" % [c, str(v), str(w), "ok" if ok else "OUT"])
	var hs := 4.0 * sqrt(tot); var hw := 4.0 * sqrt(want)
	if not _rel(hs, hw, 0.25): fails += 1
	if report: print("S3 Hs drawn %.4f m, spectrum %.4f m -> %s" % [hs, hw, "PASS" if fails == 0 else "FAIL"])
	return fails

func _grid_var(c: int) -> float:
	## the spectrum summed over cascade c's grid within its band (the expected height variance of that cascade)
	var d := SeaSpectrum.derive(SeaSpectrum.LAGOON)
	var L: float = SeaSpectrum.CASCADES[c]; var dk := TAU / L
	var b: Vector2 = SeaSpectrum.bands()[c]
	var v := 0.0
	for j in 256:
		for i in 256:
			var kx := (i - 256 if i >= 128 else i) * dk; var ky := (j - 256 if j >= 128 else j) * dk
			var k := sqrt(kx * kx + ky * ky)
			if k > b.x and k <= b.y: v += SeaSpectrum.spectrum(kx, ky, d) * dk * dk
	return v
