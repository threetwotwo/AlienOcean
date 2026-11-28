"""Stage 2, FORM: the creature as a signed-distance solid, built only from the adapted record.

Structure level 0 is the body mass (a loft of record sections). Structure level 1 is bone plates under the skin (opercle,
preopercle, maxilla; from below the lower-jaw rami and the branchiostegal membrane), the orbit ring and the mouth cleft. The form is never shipped: it is the bake source and the surface the
cage snaps to. Input: the adapted record (record.adapt). Output: a Form object (and, optionally, a dense mesh for the bake).
"""
import numpy as np
from scipy.interpolate import PchipInterpolator


def pch(tab):
    a = np.array(tab, float); f = PchipInterpolator(a[:, 0], a[:, 1], extrapolate=False)
    lo, hi = a[0, 0], a[-1, 0]
    return lambda x: f(np.clip(x, lo, hi))


def smax(a, b, k):
    """smooth maximum: exactly a where b is more than k below it."""
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1); return a * (1 - h) + b * h + k * h * (1 - h)


JAW_MIN = 0.003    # DEFAULT: least thickness of each jaw at the mouth line (SL): one lip thickness (cage.mouth.TLIP)
JAW_K = 0.002      # DEFAULT: the outline is carried round the mouth line over this height (SL), no crease
HW_MIN = 0.002    # DEFAULT: least half-width of a cross-section (SL). A traced top view can close to a point at the snout
                  # while the side view still has height there; a zero width is a section with no inside (the loft divided by it)
# ---- the eye's aim and the tissue round it. Source for the scan numbers: the Species thread's 79 CC0 photogrammetry scans
# (plans/species_system/gapfill/README.md "Eye aim, round 1"; eye_aim_r1/gaze_report.json meta, skin_targets.json meta).
RING_R = (1.6, 2.4)          # DEFAULT: the skin ring round the eye (x eye radius) whose best plane is "the skin's facing" (the scans' ring, eyedir.py)
AIM_BELOW_SKIN = 7.5         # DEFAULT (deg): the eye disc aims this far below the skin ring's plane (scan median, n 48)
AIM_UP = (-6.0, 12.0)        # DEFAULT (deg above horizontal): the range real eye discs keep to: scan median 2, spread 8-10 (regression error 10.7,
                             # "noise 10-17 on dead scans"); the skin follows the head's shape, the globe sits in the skull and stays near level
AIM_FWD = (4.0, 26.0)        # DEFAULT (deg toward the snout): scan median 14.3, IQR 10.2-19.6, error 7.8 -> median +- 1.5 errors
TISSUE_REACH = 3.0           # DEFAULT (x eye radius): where the tissue has run out into the loft below the eye. It covers the scans' ring (to 2.4 R);
                             # HP-HEAD-ORBIT-1 found the built skin low at 1.6 and 2.0 R, and the scan skin profile (levels_r1) is read to 2.0 R
ORBIT_SWELL = 2.0            # DEFAULT: length / height of the dorsal outline's lift over an eye that stands above it (1 = the eye's own circle)
TISSUE_K = 0.04              # DEFAULT: the tissue meets the loft over 4 % of the local half-width, no crease
PLATE_CHAMFER = 0.004   # DEFAULT: the edge of a plate drawn from below rises to full thickness over two cells of the dense form (0.2 % SL each)


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1); return b * (1 - h) + a * h - k * h * (1 - h)


def poly_sd2(px, py, poly):
    """signed distance to a closed polygon in the side plane (negative inside)."""
    P = np.array(poly, float); d = np.full(px.shape, 1e9); s = np.ones(px.shape)
    for i in range(len(P)):
        a, b = P[i], P[(i + 1) % len(P)]
        e = b - a; wx, wy = px - a[0], py - a[1]
        if e @ e < 1e-18: continue                # a repeated record point
        t = np.clip((wx * e[0] + wy * e[1]) / (e @ e), 0, 1)
        dx, dy = wx - e[0] * t, wy - e[1] * t; d = np.minimum(d, dx * dx + dy * dy)
        c1 = py >= a[1]; c2 = py < b[1]; c3 = e[0] * wy > e[1] * wx
        flip = (c1 & c2 & c3) | (~c1 & ~c2 & ~c3); s = np.where(flip, -s, s)
    return s * np.sqrt(d)


def smooth_curve(pts, n=24):
    a = np.array(pts, float)
    a = a[np.r_[True, np.linalg.norm(np.diff(a, axis=0), axis=1) > 1e-9]]     # repeated record points would stall the spline
    t = np.r_[0, np.cumsum(np.linalg.norm(np.diff(a, axis=0), axis=1))]
    tt = np.linspace(0, t[-1], n)
    return [[float(PchipInterpolator(t, a[:, 0])(v)), float(PchipInterpolator(t, a[:, 1])(v))] for v in tt]


def edge_x(curve, y):
    c = np.array(sorted(curve, key=lambda p: p[1])); return np.interp(y, c[:, 1], c[:, 0])


def grad(f, P, e=4e-4):
    g = np.stack([(f(P + v) - f(P - v)) for v in np.eye(3) * e], -1)
    return g / (np.linalg.norm(g, axis=-1, keepdims=True) + 1e-12)


class Form:
    """Body coordinates: x from snout (0) to tail root (XEND) in SL, y up, z to the left flank. theta 0 = dorsal midline,
    pi/2 = left (+z) flank."""

    def __init__(self, rec):
        self.rec = rec; O = self.O = rec['outline']
        self._TOP0, self._BOT0, self.HW, self.NUP, self.NLO = (pch(O[k]) for k in ('top', 'bot', 'hw', 'nUp', 'nLo'))
        _hw = self.HW; self.HW = lambda x: np.maximum(_hw(x), HW_MIN)
        self.XEND = O['top'][-1][0]
        self.SECT = self._sections(O.get('sections'))
        self.EY = EY = rec['eye']; self.CV = CV = rec['cover']; self.MO = MO = rec['mouth']
        # structure rule: the jaws enclose the mouth. A traced outline can leave the mouth line in the open (an upper lip
        # that overhangs, a notch where the lips part: the outline is one height per x), and lips laid on a seam outside the
        # loft fell on the midline, a mouth with no width. Each jaw is at least JAW_MIN thick at the seam.
        _ml = np.array(MO['line'], float); self._seam = _ml[np.argsort(_ml[:, 0])]
        self.ex, self.eyy, self.er = EY['x'], EY['y'], EY['d'] / 2
        # structure rule: the orbit shapes the head profile. Where the record's eye (plus a skin margin for the eye loops)
        # rises above the dorsal outline, the outline is lifted over it (ceiling frame: the alfonsino eye bulges the profile).
        self._CLR = 0.15 * EY['d'] / 2
        _xs = np.linspace(0, self.XEND, 400); self.ORBIT_LIFT = float(np.max(self._top_orbit(_xs) - self._TOP0(_xs)))
        _xm = np.linspace(0, self._seam[-1, 0], 60)
        self.JAW_LIFT = float(max(np.max(self.TOP(_xm) - self._top_orbit(_xm)), np.max(self._BOT0(_xm) - self.BOT(_xm))))
        self._orb = None; self.ORBIT = self._orbit()
        # bone plates: (name, outline, thickness, free (stepped) edge curve or None, buried-side fade width, provenance)
        self.rear, self.preop = smooth_curve(CV['rear']), smooth_curve(CV['preop'])
        self.ring_x = float(np.mean([p[0] for p in smooth_curve(CV['edge_all'])]))      # where the slit's ring goes (see record.py)
        OPERCLE = self.rear + self.preop[::-1]                                         # between preopercle margin and cover rear edge
        PREOPERCLE = self.preop + [[p[0] - 0.07, p[1]] for p in self.preop[::-1]]      # strip in front of the margin
        self.ml = ml = np.array(MO['line']); mh = MO['maxilla_h']
        MAXILLA = [list(p + [0.004, 0.002]) for p in ml] + [list(p + [0.0, mh]) for p in ml[::-1]]
        self.PLATES = [
            ('opercle', OPERCLE, CV['step'], self.rear, 0.05, 'opercle bone: record cover.rear + cover.preop, thickness cover.step'),
            ('preopercle', PREOPERCLE, CV['step'] * 0.55, self.preop, 0.05, 'preopercle bone: record cover.preop margin'),
            ('maxilla', MAXILLA, CV['step'] * 0.6, None, 0, 'maxilla bone: record mouth.line + mouth.maxilla_h'),
        ]
        self.VPLATES = self.ventral_plates(rec)

    def ventral_plates(self, rec):
        """plates seen from below: (name, outline in the bottom view (x, |z|), thickness, free edge (front x, |z| at x) or None, fade,
        side-view line the plate stays under, provenance). Sets self.vedge, the gill V's free edge (None: no V)."""
        CV, MO = self.CV, self.MO; out = []; xj, yj = rec['jaw_joint']; on = lambda x, y: 0.92 * float(self.z_on(x, y))
        # lower jaw: each ramus lies between the dentary line (outer) and the mandible's lower edge (inner); the two meet
        # at the chin, so from below they read as a V with the throat skin between
        JW = rec.get('jaw') or {}; dn, lo = JW.get('dentary'), JW.get('low'); tip = self.ml[np.argmin(self.ml[:, 0])]
        if not dn: dn = [[x, y, on(x, y)] for x, y in zip(np.linspace(tip[0] + 0.001, xj, 5), np.linspace(tip[1] - 0.004, yj, 5))]
        dn = sorted(dn, key=lambda p: p[0])
        if xj > dn[-1][0] + 1e-4: dn = dn + [[xj, yj, max(on(xj, yj), dn[-1][2])]]          # the ramus ends at the jaw joint
        if not lo: lo = [[p[0], 0, 0.5 * p[2] * k / (len(dn) - 1)] for k, p in enumerate(dn)]
        lo = sorted(lo, key=lambda p: p[0]); d_ = np.array(dn)
        if len(dn) >= 2 and dn[-1][0] - dn[0][0] > 0.01:
            poly = [[p[0], p[2]] for p in dn] + [[p[0], p[2]] for p in lo[::-1]]
            # the plate keeps under the lips (two lip thicknesses below the mouth line), or the first loops round the mouth cross
            lip = lambda x: np.interp(x, self.ml[:, 0], self.ml[:, 1] - 0.006, right=1e9)
            out.append(('mandible', poly, CV['step'] * 0.6, None, 0, lambda x: np.minimum(np.interp(x, d_[:, 0], d_[:, 1]), lip(x)),
                        'lower jaw rami: record jaw.dentary + jaw.mandibleLow (to the jaw joint)'))
        # gill V: from the cover's lower corner the free edge runs straight (seen from below) to the isthmus at the apex.
        # A cover whose corner stays above the membrane's top ray has no free membrane: a side slit only (puffers).
        self.vedge = None
        xc, yc = self.rear[-1]; zc = float(self.z_on(xc, yc)); xa = CV.get('apex_x'); xa = xj if xa is None else xa
        # the fan's angles are taken round the section scaled to its half-width: |z| = half-width x cos(angle)
        if zc <= float(self.HW(xc)) * np.cos(np.radians(CV.get('membrane_top_deg', 25))) and xa < xc - 0.03:
            za = max(float(self.HW(xa)) * np.sin(np.radians(CV.get('isthmus_deg', 20))), self.isthmus_z(xa))
            if za < zc:
                self.vedge = dict(xa=xa, za=za, xc=xc, zc=zc, fa=za / float(self.HW(xa)), fc=zc / float(self.HW(xc)))
                px, py = self.preop[int(np.argmin([p[0] for p in self.preop]))]          # under the opercle plate's lower side
                self.vunder = [[float(min(px, xc - 1e-3)), float(py)], [float(xc), float(yc)]]
                under = lambda x: np.minimum(np.interp(x, *zip(*self.vunder)), self.sec(np.clip(x, 0, self.XEND))[0])
                poly = [[float(x), float(self.vedge_z(x))] for x in np.linspace(xa, xc, 16)] + [[xc, 1.0], [xa, 1.0]]
                out.append(('branchiostegal', poly, CV['step'], (xa, self.vedge_z), 0.05, under,
                            'interopercle + branchiostegal membrane: cover corner to the isthmus at the interopercle front; angles from branchiostegals th0, dth, n'))
        return out

    def isthmus_th(self, x, room=0.012):
        """the angle nearest the ventral midline that still leaves `room` (SL) of skin to it: on a keeled belly a small |z|
        lies almost on the keel, and the two openings would meet."""
        mid = self.loft_point(np.array(x), np.array(np.pi)); lo, hi = np.pi / 2, np.pi; room = min(room, 0.5 * float(self.HW(x)))
        for _ in range(30):
            m = 0.5 * (lo + hi); lo, hi = (m, hi) if np.linalg.norm(self.loft_point(np.array(x), np.array(m)) - mid) > room else (lo, m)
        return lo

    def isthmus_z(self, x):
        return float(self.loft_point(np.array(x), np.array(self.isthmus_th(x)))[2])

    def vedge_z(self, x):
        """|z| of the gill V's free edge at x, seen from below: a share of the head's half-width that falls evenly from the
        corner to the isthmus. On an evenly tapering head that is a straight V; a straight line in z left the body where a
        tube snout necks in (trumpetfish)."""
        e = self.vedge; s_ = np.clip((np.asarray(x, float) - e['xa']) / (e['xc'] - e['xa']), 0, 1.2)
        return self.HW(np.clip(x, 0, self.XEND)) * (e['fa'] + (e['fc'] - e['fa']) * s_)

    # ---- level 0: the loft
    def _top_orbit(self, x):
        # the lift is a swell, a parabola ORBIT_SWELL times as long as it is high that runs into the outline without a step:
        # with the skull roof at the eyes' width (_tissue) a lift as short as the eye, ending square on the outline, stood
        # across the forehead as a bar from eye to eye
        # Toward the snout the swell stops short of the mouth tip where it can (porcupinefish: an eye that reaches the snout;
        # a swell over the lips thickened the upper jaw into the mouth cavity); it is never shorter than sqrt 2 x its
        # height, the shortest parabola that clears the eye's circle
        E = self.EY; t0 = self._TOP0(x); rr = E["d"] / 2 + self._CLR; dx = np.asarray(x) - E['x']
        w = np.where(dx < 0, np.clip(E['x'] - self._seam[0, 0], np.sqrt(2) * rr, rr * ORBIT_SWELL), rr * ORBIT_SWELL)
        bump = E['y'] + rr * (1 - (dx / w) ** 2)
        return smax(t0, bump, max(0.004, self._CLR))

    def _seam_y(self, x):
        """mouth line height at x, and whether x lies in the mouth (in front of the rictus)."""
        x = np.asarray(x, float); return np.interp(x, self._seam[:, 0], self._seam[:, 1]), x <= self._seam[-1, 0]

    def TOP(self, x):
        y, on = self._seam_y(x); return smax(self._top_orbit(x), np.where(on, y + JAW_MIN, -1.0), JAW_K)

    def BOT(self, x):
        y, on = self._seam_y(x); return -smax(-self._BOT0(x), np.where(on, JAW_MIN - y, -1.0), JAW_K)

    # ---- the cross-section. Without traced sections it is two half superellipses (record nUp above, nLo below the
    # section centre), widest at mid-height. A traced section (record outline.sections) is the photo's own shape: half-width
    # w (0..1 of the record half-width) at normalised height s (-1 ventral edge, +1 dorsal edge), so a keel, a flat flank or
    # a widest point above the middle come from the reference. Between stations the shape blends linearly in x; before the
    # first and after the last it holds. Width stays the record hw; height stays top/bot (front and top silhouette: SIL2).
    SECT_S, SECT_PHI = 129, 361          # DEFAULTS: samples down a traced section and round its polar boundary

    def _sections(self, S):
        if not S: return None
        S = sorted(S, key=lambda q: q['x']); ss = np.linspace(-1, 1, self.SECT_S); phi = np.linspace(0, np.pi, self.SECT_PHI)
        X, W, RHO = [], [], []
        for q in S:
            w = np.array(q['w'], float); w = w[np.argsort(w[:, 0])]
            ws = np.clip(np.interp(ss, w[:, 0], w[:, 1]), 0, None); ws = ws / max(ws.max(), 1e-9)
            ws[0] = ws[-1] = 0.0                                             # the section closes on the midline at both edges
            ang = np.arctan2(ws, ss); rad = np.hypot(ws, ss)                 # polar boundary in normalised (u = s, v = w)
            o = np.argsort(ang); X.append(q['x']); W.append(ws); RHO.append(np.interp(phi, ang[o], rad[o]))
        return dict(x=np.array(X), s=ss, w=np.array(W), phi=phi, rho=np.array(RHO))

    def _blend(self, x, T):
        S = self.SECT; x = np.asarray(x, float); k = np.clip(np.searchsorted(S['x'], x) - 1, 0, len(S['x']) - 1)
        k1 = np.minimum(k + 1, len(S['x']) - 1); span = np.maximum(S['x'][k1] - S['x'][k], 1e-9)
        t = np.clip((x - S['x'][k]) / span, 0, 1)[..., None]
        return (1 - t) * T[k] + t * T[k1]

    def rnorm(self, x, u, v, n=None):
        """how far (u, v) = (dy / a, dz / b) lies out from the section centre, in units of the boundary (1 = on the skin)."""
        return self._rnorm0(x, u, v / self._tissue(x, u), n)

    def wnorm(self, x, s):
        """half-width (0..1 of the record half-width) of the section at normalised height s."""
        return self._wnorm0(x, s) * self._tissue(x, s)

    def _rnorm0(self, x, u, v, n=None):
        """rnorm of the bare loft (record sections only, no tissue round the eye)."""
        if self.SECT is None:
            n = np.where(u > 0, self.NUP(x), self.NLO(x)) if n is None else n
            return (np.abs(u) ** n + np.abs(v) ** n) ** (1 / n)
        S = self.SECT; R = self._blend(np.broadcast_to(x, np.broadcast(x, u).shape), S['rho'])
        ph = np.arctan2(np.abs(v), u) / np.pi * (len(S['phi']) - 1); i = np.clip(ph.astype(int), 0, len(S['phi']) - 2); f = ph - i
        rb = np.take_along_axis(R, i[..., None], -1)[..., 0] * (1 - f) + np.take_along_axis(R, (i + 1)[..., None], -1)[..., 0] * f
        return np.hypot(u, v) / np.maximum(rb, 1e-9)

    def _wnorm0(self, x, s):
        """wnorm of the bare loft."""
        if self.SECT is None:
            nn = np.where(s > 0, self.NUP(x), self.NLO(x))
            return np.maximum(1 - np.minimum(np.abs(s), 1) ** nn, 1e-6) ** (1 / nn)
        S = self.SECT; Wx = self._blend(np.broadcast_to(x, np.broadcast(x, s).shape), S['w'])
        q = (np.clip(s, -1, 1) + 1) / 2 * (len(S['s']) - 1); i = np.clip(q.astype(int), 0, len(S['s']) - 2); f = q - i
        w = np.take_along_axis(Wx, i[..., None], -1)[..., 0] * (1 - f) + np.take_along_axis(Wx, (i + 1)[..., None], -1)[..., 0] * f
        return np.maximum(w, 1e-6)

    def sec(self, x):
        t, b, w = self.TOP(x), self.BOT(x), self.HW(x)
        return (t + b) / 2, (t - b) / 2, w

    def loft_point(self, x, th):
        """exact point of the record loft at body coords (x, theta)."""
        c, a, b = self.sec(x); dy, dz = np.cos(th), np.sin(th)
        rho = 1 / self._rnorm0(x, dy / a, dz / b)
        if self._orb is not None:
            # the tissue round the eye widens the section by a factor that changes with height, so the skin along a ray
            # from the section centre is found by bisection, between the bare loft less the furrow and the section's own
            # limits (the outline's height, the half-width plus the bulge)
            x_, rho = np.broadcast_arrays(np.asarray(x, float), rho); rho = rho.copy()
            m = (x_ > self.ex - self._orb['front']) & (x_ < self.ex + self._orb['back'])
            if m.any():
                bc = lambda v: np.broadcast_to(v, x_.shape)[m]
                xm, u, v, bm = x_[m], bc(dy / a), bc(dz / b), bc(b)
                lo = 0.8 * rho[m]; hi = np.minimum(1 / np.maximum(np.abs(u), 1e-9), (1 + self._orb['past'] / bm) / np.maximum(np.abs(v), 1e-9))
                hi = np.maximum(hi, lo)
                for _ in range(26):
                    t = 0.5 * (lo + hi); out = t * self._rnorm0(xm, u, v / self._tissue(xm, t * u)) > 1
                    lo, hi = np.where(out, lo, t), np.where(out, t, hi)
                rho[m] = 0.5 * (lo + hi)
        return np.stack([x, c + rho * dy, rho * dz], -1)

    def theta_of(self, x, y, z):
        c, a, b = self.sec(x); return np.arctan2(z, y - c) % (2 * np.pi)

    def z_on(self, x, y):
        """flank z of the loft at side-view point (x, y)."""
        c, a_, b_ = self.sec(x); return b_ * self.wnorm(x, (y - c) / a_)

    def radial(self, p):
        """unit direction from the section centre line to p, in the section plane."""
        c = float(self.sec(np.clip(p[0], 0, self.XEND))[0]); v = np.array([0.0, p[1] - c, p[2]]); n = np.linalg.norm(v)
        return v / n if n > 1e-9 else np.array([0.0, 1.0, 0.0])

    SD_CHUNK = 100_000   # points per pass: a traced section blends (points x SECT_PHI) tables, 2 M texels x 361 = 5.5 GB per array

    def sd_body(self, P, *a, **k):
        """pointwise body distance, taken in chunks so memory stays bounded at any map resolution (same values as one pass)."""
        P = np.asarray(P, float); sh = P.shape[:-1]; Q = P.reshape(-1, 3)
        if len(Q) <= self.SD_CHUNK: return self._sd_body(P, *a, **k)
        return np.concatenate([self._sd_body(Q[i:i + self.SD_CHUNK], *a, **k) for i in range(0, len(Q), self.SD_CHUNK)]).reshape(sh)

    def _sd_body(self, P):
        XEND = self.XEND
        x, y, z = P[..., 0], P[..., 1], P[..., 2]
        xc = np.clip(x, 0, XEND); c, a, b = self.sec(xc)
        dy = y - c; n = None if self.SECT is not None else np.where(dy > 0, self.NUP(xc), self.NLO(xc))
        r = self.rnorm(xc, dy / a, z / b, n)
        q = np.sqrt(dy * dy + z * z) + 1e-9
        d = q * (1 - 1 / np.maximum(r, 1e-6))
        h = 2e-3  # slope correction so the field stays close to a distance
        s = (q / np.maximum(r, 1e-6))
        c2, a2, b2 = self.sec(np.clip(xc + h, 0, XEND))
        r2 = self.rnorm(np.clip(xc + h, 0, XEND), (y - c2) / a2, z / b2, n)      # same exponents as r: a slope, not a new shape
        s2 = q / np.maximum(r2, 1e-6)
        d = d / np.sqrt(1 + ((s2 - s) / h) ** 2)
        return np.maximum(d, np.maximum(-x, x - XEND))

    # ---- the orbit: the eye's aim, and the tissue that carries the skin out to it.
    # Structure rule: the globe sits in the skull, so its aim is its own and not the skin's. Real eye discs aim 7.5 deg below
    # the skin round them and stay near level (AIM_UP, AIM_FWD), while the skin's facing follows the head. Taking the aim
    # from the eye rim's plane on the loft (0.5.x) pointed every eye up, most on round heads with high eyes, where a
    # loft section falls away above the eye: the head had no volume round the eye (HP-HEAD-ORBIT-1, Gary 28 Nov).
    # So the eye's plane is set first, square to the aim and never under the loft at the rim; periorbital tissue then carries
    # the skin from that plane out into the loft (brow, snout side), and above the brow the section keeps its own shape,
    # scaled out to meet it (the roof over the orbit). The tissue only widens sections, in z, and never past the record
    # half-width, so the side and top outlines stay the record's.
    def skin_ring(self, r=RING_R):
        """best plane of the skin ring round the left eye, as the scans measure it: (degrees above horizontal, degrees
        toward the snout, unit normal, eye height in the local body depth)."""
        ex, eyy, er = self.ex, self.eyy, self.er
        ph = np.linspace(0, 2 * np.pi, 90, endpoint=False); pts = []
        for rr in np.linspace(r[0], r[1], 5) * er:
            qx, qy = ex + rr * np.cos(ph), eyy + rr * np.sin(ph)
            ok = (qy < self.TOP(qx)) & (qy > self.BOT(qx)) & (qx > 0) & (qx < self.XEND)
            pts.append(np.stack([qx[ok], qy[ok], self.z_on(qx[ok], qy[ok])], -1))
        P = np.vstack(pts); n = np.linalg.svd(P - P.mean(0))[2][2]; n = n if n[2] > 0 else -n
        h = (eyy - float(self.BOT(ex))) / (float(self.TOP(ex)) - float(self.BOT(ex)))
        return float(np.degrees(np.arcsin(n[1]))), float(np.degrees(np.arctan2(-n[0], n[2]))), n, float(h)

    def _orbit(self):
        """sets the eye's aim and the tissue round it (self._orb); returns the numbers for the build report."""
        EY, er = self.EY, self.er
        up0, fwd0, _, h = self.skin_ring()                                          # the bare loft's skin ring
        a = EY.get('aim') or {}
        up = a['up'] if a.get('up') is not None else float(np.clip(up0 - AIM_BELOW_SKIN, *AIM_UP))
        fwd = a['fwd'] if a.get('fwd') is not None else float(np.clip(fwd0, *AIM_FWD))
        ph = np.linspace(0, 2 * np.pi, 360, endpoint=False); qx, qy = self.ex + er * np.cos(ph), self.eyy + er * np.sin(ph)
        z0 = self.z_on(qx, qy); past = EY['bulge'] * er                             # the bulge may show in the top view, no more
        sink = EY['groove'] * er                                                    # the eye's edge may lie this far under the skin: the furrow

        def plane(up_, fwd_):
            cu, su, cf, sf = np.cos(np.radians(up_)), np.sin(np.radians(up_)), np.cos(np.radians(fwd_)), np.sin(np.radians(fwd_))
            n = np.array([-sf * cu, su, cf * cu]); t = (n[0] * (qx - self.ex) + n[1] * (qy - self.eyy)) / n[2]
            # the plane touches the loft at the rim's outermost point and stands proud of it by the periorbital bulge
            return n, t, float(np.max(z0 + t)), float(np.min(self.HW(qx) + past + t))
        n, t, touch, room = plane(up, fwd); lam = 0.0
        if room + sink < touch:
            # the eye's plane cannot lie inside the record's top view at this aim (an eye on the round of a blunt snout):
            # a small misfit is the furrow round the eye; past that the top view is measured and the aim is a rule, so the aim
            # gives way toward the skin's own facing
            lo, hi = 0.0, 1.0
            for _ in range(12):
                lam = 0.5 * (lo + hi); n, t, touch, room = plane(up + lam * (up0 - up), fwd + lam * (fwd0 - fwd))
                lo, hi = (lo, lam) if room + sink >= touch else (lam, hi)
            lam = hi; up, fwd = up + lam * (up0 - up), fwd + lam * (fwd0 - fwd); n, t, touch, room = plane(up, fwd)
        zd = min(touch + past / n[2], max(room, touch - sink))
        # the skull roof runs from the snout tip to the head's end (the gill cover's rear edge), never less than the tissue's reach
        back = max(max(p[0] for p in self.CV['rear']) - self.ex, TISSUE_REACH * er); front = max(self.ex, TISSUE_REACH * er)
        self._orb = dict(n=n, zd=zd, y_brow=self.eyy + er * (1 + EY['over']), past=past, front=front, back=back)
        up1, fwd1, _, _ = self.skin_ring(); rim = self.z_on(qx, qy)
        return dict(aim_up_deg=round(up, 1), aim_fwd_deg=round(fwd, 1), bare_skin_up_deg=round(up0, 1), bare_skin_fwd_deg=round(fwd0, 1),
                    skin_up_deg=round(up1, 1), skin_fwd_deg=round(fwd1, 1), eye_height=round(h, 3),
                    tissue_max_R=round(float((rim - z0).max()) / er, 2), aim_gave_way=round(lam, 2),
                    rim_off_plane_R=round(float(np.abs(rim - (zd - t)).max()) / er, 3),
                    aim_source=EY.get('aim_source', 'skin ring - AIM_BELOW_SKIN, kept in AIM_UP / AIM_FWD (DEFAULT)'))

    def eye_axis(self, sg=1):
        """unit aim of the eye on side sg (+1 left)."""
        n = self._orb['n']; return np.array([n[0], n[1], sg * n[2]])

    def _tissue(self, x, u):
        """how far the tissue round the eye widens the section at (x, u = normalised height): 1 = the bare loft.
        Inside the eye's own box (its length, from its lower edge to the brow) the skin lies on the eye's plane. Outside it
        the section keeps its own shape, widened as at the nearest point of the box at the same depth under the dorsal
        outline: over the eye that is the skull roof, which runs on at that width behind the eye to the head's end and
        ahead of it to the snout tip, fading out; below the eye it has run out TISSUE_REACH eye radii down. A tissue that
        ran out the same distance all round stood on the head as a bar from eye to eye (round 1 of this fix)."""
        O = self._orb
        if O is None: return 1.0
        x, u = np.broadcast_arrays(np.asarray(x, float), np.asarray(u, float)); k = np.ones(x.shape)
        er, ex, eyy = self.er, self.ex, self.eyy
        m = (x > ex - O['front']) & (x < ex + O['back']) & (np.abs(u) < 1)
        if not m.any(): return k
        xm = x[m]; c, a, b = self.sec(xm); y = c + a * u[m]; n = O['n']
        xc = np.clip(xm, ex - er, ex + er); cc, ac, bc = self.sec(xc)
        # the brow stands record eye.over above the eye where the head has the room, and leaves the roof the skin margin
        # the outline keeps over the eye
        yc = np.clip(y - (c + a) + (cc + ac), eyy - er, np.minimum(O['y_brow'], cc + ac - self._CLR))
        K = (O['zd'] - (n[0] * (xc - ex) + n[1] * (yc - eyy)) / n[2]) / (bc * self._wnorm0(xc, (yc - cc) / ac))
        w0 = self._wnorm0(xm, u[m])
        Ko = np.minimum(smax(np.ones(K.shape), K, TISSUE_K), (1 + O['past'] / b) / w0)                 # out: inside the half-width + bulge
        dx = xm - ex; px = np.clip((np.abs(dx) - er) / (np.where(dx < 0, O['front'], O['back']) - er), 0, 1)
        py = np.clip((eyy - er - y) / ((TISSUE_REACH - 1) * er), 0, 1)
        s_ = np.clip(1 - np.hypot(px, py), 0, 1); W = s_ * s_ * (3 - 2 * s_)
        # the tissue is skull and the skin over it: it ends at the upper jaw (above the maxilla, record mouth.maxilla_h over
        # the mouth line), or the lips and the mouth cavity under them part company (porcupinefish: an eye that reaches the snout)
        ys, _ = self._seam_y(xm); xr = self._seam[-1, 0]
        s_ = np.clip((y - ys - self.MO['maxilla_h']) / er, 0, 1); s_ = np.maximum(s_, np.clip((xm - xr) / er, 0, 1)); W = W * s_ * s_ * (3 - 2 * s_)
        # in: only the furrow, where the eye's plane lies under the skin at the rim; it has closed by the skin ring
        s_ = np.clip((RING_R[0] - np.hypot(dx, y - eyy) / er) / (RING_R[0] - 1), 0, 1); Wi = s_ * s_ * (3 - 2 * s_)
        k[m] = 1 + W * (Ko - 1) + Wi * (np.minimum(K, 1) - 1)
        return k

    # ---- level 1: bone plates, orbit ring, mouth cleft
    def sd_full(self, P, parts=False, cleft=True):
        XEND, HW, EY = self.XEND, self.HW, self.EY
        d0 = self.sd_body(P); d = d0.copy(); ids = np.zeros(d.shape, np.int8)
        x, y, z = P[..., 0], P[..., 1], P[..., 2]
        for k, (name, poly, t0, free, fade, _) in enumerate(self.PLATES):
            # bone plates thin out toward their buried (front) side and keep full thickness at the free edge
            t = t0 * (np.clip((x - (edge_x(free, y) - fade)) / fade, 0.15, 1) if free is not None else 1)
            inside2 = poly_sd2(x, y, poly)
            side = np.clip((np.abs(z) - 0.25 * HW(np.clip(x, 0, XEND))) / 0.02, 0, 1)  # plates are on the flanks
            # plate solid = shell between the body surface and t above it, bounded by its outline (hard edge, small round)
            plate = np.maximum(np.maximum(d0 - t, -d0 - 0.004), inside2 + (1 - side) * 0.05)
            nd = smin(d, plate, 0.0006)
            ids = np.where(nd < d - 1e-5, k + 1, ids); d = nd
        az = np.abs(z)
        for k, (name, poly, t0, free, fade, under, _) in enumerate(self.VPLATES):
            t = t0
            if free is not None:      # full thickness at the free edge, thinning away from it and running out at its front end
                x0, ez = free; t = t0 * np.clip(1 - np.abs(az - ez(x)) / fade, 0.15, 1) * np.clip((x - x0) / (0.6 * fade), 0, 1)
            # the plate's edges are chamfers, not walls: its outline is drawn from below and its upper limit in the side view,
            # so a wall there stands along y or along z, not along the skin's normal; where the head rounds from the
            # underside into the flank such a wall leans over the skin (a ledge) and the bake sees it from behind
            t = t * np.clip(np.minimum(-poly_sd2(x, az, poly), under(x) - y) / PLATE_CHAMFER, 0, 1)
            plate = np.maximum(d0 - t, -d0 - 0.004)
            nd = smin(d, plate, 0.0006)
            # where the chamfer has run t out to 0 the plate IS the body surface, and the smooth union still lowers d there by
            # its bias: that labelled the whole flank as this plate (maps: no scale relief, metal dimmed; export r5). A point
            # belongs to the plate only where the plate has thickness. (The 0.15 mm bias itself stays for now: removing it
            # raised rest crossings 208 -> 333 on the traced board, moorish idol 47 -> 144; round 3 owns that.)
            ids = np.where((nd < d - 1e-5) & (t > 1e-5), len(self.PLATES) + k + 1, ids); d = nd
        # orbit: circumorbital ring (bone) around the eye opening, a low torus in the side plane
        ex, eyy, er = self.ex, self.eyy, self.er
        ring = np.abs(np.sqrt((x - ex) ** 2 + (y - eyy) ** 2) - max(EY['orbit'], er * 1.08)) - 0.25 * (EY['orbit'] - er * 0.8 + 0.01)
        side = np.clip((np.abs(z) - 0.3 * HW(np.clip(x, 0, XEND))) / 0.02, 0, 1)
        orb = np.maximum(np.maximum(d0 - 0.0025, -d0 - 0.004), ring + (1 - side) * 0.05)
        d = smin(d, orb, 0.003)
        # mouth cleft: the gape between the jaws is a real gap in the solid (groove cut by the lips meeting)
        ml = self.ml
        cl = np.abs(poly_sd2(x, y, [list(p) for p in ml] + [list(p - [0, 0.0012]) for p in ml[::-1]]))
        if cleft: d = np.maximum(d, -(cl - 0.0008) - np.clip(d0 + 0.004, 0, 1) * 10)
        return (d, ids) if parts else d

    def provenance(self):
        return [dict(region=p[0], source=p[5]) for p in self.PLATES] + [dict(region=p[0], source=p[6]) for p in self.VPLATES] + [
            dict(region='orbit ring', source='circumorbital bone ring: record skeleton.eye.orbitR'),
            dict(region='mouth cleft', source='gape between jaws: record mouth.line'),
            dict(region='eye aim', source=f"{self.ORBIT['aim_source']}: {self.ORBIT['aim_up_deg']} deg up, {self.ORBIT['aim_fwd_deg']} deg forward "
                                          f"(bare loft skin ring {self.ORBIT['bare_skin_up_deg']} up, {self.ORBIT['bare_skin_fwd_deg']} forward)"),
            dict(region='periorbital tissue', source=f"eye plane square to the aim, proud by record eye.bulge, brow held to record eye.over, furrow to record eye.groove; skull roof at that width from the snout tip to record cover rear edge; "
                                                     f"up to {self.ORBIT['tissue_max_R']} eye radii at the rim; skin ring now {self.ORBIT['skin_up_deg']} deg up"),
            dict(region='body mass', source='record outline top/bot/hw/nUp/nLo loft; lifted over the orbit, and carried round the mouth line '
                                            f'(each jaw at least {JAW_MIN * 100:g} % SL thick at record mouth.seam, DEFAULT; moved the outline {self.JAW_LIFT * 100:.2f} % SL)')]

    def dense_mesh(self, hres=0.002):
        """the form as a dense triangle mesh (marching cubes): the bake source, never shipped."""
        from skimage.measure import marching_cubes
        O, XEND = self.O, self.XEND
        ya = np.array(O['top'])[:, 1].max() + 0.03; yb = np.array(O['bot'])[:, 1].min() - 0.03; za = np.array(O['hw'])[:, 1].max() + 0.03
        gx = np.arange(-0.01, XEND + 0.01, hres); gy = np.arange(yb, ya, hres); gz = np.arange(-za, za, hres)
        Gd = np.zeros((len(gx), len(gy), len(gz)), np.float32)
        YY, ZZ = np.meshgrid(gy, gz, indexing='ij')
        for k, xv in enumerate(gx):
            Gd[k] = self.sd_full(np.stack([np.full(YY.shape, xv), YY, ZZ], -1))
        vv, ff, _, _ = marching_cubes(Gd, 0.0, spacing=(hres,) * 3)
        vv += [gx[0], gy[0], gz[0]]
        return vv, ff
