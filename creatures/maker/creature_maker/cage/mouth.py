"""Mouth: a real opening. The lip loop follows the record mouth line (upper lip tip to rictus, lower lip back), concentric loops
carry the skin from the lips out to the shared head ring iK, and the lips roll inward into an oval cavity that runs back to
the pharynx (domed end). Gill passages join the cavity through holes in its side wall (gill.py), which makes the throat.

Rules: loops are laid on the snout chart (polar round the mouth tip: no snout pole); corner fan at each rictus (pinned
spoke between the first loop's neighbours, HP-LIPS lesson); shared head ring (ring iK bends forward round the eye, held
back from the lips); each lip column's lining runs straight in to the first oval behind the rictus (upper lip to the
roof, lower lip to the floor, the corner column a hinge line); the pharynx ends in a dome.
"""
import numpy as np
from ..mesh import relax_rings
from . import eye as eye_mod, gill

GAP, TLIP = 0.0025, 0.003          # closed-lip gap and lip thickness (SL)
LIP_MG = 0.008                     # shared head ring: margin behind the lip (SL); the eye margin is eye.margin
NC, ND = 7, 3                      # cavity rings, dome rings
NF = 3                             # rings 1..NF belong to the mouth proper: lip roll, a ring between, first oval T


class SnoutChart:
    """polar chart centred on the mouth tip M0 on the front disc: angle = loft theta, radius = disc radius + surface length
    along the body. Front-disc points have x < 0, meaning -(1 - f) * disc radius (the UV map uses it)."""

    def __init__(self, form, chart, y_m0):
        self.form, self.chart, self.y_m0 = form, chart, y_m0; self.M0 = np.array([0.0, y_m0, 0.0])
        thb = np.linspace(0, 2 * np.pi, 721); pb = form.loft_point(np.zeros(thb.shape), thb)
        self._thb = thb; self._angb = np.unwrap(np.arctan2(pb[:, 2], pb[:, 1] - y_m0))

    def rho0(self, th):
        p = self.form.loft_point(np.zeros(np.shape(th)), th); return np.hypot(p[..., 1] - self.y_m0, p[..., 2])

    def disc_theta(self, y, z):
        """chart angle of a front-disc point = loft theta of the disc rim point on the same ray from the mouth tip."""
        # the table runs from 0 to 2 pi and is looked up as it is. (Taken modulo 2 pi its last entry fell back to 0, the
        # lookup then answered 2 pi for every angle, and the lower lip's tip was charted above the mouth: the first loops
        # under the chin started on the wrong side of the lips.)
        a = np.arctan2(z, y - self.y_m0) % (2 * np.pi); return np.interp(a, self._angb, self._thb)

    def az(self, x, th, f=None):
        x = np.asarray(x, float); th = np.asarray(th, float)
        r = np.where(x > 0, self.rho0(th) + self.chart.len_of(np.maximum(x, 1e-9), th), (1.0 if f is None else f) * self.rho0(th))
        return np.stack([r * np.sin(th), r * np.cos(th)], -1)

    def az_inv(self, XY):
        ch, lp, M0 = self.chart, self.form.loft_point, self.M0
        th = np.arctan2(XY[:, 0], XY[:, 1]) % (2 * np.pi); r = np.hypot(XY[:, 0], XY[:, 1]); r0 = self.rho0(th); L = r - r0
        thm = np.where(th > np.pi, 2 * np.pi - th, th); t = np.clip(np.round(thm / np.pi * (len(ch.ARTH) - 1)).astype(int), 0, len(ch.ARTH) - 1)
        x = np.array([np.interp(l, ch.LEN[:, k], ch.ARCX) for l, k in zip(L, t)])
        P = lp(np.maximum(x, 1e-6), th); f = np.clip(r / np.maximum(r0, 1e-9), 0, 1)
        D = M0 + f[:, None] * (lp(np.zeros(th.shape), th) - M0)
        on = L > 0
        return np.where(on[:, None], P, D), np.where(on, x, -(1 - f) * r0), th


class Mouth:
    pass


TUBE_MG = 0.005    # the cavity tube stays this far inside (SL): the cage skin is faceted and cuts inside the form
IN_MG = 0.0015     # interior surfaces stay at least this far inside the body (SL); thin snouts and puffer cheeks broke it


def keep_inside(form, P, step, it=40):
    """move only the points closer than IN_MG to the skin, by repeated small steps inward, until they clear it."""
    P = P.copy()
    for _ in range(it):
        bad = form.sd_body(P) > -IN_MG
        if not bad.any(): break
        P[bad] = step(P[bad])
    return P


def plan(B):
    """lip loop and the shared head ring, before the template grid is built. Clamps the eye blocks to ring iK.
    Writes B.mouth (ML, x_r, iK, jr, snout chart, lip loop LIP3/LIPX/LIPT/LIPF, XK, XK_EYE_SHORT)."""
    T, form, chart = B.T, B.form, B.chart; NT, XS, TH = T.NT, T.XS, T.TH
    M = B.mouth = Mouth()
    ML = np.array(form.MO['line'], float); ML = ML[np.argsort(ML[:, 0])]; M.ML = ML
    x_r, y_r = ML[-1]; M.x_r = x_r
    iK = M.iK = int(np.searchsorted(XS, x_r + 0.012))      # first ring kept behind the rictus; rings in front become loops
    B.blk = [(max(i0, iK), i1, j0, j1, sg) for (i0, i1, j0, j1, sg) in B.blk]   # ring iK can be the eye patch's front side
    y_m0 = float(np.clip(ML[0, 1], form.BOT(0.0) + 0.002, form.TOP(0.0) - 0.002))     # chart centre: the mouth tip
    S = M.snout = SnoutChart(form, chart, y_m0)
    th_r = float(form.theta_of(x_r, y_r, form.z_on(x_r, y_r)))
    jr = M.jr = int(np.clip(round(th_r / (2 * np.pi / NT)), 2, NT // 2 - 2))
    sl = np.r_[0, np.cumsum(np.linalg.norm(np.diff(ML, axis=0), axis=1))]

    def seam_at(t): return np.array([np.interp(t * sl[-1], sl, ML[:, 0]), np.interp(t * sl[-1], sl, ML[:, 1])])
    LIP3, LIPX, LIPT, LIPF = [], [], [], []           # per column j: 3D point, x (or <0 on the disc), theta, disc fraction
    for j in range(NT):
        sg = 1 if j <= NT // 2 else -1; jj = j if sg > 0 else NT - j
        if jj <= jr: t = jj / jr; off = GAP / 2 * (1 - t ** 2)
        else: t = (NT // 2 - jj) / (NT // 2 - jr); off = -GAP / 2 * (1 - t ** 2)
        u, y = seam_at(t); y = y + off
        if t == 0 or u < 1e-4:    # lip tips sit on the front disc, on the midline
            p = np.array([0.0, y, 0.0]); th = float(S.disc_theta(np.array(y), np.array(0.0))); f = abs(y - y_m0) / float(S.rho0(np.array(th)))
            LIP3.append(p); LIPT.append(th); LIPF.append(f); LIPX.append(-(1 - f) * float(S.rho0(np.array(th))))
        else:
            p = np.array([u, y, sg * float(form.z_on(np.array(u), np.array(y)))]); th = float(form.theta_of(u, y, p[2]))
            LIP3.append(p); LIPT.append(th); LIPF.append(1.0); LIPX.append(u)
    M.LIP3, M.LIPX, M.LIPT, M.LIPF = np.array(LIP3), LIPX, LIPT, LIPF
    # shared head ring (rule): ring iK is both the outer mouth loop and, where the eye is near, the eye patch's front side.
    # In fish the eye often starts in front of the rictus (alfonsino, trevally), so a straight ring would cut through the
    # eye. Per column the ring is pulled forward to where the column first comes within the eye margin of the rim, and held
    # back LIP_MG behind the lip on the same column, so the mouth loops keep room. The distance is taken on the skin along
    # the column itself: comparing chart arcs taken at two different x missed columns that graze the eye, and the ring
    # then cut across it (grouper). If both margins cannot hold they shrink in proportion; the ring never enters the eye
    # (letting the lips win put it inside the rim on a snout-tip eye, blenny).
    XK = np.full(NT, XS[iK]); short = []
    ex, eyy, er = form.ex, form.eyy, form.er; m = eye_mod.margin(form)
    xs = np.linspace(min(T.X0, XS[iK]), XS[iK], 400)
    for jj in range(NT):
        near = eye_mod.col_dist(B, jj, xs, 1 if jj <= NT // 2 else -1) < m
        if not near.any(): continue
        xl = float(xs[max(int(np.argmax(near)) - 1, 0)])                    # last sample in front of the margin
        xlip = LIPX[jj] + LIP_MG
        if xl < xlip:
            short.append(jj)
            P = form.loft_point(xs, np.full(xs.shape, TH[jj])); ins = np.hypot(P[:, 0] - ex, P[:, 1] - eyy) < er
            x_rim = float(xs[max(int(np.argmax(ins)) - 1, 0)]) if ins.any() else XS[iK]
            xl = LIPX[jj] + max(x_rim - LIPX[jj], 0.0) * LIP_MG / (LIP_MG + m) if x_rim < xlip + m else xlip
        XK[jj] = min(XK[jj], xl)
    M.XK, M.XK_EYE_SHORT = XK, short


def build_loops(B):
    """concentric loops from the lip loop out to ring iK on the snout chart. Writes M.LIPV, M.MROWS."""
    T, mesh, M = B.T, B.mesh, B.mouth; NT, TH, grid = T.NT, T.TH, T.grid; S, iK, jr = M.snout, M.iK, M.jr
    M.LIPV = LIPV = [mesh.add_v(p, x, t) for p, x, t in zip(M.LIP3, M.LIPX, M.LIPT)]
    QM = [S.az(np.array(M.LIPX), np.array(M.LIPT), np.array(M.LIPF))]
    KM = max(iK, 3)
    RK = S.az(np.array([mesh.vuv[grid[iK, j]][0] for j in range(NT)]), TH)
    QM += [(1 - k / KM) * QM[0] + (k / KM) * RK for k in range(1, KM)] + [RK]
    # corner fan (HP-LIPS lesson): at each rictus the loops step straight back from the corner along a pinned spoke, so
    # the first loops go round the corner instead of sliding across the slit towards the sparse lower lip
    # the spoke leaves the corner along the slit's outward bisector (a quadratic curve to ring iK), so the first loops
    # wrap round the corner instead of lying over the lip strip (alfonsino: loops crossed the upper lip at the rictus)
    # The spoke is laid twice. First along the slit's own bisector; then, once the loops have relaxed, along the bisector
    # of the first loop's two neighbours of the corner. Upper and lower lip rarely have the same column spacing, so the
    # slit bisector can lie on the chord from the corner to one of those neighbours: a corner triangle with no area, and
    # the lip roll behind it came through the skin at the first degrees of gape (alfonsino: 1.6 deg of margin, now 14)
    jc_ = [jr, NT - jr]
    for aim in (0, 1):
        for jc in jc_:
            Q0, R_ = QM[0][jc], RK[jc]; d0 = Q0 - 0.5 * (QM[0][(jc - 1) % NT] + QM[0][(jc + 1) % NT])
            d0 = d0 / (np.linalg.norm(d0) + 1e-12)
            if aim:
                a, b = QM[1][(jc - 1) % NT] - Q0, QM[1][(jc + 1) % NT] - Q0
                s_ = a / (np.linalg.norm(a) + 1e-12) + b / (np.linalg.norm(b) + 1e-12)
                if np.linalg.norm(s_) > 0.2: d0 = s_ / np.linalg.norm(s_) * np.sign(s_ @ d0 or 1.0)
            Cc = Q0 + d0 * 0.5 * np.linalg.norm(R_ - Q0)
            for k in range(1, KM):
                t = k / KM; QM[k][jc] = (1 - t) ** 2 * Q0 + 2 * t * (1 - t) * Cc + t * t * R_
        relax_rings(QM, 60, pin=jc_)
    B.debug('mouth', QM=np.array(QM))
    MROWS = [LIPV]
    for k in range(1, KM):
        P3, X_, T_ = S.az_inv(QM[k]); MROWS.append([mesh.add_v(p, x, t) for p, x, t in zip(P3, X_, T_)])
    MROWS.append([grid[iK, j] for j in range(NT)])
    for a, b in zip(MROWS[:-1], MROWS[1:]): mesh.band(a, b, 'mouth')
    M.MROWS = MROWS


def build_cavity(B):
    """lip roll, mouth lining in to the first oval, oval rings back to the pharynx, domed end; holes in the side wall where
    the gill passages join. Writes M.CROWS, M.DOME, M.gut, M.HOLES ({side: (cells, loop)}, see gill.holes), M.NF."""
    T, form, mesh, M = B.T, B.form, B.mesh, B.mouth; NT, J = T.NT, T.J; jr, LIP3 = M.jr, M.LIP3
    ex, eyy, er = form.ex, form.eyy, form.er
    x_back = max(B.rec['gill_u'] - 0.03, M.x_r + 0.05)
    x_c0 = float(LIP3[:, 0].mean()) + 0.004; y_l = float(LIP3[:, 1].mean())

    def oval(x):
        c, a_, b_ = form.sec(x); s_ = np.clip((x - x_c0) / (x_back - x_c0), 0, 1); s_ = s_ * s_ * (3 - 2 * s_)
        ym = (1 - s_) * y_l + s_ * (c - 0.12 * a_)          # the pharynx lies low in the head, under the eyes and brain
        hc = 0.32 * a_; top = min(form.TOP(x) - 0.012, eyy - er - 0.008 if abs(x - ex) < er * 1.2 else 9); bot = form.BOT(x) + 0.012
        return ym, max(min(hc, top - ym, ym - bot), 0.003), max(0.48 * b_, 0.004)

    def cav_ring(x, ps=2 * np.pi * np.arange(NT) / NT):
        ym, hc, wc = oval(x)
        R = np.stack([np.full(NT, x), ym + hc * np.cos(ps), wc * np.sin(ps)], -1)
        cen = np.array([x, ym, 0.0])
        return keep_inside(form, R, lambda P: cen + (P - cen) * 0.97)
    # The mouth proper (rule): each lip column runs straight in to its own point on the first oval T, just behind the
    # rictus. The upper lip takes the arc above the rictus height and the lower lip the arc below, so the two linings part
    # at the lips (palate and floor) and the corner column is a hinge line with room on both sides. Before, the rings were
    # spread evenly back to the pharynx: the lining left the lips along the lips, in needle faces under the cheek skin,
    # which folded or crossed the skin at the first degrees of gape (27 of 37 species).
    x_t = min(M.x_r + 2 * TLIP, 0.5 * (M.x_r + x_back)); ym, hc, _ = oval(x_t)
    ps_r = float(np.arccos(np.clip((LIP3[jr, 1] - ym) / hc, -0.8, 0.8)))

    def frac(cols):          # arc-length share along the lip: 0 at the tip, 1 at the corner
        d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(LIP3[cols], axis=0), axis=1))]; return d / d[-1]
    ps = np.zeros(NT); ps_even = 2 * np.pi * np.arange(NT) / NT; ps_even[ps_even > np.pi] -= 2 * np.pi
    for sg in (1, -1):
        up = [j % NT for j in (range(0, jr + 1) if sg > 0 else range(NT, NT - jr - 1, -1))]
        lo = list(range(NT // 2, jr - 1, -1) if sg > 0 else range(NT // 2, NT - jr + 1))
        ps[up] = sg * ps_r * frac(up); ps[lo] = sg * (np.pi - (np.pi - ps_r) * frac(lo))
    ps[NT // 2] = np.pi; TR = cav_ring(x_t, ps)

    def toward_t(P):         # bring lining points inside along their own line to T: the columns keep their order
        P = P.copy()
        for _ in range(40):
            bad = form.sd_body(P) > -IN_MG
            if not bad.any(): break
            P[bad] += 0.1 * (TR[bad] - P[bad])
        return P
    # the roll leaves the lip half-way between straight in and its line to T, so the lining is a lip thickness under the
    # skin. Near the lip tips, where the lip is closer to the axis than a lip is thick, it turns toward T instead (straight
    # in would cross to the other side), and on a very small mouth it is never longer than 0.4 of the way to T.
    D = TR - LIP3; ld = np.linalg.norm(D, axis=1, keepdims=True); cy = form.sec(np.clip(LIP3[:, 0], 0, form.XEND))[0]
    r0 = np.hypot(LIP3[:, 1] - cy, LIP3[:, 2])[:, None]
    D = D / ld - np.array([form.radial(p) for p in LIP3]) * np.clip(r0 / (2 * TLIP), 0, 1)
    lip_in = toward_t(LIP3 + np.minimum(TLIP, 0.4 * ld) * D / np.linalg.norm(D, axis=1, keepdims=True))

    CR = [lip_in] + [toward_t(lip_in + (TR - lip_in) * k / (NF - 1)) for k in range(1, NF - 1)]
    # Behind T the tube runs evenly back to the pharynx; its first ring takes up half the turn from T's columns to even
    # ones. Where the orbit squeezes the tube (a slender head: less than the tube's own height left under the eye), that
    # ring stands far enough back for the gill holes, two rings on, to open behind the orbit: the passage ran through
    # the eye socket (trumpetfish).
    n_ = NC - NF - 1; k_g = NC - 2 - NF - 1         # rings from the first tube ring to the back; of those, to the hole ring
    x_4 = x_t + (x_back - x_t) / (n_ + 1); squeezed = (eyy - er - 0.008) - (form.BOT(ex) + 0.012) < 2 * 0.32 * form.sec(ex)[1]
    if squeezed: x_4 = min(max(x_4, (n_ * (ex + 1.2 * er) - k_g * x_back) / (n_ - k_g)), x_back - 0.01 * n_)
    TUBE = [TR, cav_ring(x_4, 0.5 * (ps + ps_even))] + [cav_ring(x_4 + (x_back - x_4) * k / n_) for k in range(1, n_ + 1)]
    if squeezed: BACK = TUBE[1:]; relax_rings(BACK, 20); TUBE = [TR] + BACK      # the first tube ring holds its place
    else: relax_rings(TUBE, 20)
    # relaxing can carry a ring out through a hollow in the profile, and so can the straight wall between two rings
    # (small mouth, deep throat: rabbitfish). Rings shrink until they and the middle of each wall are inside.
    for _ in range(40):
        ok = True
        for k in range(1, len(TUBE)):
            for Q in (TUBE[k], 0.5 * (TUBE[k - 1] + TUBE[k])):
                bad = form.sd_body(Q) > -TUBE_MG
                if bad.any() and k < len(TUBE) - 1: c = TUBE[k].mean(0); TUBE[k][bad] = c + (TUBE[k][bad] - c) * 0.95; ok = False
        if ok: break
    CR += TUBE
    CROWS = [M.LIPV] + [[mesh.add_v(p, np.nan, np.nan) for p in R_] for R_ in CR]
    # the pharynx ends in a dome (quarter-circle rings), not a flat fan: a flat end is a 90 degree crease
    Rb = cav_ring(x_back); cb = Rb.mean(0); db = 0.5 * min(np.ptp(Rb[:, 1]), np.ptp(Rb[:, 2]))
    DOME = []
    for k in range(1, ND + 1):
        ph_ = k / (ND + 1) * np.pi / 2
        DOME.append([mesh.add_v(cb + (p - cb) * np.cos(ph_) + np.array([db * np.sin(ph_), 0, 0]), np.nan, np.nan) for p in Rb])
    gut = mesh.add_v(cb + np.array([db, 0, 0]), np.nan, np.nan)
    HOLES = gill.holes(B, [np.nan] + [float(R_[:, 0].mean()) for R_ in CR], NC - 2)     # {side: (cells, loop)}, planned with the slit
    hole_cells = set(c for cells, _ in HOLES.values() for c in cells)
    for c_ in range(len(CROWS) - 1):
        for j in range(NT):
            if (c_, j) in hole_cells: continue
            mesh.add_face([CROWS[c_][j], CROWS[c_ + 1][j], CROWS[c_ + 1][J(j + 1)], CROWS[c_][J(j + 1)]], 'cavity')
    for a, b in zip([CROWS[-1]] + DOME[:-1], DOME): mesh.band(a, b, 'cavity')
    mesh.fan(DOME[-1], gut, 'cavity')
    M.CROWS, M.DOME, M.gut, M.HOLES, M.NF = CROWS, DOME, gut, HOLES, NF
