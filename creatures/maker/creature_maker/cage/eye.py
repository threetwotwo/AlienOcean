"""Eye: a block of template cells around the record eye, filled with KR rings from the block border to the eye rim, then a
tuck ring that turns the skin into the orbit (a real opening for the eye shells).

Rules: the block takes the columns that pass within the eye margin of the rim, plus one each side; the rings are laid out in
the loft's (x, theta) plane with radial spokes and spaced by length on the skin (no fold possible); the rim lies on the
record eye circle in the side view (EY1); the tuck goes down the socket axis, scaled to the eye, and stays on its side.
"""
import numpy as np

KR = 4   # rings from block boundary to the eye rim
TUCK_MAX, TUCK_K = 0.012, 0.6   # orbit lining depth: at most 1.2 % SL, and 0.6 eye radii on small eyes
GAP_LO, GAP_HI = 0.25, 2.0   # spoke angle step round the rim, as a multiple of an even step
MG_K = 0.6   # skin margin kept between the eye rim and the patch border / shared head ring (x eye radius)


def margin(form): return float(np.clip(MG_K * form.er, 0.003, 0.02))


def rim3(form, sg, ph):
    """the record's eye circle (side view) lifted onto side sg of the loft."""
    qx = form.ex + form.er * np.cos(ph); qy = form.eyy + form.er * np.sin(ph)
    return np.stack([qx, qy, sg * form.z_on(qx, qy)], -1)


def socket_axis(form, sg):
    """the rim's best plane normal, pointing out of the body."""
    R = rim3(form, sg, np.linspace(0, 2 * np.pi, 360, endpoint=False)); c3 = R.mean(0)
    ax = np.linalg.svd(R - c3)[2][2]
    return ax if ax @ form.radial(c3) > 0 else -ax


def col_dist(B, j, xs, sg):
    """distance (3D, straight) from template column j, sampled at xs, to the eye rim on side sg. One measure for 'this
    column is near the eye', shared by the block (below) and the head ring (mouth.plan), so they agree."""
    R = rim3(B.form, sg, np.linspace(0, 2 * np.pi, 180, endpoint=False))
    P = B.form.loft_point(xs, np.full(xs.shape, B.T.TH[j % B.T.NT]))
    return np.linalg.norm(P[:, None] - R[None], axis=-1).min(1)


def rim_chart(B, sg, n=720):
    """the record's eye circle (side view) lifted onto side sg of the loft and unrolled into the chart."""
    form, chart = B.form, B.chart; ex, eyy, er = form.ex, form.eyy, form.er
    ph = np.linspace(0, 2 * np.pi, n, endpoint=False); qx = ex + er * np.cos(ph); qy = eyy + er * np.sin(ph)
    zz = form.z_on(qx, qy)
    return chart.chart(qx, form.theta_of(qx, qy, sg * zz))


def blocks(B):
    """eye block in template cells: rings sized on the unrolled chart, columns by distance to the rim on the skin.
    Returns [(i0, i1, j0, j1, side)]."""
    T, form, chart = B.T, B.form, B.chart; NU, NT, XS, TH = T.NU, T.NT, T.XS, T.TH; ex = form.ex
    out = []
    for sgn in (1, -1):
        rim = rim_chart(B, sgn); cen = rim.mean(0); ha, hb = np.ptp(rim, 0) / 2
        the = chart.unchart(cen[None], sgn)[1][0]
        lens = chart.len_of(XS, np.full(XS.shape, the))
        i0 = int(np.searchsorted(lens, cen[0] - 1.6 * ha)) - 1; i1 = int(np.searchsorted(lens, cen[0] + 1.6 * ha))
        # columns: every column that passes within the margin of the rim, plus one each side, so the patch sides are
        # columns the head ring does not bend (a side on a bent column is one long edge across the eye, and a block
        # reaching past them has a front side that runs radially away from the eye: both folded the fill)
        i1 = min(i1, NU - 2); xs = np.linspace(T.X0, XS[i1], 400); m = margin(form)
        js = list(range(0, NT // 2 + 1) if sgn > 0 else range(NT // 2, NT + 1))
        dmin = np.array([col_dist(B, j, xs, sgn).min() for j in js])
        near = [j for j, d in zip(js, dmin) if d < m] or [js[int(np.argmin(dmin))]]
        j0, j1 = max(min(near) - 1, js[0]), min(max(near) + 1, js[-1])
        out.append((max(i0, 1), min(i1, NU - 2), j0, j1, sgn))
    return out


def build_patches(B):
    """fill each eye block. Writes B.eye = dict(rims=[(side, rim)], tucks=[(rim, tuck)], rings=[...])."""
    T, form, mesh = B.T, B.form, B.mesh; grid, J = T.grid, T.J
    ex, eyy, er = form.ex, form.eyy, form.er; verts, vuv = mesh.verts, mesh.vuv
    rims, tucks, all_rings = [], [], []
    for (i0, i1, j0, j1, sg) in B.blk:
        loop = [(i0, j) for j in range(j0, j1)] + [(i, j1) for i in range(i0, i1)] + \
               [(i1, j) for j in range(j1, j0, -1)] +[(i, j0) for i in range(i1, i0, -1)]
        bidx = [grid[i, J(j)] for i, j in loop]
        L = len(bidx)
        # rings are laid out in the loft's own (x, theta) plane, scaled to the skin at the eye. It is the one map of the
        # skin that never folds (side and socket views are edge-on at a blunt snout or the crown; the unrolled chart
        # shears a round eye into a bean on a deep head), so a layout that does not fold there cannot fold on the skin.
        # Spokes are radial: border vertex m joins the rim point seen at its own angle from the eye centre. Matching by
        # arc-length fraction twisted the spokes wherever the eye is off-centre in its block and folded the rings.
        thc = float(form.theta_of(ex, eyy, sg * form.z_on(ex, eyy)))
        sc = float(np.linalg.norm(form.loft_point(np.array(ex), np.array(thc + 1e-3)) - form.loft_point(np.array(ex), np.array(thc - 1e-3)))) / 2e-3
        view = lambda x, th: np.stack([x - ex, sc * (th - thc)], -1)
        bx = np.array([vuv[k][0] for k in bidx]); bt = np.array([2 * np.pi * j / T.NT for _, j in loop]); Pb = view(bx, bt)
        al = np.unwrap(np.arctan2(Pb[:, 1], Pb[:, 0])); order = 1 if al[-1] > al[0] else -1
        # the angular step is kept within GAP_LO..GAP_HI of an even one: a border that doubles back as seen from the eye
        # would cross spokes, and one long border edge would leave a flat on the rim (the eye must stay round, EY1)
        gap = order * np.diff(np.r_[al, al[0] + order * 2 * np.pi])
        for _ in range(8): gap = np.clip(gap, GAP_LO * 2 * np.pi / L, GAP_HI * 2 * np.pi / L); gap *= 2 * np.pi / gap.sum()
        a2 = al[0] + order * np.r_[0, np.cumsum(gap)[:-1]]; al = a2 + (al - a2).mean()
        # rim on the record eye circle in the side view (EY1): the circle point seen at each spoke angle
        phs = np.linspace(0, 2 * np.pi, 1440, endpoint=False); R3 = rim3(form, sg, phs)
        rv = view(R3[:, 0], form.theta_of(R3[:, 0], R3[:, 1], R3[:, 2])); ar = np.arctan2(rv[:, 1], rv[:, 0])
        pick = np.argmin(np.abs((ar[None] - al[:, None] + np.pi) % (2 * np.pi) - np.pi), 1); Rb, Rb3 = rv[pick], R3[pick]

        def lift(Q):
            x = np.clip(Q[..., 0] + ex, 1e-4, form.XEND); th = np.clip(Q[..., 1] / sc + thc, *((0, np.pi) if sg > 0 else (np.pi, 2 * np.pi)))
            return form.loft_point(x, th), x, th
        ts = np.linspace(0, 1, 49)
        S3 = lift(Pb[:, None] + ts[None, :, None] * (Rb - Pb)[:, None])[0]       # (L, samples, 3) spokes on the skin
        # ring k sits at k/KR of the spoke's length on the skin
        cl = np.concatenate([np.zeros((L, 1)), np.cumsum(np.linalg.norm(np.diff(S3, axis=1), axis=-1), axis=1)], 1)
        rings = [bidx]; QS = [Pb]
        for k in range(1, KR + 1):
            tk = np.array([np.interp(k / KR * cl[m, -1], cl[m], ts) for m in range(L)]) if k < KR else np.ones(L)
            Q2 = Pb + tk[:, None] * (Rb - Pb); P3, qx, qt = lift(Q2)
            if k == KR: P3 = Rb3
            QS.append(Q2); rings.append([mesh.add_v(p, x_, t_) for p, x_, t_ in zip(P3, qx, qt)])
        B.debug(f'eye{sg}', QS=np.array(QS))
        # tuck ring: skin turns into the orbit (a short lining) so the eye shell sits inside a real opening
        # it goes down the socket axis, not straight across the body, and its depth follows the eye size and stops
        # short of the midline: a fixed 1.2 % SL step in z carried the tucks of small eyes set high on the head through
        # the midline into each other (sand diver) and into the gill passage (trumpetfish)
        Rm = np.array([verts[k] for k in rings[-1]]); ax = socket_axis(form, sg)
        depth = min(TUCK_MAX, TUCK_K * er, 0.75 * float((sg * Rm[:, 2]).min()) / max(sg * ax[2], 1e-6))
        tuck = []
        for k in rings[-1]:
            p = verts[k] - depth * ax; tuck.append(len(verts)); verts.append(p)
            qx, qy = p[0] + (ex - p[0]) * 0.18, p[1] + (eyy - p[1]) * 0.18      # lining gets its own UV strip inside the rim
            vuv.append((qx, form.theta_of(qx, qy, sg * 0.5 * abs(p[2]) + sg * 1e-4)))
        rings.append(tuck); tucks.append((rings[-2], tuck))
        for a, b in zip(rings[:-1], rings[1:]):
            for m in range(L):
                q = [a[m], b[m], b[(m + 1) % L], a[(m + 1) % L]]
                mesh.add_face(q if order < 0 else q[::-1], 'eye')
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
