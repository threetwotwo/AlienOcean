## M30 world clock 0.1.0 (core/world, the Clock contract): the sun, the two moons and the light they give, at any clock hour.
## A straight port of the Unreal-era sky clock's "sky maths" (sun_v184.py, Lighting + Sky threads, Oct-Nov 2026),
## which was plain Python tested offline. Same constants, same formulas, same names; checked against that Python
## by tests/test_world_clock.gd. World lore lives here: change a constant only with Gary's word.
## Engine-agnostic: plain floats and Vector3 (z up, as the original). The adapter maps z-up to Godot's y-up.
class_name SkyClock
extends RefCounted

# ---- the star: a Sun twin
const STAR := {"name": "Sun twin (G2V)", "kelvin": 5772.0, "toa_lux": 128000.0, "disc_deg": 0.533}
const NOON_ELEVATION := 78.0          # equator, about a month from an equinox with Earth's 23.4 deg tilt
const SUN_DEC := 90.0 - NOON_ELEVATION
# ---- the moons. A: Earth's Moon. B: 5% of A's mass at 44% of its distance, icy, so colder light.
const MOONS := [
	{"name": "A", "disc_deg": 0.52, "albedo": 0.12, "kelvin": 4100.0, "drawn_deg": 2.75},
	{"name": "B", "disc_deg": 0.43, "albedo": 0.20, "kelvin": 6500.0, "drawn_deg": 2.25},
]
const MONTHS := [29.5, 8.0]           # game days per lunar month, A and B
const ORBITS := {"A": {"tilt_deg": 0.0, "node_days": 0.0, "node_deg": 0.0},
		"B": {"tilt_deg": 0.0, "node_days": 0.0, "node_deg": 0.0}}
const STUDY_ORBIT_B := {"tilt_deg": 13.0, "node_days": 352.0, "node_deg": 0.0}   # Atlas's tilted orbit for B (study)
const MOON_TINTS := {"A": Color(1.55, 0.95, 0.50), "B": Color(0.60, 0.88, 1.70)}  # night colour per moon
const TOTALITY_FRAC := 1e-5
const GLOW_WIDTH := 0.08
const FULL_MOON_A_LUX := 0.32
const AIR_TAU := 0.16                 # Rayleigh 0.10, ozone 0.03, sea salt 0.03
const TWILIGHT := [[0.0, 2.85], [-3.0, 1.8], [-6.0, 0.53], [-9.0, -0.78], [-12.0, -2.1], [-15.0, -2.85], [-18.0, -3.2]]
const NIGHT_SKY_LUX := 0.001
const MARINE_AOD := 0.03
const AEROSOL_HEIGHT_KM := 1.2
const AEROSOL_SSA := 0.97
const OCEAN_ALBEDO := 0.06
const SUN_SIZE := 8.25                # drawn sun x real for the disc's quad (v19)
const SUN_SIZE_NOW := 5.288461538461538   # drawn sun x real now (v136): 2.8 deg on the sky
const AIR_EXT := Vector3(0.0862, 0.1665, 0.2961)   # per-band extinction of the air, x air mass (SUN_HLSL)
const CORONA := 1.0
const MOON_LOOK := {"albedo_A": 0.12, "albedo_B": 0.20, "maria": 0.3, "planetshine": 2e-4, "moon_sat": 0.5,
		"moon_blue": 0.2, "moon_cap": 3.0, "moon_tint_mix": 0.5, "moon_edge": 1.5}
const SUN_BIAS := 4.0
const HANDOVER_FADE := 0.6
# ---- exposure (Lighting): EV100 limits and per-place compensation
const EV_MAX := 15.5
const BRIGHTEN_STOPS := 1.5
const EXPOSURE_BIAS := {"open_ocean": 0.0, "calm_lagoon": 1.2}
const STEADY_UNDER_AT := 0.75         # under water by day the eye sits this many stops below the cap
const HOLD_HOURS := {"open_ocean": 65.5}   # day 2, 5:30 pm, crescent Moon A above the low sun; others hold noon

static func airmass(h: float) -> float:
	return 1.0 / (sin(deg_to_rad(h)) + 0.50572 * pow(h + 6.07995, -1.6364))

static func transmittance(h: float) -> float:
	return exp(-AIR_TAU * airmass(h)) if h > 0.0 else 0.0

static func sky_lux(h: float) -> float:
	if h >= 0.0:
		return 700.0 + 15500.0 * pow(sin(deg_to_rad(h)), 0.5)
	if h <= TWILIGHT[-1][0]:
		return 0.0
	for i in TWILIGHT.size() - 1:
		var h0: float = TWILIGHT[i][0]; var l0: float = TWILIGHT[i][1]
		var h1: float = TWILIGHT[i + 1][0]; var l1: float = TWILIGHT[i + 1][1]
		if h1 <= h and h <= h0:
			return pow(10.0, l0 + (l1 - l0) * (h - h0) / (h1 - h0))
	return 0.0

static func beam_lux(h: float) -> float:
	return STAR.toa_lux * transmittance(h) * sin(deg_to_rad(h)) if h > 0.0 else 0.0

static func moon_toa_lux(moon: Dictionary, alpha: float) -> float:
	var full: float = FULL_MOON_A_LUX * pow(moon.disc_deg / 0.52, 2) * (moon.albedo / 0.12)
	var a := absf(alpha)
	return full * pow(10.0, -0.4 * (0.026 * a + 4e-9 * pow(a, 4)))

static func orbit_offset(days: float, month: float, orbit: Dictionary) -> Vector2:
	## (x = east of the sun in right ascension, rad; y = declination, deg)
	var u := TAU * days / month
	var tilt := deg_to_rad(orbit.get("tilt_deg", 0.0))
	if tilt == 0.0:
		return Vector2(u, 0.0)
	var nd: float = orbit.get("node_days", 0.0)
	var om := deg_to_rad(orbit.get("node_deg", 0.0)) - (TAU * days / nd if nd != 0.0 else 0.0)
	var x := cos(u); var y := sin(u)
	var y2 := y * cos(tilt); var z := y * sin(tilt)
	var X := x * cos(om) - y2 * sin(om)
	var Y := x * sin(om) + y2 * cos(om)
	return Vector2(atan2(Y, X), rad_to_deg(asin(clampf(z, -1.0, 1.0))))

static func cover_frac(sep: float, rs: float, rm: float) -> float:
	if sep >= rs + rm:
		return 0.0
	if sep <= absf(rm - rs):
		return 1.0 if rm >= rs else pow(rm / rs, 2)
	var a := (rs * rs * acos(clampf((sep * sep + rs * rs - rm * rm) / (2 * sep * rs), -1.0, 1.0)) +
			rm * rm * acos(clampf((sep * sep + rm * rm - rs * rs) / (2 * sep * rm), -1.0, 1.0)) -
			0.5 * sqrt(maxf(0.0, (-sep + rs + rm) * (sep + rs - rm) * (sep - rs + rm) * (sep + rs + rm))))
	return a / (PI * rs * rs)

static func angle(a: Vector3, b: Vector3) -> float:
	return atan2(a.cross(b).length(), a.dot(b))

static func drawn_sizes(sun_size := SUN_SIZE) -> Dictionary:
	return {"sun": STAR.disc_deg * sun_size, "A": MOONS[0].drawn_deg, "B": MOONS[1].drawn_deg}

static func site_frame(noon_yaw: float) -> Array:
	var y := deg_to_rad(noon_yaw)
	var n := Vector3(-cos(y), -sin(y), 0.0)
	return [Vector3(0, 0, 1), n, Vector3(n.y, -n.x, 0.0)]

static func body_dir(hour_angle: float, dec_deg: float, frame: Array) -> Vector3:
	var cd := cos(deg_to_rad(dec_deg)); var sd := sin(deg_to_rad(dec_deg))
	var ch := cos(hour_angle); var sh := sin(hour_angle)
	return cd * ch * frame[0] - cd * sh * frame[2] + sd * frame[1]

static func elevation(d: Vector3) -> float:
	return rad_to_deg(asin(clampf(d.z, -1.0, 1.0)))

static func sky_state(hours: float, noon_yaw := 0.0, day_hours := 24.0, months := MONTHS, sizes := {}, orbits := ORBITS) -> Dictionary:
	if sizes.is_empty():
		sizes = drawn_sizes()
	var frame := site_frame(noon_yaw)
	var days := hours / day_hours
	var sun_h := TAU * (days - 0.5)
	var sd := body_dir(sun_h, SUN_DEC, frame)
	var se := elevation(sd)
	var st := {"days": days, "frame": frame,
		"sun": {"dir": sd, "elev": se, "toa": STAR.toa_lux, "kelvin": STAR.kelvin, "disc": STAR.disc_deg,
			"horiz": beam_lux(se) + sky_lux(se), "sky": sky_lux(se)}}
	for i in MOONS.size():
		var moon: Dictionary = MOONS[i]; var month: float = months[i]
		var phase := days / month - floorf(days / month)
		var off := orbit_offset(days, month, orbits.get(moon.name, {}))
		var d := body_dir(sun_h - off.x, off.y, frame)
		var cos_psi := clampf(sd.dot(d), -1.0, 1.0)
		var alpha := 180.0 - rad_to_deg(acos(cos_psi))
		var toa := moon_toa_lux(moon, alpha)
		var e := elevation(d)
		var k := toa / STAR.toa_lux
		st[moon.name] = {"dir": d, "elev": e, "toa": toa, "kelvin": moon.kelvin, "disc": moon.disc_deg,
			"phase": phase, "lit": 0.5 * (1.0 + cos(deg_to_rad(alpha))),
			"horiz": k * (beam_lux(e) + sky_lux(e)), "sky": k * sky_lux(e)}
	var rs := deg_to_rad(sizes.sun / 2.0)
	var dim := 1.0
	for n in ["A", "B"]:
		dim *= 1.0 - cover_frac(angle(sd, st[n].dir), rs, deg_to_rad(sizes[n] / 2.0))
	var cover := 1.0 - dim
	var s: Dictionary = st.sun
	var floor_: float = TOTALITY_FRAC * s.horiz
	var glow: float = floor_ * pow(clampf((cover - 0.97) / 0.03, 0.0, 1.0), 2) / (TAU * GLOW_WIDTH * GLOW_WIDTH)
	s.toa *= dim
	s.horiz = s.horiz * dim + floor_ * cover
	s.sky = s.sky * dim + floor_ * cover
	st["eclipse"] = {"cover": cover, "glow": glow if se > 0.0 else 0.0}
	st["total"] = st.sun.horiz + st.A.horiz + st.B.horiz + NIGHT_SKY_LUX
	st["skylux"] = st.sun.sky + st.A.sky + st.B.sky + NIGHT_SKY_LUX
	return st

static func pick_key(st: Dictionary, current := "") -> String:
	## the one key light carries whichever body lights the site most (25% hysteresis)
	if st.sun.elev > 0.0:
		return "sun"
	var best := "sun"; var best_lux: float = SUN_BIAS * st.sun.horiz
	for n in ["A", "B"]:
		if st[n].elev > 0.0 and st[n].horiz > best_lux:
			best = n; best_lux = st[n].horiz
	if st.has(current) and current != best:
		var cur: Dictionary = st[current]
		var cur_lux: float = cur.horiz * (SUN_BIAS if current == "sun" else 1.0)
		if (current == "sun" or cur.elev > 0.0) and cur_lux * 1.25 > best_lux:
			return current
	return best

static func _ss(t: float) -> float:
	t = clampf(t, 0.0, 1.0); return t * t * (3.0 - 2.0 * t)

static func _eased(f: float) -> float:
	return (pow(100.0, f) - 1.0) / 99.0

static func key_fade(st: Dictionary, key: String, width := HANDOVER_FADE) -> float:
	## the share of its light the key gives while the sun and a moon hand it over (no flash, no dark frame)
	if width <= 0.0 or st.sun.elev > 0.0:
		return 1.0
	var hy := log(1.25) / log(10.0)
	var sun: float = SUN_BIAS * st.sun.horiz
	if key == "sun":
		var mx := -1.0
		for n in ["A", "B"]:
			if st[n].elev > 0.0 and st[n].horiz > 0.0: mx = maxf(mx, st[n].horiz)
		if mx < 0.0: return 1.0
		if sun <= 0.0: return 0.0
		return _eased(1.0 - _ss((log(mx / sun) / log(10.0) + hy + width) / width))
	var m: float = st[key].horiz
	if m <= 0.0 or sun <= 0.0: return 1.0
	return _eased(_ss((log(m / sun) / log(10.0) - hy) / width))

static func kelvin_rgb(k: float) -> Color:
	## blackbody colour (Tanner Helland fit), linear-ish, normalised so 6500 K is white
	var t := k / 100.0
	var r := 255.0 if t <= 66.0 else 329.698727446 * pow(t - 60.0, -0.1332047592)
	var g := 99.4708025861 * log(t) - 161.1195681661 if t <= 66.0 else 288.1221695283 * pow(t - 60.0, -0.0755148492)
	var b := 255.0 if t >= 66.0 else (0.0 if t <= 19.0 else 138.5177312231 * log(t - 10.0) - 305.0447927307)
	return Color(clampf(r, 0, 255) / 255.0, clampf(g, 0, 255) / 255.0, clampf(b, 0, 255) / 255.0)
