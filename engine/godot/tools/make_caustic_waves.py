#!/usr/bin/env python3
"""Generate look/caustic_waves.gdshaderinc: the waves the light net on the sand is drawn from (Unreal lagoonwater v98).

Unreal drew the net from its FFT sea every frame: the slopes of cascade 2 (2.56 m tile, waves of 9.40 to 78.54 rad/m,
CAUS_SLOPE_HLSL) -> one caustic map for 0.8, 2 and 5 m (CAUS_HLSL) -> softened by the sun's disc (CAUS_BLUR_HLSL) ->
read by the sun's light function with three turned copies of the tile (FFT_NET_HLSL). Godot has no FFT sea yet, so this
tool draws CAUS_N waves from the same spectrum (derive() and spectrum() below are v98's, unchanged: Elfouhaily 1997,
wind 2 m/s over 3 km, the slick CALM_K 16), moves each to the nearest whole wave on the 2.56 m tile (its slope kept), and
writes them as constant tables. Two readers:
- the map (adapters/godot/caustics_map.gd with look/caustics_slope / _focus / _blur.gdshader): v98's passes as they were,
  once a frame into a 512 px tile; CAUS_B is each wave's slope in the mip a depth reads (2, 4, 8 cm texels: a box);
- the per-pixel check path (look/caustics.gdshaderinc caus_level): CAUS_G and CAUS_H also carry the bilinear read's
  tent and the span the curvature is read over (CAUS_E x depth, a finite difference).
CAUS_K (kx, ky, phase, turns per hour) and CAUS_A (height amplitude, m) are the sea's own waves, for the surface too.

Usage: python3 -I tools/make_caustic_waves.py look/caustic_waves.gdshaderinc [--stats] [--dump file.npy t]
--stats (needs numpy) prints the net's statistics per depth for both readers; v98's own map, emulated the same way
(256 px FFT of this spectrum, its mips, CAUS_HLSL, the 9-tap blur), gives per depth 0.8 / 2 / 5 m:
std 0.14-0.15 / 0.29-0.31 / 0.34, p5 0.78 / 0.61 / 0.50-0.53, p95 1.25 / 1.52-1.58 / 1.54-1.57, cell 12 / 12-14 / 15-16 cm.
--dump writes the map (512 x 512 x 3) at time t s, to check the engine's map against."""
import math, random, sys

G = 9.81
KM = 370.0           # rad/m: gravity-capillary phase-speed minimum
CM = 0.23            # m/s: that minimum phase speed
CALM_K = 16.0        # v84: the lagoon's slick (waves shorter than ~39 cm damped)
CASCADES = (250.0, 21.4, 2.56, 0.32)
RING_HI = (32.0, 32.0, 32.0, 64.0)
SEA = {"U10": 2.0, "fetch_km": 3.0, "wind_deg": 0.0, "swell_hs": 0.03, "swell_tp": 12.0, "swell_deg": 40.0, "swell_s": 40.0}
CAUS_DEPTHS = (0.8, 2.0, 5.0)    # m: v98's RT_LW_Caus R, G, B
CAUS_SUN = 1.0                   # x the real sun's disc
CAUS_EPS = 0.03                  # the narrowest focus
CAUS_CAP = 12.0                  # the brightest a focus gets, x plain sun
CAUS_E = 0.03                    # x depth: the span the curvature is read over
CAUS_MIP_M = (0.02, 0.04, 0.08)  # the slope texels each depth reads (RT_LW_CausS1..3)
BEND = 0.24981                   # 1 - 1/1.333: how far a slope bends the ray, x depth
N_RINGS, N_DIRS, SEED = 4, 8, 3  # 32 waves
TILE_M = 2.56                    # v98 CASCADES[2]: the tile the map covers
CAUS_PX = 512                    # v98: the map's size
LOOP_S = 3600.0                  # Godot's TIME rolls over here; every wave makes a whole number of turns in it (as v98's Tm.y)


def derive(p):
    U = max(float(p["U10"]), 0.5)
    F = max(float(p["fetch_km"]), 1.0) * 1000.0
    X = G * F / (U * U)
    om = max(0.84 * math.tanh((X / 2.2e4) ** 0.4) ** -0.75, 0.84)
    kp = G * (om / U) ** 2
    cp = math.sqrt(G / kp)
    alpha_p = 6e-3 * math.sqrt(om)
    gamma = 1.7 if om < 1.0 else 1.7 + 6.0 * math.log10(om)
    sigma = 0.08 * (1.0 + 4.0 * om ** -3)
    ustar = U * math.sqrt((0.8 + 0.065 * U) * 1e-3)
    alpha_m = max(0.0, 0.01 * (1.0 + (math.log(ustar / CM) if ustar < CM else 3.0 * math.log(ustar / CM))))
    wp = math.sqrt(G * kp * (1.0 + (kp / KM) ** 2))
    d = {"U": U, "Omega": om, "kp": kp, "cp": cp, "alpha_p": alpha_p, "gamma": gamma, "sigma": sigma,
         "ustar": ustar, "alpha_m": alpha_m, "wp": wp, "wind": math.radians(float(p.get("wind_deg", 0.0)))}
    hs = max(float(p.get("swell_hs", 0.0)), 0.0)
    ws = 2.0 * math.pi / max(float(p.get("swell_tp", 12.0)), 2.0)
    d.update({"swell_w": ws, "swell_gamma": 7.0, "swell_dir": math.radians(float(p.get("swell_deg", 40.0))),
              "swell_s": max(float(p.get("swell_s", 40.0)), 1.0)})
    m0, n = 0.0, 4000
    for i in range(n):
        w = ws * (0.3 + 3.7 * (i + 0.5) / n)
        sg = 0.07 if w <= ws else 0.09
        r = math.exp(-((w - ws) ** 2) / (2.0 * sg * sg * ws * ws))
        m0 += G * G * w ** -5 * math.exp(-1.25 * (ws / w) ** 4) * 7.0 ** r * (3.7 * ws / n)
    d["swell_a"] = (hs / 4.0) ** 2 / m0 if m0 > 0.0 and hs > 0.0 else 0.0
    s = d["swell_s"]
    d["swell_norm"] = math.exp(math.lgamma(s + 1.0) - math.lgamma(s + 0.5)) / (2.0 * math.sqrt(math.pi))
    return d


def spectrum(kx, ky, d):
    """Directional wavenumber spectrum per unit kx ky (m^4): wind sea (E97 x Donelan-Banner) + swell, x the slick."""
    k = math.hypot(kx, ky)
    if k <= 0.0:
        return 0.0
    th = math.atan2(ky, kx)
    c = math.sqrt(G / k * (1.0 + (k / KM) ** 2))
    lpm = math.exp(-1.25 * (d["kp"] / k) ** 2)
    sq = math.sqrt(k / d["kp"])
    jp = d["gamma"] ** math.exp(-((sq - 1.0) ** 2) / (2.0 * d["sigma"] ** 2))
    fp = lpm * jp * math.exp(-d["Omega"] / math.sqrt(10.0) * (sq - 1.0))
    bl = 0.5 * d["alpha_p"] * (d["cp"] / c) * fp
    fm = lpm * jp * math.exp(-0.25 * (k / KM - 1.0) ** 2)
    bh = 0.5 * d["alpha_m"] * (CM / c) * fm
    s = (bl + bh) / k ** 3
    w = math.sqrt(G * k * (1.0 + (k / KM) ** 2))
    r = max(w / d["wp"], 0.56)
    if r < 0.95:
        beta = 2.61 * r ** 1.3
    elif r < 1.6:
        beta = 2.28 * r ** -1.3
    else:
        beta = 10.0 ** (-0.4 + 0.8393 * math.exp(-0.567 * math.log(r * r)))
    a = math.atan2(math.sin(th - d["wind"]), math.cos(th - d["wind"]))
    out = s * beta / (2.0 * math.tanh(beta * math.pi)) / math.cosh(beta * a) ** 2 / k
    if d["swell_a"] > 0.0:
        ws = d["swell_w"]
        sg = 0.07 if w <= ws else 0.09
        rr = math.exp(-((w - ws) ** 2) / (2.0 * sg * sg * ws * ws))
        sw = d["swell_a"] * G * G * w ** -5 * math.exp(-1.25 * (ws / w) ** 4) * d["swell_gamma"] ** rr
        dwdk = G * (1.0 + 3.0 * (k / KM) ** 2) / (2.0 * w)
        b = math.atan2(math.sin(th - d["swell_dir"]), math.cos(th - d["swell_dir"]))
        out += sw * dwdk * d["swell_norm"] * abs(math.cos(0.5 * b)) ** (2.0 * d["swell_s"]) / k
    if CALM_K:
        out /= 1.0 + (k / CALM_K) ** 4
    return out


def waves():
    """N_RINGS x N_DIRS waves (kx, ky, height amplitude m, phase, turns per LOOP_S) carrying the band's slope variance:
    rings of equal slope variance in k, equal slices in direction (the spread is the spectrum's own, through the
    amplitudes), each moved to the nearest free whole wave of the tile."""
    d = derive(SEA)
    k_lo = 2.0 * math.pi * RING_HI[1] / CASCADES[1]          # cascade 2's band: 9.40 ...
    k_hi = 2.0 * math.pi * RING_HI[2] / CASCADES[2]          # ... to 78.54 rad/m
    nk, nt = 400, 360
    dl, dt = (math.log(k_hi) - math.log(k_lo)) / nk, 2.0 * math.pi / nt
    ks = [math.exp(math.log(k_lo) + (i + 0.5) * dl) for i in range(nk)]
    ths = [-math.pi + (j + 0.5) * dt for j in range(nt)]
    P = [[spectrum(k * math.cos(t), k * math.sin(t), d) * k * k for t in ths] for k in ks]     # var h per d ln k d theta
    sv = [sum(row) * k * k for row, k in zip(P, ks)]
    tot, run, edges = sum(sv), 0.0, [0]
    for i, v in enumerate(sv):
        run += v
        if len(edges) < N_RINGS and run >= tot * len(edges) / N_RINGS:
            edges.append(i + 1)
    edges.append(nk)
    rng, out, used = random.Random(SEED), [], set()
    dk = 2.0 * math.pi / TILE_M
    for r in range(N_RINGS):
        off = rng.random() * 2.0 * math.pi / N_DIRS
        for j in range(N_DIRS):
            t0 = -math.pi + off + j * 2.0 * math.pi / N_DIRS
            var = ssk = 0.0
            for i in range(edges[r], edges[r + 1]):
                for jj, t in enumerate(ths):
                    if (t - t0) % (2.0 * math.pi) < 2.0 * math.pi / N_DIRS:
                        var += P[i][jj] * dl * dt
                        ssk += P[i][jj] * ks[i] ** 2 * dl * dt
            k = math.sqrt(ssk / max(var, 1e-30))               # the wave keeps its cell's slope variance
            tt = t0 + (0.15 + 0.7 * rng.random()) * 2.0 * math.pi / N_DIRS
            ph = rng.random() * 2.0 * math.pi
            fx, fy = k * math.cos(tt) / dk, k * math.sin(tt) / dk
            cand = sorted(((ix - fx) ** 2 + (iy - fy) ** 2, ix, iy) for ix in range(int(fx) - 2, int(fx) + 3)
                          for iy in range(int(fy) - 2, int(fy) + 3) if (ix, iy) not in used and (ix, iy) != (0, 0))
            _, ix, iy = cand[0]
            used.add((ix, iy))
            kq = math.hypot(ix, iy) * dk
            w = math.sqrt(G * kq * (1.0 + (kq / KM) ** 2))      # v98's dispersion (tanh(k h) is 1 for these waves)
            out.append((ix * dk, iy * dk, math.sqrt(2.0 * var) * k / kq, ph, float(round(w * LOOP_S / (2.0 * math.pi)))))
    return out


def sinc(x):
    return 1.0 if abs(x) < 1e-9 else math.sin(x) / x


def tables(W):
    """Per depth and wave. B: the slope in that depth's mip (the map's reader). G: the ray's sideways step (m) per cos,
    H: the bundle's curvature terms (a - 1, d - 1, b) per sin (the per-pixel reader)."""
    Bs, Gs, Hs = [], [], []
    for D, w in zip(CAUS_DEPTHS, CAUS_MIP_M):
        h, e = BEND * D, CAUS_E * D
        for kx, ky, a, _ph, _m in W:
            box = sinc(kx * w / 2.0) * sinc(ky * w / 2.0)             # the mip's texel
            Bs.append((a * box * kx, a * box * ky))
            att = box ** 3                                            # x the bilinear read's tent
            Gs.append((h * a * att * kx, h * a * att * ky))
            Hs.append((-h * a * att * kx * math.sin(kx * e) / e, -h * a * att * ky * math.sin(ky * e) / e,
                       -h * a * att * 0.5 * (ky * math.sin(kx * e) + kx * math.sin(ky * e)) / e))
    return Bs, Gs, Hs


SHADER = r"""// GENERATED by tools/make_caustic_waves.py. Do not edit: edit the tool and run it again.
// The waves the light net is drawn from: @N@ of the Unreal lagoon's spectrum (lagoonwater v98: wind 2 m/s over 3 km, slick
// 16 rad/m, cascade 2's band; rms slope @RMS@), each a whole wave on the @TL@ m tile so the caustic map repeats cleanly.
// Height (m) at the island's (x east, y north) = sum CAUS_A[i] sin(dot(CAUS_K[i].xy, x) + CAUS_K[i].z - 2 pi fract(CAUS_K[i].w t / CAUS_LOOP)).
// Godot (x, y, z) -> island (x, -z).
const int CAUS_N = @N@;
const float CAUS_TILE = @TL@;          // m: the tile the waves and the map repeat on (v98 CASCADES[2])
const float CAUS_PX = @PX@;            // the map's size (v98 CAUS_PX)
const float CAUS_EPS = @EPS@;          // the narrowest focus
const float CAUS_CAP = @CAP@;            // the brightest a focus gets, x plain sun
const float CAUS_D0 = @D0@;            // m: the first depth; the net fades in over it
const float CAUS_DSTEP = @DSTEP@;      // log2 of the step between depths (x2.5)
const float CAUS_BEND = @BEND@;        // 1 - 1/1.333: the ray's sideways step per slope, x depth
const float CAUS_E = @E@;              // x depth: the span the curvature is read over
const float CAUS_SUN_RAD = @SUNRAD@;   // the sun's radius (0.2665 deg), rad
const float CAUS_LOOP = @LOOP@;        // s: TIME's rollover; each wave makes a whole number of turns in it
const float CAUS_DEPTHS[3] = { @DEPTHS@ };
// wave: kx, ky (rad/m), phase, turns per CAUS_LOOP
const vec4 CAUS_K[@N@] = {
@K@
};
// wave: height amplitude, m
const float CAUS_A[@N@] = {
@A@
};
// per depth (0.8, 2, 5 m) and wave: the slope in the mip that depth reads (2, 4, 8 cm texels), x cos
const vec2 CAUS_B[@N3@] = {
@B@
};
// per depth and wave, for the per-pixel reader: the ray's sideways step in m, x cos
const vec2 CAUS_G[@N3@] = {
@G@
};
// per depth and wave, for the per-pixel reader: the bundle's curvature (a - 1, d - 1, b), x sin
const vec3 CAUS_H[@N3@] = {
@H@
};
"""


def write(path, W):
    Bs, Gs, Hs = tables(W)
    rms = math.sqrt(sum(a * a * (kx * kx + ky * ky) / 2.0 for kx, ky, a, _p, _m in W))
    rep = {"@N@": "%d" % len(W), "@N3@": "%d" % (3 * len(W)), "@EPS@": "%.4f" % CAUS_EPS, "@CAP@": "%.1f" % CAUS_CAP,
           "@D0@": "%.4f" % CAUS_DEPTHS[0], "@DSTEP@": "%.6f" % math.log2(CAUS_DEPTHS[1] / CAUS_DEPTHS[0]),
           "@SUNRAD@": "%.6f" % (0.004651 * CAUS_SUN), "@LOOP@": "%.1f" % LOOP_S, "@RMS@": "%.4f" % rms,
           "@TL@": "%.4f" % TILE_M, "@PX@": "%.1f" % CAUS_PX, "@BEND@": "%.5f" % BEND, "@E@": "%.4f" % CAUS_E,
           "@DEPTHS@": ", ".join("%.4f" % x for x in CAUS_DEPTHS),
           "@K@": ",\n".join("\tvec4(%.6f, %.6f, %.5f, %.1f)" % (kx, ky, ph, m) for kx, ky, _a, ph, m in W),
           "@A@": ",\n".join("\t%.7f" % a for _kx, _ky, a, _ph, _m in W),
           "@B@": ",\n".join("\tvec2(%.7f, %.7f)" % g for g in Bs),
           "@G@": ",\n".join("\tvec2(%.7f, %.7f)" % g for g in Gs),
           "@H@": ",\n".join("\tvec3(%.6f, %.6f, %.6f)" % h for h in Hs)}
    code = SHADER
    for k, v in rep.items():
        code = code.replace(k, v)
    with open(path, "w") as f:
        f.write(code)
    print("%s: %d waves, rms slope %.4f, %.1f to %.1f rad/m" % (path, len(W), rms, min(math.hypot(w[0], w[1]) for w in W),
                                                                 max(math.hypot(w[0], w[1]) for w in W)))


def np_map(W, t=0.0):
    """The map as the engine draws it (caustics_slope -> _focus -> _blur), in numpy: 512 x 512 x 3, [v, u, depth]."""
    import numpy as np
    Bs, _g, _h = tables(W)
    n = len(W)
    kx, ky, ph, tn = (np.array([w[i] for w in W])[:, None, None] for i in (0, 1, 3, 4))
    arg0 = ph - 2.0 * math.pi * np.modf(tn * (t / LOOP_S))[0]

    def bil(a, u, v):
        m = a.shape[0]
        x, y = u * m - 0.5, v * m - 0.5
        x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
        fx, fy = x - x0, y - y0
        g = lambda yy, xx: a[yy % m, xx % m]
        return (g(y0, x0) * (1 - fx) + g(y0, x0 + 1) * fx) * (1 - fy) + (g(y0 + 1, x0) * (1 - fx) + g(y0 + 1, x0 + 1) * fx) * fy

    c = (np.arange(CAUS_PX) + 0.5) / CAUS_PX
    U, V = np.meshgrid(c, c)
    out = []
    for lv, D in enumerate(CAUS_DEPTHS):
        m = int(round(TILE_M / CAUS_MIP_M[lv]))
        cm = (np.arange(m) + 0.5) * TILE_M / m
        Xm, Ym = np.meshgrid(cm, cm)
        b = np.array(Bs[lv * n:(lv + 1) * n])
        cs = np.cos(kx * Xm + ky * Ym + arg0)
        sx, sy = (b[:, 0, None, None] * cs).sum(0), (b[:, 1, None, None] * cs).sum(0)
        h, e = BEND * D, CAUS_E * D / TILE_M
        u, v = U, V
        for _ in range(3):
            u, v = U - h / TILE_M * bil(sx, u, v), V - h / TILE_M * bil(sy, u, v)
        k = h / (2 * e * TILE_M)
        a = 1 + k * (bil(sx, u + e, v) - bil(sx, u - e, v))
        dd = 1 + k * (bil(sy, u, v + e) - bil(sy, u, v - e))
        bb = 0.5 * k * ((bil(sy, u + e, v) - bil(sy, u - e, v)) + (bil(sx, u, v + e) - bil(sx, u, v - e)))
        det = a * dd - bb * bb
        raw = np.minimum(1 / np.sqrt(det * det + CAUS_EPS ** 2), CAUS_CAP)
        r = D * 0.004651 * CAUS_SUN / TILE_M
        acc = raw.copy()
        for kk in range(8):
            an = 0.7853982 * (kk + 0.5)
            acc += bil(raw, U + 0.7 * math.cos(an) * r, V + 0.7 * math.sin(an) * r)
        out.append(acc / 9)
    return np.stack(out, 2)


def np_pixel(W):
    """The per-pixel reader's maths (look/caustics.gdshaderinc caus_level) over one tile at 5 mm, per depth."""
    import numpy as np
    _b, Gs, Hs = tables(W)
    n = len(W)
    kx, ky, ph = (np.array([w[i] for w in W])[:, None, None] for i in (0, 1, 3))
    c = (np.arange(CAUS_PX) + 0.5) * TILE_M / CAUS_PX
    X, Y = np.meshgrid(c, c)

    def back(o, X, Y, x, y, steps):
        g = np.array(Gs[o:o + n])
        for _ in range(steps):
            cs = np.cos(kx * x + ky * y + ph)
            x, y = X - (g[:, 0, None, None] * cs).sum(0), Y - (g[:, 1, None, None] * cs).sum(0)
        return x, y

    def focus(o, x, y):
        h = np.array(Hs[o:o + n])
        s = np.sin(kx * x + ky * y + ph)
        a, d, b = ((h[:, i, None, None] * s).sum(0) for i in range(3))
        det = (1 + a) * (1 + d) - b * b
        return np.minimum(1 / np.sqrt(det * det + CAUS_EPS ** 2), CAUS_CAP)

    out = []
    for lv, D in enumerate(CAUS_DEPTHS):
        o = lv * n
        x, y = back(o, X, Y, X, Y, 3)
        acc = focus(o, x, y)
        r = 0.7 * 0.004651 * CAUS_SUN * D
        for k in range(4):
            an = 1.5707963 * (k + 0.5)
            Xk, Yk = X + r * math.cos(an), Y + r * math.sin(an)
            acc = acc + focus(o, *back(o, Xk, Yk, Xk + x - X, Yk + y - Y, 2))
        out.append(acc / 5)
    return np.stack(out, 2)


def stats(W):
    import numpy as np
    M, P = np_map(W), np_pixel(W)
    for name, I3 in (("map", M), ("per pixel", P)):
        for lv, D in enumerate(CAUS_DEPTHS):
            I = I3[:, :, lv]
            ac = np.real(np.fft.ifft2(np.abs(np.fft.fft2(I - I.mean())) ** 2))[0, :256]
            print("  %-9s %.1f m: mean %.3f std %.3f p5 %.2f p50 %.2f p95 %.2f p99 %.2f max %.1f cell %.0f cm"
                  % (name, D, I.mean(), I.std(), *np.percentile(I, [5, 50, 95, 99]), I.max(), np.argmax(ac < 0) * 100 * TILE_M / CAUS_PX))
    for lv, D in enumerate(CAUS_DEPTHS):
        a, b = M[:, :, lv], P[:, :, lv]
        print("  map against per pixel %.1f m: correlation %.3f, rms difference %.3f" % (D, np.corrcoef(a.ravel(), b.ravel())[0, 1], np.sqrt(((a - b) ** 2).mean())))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    W_ = waves()
    write(sys.argv[1], W_)
    if "--stats" in sys.argv:
        stats(W_)
    if "--dump" in sys.argv:
        import numpy
        i_ = sys.argv.index("--dump")
        numpy.save(sys.argv[i_ + 1], np_map(W_, float(sys.argv[i_ + 2])).astype("float32"))
