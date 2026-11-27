"""Eye: a block of template cells around the record eye, filled with KR rings from the block border to the eye rim, then a
tuck ring that turns the skin into the orbit (a real opening for the eye shells).

Rules: the patch is sized and laid out on the unrolled chart (near-isometric, so it is round on the skin); the rim lies on the
record eye circle in the side view (EY1); rim vertices are matched to the border by arc-length fraction; rings relax by
sliding only (rings.relax_rings).
"""
import numpy as np
from ..mesh import relax_rings

KR = 4   # rings from block boundary to the eye rim


def rim_chart(B, sg, n=720):
    """the record's eye circle (side view) lifted onto side sg of the loft and unrolled into the chart."""
    form, chart = B.form, B.chart; ex, eyy, er = form.ex, form.eyy, form.er
    ph = np.linspace(0, 2 * np.pi, n, endpoint=False); qx = ex + er * np.cos(ph); qy = eyy + er * np.sin(ph)
    c, a_, b_ = form.sec(qx); dy = qy - c; nn = np.where(dy > 0, form.NUP(qx), form.NLO(qx))
    zz = b_ * np.maximum(1 - np.abs(dy / a_) ** nn, 1e-6) ** (1 / nn)
    return chart.chart(qx, form.theta_of(qx, qy, sg * zz))


def blocks(B):
    """eye block in template cells, sized in the unrolled chart so the square-to-circle patch is square on the skin.
    Returns [(i0, i1, j0, j1, side)]."""
    T, form, chart = B.T, B.form, B.chart; NU, NT, XS, TH = T.NU, T.NT, T.XS, T.TH; ex = form.ex
    out = []
    for sgn in (1, -1):
        rim = rim_chart(B, sgn); cen = rim.mean(0); ha, hb = np.ptp(rim, 0) / 2
        the = chart.unchart(cen[None], sgn)[1][0]
        lens = chart.len_of(XS, np.full(XS.shape, the))
        i0 = int(np.searchsorted(lens, cen[0] - 1.6 * ha)) - 1; i1 = int(np.searchsorted(lens, cen[0] + 1.6 * ha))
        js = np.arange(1, NT // 2) if sgn > 0 else np.arange(NT // 2 + 1, NT)
        arcs = chart.arc_of(np.full(js.shape, ex), TH[js])
        inside = js[np.abs(arcs - cen[1]) <= 1.6 * hb]
        j0, j1 = int(inside.min()) - 1, int(inside.max()) + 1
        if sgn > 0 and rim[:, 1].min() < 1.5 * chart.arc_of(np.array([ex]), TH[[1]])[0]: j0 = 0
        lo, hi = (1, NT // 2 - 1) if sgn > 0 else (NT // 2 + 1, NT - 1)   # off the dorsal/ventral midline columns ...
        a1 = chart.arc_of(np.array([ex]), TH[[1]])[0]
        if rim[:, 1].min() < 1.5 * a1:      # ... unless the eye nearly meets the profile: then the midline itself bounds the patch
            if sgn > 0: lo = 0
            else: hi = NT
        j0, j1 = max(j0, lo), min(j1, hi)
        if sgn < 0 and hi == NT: j1 = NT
        out.append((max(i0, 1), min(i1, NU - 2), j0, j1, sgn))
    return out


def build_patches(B):
    """fill each eye block. Writes B.eye = dict(rims=[(side, rim)], tucks=[(rim, tuck)], rings=[...])."""
    T, form, chart, mesh = B.T, B.form, B.chart, B.mesh; grid, J = T.grid, T.J
    ex, eyy, er = form.ex, form.eyy, form.er; verts, vuv = mesh.verts, mesh.vuv
    rims, tucks, all_rings = [], [], []
    for (i0, i1, j0, j1, sg) in B.blk:
        loop = [(i0, j) for j in range(j0, j1)] + [(i, j1) for i in range(i0, i1)] + \
               [(i1, j) for j in range(j1, j0, -1)] +[(i, j0) for i in range(i1, i0, -1)]
        bidx = [grid[i, J(j)] for i, j in loop]
        L = len(bidx)
        # build the rings on the unrolled surface (chart), then lift to the loft: no folds where the side view is degenerate
        Bc = chart.chart(np.array([vuv[k][0] for k in bidx]), np.array([vuv[k][1] for k in bidx]))
        rimc = rim_chart(B, sg); cen = rimc.mean(0)
        angB = np.unwrap(np.arctan2(Bc[:, 1] - cen[1], Bc[:, 0] - cen[0]))
        order = 1 if angB[-1] - angB[0] > 0 else -1
        # rim vertices: matched to the boundary by arc-length fraction (same spacing ratios on both loops, so the rings
        # between them cannot cross where the boundary bends), starting on the spoke of boundary vertex 0
        angR = np.arctan2(rimc[:, 1] - cen[1], rimc[:, 0] - cen[0])
        k0 = int(np.argmin(np.abs((angR - angB[0] + np.pi) % (2 * np.pi) - np.pi)))
        rl = np.roll(rimc, -k0, 0)
        a_ = np.unwrap(np.arctan2(rl[:, 1] - cen[1], rl[:, 0] - cen[0]))
        if (a_[len(a_) // 4] - a_[0]) * order < 0: rl = np.r_[rl[:1], rl[1:][::-1]]
        rl = np.r_[rl, rl[:1]]; cr = np.r_[0, np.cumsum(np.linalg.norm(np.diff(rl, axis=0), axis=1))]; cr /= cr[-1]
        cb = np.r_[0, np.cumsum(np.linalg.norm(np.diff(np.r_[Bc, Bc[:1]], axis=0), axis=1))]; cb = cb[:-1] / cb[-1]
        R2 = np.stack([np.interp(cb, cr, rl[:, k]) for k in (0, 1)], -1)
        rings = [bidx]
        QS = [Bc] + [(1 - k / KR) * Bc + (k / KR) * R2 for k in range(1, KR)] + [R2]
        relax_rings(QS, 40)
        B.debug(f'eye{sg}', QS=np.array(QS), rimc=rimc, R2=R2)
        for k in range(1, KR + 1):
            qx, qt = chart.unchart(QS[k], sg)
            P3 = form.loft_point(qx, qt)
            if k == KR:   # rim lies exactly on the record eye circle in the side view (EY1)
                ph = np.unwrap(np.arctan2(P3[:, 1] - eyy, P3[:, 0] - ex))
                # rim order must follow the ring order: lifting the chart can jitter the side-view angle backwards near
                # the profile, which zigzagged the rim (folds at the opening). Make it monotone.
                sgn_ = 1 if ph[-1] > ph[0] else -1; ph = sgn_ * np.maximum.accumulate(sgn_ * ph)
                qx2 = ex + er * np.cos(ph); qy2 = eyy + er * np.sin(ph)
                c, a2, b2 = form.sec(qx2); dy = qy2 - c; nn = np.where(dy > 0, form.NUP(qx2), form.NLO(qx2))
                zz = b2 * np.maximum(1 - np.abs(dy / a2) ** nn, 1e-6) ** (1 / nn); P3 = np.stack([qx2, qy2, sg * zz], -1)
                qt = form.theta_of(qx2, qy2, sg * zz); qx = qx2
            rings.append([mesh.add_v(p, x_, t_) for p, x_, t_ in zip(P3, qx, qt)])
        # tuck ring: skin turns into the orbit (a short lining) so the eye shell sits inside a real opening
        tuck = []
        for k in rings[-1]:
            p = verts[k].copy(); p[2] -= sg * 0.012; tuck.append(len(verts)); verts.append(p)
            qx, qy = p[0] + (ex - p[0]) * 0.18, p[1] + (eyy - p[1]) * 0.18      # lining gets its own UV strip inside the rim
            vuv.append((qx, form.theta_of(qx, qy, sg * 0.5 * abs(p[2]) + sg * 1e-4)))
        rings.append(tuck); tucks.append((rings[-2], tuck))
        for a, b in zip(rings[:-1], rings[1:]):
            for m in range(L):
                q = [a[m], b[m], b[(m + 1) % L], a[(m + 1) % L]]
                mesh.add_face(q if -order * sg > 0 else q[::-1], 'eye')  # chart arc runs down, side-view y runs up
        rims.append((sg, rings[-2])); all_rings.append([list(map(int, r)) for r in rings])
    B.eye = dict(rims=rims, tucks=tucks, rings=all_rings)


def shells(B, V):
    """eye shell placement (iris dome + cornea are made in the exporter), seated on each rim ring."""
    eyes = []
    for sg, rim in B.eye['rims']:
        R = V[rim]; ctr = R.mean(0); nrm = np.cross(R[len(R) // 4] - R[0], R[len(R) // 2] - R[0]); nrm /= np.linalg.norm(nrm)
        if nrm[2] * sg < 0: nrm = -nrm
        eyes.append(dict(c=ctr, n=nrm, r=float(np.linalg.norm(R - ctr, axis=1).mean()),
                         r_side=float(np.linalg.norm((R - ctr)[:, :2], axis=1).mean()), side=sg))
    return eyes
