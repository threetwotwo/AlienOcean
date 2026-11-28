"""Eye: a block of template cells around the record eye, filled with KR rings from the block border to the eye rim, then a
tuck ring that turns the skin into the orbit (a real opening for the eye shells).

Rules: the block takes the columns that pass within the eye margin of the rim, plus one each side; the rings are laid out in
the loft's (x, theta) plane with radial spokes and spaced by length on the skin (no fold possible); the rim lies on the
record eye circle in the side view (EY1); the tuck goes down the eye's axis, scaled to the eye, and stays on its side.
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
    """the eye's aim on side sg (form.Form._orbit): the orbit lining goes down it. Up to 0.5.x this was the rim's own best
    plane on the loft, which leans up wherever the head falls away above the eye."""
    return form.eye_axis(sg)


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


EYE_RULE = 0.8         # DEFAULT: visible eye radius / globe radius, the Species records' own eye rule (skeleton.eye._origin: "R = 0.8 orbitR")
LENS_M = 2.55          # DEFAULT: Matthiessen's ratio, retina to lens centre = 2.55 lens radii (old Eyes work: EYELENSOPT, handover/eyes.md)
WINDOW_GAP = 0.05      # DEFAULT (x eye radius): the cornea clears the lens front by this (old Eyes work: EYEWINDOME 0.05, the flat window)
IRIS_SEAT = 0.10       # DEFAULT (x eye radius): the iris root lies this far under the rim (record eye.groove, the same furrow, where a record has it)
CORNEA_SAG = (0.04, 0.40)   # the cornea's height over its rim, x eye radius: scans show a flat window (centre minus rim 0.04-0.15), and
                            # HP-EYE-PROUD names 0.40 as the limit before the eye reads as goggles (the old builds stood 0.66-0.77)


def optics(EY, r):
    """the eyeball behind a rim of radius r, as heights along the eye's axis over the rim plane (SL). Ported from the old
    Eyes work (HARD_PROBLEMS HP-EYE-PROUD, handover/eyes.md), the look and not the mesh:
      the globe is a sphere of the orbit's radius whose FRONT is shortened by record eye.axial (the retina keeps the back
      half), and the rim is where that front has the visible eye's radius;
      the lens is a ball of record lens_ED, its centre LENS_M lens radii in front of the retina (focus), so it stands
      through the pupil; the pupil (record pupil_ED) is wider than the lens: the dark gap round it is real (aphakic);
      the iris runs from under the rim onto the lens; the cornea is a flat window, as high as the globe's front or the
      lens front plus a gap, whichever is higher."""
    # the globe is at least the visible eye / EYE_RULE: on traced records the visible eye (measured on the photo) can be
    # as large as the bony orbit (FishBase), and a globe no wider than its own window is a hemisphere: goggles
    Rg = max(EY['orbit'], r / EYE_RULE); ax = float(np.clip(EY['axial'], 0.55, 1.0)); af = Rg * (2 * ax - 1)
    eq = -af * np.sqrt(1 - (r / Rg) ** 2)                                   # the globe's equator, under the rim plane
    rL = EY['lens_ED'] * Rg; zL = eq - Rg + LENS_M * rL                      # lens radius and centre
    rp = float(np.clip(EY['pupil_ED'] * Rg if EY.get('pupil') is None else EY['pupil'] * r, 1.02 * rL, 0.8 * r))
    sag = max(af + eq, zL + rL + WINDOW_GAP * r)                             # cornea apex over the rim plane
    seat = -EY.get('groove', IRIS_SEAT) * r
    zi = min(zL + 0.4 * rL, seat)                                            # the pupil's edge: on the lens, never over the rim
    return dict(globe_r=float(Rg), lens_r=float(rL), lens_z=float(zL), pupil_r=rp, iris_z=float(zi), iris_seat=float(seat),
                cornea_sag=float(sag), cornea_sag_R=round(float(sag / r), 3), lens_under_cornea_R=round(float((sag - zL - rL) / r), 3))


def shells(B, V):
    """eye shell placement (iris dome + cornea are made in the exporter), seated on each rim ring and aimed down the eye's
    own axis. The rim lies in the plane square to that axis (the form's periorbital tissue carries the skin out to it), so
    the shells sit true in the opening. Up to 0.5.x the aim was the normal of three rim points: the skin's facing at the
    eye, further up than the skin round it, where real eyes aim below it."""
    eyes = []
    for sg, rim in B.eye['rims']:
        R = V[rim]; ctr = R.mean(0); nrm = B.form.eye_axis(sg)
        eyes.append(dict(c=ctr, n=nrm, r=float(np.linalg.norm(R - ctr, axis=1).mean()),
                         r_side=float(np.linalg.norm((R - ctr)[:, :2], axis=1).mean()), side=sg))
        eyes[-1]['optics'] = optics(B.form.EY, eyes[-1]['r'])
    return eyes
