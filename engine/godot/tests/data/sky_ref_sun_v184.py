import math
STAR = {
    "name": "Sun twin (G2V)",
    "kelvin": 5772.0,            # effective temperature (IAU 2015 nominal Sun)
    "toa_lux": 128000.0,         # illuminance above the air: 1361 W/m2 x ~94 lm/W
    "disc_deg": 0.533,           # angular diameter seen from the planet
}
NOON_ELEVATION = 78.0            # equator, about a month from an equinox with Earth's 23.4 deg tilt
SUN_DEC = 90.0 - NOON_ELEVATION  # the sun's declination that gives that noon
MOONS = (
    # A: Earth's Moon. B: 5% of A's mass at 44% of its distance (the plugin's tide model), so 0.43 deg;
    # its surface is ours to choose: icy by default, so its light is colder than A's.
    # disc_deg is the real width (it sets the light); drawn_deg the width drawn in the sky (v10, MPC_Sky MoonADeg/BDeg).
    {"name": "A", "label": "Moon_A", "disc_deg": 0.52, "albedo": 0.12, "kelvin": 4100.0, "drawn_deg": 2.75,       # v70: 0.5 x 5.5; v136
     "dist_cm": 2.0e6, "knob": "MoonADeg"},
    {"name": "B", "label": "Moon_B", "disc_deg": 0.43, "albedo": 0.20, "kelvin": 6500.0, "drawn_deg": 2.25,       # v70: 0.5 x 4.51; v136
     "dist_cm": 1.8e6, "knob": "MoonBDeg"},
)
# v10: both orbits as the plugin's tide model (over the equator, new at clock 0). A tilt (deg to the equator), a
# node period (game days, turning backwards) and a node angle can be set per moon in the settings file
# "moon_orbits"; Atlas's tilted, oval orbit for B comes in the next sun step.
ORBITS = {"A": {"tilt_deg": 0.0, "node_days": 0.0, "node_deg": 0.0},
          "B": {"tilt_deg": 0.0, "node_days": 0.0, "node_deg": 0.0}}
STUDY_ORBIT_B = {"tilt_deg": 13.0, "node_days": 352.0, "node_deg": 0.0}   # the Bigger moons study's (offline check)
TOTALITY_FRAC = 1e-5             # light left at totality, as a share of the sun's (from beyond the moon's shadow)
GLOW_WIDTH = 0.08                # rad: height of the totality horizon glow (the same 0.08 is in STARS_HLSL)
FULL_MOON_A_LUX = 0.32           # Earth's full Moon above the air: magnitude -12.74 against the Sun's -26.74
AIR_TAU = 0.16                   # vertical optical depth at 550 nm: Rayleigh 0.10, ozone 0.03, sea salt 0.03
# Clear-sky horizontal illuminance with the sun below the horizon (deg, log10 lux): 700 lx at sunset,
# 3.4 at the end of civil twilight, 0.008 at -12, about 6e-4 at -18 (Bond & Henderson; USNO tables).
TWILIGHT = ((0.0, 2.85), (-3.0, 1.8), (-6.0, 0.53), (-9.0, -0.78), (-12.0, -2.1), (-15.0, -2.85), (-18.0, -3.2))
NIGHT_SKY_LUX = 0.001            # starlight and airglow on a moonless night
MARINE_AOD = 0.03                # aerosol optical depth at 550 nm, very clean open-ocean air (halved from 0.06 at Gary's call)
AEROSOL_HEIGHT_KM = 1.2          # scale height of the sea-salt layer
AEROSOL_SSA = 0.97               # sea salt barely absorbs
OCEAN_ALBEDO = 0.06
SUN_SIZE = 8.25
SUN_BIAS = 4.0
HANDOVER_FADE = 0.6

def airmass(h):
    """Kasten & Young (1989) relative air mass at elevation h (deg)."""
    return 1.0 / (math.sin(math.radians(h)) + 0.50572 * (h + 6.07995) ** -1.6364)


def transmittance(h):
    return math.exp(-AIR_TAU * airmass(h)) if h > 0.0 else 0.0


def sky_lux(h):
    """Horizontal illuminance from the sky alone, for a sun-bright source at elevation h (deg)."""
    if h >= 0.0:
        return 700.0 + 15500.0 * math.sin(math.radians(h)) ** 0.5      # 700 lx at sunset, ~16 klx at noon
    if h <= TWILIGHT[-1][0]:
        return 0.0
    for (h0, l0), (h1, l1) in zip(TWILIGHT, TWILIGHT[1:]):
        if h1 <= h <= h0:
            return 10.0 ** (l0 + (l1 - l0) * (h - h0) / (h1 - h0))
    return 0.0


def beam_lux(h):
    """Horizontal illuminance from the disc itself, after the air."""
    return STAR["toa_lux"] * transmittance(h) * math.sin(math.radians(h)) if h > 0.0 else 0.0


def moon_toa_lux(moon, alpha):
    """A moon's light above the air at phase angle alpha (deg, 0 = full). Allen's lunar phase law."""
    full = FULL_MOON_A_LUX * (moon["disc_deg"] / 0.52) ** 2 * (moon["albedo"] / 0.12)
    a = abs(alpha)
    return full * 10.0 ** (-0.4 * (0.026 * a + 4e-9 * a ** 4))


def orbit_offset(days, month, orbit):
    """A moon's place against the sun: (how far east of the sun in right ascension, rad; declination, deg).
    Circular orbit tilted orbit["tilt_deg"] to the equator, node turning backwards once in orbit["node_days"].
    New moon (right ascension equal to the sun's) at clock 0, as OceanWorld's tide model."""
    u = 2.0 * math.pi * days / month
    tilt = math.radians(orbit.get("tilt_deg", 0.0) if orbit else 0.0)
    if tilt == 0.0:
        return u, 0.0
    nd = orbit.get("node_days", 0.0)
    om = math.radians(orbit.get("node_deg", 0.0)) - (2.0 * math.pi * days / nd if nd else 0.0)
    x, y = math.cos(u), math.sin(u)
    y2, z = y * math.cos(tilt), y * math.sin(tilt)
    X = x * math.cos(om) - y2 * math.sin(om)
    Y = x * math.sin(om) + y2 * math.cos(om)
    return math.atan2(Y, X), math.degrees(math.asin(max(-1.0, min(1.0, z))))


def cover_frac(sep, rs, rm):
    """Share of a disc of radius rs covered by a disc of radius rm at separation sep (all rad, flat circles)."""
    if sep >= rs + rm:
        return 0.0
    if sep <= abs(rm - rs):
        return 1.0 if rm >= rs else (rm / rs) ** 2
    a = (rs * rs * math.acos(max(-1.0, min(1.0, (sep * sep + rs * rs - rm * rm) / (2 * sep * rs)))) +
         rm * rm * math.acos(max(-1.0, min(1.0, (sep * sep + rm * rm - rs * rs) / (2 * sep * rm)))) -
         0.5 * math.sqrt(max(0.0, (-sep + rs + rm) * (sep + rs - rm) * (sep - rs + rm) * (sep + rs + rm))))
    return a / (math.pi * rs * rs)


def angle(a, b):
    """Angle between unit vectors (rad), precise for small angles."""
    c = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    return math.atan2(math.sqrt(sum(x * x for x in c)), sum(x * y for x, y in zip(a, b)))


def drawn_sizes(sun_size=SUN_SIZE, a_deg=None, b_deg=None):
    """Drawn widths in degrees: the sun's disc and both moons (MPC_Sky SunSize, MoonADeg, MoonBDeg)."""
    return {"sun": STAR["disc_deg"] * sun_size,
            "A": MOONS[0]["drawn_deg"] if a_deg is None else a_deg,
            "B": MOONS[1]["drawn_deg"] if b_deg is None else b_deg}


def site_frame(noon_yaw):
    """Up, north and east for a light whose noon yaw is noon_yaw (the light points away from the sun)."""
    y = math.radians(noon_yaw)
    n = (-math.cos(y), -math.sin(y), 0.0)        # toward the noon sun, level
    return (0.0, 0.0, 1.0), n, (n[1], -n[0], 0.0)


def body_dir(hour_angle, dec_deg, frame):
    """Unit vector to a body at this hour angle (rad, 0 = due overhead line, + = afternoon) on the equator."""
    up, north, east = frame
    cd, sd = math.cos(math.radians(dec_deg)), math.sin(math.radians(dec_deg))
    ch, sh = math.cos(hour_angle), math.sin(hour_angle)
    return tuple(cd * ch * u - cd * sh * e + sd * n for u, n, e in zip(up, north, east))


def elevation(d):
    return math.degrees(math.asin(max(-1.0, min(1.0, d[2]))))


def sky_state(hours, noon_yaw, day_hours=24.0, months=(29.5, 8.0), sizes=None, orbits=None):
    """Everything the sky needs at this clock time. Same angles as OceanWorld's tide model, except that B's
    orbit is tilted (v10; the tides keep the equatorial orbits). sizes: drawn widths (deg), for eclipses."""
    sizes = sizes or drawn_sizes()
    orbits = orbits or ORBITS
    frame = site_frame(noon_yaw)
    days = hours / day_hours
    sun_h = 2.0 * math.pi * (days - 0.5)                                # 0 at noon
    sd = body_dir(sun_h, SUN_DEC, frame)
    se = elevation(sd)
    st = {"days": days, "frame": frame,
          "sun": {"dir": sd, "elev": se, "toa": STAR["toa_lux"], "kelvin": STAR["kelvin"],
                  "disc": STAR["disc_deg"], "horiz": beam_lux(se) + sky_lux(se), "sky": sky_lux(se)}}
    for moon, month in zip(MOONS, months):
        phase = days / month - math.floor(days / month)              # 0 new, 0.5 full (as the plugin)
        ra, dec = orbit_offset(days, month, orbits.get(moon["name"]))
        d = body_dir(sun_h - ra, dec, frame)
        cos_psi = max(-1.0, min(1.0, sum(a * b for a, b in zip(sd, d))))
        alpha = 180.0 - math.degrees(math.acos(cos_psi))               # phase angle
        toa = moon_toa_lux(moon, alpha)
        e = elevation(d)
        k = toa / STAR["toa_lux"]
        st[moon["name"]] = {"dir": d, "elev": e, "toa": toa, "kelvin": moon["kelvin"], "disc": moon["disc_deg"],
                            "phase": phase, "lit": 0.5 * (1.0 + math.cos(math.radians(alpha))),
                            "horiz": k * (beam_lux(e) + sky_lux(e)), "sky": k * sky_lux(e)}
    # v10: eclipses. The sun's light, and the sky it lights, by the uncovered share of the drawn disc; at
    # totality TOTALITY_FRAC stays (light from beyond the shadow), with the horizon glow carrying it.
    rs = math.radians(sizes["sun"] / 2.0)
    dim = 1.0
    for n in ("A", "B"):
        dim *= 1.0 - cover_frac(angle(sd, st[n]["dir"]), rs, math.radians(sizes[n] / 2.0))
    cover = 1.0 - dim
    s = st["sun"]
    floor = TOTALITY_FRAC * s["horiz"]
    glow = floor * max(0.0, min(1.0, (cover - 0.97) / 0.03)) ** 2 / (2.0 * math.pi * GLOW_WIDTH ** 2)
    s["toa"] *= dim
    s["horiz"] = s["horiz"] * dim + floor * cover
    s["sky"] = s["sky"] * dim + floor * cover
    st["eclipse"] = {"cover": cover, "glow": glow if se > 0.0 else 0.0}
    st["total"] = sum(st[n]["horiz"] for n in ("sun", "A", "B")) + NIGHT_SKY_LUX
    st["skylux"] = sum(st[n]["sky"] for n in ("sun", "A", "B")) + NIGHT_SKY_LUX
    return st


def pick_key(st, current):
    """The one DirectionalLight carries whichever body lights the site most (a moon only when above the
    horizon). The sun counts 4x while it sets, because the sky only draws the twilight glow for the light's
    own body: the glow stays until a moon clearly outshines it (sun about -10 deg). 25% hysteresis on top."""
    if st["sun"]["elev"] > 0.0:
        return "sun"                    # v10: the sun keeps the light while it is up, eclipsed or not
    best, best_lux = "sun", SUN_BIAS * st["sun"]["horiz"]
    for n in ("A", "B"):
        if st[n]["elev"] > 0.0 and st[n]["horiz"] > best_lux:
            best, best_lux = n, st[n]["horiz"]
    if current in st and current != best:
        cur = st[current]
        cur_lux = cur["horiz"] * (SUN_BIAS if current == "sun" else 1.0)
        if (current == "sun" or cur["elev"] > 0.0) and cur_lux * 1.25 > best_lux:
            return current
    return best


HANDOVER_FADE = 0.6              # v94: decades of the moon/sun light ratio each handover fade spans ("handover_fade"; 0 = cut)


def key_fade(st, key, width=HANDOVER_FADE):
    """v94 (Gary 03:10Z Oct 26 "one brief bright flash everywhere, and the next frame, all dark"): the share of its
    light the DirectionalLight gives while the sun and a moon hand it over. The sun fades out before pick_key passes
    the light on and the moon fades in after, so the sky's twilight glow (drawn only for the light's own body) fades
    instead of vanishing. Both ends sit outside pick_key's 25% hysteresis, so it is the same either way of time."""
    if width <= 0.0 or st["sun"]["elev"] > 0.0:
        return 1.0
    def ss(t):
        t = min(max(t, 0.0), 1.0)
        return t * t * (3.0 - 2.0 * t)
    def eased(f):                         # even in stops: 1% of the light at the fade's middle-to-end, then 0
        return (100.0 ** f - 1.0) / 99.0
    hy = math.log10(1.25)
    sun = SUN_BIAS * st["sun"]["horiz"]
    if key == "sun":
        moons = [st[n]["horiz"] for n in ("A", "B") if st[n]["elev"] > 0.0 and st[n]["horiz"] > 0.0]
        if not moons:
            return 1.0
        if sun <= 0.0:
            return 0.0
        return eased(1.0 - ss((math.log10(max(moons) / sun) + hy + width) / width))
    m = st[key]["horiz"]
    if m <= 0.0 or sun <= 0.0:
        return 1.0
    return eased(ss((math.log10(m / sun) - hy) / width))


