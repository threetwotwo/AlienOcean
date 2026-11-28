## Sea spectrum 0.3.0 (core/world; water surface thread, 27-28 Nov 2026): the Unreal lagoon's wave spectrum, ported.
## 0.2.0: the open sea too: the Unreal open-water tank's (openocean_tank v374) cascades (1500, 179, 21.4, 2.56 m), its
## default sea (wind 8 m/s over 500 km, swell 1 m 12 s), its Sea knob (beaufort(): the Beaufort table, wind at each
## band's middle and the fetch fitted to the WMO's probable wave height, tools/oo_seastate.py) and its whitecap
## calibration (foam_jt(): the Jacobian under which the sea breaks, FOAM_JT v331, Brumer et al. 2017). A preset
## carries its own cascades ("cascades", "ring_hi"); bands() and moments() follow them.
## Source: lagoonwater v98 (openocean_tank v311's FFT sea): derive(), spectrum(), bands(), band_moments(), moments(),
## spec_vectors(), unchanged maths. Elfouhaily et al. (1997) wind sea with Donelan-Banner spreading + a JONSWAP swell,
## the lagoon's slick (energy x 1 / (1 + (k / CALM_K)^4), v84 CALM_K 16) and shallow-water speed (tanh(k h)).
## Engine-agnostic: the Godot compute pass (adapters/godot/fft_sea.gd + look/sea_*.glsl) reads spec_vectors() and
## moments(); tools/make_caustic_waves.py draws its 32 waves from the same spectrum.
class_name SeaSpectrum
extends RefCounted

const G := 9.81
const KM := 370.0            # rad/m: gravity-capillary phase-speed minimum
const CM := 0.23             # m/s: that minimum phase speed
const CASCADES := [250.0, 21.4, 2.56, 0.32]   # patch sizes m, largest first (v98)
const RING_HI := [32.0, 32.0, 32.0, 64.0]     # band top in rings of its own grid (v98)
const N := 256               # FFT size per cascade
const T_REPEAT := 1000.0     # s: every frequency a whole multiple of 2 pi / 1000 s, so time wraps exactly
const CHOP := 1.0            # the tank's Chop (sideways squeeze at the crests)
const SEED := 1.0            # SpecD.w (v98)
## The lagoon's sea (v98 LAB_WIND 2 m/s, the lagoon actor's fetch 3 km, LAB_SWELL_HS 0.03 m over the reef,
## LAB_SWELL_SPREAD 40, swell period 12 s heading 40 deg), its depth (mean_depth 4 m) and slick (CALM_K 16).
## 0.3.0 (28 Nov): to key frame v7c's sea (Gary approved v7c 04:35Z; its waves reach 0.15 m at RMS slope 0.09 from
## 2.5 m/s at 30 deg; v98's slick at k 16 cut everything under 0.4 m, so the caustic net and Snell's window had no
## fine detail): wind 2.5 m/s from 30 deg, the lagoon's own fetch (1 km, inside the reef), slick at k 40 (0.16 m).
## RMS slope 0.091, wind-sea peak 1.1 m, Hs 0.05 m (was 0.074, 0.056 m).
const LAGOON := {"U10": 2.5, "fetch_km": 1.0, "wind_deg": 30.0, "swell_hs": 0.03, "swell_tp": 12.0, "swell_deg": 40.0,
	"swell_s": 40.0, "depth": 2.4, "calm_k": 40.0}   # 2.4 m: the lagoon depth Gary picked (28 Nov)
## The open sea (openocean_tank v374 KNOBS: Wind 8 m/s 500 km, Swell 1 m 12 s 40 deg spread 40; CASCADES, RING_HI),
## deep (tanh(k h) = 1) and with no slick.
const OCEAN_CASCADES := [1500.0, 179.0, 21.4, 2.56]
const OPEN_OCEAN := {"U10": 8.0, "fetch_km": 500.0, "wind_deg": 0.0, "swell_hs": 1.0, "swell_tp": 12.0, "swell_deg": 40.0,
	"swell_s": 40.0, "depth": 4000.0, "calm_k": 0.0, "cascades": OCEAN_CASCADES, "ring_hi": [32.0, 32.0, 32.0, 64.0]}
## The tank's Sea knob (v374 BEAUFORT): force -> (wind m/s at 10 m, fetch km, name). Force 0 (calm, under 0.5 m/s)
## added here: the spectrum's floor wind 0.5 m/s over the longest fetch.
const BEAUFORT := {0: [0.5, 5000.0, "calm"], 1: [0.9, 5000.0, "light air"], 2: [2.4, 5000.0, "light breeze"],
	3: [4.4, 5000.0, "gentle breeze"], 4: [6.7, 260.0, "moderate breeze"], 5: [9.3, 580.0, "fresh breeze"],
	6: [12.3, 490.0, "strong breeze"], 7: [15.5, 390.0, "near gale"], 8: [18.9, 450.0, "gale"],
	9: [22.6, 460.0, "strong gale"], 10: [26.4, 530.0, "storm"], 11: [30.5, 640.0, "violent storm"],
	12: [34.0, 750.0, "hurricane force"]}
## WMO probable wave height (m) per force (tools/oo_seastate.py WMO_HS), for the stress test
const WMO_HS := {0: 0.0, 1: 0.1, 2: 0.2, 3: 0.6, 4: 1.0, 5: 2.0, 6: 3.0, 7: 4.0, 8: 5.5, 9: 7.0, 10: 9.0, 11: 11.5, 12: 14.0}
## v374 FOAM_JT_V331 (cascades 0-1) and FOAM_JT2_V331 (cascades 0-2, the foam step's): wind m/s -> the Jacobian quantile
## at the breaking share p_b (Brumer 2017 whitecaps, minus the share of foam lingering 4 s): under it the sea breaks
const FOAM_JT := [[3.0, 0.865], [5.0, 0.744], [7.0, 0.733], [8.0, 0.729], [10.0, 0.724], [12.0, 0.722], [15.0, 0.722],
	[20.0, 0.732], [22.6, 0.740], [26.4, 0.753], [30.5, 0.766], [34.0, 0.776]]
const FOAM_JT2 := [[3.0, 0.631], [5.0, 0.581], [7.0, 0.609], [8.0, 0.617], [10.0, 0.628], [12.0, 0.638], [15.0, 0.653],
	[20.0, 0.677], [22.6, 0.690], [26.4, 0.707], [30.5, 0.723], [34.0, 0.736]]

## v374 FOAM_JTA_D / FOAM_JTA2_D (Brumer, v331): how far under the threshold the Jacobian goes for the deep fold (the
## breaking crest itself: the p_b -> p_b / 3 quantile step), cascades 0-1 / 0-2
const FOAM_JTA_D := [[3.0, 0.002], [5.0, 0.009], [7.0, 0.021], [8.0, 0.024], [10.0, 0.035], [12.0, 0.040], [15.0, 0.041],
	[20.0, 0.046], [22.6, 0.048], [26.4, 0.053], [30.5, 0.056], [34.0, 0.059]]
const FOAM_JTA2_D := [[3.0, 0.008], [5.0, 0.020], [7.0, 0.035], [8.0, 0.038], [10.0, 0.041], [12.0, 0.044], [15.0, 0.048],
	[20.0, 0.055], [22.6, 0.058], [26.4, 0.062], [30.5, 0.066], [34.0, 0.069]]
const FOAM_SOFT := 0.04
const FOAM_TAU := 4.0        # s: foam fades with this time constant (Callaghan 2012)

static func foam_delta_a(U: float, chop := CHOP, cascades_02 := false) -> float:
	return _table(FOAM_JTA2_D if cascades_02 else FOAM_JTA_D, U) * maxf(chop, 0.05)

const FOAM_ROW_A := 0.012   # v336 FFLOW_ROW_A: the windrows' speed, m/s per m/s of wind, from 6 m/s (full at 12)

static func foam_consts(d: Dictionary) -> Dictionary:
	## what the foam step and the foam's look need from a derived sea (v374 sea-state push): thresholds, the breaker
	## speed, the wind drift (3 % of the wind, island m/s), the storm ramp. No whitecaps under 4.23 m/s (Brumer's W_B = 0):
	## the thresholds go out of reach, so the calm lagoon never breaks.
	var U: float = d.U
	var on := breaking_share(U, TAU / float(d.wp)) > 0.0
	var a: float = d.wind
	return {"jt": foam_jt(U) if on else -10.0, "jt2": foam_jt(U, CHOP, true) if on else -10.0,
		"da": foam_delta_a(U), "da2": foam_delta_a(U, CHOP, true), "soft": FOAM_SOFT, "tau": FOAM_TAU,
		"cbreak": clampf(0.45 * float(d.cp), 2.0, 10.0), "drift": Vector2(cos(a), sin(a)) * 0.03 * U,
		"wind": Vector2(cos(a), sin(a)), "U": U, "storm": clampf((U - 20.0) / 10.0, 0.0, 1.0), "on": on,
		"rows": FOAM_ROW_A * U * clampf((U - 6.0) / 6.0, 0.0, 1.0)}

static func beaufort(force: int, base: Dictionary = OPEN_OCEAN) -> Dictionary:
	## the tank's Sea knob: base with the force's wind and fetch (swell, depth, cascades kept)
	var b: Array = BEAUFORT[clampi(force, 0, 12)]
	var p := base.duplicate()
	p.U10 = b[0]; p.fetch_km = b[1]
	return p

static func _table(t: Array, U: float) -> float:
	if U <= t[0][0]: return t[0][1]
	if U >= t[-1][0]: return t[-1][1]
	for i in t.size() - 1:
		if U <= t[i + 1][0]:
			return lerpf(t[i][1], t[i + 1][1], (U - t[i][0]) / (t[i + 1][0] - t[i][0]))
	return t[-1][1]

static func foam_jt(U: float, chop := CHOP, cascades_02 := false) -> float:
	## v374 foam_threshold() (FOAM_COVER = 1 under Brumer): the Jacobian under which the sea breaks
	var jt := _table(FOAM_JT2 if cascades_02 else FOAM_JT, U)
	return 1.0 - (1.0 - jt) * maxf(chop, 0.05)

static func breaking_share(U: float, tp: float) -> float:
	## v331 (tank331/fitB.py): the share of the sea breaking now, p_b = W_B / (1 + 4 s / (0.33 Tp)),
	## W_B = min(7.38e-4 (U - 4.23)^1.42, 0.1) (Brumer et al. 2017 whitecap cover; foam lingers 4 s)
	var wb := minf(7.38e-4 * pow(maxf(U - 4.23, 0.0), 1.42), 0.1)
	return wb / (1.0 + 4.0 / (0.33 * maxf(tp, 0.5)))

static func derive(p: Dictionary) -> Dictionary:
	var U := maxf(float(p.U10), 0.5)
	var F := maxf(float(p.fetch_km), 1.0) * 1000.0
	var X := G * F / (U * U)
	var om := maxf(0.84 * pow(tanh(pow(X / 2.2e4, 0.4)), -0.75), 0.84)
	var kp := G * pow(om / U, 2)
	var cp := sqrt(G / kp)
	var alpha_p := 6e-3 * sqrt(om)
	var gamma := 1.7 if om < 1.0 else 1.7 + 6.0 * log(om) / log(10.0)
	var sigma := 0.08 * (1.0 + 4.0 * pow(om, -3))
	var ustar := U * sqrt((0.8 + 0.065 * U) * 1e-3)
	var alpha_m := maxf(0.0, 0.01 * (1.0 + (log(ustar / CM) if ustar < CM else 3.0 * log(ustar / CM))))
	var wp := sqrt(G * kp * (1.0 + pow(kp / KM, 2)))
	var d := {"U": U, "Omega": om, "kp": kp, "cp": cp, "alpha_p": alpha_p, "gamma": gamma, "sigma": sigma,
		"ustar": ustar, "alpha_m": alpha_m, "wp": wp, "wind": deg_to_rad(float(p.get("wind_deg", 0.0))),
		"calm_k": float(p.get("calm_k", 0.0)), "depth": float(p.get("depth", 100.0)),
		"cascades": p.get("cascades", CASCADES), "ring_hi": p.get("ring_hi", RING_HI)}
	var hs := maxf(float(p.get("swell_hs", 0.0)), 0.0)
	var ws := TAU / maxf(float(p.get("swell_tp", 12.0)), 2.0)
	d.swell_w = ws; d.swell_gamma = 7.0
	d.swell_dir = deg_to_rad(float(p.get("swell_deg", 40.0)))
	d.swell_s = maxf(float(p.get("swell_s", 40.0)), 1.0)
	var m0 := 0.0; var n := 4000
	for i in n:
		var w := ws * (0.3 + 3.7 * (i + 0.5) / n)
		var sg := 0.07 if w <= ws else 0.09
		var r := exp(-pow(w - ws, 2) / (2.0 * sg * sg * ws * ws))
		m0 += G * G * pow(w, -5) * exp(-1.25 * pow(ws / w, 4)) * pow(7.0, r) * (3.7 * ws / n)
	d.swell_a = pow(hs / 4.0, 2) / m0 if m0 > 0.0 and hs > 0.0 else 0.0
	var s: float = d.swell_s
	d.swell_norm = exp(_lgamma(s + 1.0) - _lgamma(s + 0.5)) / (2.0 * sqrt(PI))
	return d

static func _lgamma(x: float) -> float:
	## Lanczos (g 7, 9 terms): log Gamma(x) for x > 0.5, to ~1e-13
	var c := [0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313, -176.61502916214059,
		12.507343278686905, -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7]
	x -= 1.0
	var a: float = c[0]
	var t := x + 7.5
	for i in range(1, 9): a += c[i] / (x + i)
	return 0.5 * log(TAU) + (x + 0.5) * log(t) - t + log(a)

static func spectrum(kx: float, ky: float, d: Dictionary) -> float:
	## directional wavenumber spectrum per unit kx ky (m^4): wind sea + swell, with the slick (v98 spectrum())
	var k := sqrt(kx * kx + ky * ky)
	if k <= 0.0: return 0.0
	var th := atan2(ky, kx)
	var c := sqrt(G / k * (1.0 + pow(k / KM, 2)))
	var lpm := exp(-1.25 * pow(d.kp / k, 2))
	var sq := sqrt(k / d.kp)
	var jp := pow(d.gamma, exp(-pow(sq - 1.0, 2) / (2.0 * d.sigma * d.sigma)))
	var fp: float = lpm * jp * exp(-d.Omega / sqrt(10.0) * (sq - 1.0))
	var bl: float = 0.5 * d.alpha_p * (d.cp / c) * fp
	var fm: float = lpm * jp * exp(-0.25 * pow(k / KM - 1.0, 2))
	var bh: float = 0.5 * d.alpha_m * (CM / c) * fm
	var s := (bl + bh) / pow(k, 3)
	var w := sqrt(G * k * (1.0 + pow(k / KM, 2)))
	var r := maxf(w / d.wp, 0.56)
	var beta: float
	if r < 0.95: beta = 2.61 * pow(r, 1.3)
	elif r < 1.6: beta = 2.28 * pow(r, -1.3)
	else: beta = pow(10.0, -0.4 + 0.8393 * exp(-0.567 * log(r * r)))
	var a := atan2(sin(th - d.wind), cos(th - d.wind))
	var out := s * beta / (2.0 * tanh(beta * PI)) / pow(cosh(beta * a), 2) / k
	if d.swell_a > 0.0:
		var ws: float = d.swell_w
		var sg := 0.07 if w <= ws else 0.09
		var rr := exp(-pow(w - ws, 2) / (2.0 * sg * sg * ws * ws))
		var sw: float = d.swell_a * G * G * pow(w, -5) * exp(-1.25 * pow(ws / w, 4)) * pow(d.swell_gamma, rr)
		var dwdk := G * (1.0 + 3.0 * pow(k / KM, 2)) / (2.0 * w)
		var b := atan2(sin(th - d.swell_dir), cos(th - d.swell_dir))
		out += sw * dwdk * d.swell_norm * pow(absf(cos(0.5 * b)), 2.0 * d.swell_s) / k
	if d.calm_k > 0.0:
		out /= 1.0 + pow(k / d.calm_k, 4)
	return out

static func bands(cascades: Array = CASCADES, ring_hi: Array = RING_HI) -> Array:
	var out := []; var lo := 0.0
	for i in cascades.size():
		var hi: float = TAU * ring_hi[i] / cascades[i]
		out.append(Vector2(lo, hi)); lo = hi
	return out

static func band_moments(d: Dictionary, k_lo: float, k_hi: float, nk := 60, nth := 48) -> Vector4:
	## over k_lo < |k| <= k_hi: (var h m^2, E[sx^2], E[sy^2], E[sx sy]), sx = dh/dx
	if k_hi <= k_lo: return Vector4.ZERO
	var a := log(maxf(k_lo, 1e-4)); var b := log(k_hi)
	var m := Vector4.ZERO
	var dth := TAU / nth
	for i in nk:
		var k := exp(a + (b - a) * (i + 0.5) / nk)
		var dk := k * (b - a) / nk
		for j in nth:
			var th := -PI + (j + 0.5) * dth
			var kx := k * cos(th); var ky := k * sin(th)
			var w := spectrum(kx, ky, d) * k * dk * dth
			m += Vector4(w, w * kx * kx, w * ky * ky, w * kx * ky)
	return m

static func moments(d: Dictionary) -> Dictionary:
	## per cascade (var h, sx2, sy2, sxy), the slopes shorter than the finest cascade, and the shader vectors
	## MomX / MomY (sx2, sy2 per cascade) and MomR (residual sx2, sy2, sxy, Hs) as v98 set them
	var b := bands(d.get("cascades", CASCADES), d.get("ring_hi", RING_HI))
	var per := []
	for bb in b: per.append(band_moments(d, bb.x, bb.y))
	var res := band_moments(d, b[-1].y, 10.0 * KM, 80)
	var vh := 0.0
	for p in per: vh += p.x
	return {"per": per, "res": res, "hs": 4.0 * sqrt(vh),
		"mom_x": Vector4(per[0].y, per[1].y, per[2].y, per[3].y),
		"mom_y": Vector4(per[0].z, per[1].z, per[2].z, per[3].z),
		"mom_r": Vector4(res.y, res.z, res.w, 4.0 * sqrt(vh))}

static func spec_vectors(d: Dictionary) -> Array:
	## SpecA..D as v98 packed them, + Depth (depth m, calm k, fine pass-through, 0)
	return [Vector4(d.kp, d.cp, d.alpha_p, d.gamma), Vector4(d.sigma, d.alpha_m, d.Omega, d.wp),
		Vector4(d.wind, d.swell_a, d.swell_w, d.swell_dir), Vector4(d.swell_s, d.swell_norm, d.swell_gamma, SEED),
		Vector4(d.depth, d.calm_k, 0.0, 0.0)]
