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
        self.XEND = O['top'][-1][0]
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
        E = self.EY; t0 = self._TOP0(x); rr = E["d"] / 2 + self._CLR; w = rr
        bump = E['y'] + rr * np.sqrt(np.clip(1 - ((np.asarray(x) - E['x']) / w) ** 2, 0, 1)) - (np.abs(np.asarray(x) - E['x']) >= w) * 1.0
        return smax(t0, bump, 0.004)

    def _seam_y(self, x):
        """mouth line height at x, and whether x lies in the mouth (in front of the rictus)."""
        x = np.asarray(x, float); return np.interp(x, self._seam[:, 0], self._seam[:, 1]), x <= self._seam[-1, 0]

    def TOP(self, x):
        y, on = self._seam_y(x); return smax(self._top_orbit(x), np.where(on, y + JAW_MIN, -1.0), JAW_K)

    def BOT(self, x):
        y, on = self._seam_y(x); return -smax(-self._BOT0(x), np.where(on, JAW_MIN - y, -1.0), JAW_K)

    def sec(self, x):
        t, b, w = self.TOP(x), self.BOT(x), self.HW(x)
        return (t + b) / 2, (t - b) / 2, w

    def loft_point(self, x, th):
        """exact point of the record loft at body coords (x, theta)."""
        c, a, b = self.sec(x); dy, dz = np.cos(th), np.sin(th)
        n = np.where(dy > 0, self.NUP(x), self.NLO(x))
        r = (np.abs(dy / a) ** n + np.abs(dz / b) ** n) ** (1 / n)
        rho = 1 / r
        return np.stack([x, c + rho * dy, rho * dz], -1)

    def theta_of(self, x, y, z):
        c, a, b = self.sec(x); return np.arctan2(z, y - c) % (2 * np.pi)

    def z_on(self, x, y):
        """flank z of the loft at side-view point (x, y)."""
        c, a_, b_ = self.sec(x); dy = y - c; nn = np.where(dy > 0, self.NUP(x), self.NLO(x))
        return b_ * np.maximum(1 - np.minimum(np.abs(dy / a_), 1) ** nn, 1e-6) ** (1 / nn)

    def radial(self, p):
        """unit direction from the section centre line to p, in the section plane."""
        c = float(self.sec(np.clip(p[0], 0, self.XEND))[0]); v = np.array([0.0, p[1] - c, p[2]]); n = np.linalg.norm(v)
        return v / n if n > 1e-9 else np.array([0.0, 1.0, 0.0])

    def sd_body(self, P):
        XEND = self.XEND
        x, y, z = P[..., 0], P[..., 1], P[..., 2]
        xc = np.clip(x, 0, XEND); c, a, b = self.sec(xc)
        dy = y - c; n = np.where(dy > 0, self.NUP(xc), self.NLO(xc))
        r = (np.abs(dy / a) ** n + np.abs(z / b) ** n) ** (1 / n)
        q = np.sqrt(dy * dy + z * z) + 1e-9
        d = q * (1 - 1 / np.maximum(r, 1e-6))
        h = 2e-3  # slope correction so the field stays close to a distance
        s = (q / np.maximum(r, 1e-6))
        c2, a2, b2 = self.sec(np.clip(xc + h, 0, XEND))
        r2 = (np.abs((y - c2) / a2) ** n + np.abs(z / b2) ** n) ** (1 / n)
        s2 = q / np.maximum(r2, 1e-6)
        d = d / np.sqrt(1 + ((s2 - s) / h) ** 2)
        return np.maximum(d, np.maximum(-x, x - XEND))

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
            ids = np.where(nd < d - 1e-5, len(self.PLATES) + k + 1, ids); d = nd
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
