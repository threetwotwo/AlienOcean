"""Stage 4, UV: the skin unrolls into two islands (left, right) on the arc-length chart at one texel density along and round
the body; the front disc inside the mouth loops unrolls in front of u = 0. Orbit linings are placed in UV space inside
their rim. The interior (cavity, passages) gets its own island. libigl SLIM then evens the density inside each skin island
with every seam and opening pinned (only from a fold-free start).
Input: the built cage. Output: face_uv (per face, per corner), s_uv, uv_relax report.
"""
import numpy as np
from .mesh import SKIN_TAGS, INNER_TAGS


def unwrap(B):
    T, chart, mesh, M = B.T, B.chart, B.mesh, B.mouth; NT = T.NT; V = B.V; faces, ftag = mesh.faces, mesh.ftag
    rho0 = M.snout.rho0
    RHS = float(rho0(np.linspace(0, 2 * np.pi, 73)).max())          # the front disc unrolls in front of u = 0
    # texels per SL, the same along and round the body: as large as fits both the length and the half girth (deep bodies:
    # angelfish, batfish are taller than long per island, so the girth decides)
    S_UV = min(0.94 / (chart.LEN.max() + RHS + 0.02), 0.46 / chart.ARC[:, -1].max())
    GIRTH = chart.ARC[:, -1].max()

    def body_uv(x, th, side):
        x = np.asarray(x, float); th = np.asarray(th, float)
        disc = x < 0; f = np.where(disc, 1 + x / np.maximum(rho0(th), 1e-9), 1.0)
        a = np.where(disc, f * chart.arc_of(np.zeros_like(x), th), chart.arc_of(np.maximum(x, 0), th))
        u = 0.03 + (np.where(disc, x, chart.len_of(np.maximum(x, 0), th)) + RHS) * S_UV
        v0 = 0.985 if side > 0 else 0.485
        return np.stack([u, v0 - a * S_UV], -1)
    assert GIRTH * S_UV < 0.47, ('girth does not fit the island', GIRTH * S_UV)
    XT = np.array(mesh.vuv)
    CROWS, DOME, SLITS = M.CROWS, M.DOME, B.gill.slits; ND = len(DOME)
    CIDX = {v: (c_, j) for c_, row in enumerate(CROWS + DOME) for j, v in enumerate(row)}; CIDX[M.gut] = (len(CROWS) + ND, None)
    TIDX = {}
    for sl_ in SLITS:
        for k, row in enumerate(sl_['rows']):
            for m, v in enumerate(row): TIDX[(sl_['side'], v)] = (k, m, len(row))

    def inner_uv(f, tg):
        """interior island: cavity by (ring, angle); each passage by (row, position) in its own band."""
        if tg == 'cavity':
            cj = [CIDX[v] for v in f]; aa = [j / NT if j is not None else None for _, j in cj]
            known = [a for a in aa if a is not None]
            if max(known) - min(known) > 0.5: aa = [a + 1 if a is not None and a < 0.5 else a for a in aa]
            aa = [a if a is not None else float(np.mean([b for b in aa if b is not None])) for a in aa]
            return np.array([[0.04 + 0.6 * c_ / (len(CROWS) + ND), 0.04 + 0.88 * a] for (c_, _), a in zip(cj, aa)])
        side = 1 if V[f, 2].mean() >= 0 else -1
        km = [TIDX[(side, v)] for v in f]; aa = [m / L_ for _, m, L_ in km]
        if max(aa) - min(aa) > 0.5: aa = [a + 1 if a < 0.5 else a for a in aa]
        u0 = 0.70 if side > 0 else 0.85
        return np.array([[u0 + 0.12 * k / (len(SLITS[0]['rows']) - 1), 0.04 + 0.88 * a / (1 + 1.0 / km[0][2])] for (k, _, _), a in zip(km, aa)])
    nose, tail = M.LIPV[0], B.tail
    face_uv = []
    for f, tg in zip(faces, ftag):
        if tg in INNER_TAGS: face_uv.append(inner_uv(f, tg)); continue
        zc = V[f, 2].mean(); side = 1 if zc >= 0 else -1
        x = XT[f, 0]; th = XT[f, 1].copy()
        if tg == 'cap': th = np.where(np.array(f) == (nose if x.min() < 0.5 else tail), np.pi / 2 if side > 0 else 1.5 * np.pi, th)
        if side > 0: th = np.where(th > np.pi + 1e-6, 0.0 if th.mean() < 1 else np.pi, th)
        else: th = np.where(th < np.pi - 1e-6, np.where(th < 1.0, 2 * np.pi, np.pi), th)
        face_uv.append(body_uv(x, th, side))
    # tuck (lining) UVs: a fixed inset from the rim toward the rim's UV centre, so the lining strip never folds over the rim
    for rim, tuck in B.eye['tucks']:
        ruv = {}
        for f, u in zip(faces, face_uv):
            for v, uu in zip(f, u):
                if v in rim: ruv[v] = uu
        cen = np.mean([ruv[v] for v in rim], 0); tmap = {t: ruv[r] + 0.3 * (cen - ruv[r]) for r, t in zip(rim, tuck)}
        for k, f in enumerate(faces):
            if any(v in tmap for v in f): face_uv[k] = np.array([tmap.get(v, uu) for v, uu in zip(f, face_uv[k])])
    relax = slim_relax(V, faces, ftag, face_uv)
    return dict(face_uv=face_uv, s_uv=S_UV, uv_relax=relax, XT=XT)


def slim_relax(V, faces, ftag, face_uv):
    """libigl SLIM (symmetric Dirichlet) inside each skin island, every island boundary pinned. Edits face_uv in place."""
    import igl
    side_ = np.array([(1 if V[f, 2].mean() >= 0 else -1) if t in SKIN_TAGS else 0 for f, t in zip(faces, ftag)]); out = {}
    for sg in (1, -1):
        fi = np.where(side_ == sg)[0]; key, pv, pu, T, corner = {}, [], [], [], []
        for k in fi:
            ids = []
            for v, u in zip(faces[k], face_uv[k]):
                kk = (v, round(float(u[0]), 6), round(float(u[1]), 6))
                if kk not in key: key[kk] = len(pv); pv.append(V[v]); pu.append(u)
                ids.append(key[kk])
            corner.append(ids); T += [[ids[0], ids[1], ids[2]]] + ([[ids[0], ids[2], ids[3]]] if len(ids) == 4 else [])
        P_, U0, T = np.array(pv), np.array(pu, float), np.array(T, np.int32)
        sa = lambda U: (U[T[:, 1], 0] - U[T[:, 0], 0]) * (U[T[:, 2], 1] - U[T[:, 0], 1]) - (U[T[:, 1], 1] - U[T[:, 0], 1]) * (U[T[:, 2], 0] - U[T[:, 0], 0])
        s0 = np.sign(np.median(sa(U0))); flips0 = int((sa(U0) * s0 <= 0).sum())
        if flips0:   # SLIM needs a fold-free start; keep the chart and report it (the UV fold check fails the build)
            out[sg] = dict(flips_before=flips0, relaxed=False); continue
        bnd = np.unique(igl.boundary_facets(T)[0].ravel()).astype(np.int32)
        data = igl.slim_precompute(np.asfortranarray(P_), np.asfortranarray(T), np.asfortranarray(U0), igl.MappingEnergyType.SYMMETRIC_DIRICHLET,
                                   bnd, np.asfortranarray(U0[bnd]), 1e6)
        U = igl.slim_solve(data, 30); flips1 = int((sa(U) * s0 <= 0).sum())
        if flips1: out[sg] = dict(flips_before=0, flips_after=flips1, relaxed=False); continue
        for k, ids in zip(fi, corner): face_uv[k] = U[ids]
        out[sg] = dict(flips_before=0, flips_after=0, relaxed=True)
    return out
