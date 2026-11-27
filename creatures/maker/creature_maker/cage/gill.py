"""Gill openings: the record cover's free edge bends one template ring onto it; that ring is cut along the edge into a slit
whose cover flap (A, over and behind) overlaps the body lip (B, tucked under). Where the cover has a free membrane the cut
turns the corner and runs forward under the head along one column, bent onto the form's gill V (form.vedge): seen from
below the two openings converge on the isthmus. From the slit a flat passage (Hermite rows, relaxed) runs inward to a hole
in the cavity wall: water can pass from the mouth out through the gills.
"""
import numpy as np
from ..form import edge_x, grad

TG = 4   # passage rows between the slit and the cavity hole


class Gill:
    pass


def plan(B):
    """choose ring i_g and the slit columns; ring_dx bends the rings near i_g onto the cover edge. Writes B.gill."""
    T, form = B.T, B.form; NT, XS, TH = T.NT, T.XS, T.TH; rear = form.rear
    G = B.gill = Gill()
    rr = np.array(rear); ylo, yhi = rr[:, 1].min(), rr[:, 1].max()
    i_g = int(np.argmin(np.abs(XS - np.mean(rr[:, 0]))))
    yj = form.loft_point(np.full(NT, XS[i_g]), TH)[:, 1]
    cols = [j for j in range(1, NT // 2) if ylo <= yj[j] <= yhi]
    G.info = None; G.ring_dx = G.col_dth = lambda i, j: 0.0
    if len(cols) < 3:      # small gill opening (puffers: a short slit in front of the pectoral): at least 3 columns round its centre
        jc = int(np.argmin(np.abs(yj[1:NT // 2] - 0.5 * (ylo + yhi)))) + 1
        cols = [j for j in (jc - 1, jc, jc + 1) if 1 <= j < NT // 2]
    if len(cols) < 3: return
    j_top, j_bot = min(cols), max(cols)
    if j_bot - j_top > 14: j_bot = j_top + 14
    G.info = dict(i=i_g, top=j_top, bot=j_bot, nj=j_bot - j_top, ia=None, ne=j_bot - j_top)
    dx = np.zeros(NT)
    for j in range(NT):
        jj = j if j <= NT // 2 else NT - j
        if j_top - 1 <= jj <= j_bot + 1:
            dx[j] = (edge_x(rear, yj[jj]) - XS[i_g]) * (1.0 if j_top <= jj <= j_bot else 0.5)
    sp = np.diff(XS)[i_g]; W = int(max(3, np.ceil(2.2 * np.abs(dx).max() / sp) + 1))

    def ring_dx(i, j):
        k = abs(i - i_g)
        return 0.0 if k > W else dx[j] * 0.5 * (1 + np.cos(np.pi * k / (W + 1)))
    G.ring_dx = ring_dx
    plan_leg(B, ring_dx)


ECAP = 17          # slit edges per side: the cavity hole has one cell less, and at most 16 fit on one side of a cavity ring
DTH_UP = 6         # columns above the leg that share its bend
HW_MIN = 0.03      # DEFAULT: half-width (SL) under which a head has no room for the ventral lens (trumpetfish, needlefish)


def plan_leg(B, ring_dx):
    """the ventral leg: from the slit's lower end the cut runs forward along column j_bot to ring ia, and col_dth bends
    that column onto the form's gill V. It stops two rings behind the mouth ring (which must stay unbent) and at ECAP."""
    T, form, G = B.T, B.form, B.gill; NT, XS, TH = T.NT, T.XS, T.TH; g = G.info; G.col_dth = lambda i, j: 0.0
    if form.vedge is None: return
    i_g, jc, iK = g['i'], g['bot'], B.mouth.iK
    ia = max(iK + 2, int(np.searchsorted(XS, form.vedge['xa'])), i_g - (ECAP - g['nj']))
    while ia < i_g and form.HW(XS[ia:i_g + 1]).min() < HW_MIN: ia += 1      # a slender head has no room for the lens
    # the leg must run forward past the cavity slot it drains into (its front row, estimated as mouth.build_cavity lays
    # it); a leg cut short of it has its end fold back over its own lining (moorish idol, rabbitfish)
    from .mouth import NC
    x0 = float(B.mouth.LIP3[:, 0].mean()) + 0.007; x_slot = x0 + (max(B.rec['gill_u'] - 0.03, B.mouth.x_r + 0.05) - x0) * (NC - 3) / (NC - 1)
    if i_g - ia < 2 or XS[ia] > x_slot: return
    g['ia'] = ia; g['ne'] = g['nj'] + i_g - ia
    D = np.zeros(T.NU)
    for i in range(ia, i_g + 1):          # angle where the loft is as wide as the V edge, seen from below
        x = XS[i] + ring_dx(i, jc); zt = float(form.vedge_z(x)); lo, hi = np.pi / 2, np.pi
        for _ in range(30):
            m = 0.5 * (lo + hi); lo, hi = (m, hi) if form.loft_point(np.array(x), np.array(m))[2] > zt else (lo, m)
        D[i] = min(0.5 * (lo + hi), form.isthmus_th(x)) - TH[jc]
    for i in range(iK, ia): D[i] = D[ia] * (i - iK) / (ia - iK)                       # fades out to the mouth ring
    for k in (1, 2, 3):
        if i_g + k < T.NU: D[i_g + k] = D[i_g] * 0.5 * (1 + np.cos(np.pi * k / 4))     # and behind the corner

    e_ = [b for b in B.blk if b[4] > 0 and b[0] <= i_g + 3]                        # the eye block's columns stay unbent
    n_up = max(1, min([DTH_UP] + [jc - b[3] for b in e_]))

    def col_dth(i, j):
        jj = j if j <= NT // 2 else NT - j
        w = (NT // 2 - jj) / (NT // 2 - jc) if jj >= jc else max(0.0, 1 - (jc - jj) / n_up)   # the midline holds
        return D[i] * w * (1 if j <= NT // 2 else -1)
    G.col_dth = col_dth


def holes(B, xrow, c_g):
    """the cavity hole of each slit, as (cells, loop of (ring, column)): one cell less than the slit has edges, so the two
    loops match. A side slit gets a slot along cavity band c_g. With a ventral leg the slot reaches the floor edge and
    turns forward, as the slit does, through the bands behind the jaw joint (the floor in front of it moves with the jaw)."""
    g = B.gill.info; NT = B.T.NT; out = {}
    if g is None: return out
    leg = g['ne'] - g['nj']; fit = 0
    x_ap = B.T.XS[g['ia']] if leg else 0.0           # and no further forward than the leg itself runs
    while leg and c_g - 1 - fit >= 2 and xrow[c_g - 1 - fit] >= B.rec['jaw_joint'][0] and xrow[c_g - fit] >= x_ap: fit += 1
    n_col = min(fit, leg); n_ring = g['ne'] - 1 - n_col
    k0 = NT // 2 - 1 - n_ring if leg else int(np.clip(NT // 4 - n_ring // 2, 1, NT // 2 - 1 - n_ring))
    k1 = k0 + n_ring; c_a = c_g - n_col; assert k0 >= 1, (k0, g)
    cells = [(c_g, k) for k in range(k0, k1)] + [(c, k1 - 1) for c in range(c_a, c_g)]
    loop = [(c_g, k) for k in range(k0, k1)] + [(c, k1 - 1) for c in range(c_g - 1, c_a - 1, -1)] + \
           [(c, k1) for c in range(c_a, c_g + 2)] + [(c_g + 1, k) for k in range(k1 - 1, k0 - 1, -1)]
    out[1] = (cells, loop)
    out[-1] = ([(c, NT - k - 1) for c, k in cells], [(c, NT - k) for c, k in loop])
    return out


def build_slits(B):
    """cut each slit and build its passage to the cavity hole. Writes B.gill.slits."""
    T, form, mesh, M, G = B.T, B.form, B.mesh, B.mouth, B.gill; NT, grid = T.NT, T.grid; verts, vuv = mesh.verts, mesh.vuv
    G.slits = SLITS = []
    if G.info is None: return
    ig, jt, jb, ia = (G.info[k] for k in ('i', 'top', 'bot', 'ia')); radial = form.radial
    G.apex = None
    for sg in (1, -1):
        col = (lambda jj: jj) if sg > 0 else (lambda jj: NT - jj)
        path = [(ig, jj) for jj in range(jt, jb + 1)] + ([(i, jb) for i in range(ig - 1, ia - 1, -1)] if ia is not None else [])
        Amap = {}; order = []; under = {}
        for m, (i, jj) in enumerate(path):
            v = grid[i, col(jj)]; p = verts[v].copy(); t = np.zeros(3); leg = jj == jb and ia is not None
            n = grad(form.sd_body, p[None])[0] if leg else radial(p)       # a keeled belly: the radial runs along the skin
            if i == ig: t += [1.0, 0, 0]                                   # side: the flap lies over and behind the body lip
            if leg:                                                        # under the head: over and toward the midline
                d = verts[grid[i, col(jb + 1)]] - p; t += d / (np.linalg.norm(d) + 1e-12)
            t /= np.linalg.norm(t); k = float(np.clip(form.HW(p[0]) / 0.04, 0.3, 1)) if leg else 1.0    # a slender head: smaller lens
            # first passage row under the head, designed: the flap's lining turns back under the flap through the gap over
            # the body lip, the lip's lining goes straight in. Left to the relax the two linings crossed there: the cavity
            # is narrower than the head, so the hole lies inward of the slit, not under the flap.
            q = jb - jj if ia is not None else 9                           # columns from the corner; eases in over 3
            if q < 3: under[v] = (p - k * (t * 0.004 + n * 0.0025), p - n * 0.0052 * k, 1 - q / 3)
            if m in (0, len(path) - 1): continue
            Amap[v] = mesh.add_v(p + k * (n * 0.0010 + t * 0.0025), *vuv[v]); order.append(v)
            verts[v] = p - n * 0.0012 * k                                                     # body lip: tucked under
        # faces on the cover side of the cut take the flap copies: those with no vertex behind or below it
        far = {grid[ig + 1, col(jj)] for jj in range(jt - 1, jb + 2)}
        if ia is not None: far |= {grid[i, col(jb + 1)] for i in range(ia - 1, ig + 2)}
        for k, f in enumerate(mesh.faces):
            if mesh.ftag[k] == 'body' and any(v in Amap for v in f) and not any(v in far for v in f):
                mesh.faces[k] = [Amap.get(v, v) for v in f]
        e0, e1 = grid[path[0][0], col(path[0][1])], grid[path[-1][0], col(path[-1][1])]
        S_loop = [e0] + [Amap[v] for v in order] + [e1] + order[::-1]
        if ia is not None and sg > 0: G.apex = [float(c) for c in verts[e1]]
        H_loop = [M.CROWS[c][k] for c, k in M.HOLES[sg][1]]
        assert len(S_loop) == len(H_loop), (len(S_loop), len(H_loop))
        rows = [S_loop]
        Ps, Ph = np.array([verts[v] for v in S_loop]), np.array([verts[v] for v in H_loop])
        Ns = np.array([radial(p) for p in Ps]); depth = 0.35 * np.linalg.norm(Ps.mean(0) - Ph.mean(0))
        # Hermite path per loop vertex: leaves the slit straight inward (under the flap), arrives at the cavity wall along -radial
        Nh = np.array([radial(p) for p in Ph])
        mids = []
        for k in range(1, TG + 1):
            s_ = k / (TG + 1); h00, h10, h01, h11 = 2*s_**3 - 3*s_**2 + 1, s_**3 - 2*s_**2 + s_, -2*s_**3 + 3*s_**2, s_**3 - s_**2
            mids.append(h00 * Ps + h10 * (-Ns * depth) + h01 * Ph + h11 * (-Nh * depth))
        allr = [Ps] + mids + [Ph]
        base = [e0] + order + [e1] + order[::-1]; nA = len(order) + 1
        wp = np.array([under[v][2] if v in under else 0.0 for v in base])[:, None]
        D1 = np.array([under[v][0 if m <= nA else 1] if v in under else allr[1][m] for m, v in enumerate(base)])   # ends: flap lining
        for _ in range(30):          # relax the inner loops along the loop and between loops
            for k in range(1, TG + 1):
                Q = allr[k]; Qn = 0.5 * Q + 0.5 * (0.25 * (np.roll(Q, 1, 0) + np.roll(Q, -1, 0)) + 0.25 * (allr[k - 1] + allr[k + 1]))
                allr[k] = wp * D1 + (1 - wp) * Qn if k == 1 else Qn
        for k in range(1, TG + 1): allr[k][:, 2] = sg * np.maximum(sg * allr[k][:, 2], 0.0008)    # each passage on its own side (keeled bellies)
        for _ in range(60):          # and inside the body: vertices, and from the second row on edge midpoints too (a
            ok = True                # throat that curves in). The first row lies in the lens by design and is left alone.
            for k in range(1, TG + 1):
                Q = allr[k]
                tests = ((Q, 0),) if k == 1 else ((Q, 0), (0.5 * (Q + np.roll(Q, -1, 0)), 1), (0.5 * (Q + allr[k + 1]), 0), (0.5 * (Q + allr[k - 1]), 0))
                for T_, nxt in tests:
                    bad = form.sd_body(T_) > (-0.001 if k == 1 else -0.0015)
                    if not bad.any(): continue
                    ok = False; step = np.zeros_like(Q); step[bad] = grad(form.sd_body, T_[bad]) * 0.0005
                    Q -= step + (np.roll(step, nxt, 0) if nxt else 0)
            if ok: break
        for k in range(1, TG + 1): rows.append([mesh.add_v(p, np.nan, np.nan) for p in allr[k]])
        rows.append(H_loop)
        for a, b in zip(rows[:-1], rows[1:]): mesh.band(a, b, 'gill')
        turn = [rows[1][m] for m in range(nA + 1) if wp[m, 0] > 0]         # where the flap lining turns back: a designed hairpin
        SLITS.append(dict(side=sg, A=list(Amap.values()), B=list(Amap.keys()), loop=S_loop, rows=rows, hole=H_loop, turn=turn))
