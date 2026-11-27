"""Mouth: a real opening. The lip loop follows the record mouth line (upper lip tip to rictus, lower lip back), concentric loops
carry the skin from the lips out to the shared head ring iK, and the lips roll inward into an oval cavity that runs back to
the pharynx (domed end). Gill passages join the cavity through holes in its side wall (gill.py), which makes the throat.

Rules: loops are laid on the snout chart (polar round the mouth tip: no snout pole); corner fan at each rictus (pinned
straight spoke, HP-LIPS lesson); shared head ring (ring iK bends forward round the eye, held back from the lips); the lip
roll turns inward and forward at the corners; the pharynx ends in a dome.
"""
import numpy as np
from ..mesh import relax_rings
from . import eye as eye_mod

GAP, TLIP = 0.0025, 0.003          # closed-lip gap and lip thickness (SL)
EYE_MG_K, LIP_MG = 0.6, 0.008      # shared head ring: margin in front of the eye rim (x eye radius), behind the lip (SL)
NC, ND = 7, 3                      # cavity rings, dome rings


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
        _angb, _thb = self._angb, self._thb
        a = np.arctan2(z, y - self.y_m0) % (2 * np.pi); return np.interp(a, _angb % (2 * np.pi) if _angb[-1] < 2 * np.pi + 1e-6 else _angb, _thb)

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
    # eye. Per column the ring is pulled forward to keep EYE_MG in front of the eye rim (measured on the unrolled chart) and
    # held back LIP_MG behind the lip on the same column, so the mouth loops keep room. Lips win if both cannot hold.
    XK = np.full(NT, XS[iK]); short = []
    for sg in (1, -1):
        rimc = eye_mod.rim_chart(B, sg); m = float(np.clip(EYE_MG_K * form.er, 0.003, 0.02))
        for j in (range(0, NT // 2 + 1) if sg > 0 else range(NT // 2, NT + 1)):
            jj = j % NT; a = chart.arc_of(np.array([XS[iK]]), TH[[jj]])[0]
            d2 = m ** 2 - (a - rimc[:, 1]) ** 2
            if not (d2 > 0).any(): continue
            Llim = float(np.min(rimc[d2 > 0, 0] - np.sqrt(d2[d2 > 0])))
            lens = chart.len_of(XS, np.full(XS.shape, TH[jj])); xl = float(np.interp(Llim, lens, XS))
            xlip = LIPX[jj] + LIP_MG
            x_new = max(min(XK[jj], xl), xlip)
            if xl < xlip: short.append(jj)
            XK[jj] = x_new
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
    jc_ = [jr, NT - jr]
    for k in range(1, KM):
        for jc in jc_: QM[k][jc] = (1 - k / KM) * QM[0][jc] + (k / KM) * RK[jc]
    relax_rings(QM, 60, pin=jc_)
    B.debug('mouth', QM=np.array(QM))
    MROWS = [LIPV]
    for k in range(1, KM):
        P3, X_, T_ = S.az_inv(QM[k]); MROWS.append([mesh.add_v(p, x, t) for p, x, t in zip(P3, X_, T_)])
    MROWS.append([grid[iK, j] for j in range(NT)])
    for a, b in zip(MROWS[:-1], MROWS[1:]): mesh.band(a, b, 'mouth')
    M.MROWS = MROWS


def build_cavity(B):
    """lip roll, oval cavity rings back to the pharynx, domed end; holes in the side wall where the gill passages join.
    Writes M.CROWS, M.DOME, M.gut, M.HOLES."""
    T, form, mesh, M = B.T, B.form, B.mesh, B.mouth; NT, J = T.NT, T.J; jr, LIP3 = M.jr, M.LIP3
    ex, eyy, er = form.ex, form.eyy, form.er
    x_back = max(B.rec['gill_u'] - 0.03, M.x_r + 0.05)
    # the lip rolls back into the mouth, except at the rictus: the corner is the back-most lip point and the skin loops
    # step back from it (corner fan), so there the roll turns inward and forward into the cheek pocket
    cw = np.array([max(0.0, 1 - min(abs(j - jr), abs(j - (NT - jr))) / 2.5) for j in range(NT)])
    lip_in = np.array([p + np.array([TLIP * (1 - 2 * c), 0, 0]) - (form.radial(p) * TLIP * (0.6 + 0.4 * c) if p[0] > 1e-4 else 0)
                       for p, c in zip(LIP3, cw)])
    x_c0 = float(lip_in[:, 0].mean()) + 0.004; y_l = float(LIP3[:, 1].mean())

    def cav_ring(x):
        c, a_, b_ = form.sec(x); s_ = np.clip((x - x_c0) / (x_back - x_c0), 0, 1); s_ = s_ * s_ * (3 - 2 * s_)
        ym = (1 - s_) * y_l + s_ * (c - 0.12 * a_)          # the pharynx lies low in the head, under the eyes and brain
        hc = 0.32 * a_; top = min(form.TOP(x) - 0.012, eyy - er - 0.008 if abs(x - ex) < er * 1.2 else 9); bot = form.BOT(x) + 0.012
        hc = max(min(hc, top - ym, ym - bot), 0.003); wc = max(0.48 * b_, 0.004)
        ps = 2 * np.pi * np.arange(NT) / NT
        return np.stack([np.full(NT, x), ym + hc * np.cos(ps), wc * np.sin(ps)], -1)
    CROWS = [M.LIPV, [mesh.add_v(p, np.nan, np.nan) for p in lip_in]]
    CR = [lip_in]
    for c_ in range(2, NC + 1):
        x = x_c0 + (x_back - x_c0) * (c_ - 1) / (NC - 1); R_ = cav_ring(x)
        if c_ == 2: R_ = 0.5 * R_ + 0.5 * (lip_in + np.outer(1 - cw, [0.006, 0, 0]))
        CR.append(R_)
    relax_rings(CR, 20)          # even out the slit-to-oval transition behind the lips (it creased near the corners)
    for R_ in CR[1:]: CROWS.append([mesh.add_v(p, np.nan, np.nan) for p in R_])
    # the pharynx ends in a dome (quarter-circle rings), not a flat fan: a flat end is a 90 degree crease
    Rb = cav_ring(x_back); cb = Rb.mean(0); db = 0.5 * min(np.ptp(Rb[:, 1]), np.ptp(Rb[:, 2]))
    DOME = []
    for k in range(1, ND + 1):
        ph_ = k / (ND + 1) * np.pi / 2
        DOME.append([mesh.add_v(cb + (p - cb) * np.cos(ph_) + np.array([db * np.sin(ph_), 0, 0]), np.nan, np.nan) for p in Rb])
    gut = mesh.add_v(cb + np.array([db, 0, 0]), np.nan, np.nan)
    HOLES = {}
    G = B.gill.info
    if G is not None:
        nj = G['nj']; w = nj - 1; c_g = NC - 2
        k0 = int(np.clip(NT // 4 - w // 2, 1, NT // 2 - 1 - w))
        for sg in (1, -1):
            cols = [k0 + m for m in range(w + 1)] if sg > 0 else [NT - (k0 + m) for m in range(w + 1)]
            HOLES[sg] = (c_g, cols)
    hole_cells = set()
    for sg, (c_g, cols) in HOLES.items():
        for m in range(len(cols) - 1):
            a, b = cols[m], cols[m + 1]; hole_cells.add((c_g, min(a, b) if abs(a - b) == 1 else max(a, b)))
    for c_ in range(len(CROWS) - 1):
        for j in range(NT):
            if (c_, j) in hole_cells: continue
            mesh.add_face([CROWS[c_][j], CROWS[c_ + 1][j], CROWS[c_ + 1][J(j + 1)], CROWS[c_][J(j + 1)]], 'cavity')
    for a, b in zip([CROWS[-1]] + DOME[:-1], DOME): mesh.band(a, b, 'cavity')
    mesh.fan(DOME[-1], gut, 'cavity')
    M.CROWS, M.DOME, M.gut, M.HOLES = CROWS, DOME, gut, HOLES
