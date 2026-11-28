## M34 Bubbles: motion 0.1.0 (bubbles thread, 28 Nov 2026). Pure functions, no engine nodes: where an air bubble is at a
## given age, how big it is, when it reaches its cap (the surface or a ceiling). look/bubble.gdshader draws every bubble
## from exactly this maths on the GPU (keep the two in step: test_bubbles.gd checks this mirror; the shader carries the
## same names). Ported from Gary's Thalassa v20.19 (style/particles.js ParticleSystem.updateBubbles: rise, swirl that
## grows with age, current x 0.35, sideways drag e^-1.1t) and upgraded with the Unreal-era bubbles v4 physics
## (/mnt/project-files/bubbles/tools/look_v4: motion.py, shapes.py; paper papers/systems/bubbles):
##  - rise: the coated-seawater terminal speed table by radius (RISE_A mm -> RISE_W cm/s, 0.1 mm 1.6 cm/s .. 10 mm 32)
##  - the exhaled jet: the bubble leaves with the jet's speed and settles to its rise over JET_TAU. A real 2 mm bubble loses
##    its own momentum in ~5 ms; what carries a diver's puff is the exhaled water jet, which no flow model holds yet.
##    STAND-IN for that missing jet flow (owner: bubbles thread; removal: when a water-flow field exists, sample it)
##  - riding the water: a bubble takes up the water's sideways speed in ~a^2/18nu (0.06 s at 1 mm), so it rides the
##    current and the swell's orbit (the shared drift, adapters/godot/motes.gd) and 4 small Kolmogorov eddies, integrated
##    exactly along its rising path (no 'displacement field' sampled at a moving point, which would wiggle unphysically)
##  - zigzag / spiral of its wake above Re 275 (Wu & Gharib 2002, St 0.087), path tilt up to TILT, half wind into a spiral
##  - growth with ascent: the gas expands as the pressure drops, a ~ ((10.3 + z0) / (10.3 + z))^(1/3)
##  - its cap: it slows to rest under the surface (or a ceiling) at cap_y - a (soft_cap), sits for a dwell, then pops
## Everything is a closed-form function of (spawn record, age): no per-frame state, so it cannot jitter or drift with the
## frame or tick rate (Gary 28 Nov: no jitter anywhere).
class_name BubbleMotion
extends RefCounted

const NU := 1.05e-6                      # m2/s seawater
const RHO := 1023.0
const SIGMA := 0.073                     # N/m
const RISE_A := [0.05, 0.1, 0.3, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0]   # radius mm (bubbles v4 render.py, coated seawater)
const RISE_W := [0.5, 1.6, 6.6, 10.7, 16.8, 20.1, 24.1, 31.7, 44.1] # cm/s
const ST := 0.087
const RE_C := 275.0
const RE_FULL := 400.0
const TILT := 0.2094                      # rad, 12 deg (Gary 12 Nov 16:05Z: 25 swung the reflected horizon too far)
const SP0 := 0.5                          # s: a spiralling bubble winds in between SP0 and SP1 of age
const SP1 := 1.5
const P_ATM_M := 10.3                     # m of seawater per atmosphere
# 4 eddies (bubbles v4 motion.py Water: u_rms 1 cm/s, L 0.3 m, Kolmogorov speeds), fixed so GPU and CPU agree
const EDDY_U := 0.01
const EDDY_L := 0.3

static var _ek: Array = []                # wave vectors k_i (rad/m)
static var _ee: Array = []                # unit directions e_i (perpendicular to k_i: no divergence)
static var _eu: Array = []                # speeds u_i (m/s)
static var _ew: Array = []                # turnover rates w_i = u_i |k_i|
const EDDY_P := [1.3, 4.1, 2.2, 5.9]

## terminal rise speed (m/s) of a bubble of radius a_mm
static func rise(a_mm: float) -> float:
	var la := log(clampf(a_mm, RISE_A[0], RISE_A[-1]))
	for i in RISE_A.size() - 1:
		var l0 := log(float(RISE_A[i])); var l1 := log(float(RISE_A[i + 1]))
		if la <= l1:
			var f := (la - l0) / (l1 - l0)
			return 0.01 * exp(lerpf(log(float(RISE_W[i])), log(float(RISE_W[i + 1])), f))
	return 0.01 * float(RISE_W[-1])

## the jet's settling time (s): art stand-in, see the header
static func jet_tau(a_mm: float) -> float:
	return clampf(0.12 + 0.02 * a_mm, 0.12, 0.45)

static func _eddies() -> void:
	if not _ek.is_empty(): return
	var us := []
	var gold := PI * (3.0 - sqrt(5.0))
	for i in 4:
		var kmag := TAU / EDDY_L * pow(1.7, i)
		var th := acos(1.0 - 2.0 * ((i + 0.5) / 4.0))
		var ph := i * gold + 3.0
		var kh := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))     # y up
		var e := kh.cross(Vector3(0.3, 0.81, 0.5)).normalized()
		_ek.append(kh * kmag); _ee.append(e); us.append(pow(kmag, -1.0 / 3.0))
	var s2 := 0.0
	for u in us: s2 += u * u
	var k := EDDY_U / sqrt(0.5 * s2)
	for i in 4:
		_eu.append(us[i] * k); _ew.append(us[i] * k * (_ek[i] as Vector3).length())

## the eddies' push integrated along the base path p0 + (0, w, 0) t for age t (m): each eddy is u e cos(k.x - w t + p);
## along the path its phase runs at Om = k_y w - w_i, so the displacement is u e (sin(ph0 + Om t) - sin(ph0)) / Om,
## written in the sinc form that stays exact as Om -> 0. The phase at birth depends on where it was born only (not when),
## so a stream sways as one ribbon and nothing depends on the clock's epoch (bubbles.gd rebases it every 15 min).
static func eddy(p0: Vector3, w: float, t: float) -> Vector3:
	_eddies()
	var d := Vector3.ZERO
	for i in 4:
		var k: Vector3 = _ek[i]
		var om: float = k.y * w - float(_ew[i])
		var ph0: float = k.dot(p0) + float(EDDY_P[i])
		var x := 0.5 * om * t
		var sinc := 1.0 if absf(x) < 1e-4 else sin(x) / x
		d += (_ee[i] as Vector3) * float(_eu[i]) * t * cos(ph0 + x) * sinc
	return d

## the path without the water's drift, eddies or wake: jet settling to the rise
static func base(p0: Vector3, v0: Vector3, w: float, tau: float, t: float) -> Vector3:
	var up := Vector3(0, w, 0)
	return p0 + up * t + (v0 - up) * (tau * (1.0 - exp(-t / tau)))

static func base_y(y0: float, v0y: float, w: float, tau: float, t: float) -> float:
	return y0 + w * t + (v0y - w) * tau * (1.0 - exp(-t / tau))

## the wake's zigzag / spiral offset (m) at age t for a bubble of radius a (m) rising at w; ph from its seed
static func wake(a: float, w: float, t: float, ph: float, spiral: bool, tau: float) -> Vector3:
	var re := w * 2.0 * a / NU
	if re <= RE_C: return Vector3.ZERO
	var al := TILT * sqrt(clampf((re - RE_C) / (RE_FULL - RE_C), 0.0, 1.0))
	var fz := ST * w / (2.0 * a)
	var amp := w * tan(al) / (TAU * fz) * (1.0 - exp(-t / tau))      # grows as the jet settles
	var dz := Vector2(cos(1.7 * ph), sin(1.7 * ph)); var dq := Vector2(-dz.y, dz.x)
	var u := clampf((t - SP0) / (SP1 - SP0), 0.0, 1.0)
	var sp := u * u * (3.0 - 2.0 * u) if spiral else 0.0
	var x := TAU * fz * t + ph
	var o := amp * (sin(x) * dz - sp * cos(x) * dq)
	return Vector3(o.x, 0.0, o.y)

## radius (m) at depth z (m under the surface) for a bubble born a0 at depth z0
static func grown(a0: float, z0: float, z: float) -> float:
	return a0 * pow((P_ATM_M + maxf(z0, 0.0)) / (P_ATM_M + maxf(z, 0.0)), 1.0 / 3.0)

## age (s) at which the bubble's top reaches cap_y (Newton on the base path; the growth is small and taken at the cap)
static func time_to_cap(y0: float, v0y: float, a_cap: float, w: float, tau: float, cap_y: float) -> float:
	var target := cap_y - a_cap
	if y0 >= target: return 0.0
	var t := maxf(0.0, (target - y0 - (v0y - w) * tau) / w)
	for i in 12:
		var f := base_y(y0, v0y, w, tau, t) - target
		var df := w + (v0y - w) * exp(-t / tau)
		if absf(df) < 1e-5: df = w
		t = maxf(0.0, t - f / df)
	return t

## soft landing under the cap: y never passes y_max, and closes on it smoothly over about one radius k (a real bubble slows
## within about its own size as it meets the surface); C-infinity, so no kink in its path when it arrives
static func soft_cap(y: float, y_max: float, k: float) -> float:
	var x := (y_max - y) / k
	return y_max - k * (maxf(x, 0.0) + log(1.0 + exp(-absf(x))))

## the full position (without the shared drift, which the shader adds as drift_now - drift0) at age t
static func position(rec: Dictionary, t: float) -> Vector3:
	var p := base(rec.p0, rec.v0, rec.w, rec.tau, t)
	p += eddy(rec.p0, rec.w, t)
	var a_cap := float(rec.a_cap)
	var y_max := float(rec.cap_y) - a_cap
	var q := y_max - p.y
	p += wake(rec.a0, rec.w, t, float(rec.seed) * TAU, fmod(float(rec.seed) * 7.31, 1.0) < 0.5, rec.tau) * smoothstep(0.0, 4.0 * a_cap, q)
	p.y = soft_cap(p.y, y_max, a_cap)
	return p
