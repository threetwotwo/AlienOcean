"""Gill openings: the record cover's free edge bends one template ring onto it; that ring is cut along the edge into a slit
whose cover flap (A, over and behind) overlaps the body lip (B, tucked under). From the slit a flat passage (Hermite rows,
relaxed) runs inward to a hole in the cavity side wall: water can pass from the mouth out through the gills.
"""
import numpy as np
from ..form import edge_x

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
    G.info = None; G.ring_dx = lambda i, j: 0.0
    if len(cols) < 3:      # small gill opening (puffers: a short slit in front of the pectoral): at least 3 columns round its centre
        jc = int(np.argmin(np.abs(yj[1:NT // 2] - 0.5 * (ylo + yhi)))) + 1
        cols = [j for j in (jc - 1, jc, jc + 1) if 1 <= j < NT // 2]
    if len(cols) < 3: return
    j_top, j_bot = min(cols), max(cols)
    if j_bot - j_top > 14: j_bot = j_top + 14
    G.info = dict(i=i_g, top=j_top, bot=j_bot, nj=j_bot - j_top)
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


def build_slits(B):
    """cut each slit and build its passage to the cavity hole. Writes B.gill.slits."""
    T, form, mesh, M, G = B.T, B.form, B.mesh, B.mouth, B.gill; NT, grid = T.NT, T.grid; verts, vuv = mesh.verts, mesh.vuv
    G.slits = SLITS = []
    if G.info is None: return
    ig, jt, jb = G.info['i'], G.info['top'], G.info['bot']; radial = form.radial
    for sg in (1, -1):
        col = (lambda jj: jj) if sg > 0 else (lambda jj: NT - jj)
        Amap = {}
        for jj in range(jt + 1, jb):
            v = grid[ig, col(jj)]; p = verts[v].copy(); n = radial(p)
            Amap[v] = mesh.add_v(p + n * 0.0010 + np.array([0.0025, 0, 0]), *vuv[v])      # cover flap: over and behind
            verts[v] = p - n * 0.0012                                                     # body lip: tucked under
        prev = {grid[ig - 1, col(jj)] for jj in range(jt, jb + 1)}
        for k, f in enumerate(mesh.faces):     # faces in front of the slit row take the flap copies
            if mesh.ftag[k] == 'body' and any(v in Amap for v in f) and any(v in prev for v in f):
                mesh.faces[k] = [Amap.get(v, v) for v in f]
        S_loop = [grid[ig, col(jt)]] + [Amap[grid[ig, col(jj)]] for jj in range(jt + 1, jb)] + [grid[ig, col(jb)]] + \
                 [grid[ig, col(jj)] for jj in range(jb - 1, jt, -1)]
        c_g, cols = M.HOLES[sg]
        H_loop = [M.CROWS[c_g][k] for k in cols] + [M.CROWS[c_g + 1][k] for k in cols[::-1]]
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
        for _ in range(30):          # relax the inner loops along the loop and between loops
            for k in range(1, TG + 1):
                Q = allr[k]; allr[k] = 0.5 * Q + 0.5 * (0.25 * (np.roll(Q, 1, 0) + np.roll(Q, -1, 0)) + 0.25 * (allr[k - 1] + allr[k + 1]))
        for k in range(1, TG + 1): rows.append([mesh.add_v(p, np.nan, np.nan) for p in allr[k]])
        rows.append(H_loop)
        for a, b in zip(rows[:-1], rows[1:]): mesh.band(a, b, 'gill')
        SLITS.append(dict(side=sg, A=list(Amap.values()), B=list(Amap.keys()), loop=S_loop, rows=rows, hole=H_loop))
