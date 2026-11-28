"""Stage 2, FORM: the creature as a signed-distance solid, built only from the adapted record.

Structure level 0 is the body mass (a loft of record sections). Structure level 1 is bone plates under the skin (opercle,
preopercle, maxilla; from below the lower-jaw rami and the branchiostegal membrane), the orbit ring and the mouth cleft. The form is never shipped: it is the bake source and the surface the
cage snaps to. Input: the adapted record (record.adapt). Output: a Form object (and, optionally, a dense mesh for the bake).
"""
import numpy as np
from scipy.interpolate import PchipInterpolator, CubicSpline
from scipy.optimize import lsq_linear


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
# ---- the eye's aim, the swelling round its rim and the head's facing round it. Source for the scan numbers: the Species thread's 79 CC0 photogrammetry scans
# (plans/species_system/gapfill/README.md "Eye aim, round 1"; eye_aim_r1/gaze_report.json meta, skin_targets.json meta).
RING_R = (1.6, 2.4)          # DEFAULT: the skin ring round the eye (x eye radius) whose best plane is "the skin's facing" (the scans' ring, eyedir.py)
AIM_BELOW_SKIN = 7.5         # DEFAULT (deg): the eye disc aims this far below the skin ring's plane (scan median, n 48)
AIM_UP = (-6.0, 12.0)        # DEFAULT (deg above horizontal): the range real eye discs keep to: scan median 2, spread 8-10 (regression error 10.7,
                             # "noise 10-17 on dead scans"); the skin follows the head's shape, the globe sits in the skull and stays near level
AIM_FWD = (4.0, 26.0)        # DEFAULT (deg toward the snout): scan median 14.3, IQR 10.2-19.6, error 7.8 -> median +- 1.5 errors
SWELL_REACH = RING_R[0]      # DEFAULT (x eye radius): the swelling round the rim has run out where the scans' skin ring begins, so the ring
                             # stays the head's own. (PR #109 ran tissue out to 3 radii and along the whole skull roof: 17 of 28 traced heads
                             # came out more than 8 deg fuller than the scan line, with a boxy roof creased from brow to snout)
RING_LINE = (-57.4, 103.8)   # the scans' line: skin ring degrees above horizontal = a + b x eye height in the local body depth (79 species, r 0.84;
                             # the same line as checks.EA1_LINE)
RING_HOLD = 7.0              # DEFAULT (deg): a head whose skin ring lies further than this off the line (or off record eye.skin_up) is turned
                             # back to it: 1 deg inside the line's leave-one-out error (8.0, checks.EA1_TOL)
SWELL_SLOPE = 0.75           # DEFAULT: where the swelling stands high (the brow of a high eye) it runs out further, no steeper than this
                             # (rise over run), as far as the scans' band lets the skin ring fill (RING_HOLD) and never past SWELL_MAX
SWELL_MAX = 3.0              # DEFAULT (x eye radius): HP-HEAD-ORBIT-1 read the scan skin profile to 2.0 R; the ring ends at 2.4
HOLD_REACH = 2 * RING_R[1]   # DEFAULT (x eye radius): that turn is whole out to the ring's outer edge and has run out at twice that
HOLD_K = (0.5, 1.5)          # DEFAULT: the turn narrows or widens a section to no less than half, no more than half again (and never past the half-width)
ORBIT_SWELL = 1.0            # DEFAULT: half-length of the dorsal outline's swell over an eye that stands above it, x the eye's radius + margin:
                             # the eye's own length. (PR #109 made it 2.0 to hide the bar its boxy roof left across the forehead; the side
                             # silhouette paid: porcupinefish head IoU 0.973 -> 0.953, SIL1 lost. With the roof's round edge there is no bar.)
ROOF_EDGE = 0.25             # DEFAULT (x eye radius): where the swelling reaches the dorsal outline (a high eye) the section closes on the midline
                             # as a roof with a round edge this deep at the rim, deeper further out (the two taken as a hypotenuse: no
                             # corner at the rim). On the 28 traced fish: at 0.15 the edge is tight enough to read as a crease (FM1 11.8 deg,
                             # grouper), at 0.35 the rim's top falls 0.16 eye radii short of the eye's plane; at 0.25 FM1 <= 5.2, rim <= 0.05.
                             # (A superellipse of exponent 6, PR #109, closed as a flat lid with a square edge: FM1 54 deg on the proof
                             # record with a traced section.)
U_EDGE = 1 - 1e-9            # DEFAULT: the section's edge (normalised height) at which a width factor is held; past it lies the outline. (At
                             # 0.999, PR #109, a swelling that reached the outline was cut off there as a lid up to 0.2 % SL wide)
LOFT_ITERS = 12      # DEFAULT: false-position steps of loft_point through the swelling round the eye; against 40 bisections on the 28 traced fish the worst difference is 4e-7 SL
HW_FAIR_TOL = 0.002   # DEFAULT: a half-width knot is faired by at most this (SL). A top view traced from a photo carries the trace's
                      # jitter (about 0.3 of 170 record units, 0.18 % SL, at knots 2 % SL apart): through the knots as they stand the
                      # flank's normal swings a few degrees from knot to knot, and the bake writes that as vertical bands (export r5)
HW_FAIR_LEN = 0.12    # DEFAULT: width changes shorter than this along the body (SL) are the trace's, longer ones the fish's: six
                      # knots of a 2 % SL trace. Jitter from knot to knot (wavelength 4 % SL) is cut 80 times. Trevally flank
                      # ripple (checks FM1): 2.9 deg as traced, 0.96 at 0.08, 0.54 at 0.12, 0.46 at 0.16
SECT_FAIR_LEN = 1.2   # DEFAULT: the same round a section, in radians of its polar angle: about eight rows of a 21-row trace (a
                      # section is one closed oval: what is shorter than a third of its half-boundary is the reading)
SECT_FAIR_TOL = 0.02  # DEFAULT: a traced cross-section row is faired by at most this share of the section's half-size (rows are read
                      # off a scan every 0.1 of the height to about 2 % of the width: plateaus and steps between rows are the reading)
COL_HEAD, COL_BLEND = 0.04, 0.20   # DEFAULTS: the columns round the body keep the head's even angles to this far behind the gill
                      # cover's rear edge (SL), and reach the trunk's spacing over this length (see Form._asp)
PLATE_CHAMFER = 0.004   # DEFAULT: a plate's free edge rises to its full step over two cells of the dense form (0.2 % SL each). An edge
                        # sharper than the bake source can carry comes out of marching cubes as a staircase, and the bake writes
                        # the staircase into the normal map: saw-toothed plate edges (export r6, trevally: 6.5 % of the head's
                        # dense-form normals more than 10 deg off the form's own gradient; check FM2)
PLATE_SLOPE = 1.0       # DEFAULT: and no steeper than this (rise over run, 45 deg) at its steepest: a bone's edge under skin is a bevel, and
                        # a wall in the normal map is the cage's shape in the map (P6). The crisp line of a gill cover is the cage's
                        # own flap edge at the slit, not this bevel
PLATE_STRIP = 0.07      # DEFAULT: the preopercle shows as a strip this wide in front of its free margin (SL)
PLATE_SHELL = 0.012     # DEFAULT: plates are worked out within this distance of the bare body's surface (SL), twice the thickest
                        # step a record carries (cover.step 0.6 % SL): further out or in, the solid is the bare body's
SKIN_OVER = 0.0003      # DEFAULT: the skin's outer face is taken this far outside the loft that the mouth and gill linings are laid out in
                        # (SL). Up to export r6 it was a by-product, never stated: two smooth unions of plates with the body each lowered
                        # the whole solid by a quarter of their 0.06 % SL blend. The unions are gone; the clearance is not yet
                        # spare: without it the lip loops of narrow mouths cross their own lining (8 traced fish: rest crossings
                        # 147 -> 200; moorish idol 34 -> 80, blenny 113 -> 119, pufferfish 0 -> 1). It stays, as a stated number,
                        # until the mouth's own clearances carry it (mouth round 3)
PLATE_P = 4.0           # DEFAULT: where plates overlap their thicknesses join as a p-norm: the thicker one, with a round fillet


def fair(x, y, tol, length, hold=()):
    """a traced table without the trace's jitter: the knot values of the smoothing spline that passes wavelengths longer than
    `length` and takes out shorter ones (least sum of (y - record)^2 dx + (length / 2 pi)^4 y''^2 dx), each knot moved by at
    most `tol` (knots listed in `hold` stay). Knots further apart than `length` are left as they are, so a table that is
    already fair moves little (the 28 hand-made half-width tables: 0.06 % SL at the median, at the close knots by the snout
    and tail root); knots closer than that lose what alternates from knot to knot. Returns the faired values."""
    x, y = np.asarray(x, float), np.asarray(y, float); n = len(x)
    if n < 4 or tol <= 0: return y.copy()
    h = np.diff(x); A = np.zeros((n - 2, n)); lam = (length / (2 * np.pi)) ** 4
    for i in range(n - 2):                       # second divided difference at knot i + 1, weighted by its share of the length
        g = np.sqrt(lam * (h[i] + h[i + 1]) / 2) * 2 / (h[i] + h[i + 1])
        A[i, i:i + 3] = g * np.array([1 / h[i], -1 / h[i] - 1 / h[i + 1], 1 / h[i + 1]])
    w = np.sqrt(np.r_[h[0], h[:-1] + h[1:], h[-1]] / 2)
    t = np.full(n, float(tol)); t[list(hold)] = 1e-9
    r = lsq_linear(np.vstack([A, np.diag(w)]), np.r_[np.zeros(n - 2), w * y], bounds=(y - t, y + t), tol=1e-13)
    return np.clip(r.x, y - t, y + t)


def pch_fair(tab, tol, length):
    """pch through the faired knots (ends held: where the table closes it stays closed)."""
    a = np.array(tab, float); return pch(np.c_[a[:, 0], fair(a[:, 0], a[:, 1], tol, length, hold=(0, -1))])


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


def line_d(P, lines):
    """smooth distance from points P (n, 3) to a set of open polylines (each (m, 3)): the distance d at which a straight
    line of infinite length would have the same pull, pull = integral of ds / r^3 along the lines (= 2 / d^2 for that
    line; closed form per segment). Beside a long edge it is the plain distance. It has no ridge where two edges are
    equally near (the plain nearest-edge distance has one along every corner's bisector, and a thickness made from it
    carried the ridges into the skin as faint creases from each corner of a plate)."""
    I = np.zeros(len(P))
    for A in lines:
        A = np.asarray(A, float)
        for a, b in zip(A[:-1], A[1:]):
            e = b - a; L = np.linalg.norm(e)
            if L < 1e-9: continue
            e = e / L; w = P - a; s1 = -(w @ e); s2 = s1 + L; d2 = np.maximum((w * w).sum(1) - s1 * s1, 0) + 1e-14
            I += (s2 / np.sqrt(d2 + s2 * s2) - s1 / np.sqrt(d2 + s1 * s1)) / d2
    return np.sqrt(2 / np.maximum(I, 1e-12))


def sstep(u):
    u = np.clip(u, 0, 1); return u * u * (3 - 2 * u)


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
        self._TOP0, self._BOT0, self.NUP, self.NLO = (pch(O[k]) for k in ('top', 'bot', 'nUp', 'nLo'))
        _hw0 = np.array(O['hw'], float); _hw = pch_fair(O['hw'], HW_FAIR_TOL, HW_FAIR_LEN)
        self.HW_FAIRED = float(np.max(np.abs(_hw(_hw0[:, 0]) - _hw0[:, 1])))       # how far the fairing moved a knot (SL)
        self.HW = lambda x: np.maximum(_hw(x), HW_MIN)
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
        _xs = np.linspace(0, self.XEND, 2000); self._swell = None; _l = self._top_orbit(_xs) - self._TOP0(_xs)
        self.ORBIT_LIFT = float(np.max(_l)); self._swell = (float(_xs[int(np.argmax(_l))]), self.ORBIT_LIFT) if self.ORBIT_LIFT > 1e-5 else None
        _xm = np.linspace(0, self._seam[-1, 0], 60)
        self.JAW_LIFT = float(max(np.max(self.TOP(_xm) - self._top_orbit(_xm)), np.max(self._BOT0(_xm) - self.BOT(_xm))))
        self._orb = None; self.ORBIT = self._orbit()
        self.rear, self.preop = smooth_curve(CV['rear']), smooth_curve(CV['preop'])
        self.ring_x = float(np.mean([p[0] for p in smooth_curve(CV['edge_all'])]))      # where the slit's ring goes (see record.py)
        self.ml = np.array(MO['line'])
        self.PLATES = self._plates(rec)

    # ---- level 1: bone plates. Structure rule: a bone under the skin shapes the skin as ONE surface. Each plate is a patch
    # of the skin with an outline whose stretches are either FREE (the bone's margin shows: gill cover rear edge and
    # membrane edge, preopercle margin, the maxilla's lower edge) or BURIED (the bone runs on under its neighbours, or the
    # outline is only where the record stops describing it). Its thickness over the bare body is a field on the skin:
    #   with a free margin:  step x bevel(distance to the free margin) x share(buried -> free)
    #   with none (lower jaw rami):  step x a round ridge between its two lines
    # so it is 0 on every outline (no wall anywhere), full only just inside a free margin, and the solid is
    # body - thickness: no stacked unions. Before (up to export r6) each plate was a slab cut off square at its outline and
    # joined with a 0.06 % SL smooth union, in two projections: side-view plates had a wall round all four sides
    # (embossed rectangles; opercle, preopercle, maxilla and membrane stacked on each other), and plates drawn from below
    # were tested in the bottom view on skin that is edge-on to it under the jaw (the lower jaw's outer line: scallops).
    # Walls 0.06 % SL wide came out of the 0.2 % SL dense form as staircases (saw-tooth edges in the normal map, r6).
    # Outlines live in (x, theta) on the skin, where a side-view line and a from-below line are both well placed, and
    # distances are measured along the skin (between the points' feet on the loft).
    def th_side(self, x, y):
        """theta of the left-flank skin point seen at (x, y) in the side view; y is held inside the outline."""
        x = np.clip(np.atleast_1d(np.asarray(x, float)), 0, self.XEND); c, a, _ = self.sec(x); y = np.clip(y, c - a, c + a)
        lo, hi = np.zeros(len(x)), np.full(len(x), np.pi)
        for _ in range(20):      # to 3e-6 rad
            m = 0.5 * (lo + hi); up = self.loft_point(x, m)[:, 1] > y; lo, hi = np.where(up, m, lo), np.where(up, hi, m)
        return 0.5 * (lo + hi)

    def th_below(self, x, z):
        """theta on the underside where the loft is as wide as z, seen from below."""
        x = np.clip(np.atleast_1d(np.asarray(x, float)), 0, self.XEND); lo, hi = np.full(len(x), np.pi / 2), np.full(len(x), np.pi)
        for _ in range(20):      # to 3e-6 rad
            m = 0.5 * (lo + hi); out = self.loft_point(x, m)[:, 2] > z; lo, hi = np.where(out, m, lo), np.where(out, hi, m)
        return 0.5 * (lo + hi)

    def vedge_th(self, x):
        """theta of the gill V's free edge at x: where the loft is as wide as the edge seen from below, and never nearer
        the ventral midline than the isthmus leaves room for. The cage cuts the slit's ventral leg on the same line."""
        x = np.atleast_1d(np.asarray(x, float)); th = self.th_below(x, self.vedge_z(x))
        return np.minimum(th, self.isthmus_th(np.clip(x, 0, self.XEND)))

    def _plates(self, rec):
        """the plates: dicts name, step (SL), poly (outline in (x, theta)), free / buried (lists of polylines on the loft, 3D),
        bevel (width of the free margin's rise) or ridge (half-width of a plate with no free margin), source.
        Sets self.vedge (the gill V's free edge; None: no V) and self.vunder (the side-view line the membrane stays under)."""
        CV, MO = self.CV, self.MO; xj, yj = rec['jaw_joint']; step = CV['step']; out = []
        side = lambda pts: np.c_[np.clip([p[0] for p in pts], 0, self.XEND), self.th_side([p[0] for p in pts], np.array([p[1] for p in pts]))]

        def plate(name, t0, free, buried, source, ridge=None):
            """free, buried: lists of (x, theta) polylines that together close the outline, given in order round it."""
            runs = sorted([(k, 0, np.asarray(a, float)) for k, a in free] + [(k, 1, np.asarray(a, float)) for k, a in buried], key=lambda r: r[0])
            poly = np.concatenate([r[2] for r in runs]); P3 = lambda a: self.loft_point(a[:, 0], a[:, 1])
            runs = [(k, b, np.r_[runs[i - 1][2][-1:], a]) for i, (k, b, a) in enumerate(runs)]     # each stretch starts where the one before it ended: no gap in the outline

            def fine(a):       # an outline edge is straight in (x, theta); its chord through the body is not on the skin, so long edges are cut up
                n = np.maximum(1, np.ceil(np.linalg.norm(np.diff(P3(a), axis=0), axis=1) / PLATE_CHAMFER)).astype(int)
                return np.concatenate([a[i] + (a[i + 1] - a[i]) * np.arange(k)[:, None] / k for i, k in enumerate(n)] + [a[-1:]])
            runs = [(k, b, fine(a)) for k, b, a in runs]
            if len(poly) < 3 or np.ptp(poly[:, 0]) < 0.01: return
            if ridge is not None: t0 = min(t0, ridge * PLATE_SLOPE / 1.5)        # a narrow ridge is a low one: its flanks keep to the same slope
            out.append(dict(name=name, step=float(t0), poly=poly, free=[P3(r[2]) for r in runs if r[1] == 0], buried=[P3(r[2]) for r in runs if r[1] == 1],
                            bevel=max(PLATE_CHAMFER, 1.5 * t0 / PLATE_SLOPE), ridge=ridge, source=source))

        # gill V: from the cover's lower corner the free edge runs straight (seen from below) to the isthmus at the apex.
        # A cover whose corner stays above the membrane's top ray has no free membrane: a side slit only (puffers).
        self.vedge = None; self.vunder = None
        xc, yc = self.rear[-1]; zc = float(self.z_on(xc, yc)); xa = CV.get('apex_x'); xa = xj if xa is None else xa
        # the fan's angles are taken round the section scaled to its half-width: |z| = half-width x cos(angle)
        if zc <= float(self.HW(xc)) * np.cos(np.radians(CV.get('membrane_top_deg', 25))) and xa < xc - 0.03:
            za = max(float(self.HW(xa)) * np.sin(np.radians(CV.get('isthmus_deg', 20))), self.isthmus_z(xa))
            if za < zc:
                self.vedge = dict(xa=xa, za=za, xc=xc, zc=zc, fa=za / float(self.HW(xa)), fc=zc / float(self.HW(xc)))
                px, py = self.preop[int(np.argmin([p[0] for p in self.preop]))]          # under the opercle's lower side
                self.vunder = [[float(min(px, xc - 1e-3)), float(py)], [float(xc), float(yc)]]
        # gill cover: opercle, subopercle and (with a V) the branchiostegal membrane are one cover with one free margin, from
        # the top of the rear edge round the lower corner to the isthmus; it is buried along the preopercle margin, at its
        # top, and under the head along the line from the preopercle's front to the apex
        rear, pre = side(self.rear), side(self.preop)
        if self.vedge is not None:
            xv = np.linspace(xc, xa, 16)[1:]; V = np.c_[xv, self.vedge_th(xv)]; k0 = int(np.argmin([p[0] for p in self.preop]))
            under = lambda x: np.minimum(np.interp(x, *zip(*self.vunder)), self.sec(np.clip(x, 0, self.XEND))[0])
            xu = np.linspace(xa, self.vunder[0][0], 8); U = np.c_[xu, np.minimum(self.th_side(xu, under(xu)), V[-1, 1])]
            plate('gill cover', step, [(0, rear), (1, V)], [(2, np.r_[U, pre[:k0 + 1][::-1], rear[:1]])],
                  'opercle to branchiostegal membrane, one cover: free margin = record cover.rear, then cover corner to the isthmus at the interopercle front '
                  '(angles from branchiostegals th0, dth, n); buried along cover.preop; step cover.step')
        else:
            plate('gill cover', step, [(0, rear)], [(1, np.r_[pre[::-1], rear[:1]])],
                  'opercle: free margin = record cover.rear; buried along cover.preop; step cover.step')
        strip = side([[p[0] - PLATE_STRIP, p[1]] for p in self.preop])
        plate('preopercle', step * 0.55, [(0, pre)], [(1, np.r_[strip[::-1], pre[:1]])], 'preopercle bone: free margin = record cover.preop, a strip in front of it')
        ml = self._seam; mh = MO['maxilla_h']; lower, upper = side(ml + [0.004, 0.002]), side(ml + [0.0, mh])
        plate('maxilla', step * 0.6, [(0, np.r_[lower, upper[-1:]])], [(1, np.r_[upper[::-1], lower[:1]])],
              'maxilla bone: record mouth.line + mouth.maxilla_h; free along its lower edge and rear end')
        # lower jaw: each ramus lies between the dentary line (outer, seen from the side) and the mandible's lower edge
        # (inner, seen from below); the two meet at the chin, so from below they read as a V with the throat skin between
        JW = rec.get('jaw') or {}; dn, lo = JW.get('dentary'), JW.get('low'); tip = self.ml[np.argmin(self.ml[:, 0])]
        on = lambda x, y: 0.92 * float(self.z_on(x, y))
        if not dn: dn = [[x, y, on(x, y)] for x, y in zip(np.linspace(tip[0] + 0.001, xj, 5), np.linspace(tip[1] - 0.004, yj, 5))]
        dn = sorted(dn, key=lambda p: p[0])
        if xj > dn[-1][0] + 1e-4: dn = dn + [[xj, yj, max(on(xj, yj), dn[-1][2])]]          # the ramus ends at the jaw joint
        if not lo: lo = [[p[0], 0, 0.5 * p[2] * k / (len(dn) - 1)] for k, p in enumerate(dn)]
        lo = sorted(lo, key=lambda p: p[0]); d_, l_ = np.array(dn, float), np.array(lo, float)
        if len(dn) >= 2 and dn[-1][0] - dn[0][0] > 0.01:
            # the ramus keeps under the lips (two lip thicknesses below the mouth line), or the first loops round the mouth cross
            lip = lambda x: np.interp(x, self.ml[:, 0], self.ml[:, 1] - 0.006, right=1e9)
            xs = np.linspace(d_[0, 0], d_[-1, 0], 16); up = np.c_[xs, self.th_side(xs, np.minimum(np.interp(xs, d_[:, 0], d_[:, 1]), lip(xs)))]
            xl = np.linspace(l_[0, 0], l_[-1, 0], 16); low = np.c_[xl, np.maximum(self.th_below(xl, np.interp(xl, l_[:, 0], l_[:, 2])), np.interp(xl, xs, up[:, 1]))]
            half = 0.5 * np.linalg.norm(self.loft_point(up[:, 0], up[:, 1]) - self.loft_point(low[:, 0], low[:, 1]), axis=1)
            plate('mandible', step * 0.6, [], [(0, np.r_[up, low[::-1], up[:1]])], 'lower jaw rami: record jaw.dentary + jaw.mandibleLow (to the jaw joint), a round ridge between the two lines',
                  ridge=max(float(np.median(half)), PLATE_CHAMFER))
        return out

    def isthmus_th(self, x, room=0.012):
        """the angle nearest the ventral midline that still leaves `room` (SL) of skin to it: on a keeled belly a small |z|
        lies almost on the keel, and the two openings would meet. x: one station or an array of them."""
        xs = np.atleast_1d(np.asarray(x, float)); mid = self.loft_point(xs, np.full(len(xs), np.pi))
        lo, hi = np.full(len(xs), np.pi / 2), np.full(len(xs), np.pi); room = np.minimum(room, 0.5 * self.HW(xs))
        for _ in range(30):
            m = 0.5 * (lo + hi); far = np.linalg.norm(self.loft_point(xs, m) - mid, axis=1) > room; lo, hi = np.where(far, m, lo), np.where(far, hi, m)
        return lo if np.ndim(x) else float(lo[0])

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
        """the dorsal outline lifted over the orbit. Where the eye's circle (plus its skin margin) stands above the record
        outline, the outline clears it, and the lift ends as a swell ORBIT_SWELL times as long as the eye's radius + margin,
        as high as the circle stands out and no higher. An eye under the outline lifts nothing. Toward the snout the swell
        runs no further than the rictus where the mouth lies under the eye (porcupinefish, blenny: an eye that reaches the
        snout; a swell over the lips thickened the upper jaw into the mouth cavity)."""
        E = self.EY; x = np.asarray(x, float); t0 = self._TOP0(x); rr = E["d"] / 2 + self._CLR; dx = x - E['x']
        bump = E['y'] + rr * np.sqrt(np.clip(1 - (dx / rr) ** 2, 0, 1)) - (np.abs(dx) >= rr) * 1.0
        lift = smax(t0, bump, 0.004) - t0
        if self._swell is None: return t0 + lift
        xp, L = self._swell; d2 = x - xp
        w = np.where(d2 < 0, np.clip(xp - self._seam[-1, 0], 0.25 * rr, rr * ORBIT_SWELL), rr * ORBIT_SWELL)
        bell = L * np.clip(1 - (d2 / w) ** 2, 0, 1) ** 2
        return t0 + smax(lift, bell, 0.2 * L)

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
    # a widest point above the middle come from the reference. Width stays the record hw; height stays top/bot (front and
    # top silhouette: SIL2).
    # The boundary is one smooth closed curve: the rows become knots of the polar radius rho(phi) (phi 0 = dorsal edge,
    # pi = ventral edge), are faired by at most SECT_FAIR_TOL, and a C2 spline runs through them with zero slope at both
    # edges, so the two sides meet on the midline without a crease. Straight lines from row to row made a crease at every
    # row (up to 19 deg on the trevally) and a wedge on the midline; the bake wrote them as stripes along the body and dark
    # rims on the back and belly (export r5). The table is looked up with its slope (cubic Hermite, C1). Between stations
    # the shape blends with a smooth step in x (C1: no kink at a station); before the first and after the last it holds.
    SECT_S, SECT_PHI = 513, 361          # DEFAULTS: samples down a traced section (w table) and round its polar boundary

    def _sections(self, S):
        if not S: return None
        S = sorted(S, key=lambda q: q['x']); ss = np.linspace(-1, 1, self.SECT_S); phi = np.linspace(0, np.pi, self.SECT_PHI)
        pd = np.linspace(0, np.pi, 4001); X, W, RHO, DRHO, moved = [], [], [], [], 0.0
        for q in S:
            w = np.array(q['w'], float); w = w[np.argsort(w[:, 0])]; s_ = np.clip(w[:, 0], -1, 1); w_ = np.clip(w[:, 1], 0, None)
            w_ = w_ / max(w_.max(), 1e-9); on = (w_ > 1e-6) & (np.abs(s_) < 1)   # the rows at s = -1 and +1 are the edges themselves: the poles below
            ang, rad = np.arctan2(w_[on], s_[on]), np.hypot(w_[on], s_[on]); o = np.argsort(ang); ang, rad = ang[o], rad[o]
            keep = np.r_[True, np.diff(ang) > 1e-6] & (ang > 1e-6) & (ang < np.pi - 1e-6); ang, rad = ang[keep], rad[keep]
            ph = np.r_[0, ang, np.pi]; r0 = np.r_[1, rad, 1]                 # the section closes on the midline at both edges
            r1 = fair(ph, r0, SECT_FAIR_TOL, SECT_FAIR_LEN, hold=(0, -1)); moved = max(moved, float(np.abs(r1 - r0).max()))
            r = CubicSpline(ph, r1, bc_type=((1, 0.0), (1, 0.0)))(pd)
            u, v = r * np.cos(pd), r * np.sin(pd); v = v / v.max()           # widest point = the record half-width
            a2 = np.arctan2(v, u); a2[0], a2[-1] = 0.0, np.pi; a2 = np.maximum.accumulate(a2); k2 = np.r_[True, np.diff(a2) > 1e-9]
            c2 = CubicSpline(a2[k2], np.hypot(u, v)[k2], bc_type=((1, 0.0), (1, 0.0)))
            o = np.argsort(u); X.append(q['x']); W.append(np.interp(ss, u[o], v[o])); RHO.append(c2(phi)); DRHO.append(c2(phi, 1))
            W[-1][0] = W[-1][-1] = 0.0
        self.SECT_FAIRED = moved
        return dict(x=np.array(X), s=ss, w=np.array(W), phi=phi, rho=np.array(RHO), drho=np.array(DRHO))

    def _station(self, x):
        """the two stations round x and the smooth-step weight of the second (0 at and before the first, 1 at the second)."""
        X = self.SECT['x']; k = np.clip(np.searchsorted(X, x) - 1, 0, len(X) - 1); k1 = np.minimum(k + 1, len(X) - 1)
        t = np.clip((x - X[k]) / np.maximum(X[k1] - X[k], 1e-9), 0, 1)
        return k, k1, t * t * (3 - 2 * t)

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
        S = self.SECT; x, u, v = np.broadcast_arrays(np.asarray(x, float), u, v); N = len(S['phi']); h = np.pi / (N - 1)
        ph = np.arctan2(np.abs(v), u) / h; i = np.clip(ph.astype(int), 0, N - 2); f = ph - i
        h00, h10, h01, h11 = (1 + 2 * f) * (1 - f) ** 2, f * (1 - f) ** 2, f * f * (3 - 2 * f), f * f * (f - 1)
        at = lambda k: h00 * S['rho'][k, i] + h10 * h * S['drho'][k, i] + h01 * S['rho'][k, i + 1] + h11 * h * S['drho'][k, i + 1]
        if len(S['x']) == 1: rb = at(np.zeros(i.shape, int))
        else: k, k1, t = self._station(x); rb = (1 - t) * at(k) + t * at(k1)
        return np.hypot(u, v) / np.maximum(rb, 1e-9)

    def _wnorm0(self, x, s):
        """wnorm of the bare loft."""
        if self.SECT is None:
            nn = np.where(s > 0, self.NUP(x), self.NLO(x))
            return np.maximum(1 - np.minimum(np.abs(s), 1) ** nn, 1e-6) ** (1 / nn)
        S = self.SECT; x, s = np.broadcast_arrays(np.asarray(x, float), s)
        q = (np.clip(s, -1, 1) + 1) / 2 * (len(S['s']) - 1); i = np.clip(q.astype(int), 0, len(S['s']) - 2); f = q - i
        # in the cell at each edge the boundary closes on the midline as a round (width ~ root of the depth under the edge), which
        # is how the polar table closes it; a straight line there was a tent, up to 20 x narrower than the polar boundary a hair
        # under the edge, and the swelling round a high eye, a factor on the width, made a lid of the difference
        end = (i == 0) | (i == len(S['s']) - 2)
        at = lambda k: np.where(end, np.sqrt(S['w'][k, i] ** 2 * (1 - f) + S['w'][k, i + 1] ** 2 * f), S['w'][k, i] * (1 - f) + S['w'][k, i + 1] * f)
        k, k1, t = self._station(x); return np.maximum((1 - t) * at(k) + t * at(k1), 1e-6)

    def sec(self, x):
        t, b, w = self.TOP(x), self.BOT(x), self.HW(x)
        return (t + b) / 2, (t - b) / 2, w

    def loft_point(self, x, th):
        """exact point of the record loft at body coords (x, theta)."""
        c, a, b = self.sec(x); dy, dz = np.cos(th), np.sin(th) / self._asp(x, a, b)
        rho = 1 / self._rnorm0(x, dy / a, dz / b)
        if self._orb is not None:
            # the swelling round the eye (and the head's turn) change the section's width by a factor that changes with height,
            # so the skin along a ray from the section centre is a root, looked for between the narrowest the turn may make
            # the section and the section's own limits (the outline's height, the half-width plus the bulge). Only sections
            # the swelling reaches are searched (PR #109 searched the whole head: form + cage took twice as long)
            x_, rho = np.broadcast_arrays(np.asarray(x, float), rho); rho = rho.copy()
            m = np.abs(x_ - self.ex) < self._orb['far'] * self.er
            if m.any():
                bc = lambda v: np.broadcast_to(v, x_.shape)[m]
                xm, u, v, cm, am, bm = x_[m], bc(dy / a), bc(dz / b), bc(c), bc(a), bc(b)
                lo = 0.9 * HOLD_K[0] * rho[m]; hi = np.minimum(1 / np.maximum(np.abs(u), 1e-9), (max(HOLD_K[1], 1) + self._orb['past'] / bm) / np.maximum(np.abs(v), 1e-9))
                hi = np.maximum(hi, lo)
                # and only rays that pass within the swelling's reach of the eye, between those two ends
                y0, y1 = cm + lo * u * am, cm + hi * u * am; gap = np.maximum(np.minimum(y0, y1) - self.eyy, self.eyy - np.maximum(y0, y1))
                k = np.hypot(xm - self.ex, np.maximum(gap, 0)) < self._orb['far'] * self.er
                if k.any():
                    xk, uk, vk, cab = xm[k], u[k], v[k], (cm[k], am[k], bm[k]); r_ = rho[m]
                    r_[k] = self._ray_root(lambda t: t * self._rnorm0(xk, uk, vk / self._tissue(xk, t * uk, cab)) - 1, lo[k], hi[k]); rho[m] = r_
        return np.stack([x, c + rho * dy, rho * dz], -1)

    @staticmethod
    def _ray_root(f, lo, hi, n=LOFT_ITERS):
        """root of f (negative inside the skin, positive outside) between lo and hi: false position with the Illinois
        halving, which lands within 1e-6 of the bracket in LOFT_ITERS steps where plain bisection took 26 (the cage
        build asks for some thousands of single points, and the 26 steps were most of its time)."""
        flo, fhi = f(lo), f(hi); side = np.zeros(np.shape(lo), int)
        # no crossing inside the bracket: the skin is at the end bisection would have run to
        lo, hi = np.where(fhi <= 0, hi, lo), np.where(flo >= 0, lo, hi); t = 0.5 * (lo + hi)
        for _ in range(n):
            d = fhi - flo; ok = (flo < 0) & (fhi > 0) & (np.abs(d) > 1e-15)
            t = np.where(ok, (lo * fhi - hi * flo) / np.where(ok, d, 1), 0.5 * (lo + hi))
            ft = f(t); out = ft > 0
            # Illinois: an end that stays twice running is halved in weight, so neither end can stall
            flo, fhi = np.where(out, np.where(side == 1, 0.5 * flo, flo), ft), np.where(out, ft, np.where(side == -1, 0.5 * fhi, fhi))
            lo, hi, side = np.where(out, lo, t), np.where(out, t, hi), np.where(out, 1, -1)
            hit = np.abs(ft) < 1e-12; lo, hi = np.where(hit, t, lo), np.where(hit, t, hi)   # found: stay there
        return t

    def theta_of(self, x, y, z):
        c, a, b = self.sec(x); return np.arctan2(z * self._asp(x, a, b), y - c) % (2 * np.pi)

    def _asp(self, x, a, b):
        """what theta measures. In the head it is the plain angle round the section centre (the eye, mouth, gill and cavity
        are laid out in it). In the trunk it is the angle in the section scaled to a circle (z x height / width), so even
        steps of theta are even steps round the section's own shape: on a deep narrow body plain angles put most columns
        on the flat of the flank and left one cell from the back's midline to 3 % SL down the side; the ridge inside that
        cell is rounder than the cell can show, and the bake wrote the difference as a dark rim along the back and belly
        (export r5: normal_z_p1 0.60). The factor goes from 1 to height / width with a smooth step behind the gill cover.
        A point and its theta still lie on one ray from the section centre, so theta_of and loft_point stay inverses."""
        t = np.clip((np.asarray(x, float) - self.ring_x - COL_HEAD) / COL_BLEND, 0, 1); return (a / b) ** (t * t * (3 - 2 * t))

    def z_on(self, x, y):
        """flank z of the loft at side-view point (x, y)."""
        c, a_, b_ = self.sec(x); return b_ * self.wnorm(x, (y - c) / a_)

    def radial(self, p):
        """unit direction from the section centre line to p, in the section plane."""
        c = float(self.sec(np.clip(p[0], 0, self.XEND))[0]); v = np.array([0.0, p[1] - c, p[2]]); n = np.linalg.norm(v)
        return v / n if n > 1e-9 else np.array([0.0, 1.0, 0.0])

    SD_CHUNK = 100_000   # points per pass, so memory stays bounded at any map resolution

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

    # ---- the orbit: the eye's aim, the swelling round its rim, and the head held to the scans' line.
    # Structure rule: the globe sits in the skull, so its aim is its own and not the skin's. Real eye discs aim 7.5 deg below
    # the skin round them and stay near level (AIM_UP, AIM_FWD), while the skin's facing follows the head. Taking the aim
    # from the eye rim's plane on the loft (0.5.x) pointed every eye up, most on round heads with high eyes, where a
    # loft section falls away above the eye (HP-HEAD-ORBIT-1, Gary 28 Nov).
    # The scans' heads fall away round an eye that bulges sideways: so the head keeps the record's sections, and the eye's
    # plane (square to the aim, never under the loft at the rim) is carried by a swelling round the rim that has run out
    # where the scans' skin ring begins (SWELL_REACH). The skin ring is then the head's own; where it lies off the scans'
    # line by more than RING_HOLD the head is turned back to it (narrower above the eye and wider below, or the reverse).
    # All of it only changes a section's width, in z, and never past the record half-width + the bulge, so the side and
    # top outlines stay the record's.
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

    def bare_skin_ring(self):
        """skin_ring of the record's own loft: the swelling round the eye and the head's turn set aside."""
        orb = self._orb
        try: self._orb = None; return self.skin_ring()
        finally: self._orb = orb

    _RIM_N = 360         # DEFAULT: points round the rim where the swelling's height is tabled

    def _orbit(self):
        """sets the eye's aim, the swelling round the rim and the head's turn (self._orb); returns the numbers for the
        build report."""
        EY, er = self.EY, self.er
        up0, fwd0, _, h = self.skin_ring()                                          # the bare loft's skin ring
        a = EY.get('aim') or {}
        ph = np.linspace(0, 2 * np.pi, self._RIM_N, endpoint=False); qx, qy = self.ex + er * np.cos(ph), self.eyy + er * np.sin(ph)
        qx = np.clip(qx, 0, self.XEND)
        past = EY['bulge'] * er                                                     # the bulge may show in the top view, no more
        sink = EY['groove'] * er                                                    # the eye's edge may lie this far under the skin: the furrow
        I = {}

        def build(tau, slope=SWELL_SLOPE):
            """the head turned by tau, the eye's plane on it, the swelling to that plane; returns the built skin ring."""
            self._orb = dict(tau=tau, D=None, past=past, far=HOLD_REACH if tau else 0.0)
            I['up_h'], I['fwd_h'], _, _ = self.skin_ring()                           # the head as held, before the swelling
            up = a['up'] if a.get('up') is not None else float(np.clip(I['up_h'] - AIM_BELOW_SKIN, *AIM_UP))
            fwd = a['fwd'] if a.get('fwd') is not None else float(np.clip(I['fwd_h'], *AIM_FWD))
            z1 = self.z_on(qx, qy)

            def plane(up_, fwd_):
                cu, su, cf, sf = np.cos(np.radians(up_)), np.sin(np.radians(up_)), np.cos(np.radians(fwd_)), np.sin(np.radians(fwd_))
                n = np.array([-sf * cu, su, cf * cu]); t = (n[0] * (qx - self.ex) + n[1] * (qy - self.eyy)) / n[2]
                # the plane touches the loft at the rim's outermost point and stands proud of it by the periorbital bulge
                return n, t, float(np.max(z1 + t)), float(np.min(self.HW(qx) + past + t))
            n, t, touch, room = plane(up, fwd); lam = 0.0
            if room + sink < touch:
                # the eye's plane cannot lie inside the record's top view at this aim (an eye on the round of a blunt snout):
                # a small misfit is the furrow round the eye; past that the top view is measured and the aim is a rule, so the aim
                # gives way toward the skin's own facing
                lo, hi = 0.0, 1.0; u_, f_ = up, fwd
                for _ in range(12):
                    lam = 0.5 * (lo + hi); n, t, touch, room = plane(u_ + lam * (I['up_h'] - u_), f_ + lam * (I['fwd_h'] - f_))
                    lo, hi = (lo, lam) if room + sink >= touch else (lam, hi)
                lam = hi; up, fwd = u_ + lam * (I['up_h'] - u_), f_ + lam * (I['fwd_h'] - f_); n, t, touch, room = plane(up, fwd)
            zd = min(touch + past / n[2], max(room, touch - sink))
            # the swelling's height over the held loft at each point of the rim (under 0: the furrow): it sets each spoke's run
            D = np.r_[zd - t - z1, zd - t[0] - z1[0]]
            # each spoke's run: SWELL_REACH, or longer where the swelling is high, so it is no steeper than `slope` (a smoothstep's
            # steepest slope is 1.5 x rise / run)
            # (taken smoothly between its two limits: a run with a corner in it round the rim is a crease along that spoke)
            L = np.hypot(1.5 * D / er / slope, SWELL_REACH - 1); L = L / (1 + (L / (SWELL_MAX - 1)) ** 6) ** (1 / 6)
            self._orb.update(n=n, zd=zd, D=D, L=L, far=max(self._orb['far'], 1 + float(L.max())))
            I.update(up=up, fwd=fwd, lam=lam, z1=z1, t=t, zd=zd)
            return self.skin_ring()[0]

        tgt = EY['skin_up'] if EY.get('skin_up') is not None else RING_LINE[0] + RING_LINE[1] * h
        # the swelling may fill the skin ring down to the band's lower edge, no further (a head the record itself draws
        # flatter than that keeps the record's ring): the gentlest run-out that allows
        build(0.0, 1e9); floor = min(self.skin_ring()[0], float(tgt) - RING_HOLD) - 0.05; slope = SWELL_SLOPE; ring = build(0.0)
        if ring < floor:
            lo, hi = SWELL_SLOPE, 16 * SWELL_SLOPE
            for _ in range(8):
                slope = np.sqrt(lo * hi); lo, hi = (lo, slope) if build(0.0, slope) >= floor else (slope, hi)
            slope = hi; ring = build(0.0, slope)
            if ring < floor: slope = 1e9; ring = build(0.0, slope)
        tau = 0.0; goal = min(ring, float(tgt) + RING_HOLD)
        if abs(ring - goal) > 1e-6:
            # the head's turn that brings the built ring to the band's edge: secant steps (the ring turns almost evenly with tau)
            t0_, r0_, t1_ = 0.0, ring, 0.02 * np.sign(ring - goal)
            for _ in range(8):
                r1_ = build(t1_, slope)
                if abs(r1_ - goal) < 0.02 or abs(r1_ - r0_) < 1e-9: break
                t0_, r0_, t1_ = t1_, r1_, t1_ + (goal - r1_) * (t1_ - t0_) / (r1_ - r0_)
            tau = float(t1_); ring = build(tau, slope)
        fwd1 = self.skin_ring()[1]; rim = self.z_on(qx, qy)
        return dict(aim_up_deg=round(I['up'], 1), aim_fwd_deg=round(I['fwd'], 1), bare_skin_up_deg=round(up0, 1), bare_skin_fwd_deg=round(fwd0, 1),
                    skin_up_deg=round(ring, 1), skin_fwd_deg=round(fwd1, 1), eye_height=round(h, 3), ring_target_deg=round(float(tgt), 1),
                    head_turn=round(tau, 4), swell_slope=round(min(float(slope), 99.0), 2), swell_reach_R=round(1 + float(self._orb['L'].max()), 2), held_skin_up_deg=round(I['up_h'], 1),
                    tissue_max_R=round(float((rim - I['z1']).max()) / er, 2), aim_gave_way=round(I['lam'], 2),
                    rim_off_plane_R=round(float(np.abs(rim - (I['zd'] - I['t'])).max()) / er, 3),
                    aim_source=EY.get('aim_source', 'skin ring - AIM_BELOW_SKIN, kept in AIM_UP / AIM_FWD (DEFAULT)'))

    def eye_axis(self, sg=1):
        """unit aim of the eye on side sg (+1 left)."""
        n = self._orb['n']; return np.array([n[0], n[1], sg * n[2]])

    def _tissue(self, x, u, cab=None):
        """how far the head's turn and the swelling round the eye change the section's width at (x, u = normalised
        height): 1 = the bare loft. Inside the rim the skin lies on the eye's plane. From the rim out the swelling keeps the
        height it has at the rim point on the same spoke and runs out by SWELL_REACH eye radii. Under both lies the head's
        turn (tau: the share of its width a section loses per eye radius above the eye and gains below), whole out to
        the skin ring's outer edge and run out at HOLD_REACH. cab: the sections' (centre, half-height, half-width) at x, if
        the caller has them (loft_point asks for the same sections a dozen times over)."""
        O = self._orb
        if O is None: return 1.0
        # beyond the outline's height the widening is that of the outline's edge, so the distance field stays whole
        # (cut off there, a point a hair over the roof read as far outside a section with no width)
        x, u = np.broadcast_arrays(np.asarray(x, float), np.clip(np.asarray(u, float), -U_EDGE, U_EDGE)); k = np.ones(x.shape)
        er, ex, eyy = self.er, self.ex, self.eyy
        m = np.abs(x - ex) < O['far'] * er
        if not m.any(): return k
        xm, um = x[m], u[m]; c, a, b = self.sec(xm) if cab is None else (np.broadcast_to(v_, x.shape)[m] for v_ in cab); dx, dy = xm - ex, c + a * um - eyy; rho = np.hypot(dx, dy) / er
        near = rho < O['far']
        if not near.any(): return k
        kk = np.ones(xm.shape)
        xm, um, dx, dy, rho, a, b = xm[near], um[near], dx[near], dy[near], rho[near], a[near], b[near]
        z0 = b * self._wnorm0(xm, um); z = z0
        if O['tau']:
            s_ = np.clip((HOLD_REACH - rho) / (HOLD_REACH - RING_R[1]), 0, 1)
            z = z0 * np.clip(1 - O['tau'] * dy / er * s_ * s_ * (3 - 2 * s_), *HOLD_K)
        if O['D'] is not None:
            f = (np.arctan2(dy, dx) % (2 * np.pi)) / (2 * np.pi) * self._RIM_N; i = np.minimum(f.astype(int), self._RIM_N - 1); f = f - i
            L = O['L'][i] * (1 - f) + O['L'][i + 1] * f; s_ = np.clip((1 + L - rho) / L, 0, 1); n = O['n']
            # the skin leaves the eye's plane at the rim with the plane's own slope (no crease at the rim) and has joined
            # the loft at the end of the spoke's run
            z = z + s_ * s_ * (3 - 2 * s_) * (O['zd'] - (n[0] * dx + n[1] * dy) / n[2] - z)
        # the swelling is skull and the skin over it: it ends at the upper jaw (above the maxilla, record mouth.maxilla_h over
        # the mouth line), or the lips and the mouth cavity under them part company (porcupinefish: an eye that reaches the snout)
        ys, _ = self._seam_y(xm); xr = self._seam[-1, 0]
        # (above the maxilla or behind the rictus: the two are joined as 1 - (1 - a)(1 - b), the greater of them had a corner)
        s_ = np.clip((dy + eyy - ys - self.MO['maxilla_h']) / er, 0, 1); s2 = np.clip((xm - xr) / er, 0, 1)
        s_ = 1 - (1 - s_ * s_ * (3 - 2 * s_)) * (1 - s2 * s2 * (3 - 2 * s2))
        # out: inside the half-width + bulge, under a roof with a round edge (ROOF_EDGE), so a section still closes on the midline
        # (a soft limit: the swelling's height e in the room r it has goes to e / (1 + (e / r)^6)^(1/6), which leaves a low
        # swelling as it is and a high one without a corner)
        z = z0 + s_ * (z - z0)
        d = a * (1 - np.abs(um)) / (er * np.hypot(ROOF_EDGE, np.maximum(rho - 1, 0)))           # depth under the outline, in roof edges
        e = np.maximum(z - z0, 0) * np.sqrt(1 - (1 - np.minimum(d, 1)) ** 2); r = np.maximum(b + O['past'] - z0, 1e-9)
        e = e / (1 + (e / r) ** 6) ** (1 / 6)
        z = np.minimum(z, z0) + e
        kk[near] = np.maximum(z, HOLD_K[0] * z0) / z0; k[m] = kk
        return k

    # ---- level 1: bone plates, orbit ring, mouth cleft
    def plates(self, P, d0=None):
        """bone over the bare body at P: (thickness (SL), plate number (1-based, 0 = none), share of that plate's step 0..1).
        A function of where P's foot lies on the skin (x, theta) only, so the solid has one surface over every point."""
        P = np.asarray(P, float); sh = P.shape[:-1]; Q = P.reshape(-1, 3); d0 = self.sd_body(Q) if d0 is None else np.asarray(d0).reshape(-1)
        T = np.zeros(len(Q)); ids = np.zeros(len(Q), np.int8); W = np.zeros(len(Q))
        if not self.PLATES: return T.reshape(sh), ids.reshape(sh), W.reshape(sh)
        x0 = min(p['poly'][:, 0].min() for p in self.PLATES); x1 = max(p['poly'][:, 0].max() for p in self.PLATES)
        m = np.where((np.abs(d0) < max(PLATE_SHELL, 2 * max(p['step'] for p in self.PLATES))) & (Q[:, 0] >= x0) & (Q[:, 0] <= x1))[0]
        if not len(m): return T.reshape(sh), ids.reshape(sh), W.reshape(sh)
        x = Q[m, 0]; th = self.theta_of(x, Q[m, 1], np.abs(Q[m, 2])); S = self.loft_point(x, th); acc = np.zeros(len(m)); best = np.zeros(len(m))
        for k, p in enumerate(self.PLATES):
            poly = p['poly']; c = np.where((x >= poly[:, 0].min()) & (x <= poly[:, 0].max()) & (th >= poly[:, 1].min()) & (th <= poly[:, 1].max()))[0]
            if not len(c): continue
            c = c[poly_sd2(x[c], th[c], poly) < 0]
            if not len(c): continue
            db = line_d(S[c], p['buried'])
            if p['free']:
                df = line_d(S[c], p['free']); t = sstep(df / p['bevel']) * sstep(db / (db + df + 1e-12))
            else:
                t = sstep(db / p['ridge'])
            acc[c] += (p['step'] * t) ** PLATE_P
            new = t > best[c]; ids[m[c[new]]] = k + 1; best[c[new]] = t[new]
        T[m] = acc ** (1 / PLATE_P); W[m] = best; ids[W < 1e-3] = 0
        return T.reshape(sh), ids.reshape(sh), W.reshape(sh)

    def sd_full(self, P, parts=False, cleft=True):
        XEND, HW, EY = self.XEND, self.HW, self.EY
        d0 = self.sd_body(P); T, ids, _ = self.plates(P, d0); d = d0 - T - SKIN_OVER
        x, y, z = P[..., 0], P[..., 1], P[..., 2]
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
        return [dict(region=p['name'], source=p['source'] + f"; free margin bevelled over {p['bevel'] * 100:.2f} % SL" if p['free'] else p['source']) for p in self.PLATES] + [
            dict(region='orbit ring', source='circumorbital bone ring: record skeleton.eye.orbitR'),
            dict(region='mouth cleft', source='gape between jaws: record mouth.line'),
            dict(region='eye aim', source=f"{self.ORBIT['aim_source']}: {self.ORBIT['aim_up_deg']} deg up, {self.ORBIT['aim_fwd_deg']} deg forward "
                                          f"(bare loft skin ring {self.ORBIT['bare_skin_up_deg']} up, {self.ORBIT['bare_skin_fwd_deg']} forward)"),
            dict(region='swelling round the eye', source=f"eye plane square to the aim, proud by record eye.bulge, furrow to record eye.groove; the skin leaves it at the rim and has joined the loft "
                                                         f"{SWELL_REACH:g} to {self.ORBIT['swell_reach_R']} eye radii out (DEFAULT SWELL_REACH, SWELL_SLOPE, SWELL_MAX); up to {self.ORBIT['tissue_max_R']} eye radii high at the rim"),
            dict(region='head round the eye', source=f"record sections; skin ring {self.ORBIT['skin_up_deg']} deg up (bare loft {self.ORBIT['bare_skin_up_deg']}), scans' line {self.ORBIT['ring_target_deg']} "
                                                     f"(DEFAULT RING_LINE, or record skeleton.eye.skin_up); head turn {self.ORBIT['head_turn']} (0 = the ring lies no more than {RING_HOLD:g} deg over the line)"),
            dict(region='body mass', source='record outline top/bot/hw/nUp/nLo loft; half-width knots faired over '
                                            f'{HW_FAIR_LEN * 100:g} % SL, by at most {HW_FAIR_TOL * 100:g} % SL (DEFAULTS; moved {self.HW_FAIRED * 100:.3f} % SL)'
                                            + (f', traced section rows by at most {SECT_FAIR_TOL * 100:g} % (DEFAULT; moved {self.SECT_FAIRED * 100:.2f} %)' if self.SECT is not None else '')
                                            + '; lifted over the orbit, and carried round the mouth line '
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
