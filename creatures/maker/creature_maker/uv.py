"""Stage 5, UV: each half of the skin (left, right) is flattened as it is built, in 3D, into one island: Tutte's map of the
half (fold-free by construction), then libigl SLIM (symmetric Dirichlet, free border) until it stops moving, which takes it
as near to its true shape as a flat sheet allows (one texel density along and round the body). The island is turned to the
side view (head left, back up), and both are packed at one scale: left in the upper half, right in the lower half at the same
place, so the two halves of a symmetric fish use the same texels half a texture apart. The interior (cavity, passages) gets
its own island for its own texture (blender/interior.py); it shares no texel with the skin's bake.

Why not the unrolled (length, arc) chart of the loft (rounds 0.1 to 0.3): its length runs along constant theta, so the
midline of a deep head (domed forehead, steep throat) is much longer than the column next to it, and its mouth loops live
on another chart. On records traced from photos it folded on all 28 species, and SLIM, which needs a fold-free start,
never ran on them.
Input: the built cage. Output: face_uv (per face, per corner), s_uv, uv_relax report.
"""
import numpy as np
from .mesh import SKIN_TAGS, INNER_TAGS

ISLAND_W, ISLAND_H = 0.94, 0.46    # DEFAULT: an island's box in the 0-1 texture: 3 % free at each end, and 4 % between the
                                   # two islands, more than the bake's 16 texel margin on each at 512 and up
U_LEFT, V_TOP = 0.03, {1: 0.985, -1: 0.485}   # DEFAULT: where each island's box starts (left side above, right side below)
SLIM_STEP, SLIM_MAX, SLIM_TOL = 5, 600, 2e-5  # DEFAULT: SLIM runs in steps of 5 until no vertex moves 0.002 % SL per step
                                              # (under a tenth of a texel at 4K). Deep bodies settle in about 100, the
                                              # longest (needlefish) in about 450; 600 stops a mesh that never settles


def unwrap(B):
    T, mesh, M = B.T, B.mesh, B.mouth; NT = T.NT; V = B.V; faces, ftag = mesh.faces, mesh.ftag
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
    face_uv = [inner_uv(f, tg) if tg in INNER_TAGS else None for f, tg in zip(faces, ftag)]
    side_ = np.array([(1 if V[f, 2].mean() >= 0 else -1) if t in SKIN_TAGS else 0 for f, t in zip(faces, ftag)])
    # the flattening sees each gill slit welded shut, flap edge on lip edge: the cover flap lies 0.25 % SL over the body
    # lip by design (gill.py), and flattened as built it would lie over the lip's own texels
    weld = {a: b for sl_ in SLITS for a, b in zip(sl_['A'], sl_['B'])}
    halves = {}
    for sg in (1, -1):
        fi = np.where(side_ == sg)[0]; ids = sorted(set(weld.get(v, v) for k in fi for v in faces[k]))
        loc = {v: i for i, v in enumerate(ids)}; loc.update({a: loc[b] for a, b in weld.items() if b in loc})
        halves[sg] = (fi, loc, V[ids], [[loc[v] for v in faces[k]] for k in fi])
    US, relax = flatten({sg: (h[2], h[3]) for sg, h in halves.items()})
    flat = {sg: (h[0], h[1], US[sg]) for sg, h in halves.items()}
    # one scale for both islands (one texel density over the whole skin), as large as fits the box
    S_UV = min(min(ISLAND_W / np.ptp(U[:, 0]), ISLAND_H / np.ptp(U[:, 1])) for _, _, U in flat.values())
    for sg, (fi, loc, U) in flat.items():
        Up = np.stack([U_LEFT + (U[:, 0] - U[:, 0].min()) * S_UV, V_TOP[sg] - (U[:, 1].max() - U[:, 1]) * S_UV], -1)
        for k in fi: face_uv[k] = Up[[loc[v] for v in faces[k]]]
    return dict(face_uv=face_uv, s_uv=float(S_UV), uv_relax=relax, XT=np.array(mesh.vuv))


def signed_areas(U, T):
    return (U[T[:, 1], 0] - U[T[:, 0], 0]) * (U[T[:, 2], 1] - U[T[:, 0], 1]) - (U[T[:, 1], 1] - U[T[:, 0], 1]) * (U[T[:, 2], 0] - U[T[:, 0], 0])


def tutte(P, polys, T):
    """Tutte's map: the longest border loop (the midlines, the lips and the tail end) goes on a circle by its length on the
    skin, every other vertex to the mean of its neighbours along the cage's own edges. It cannot fold, whatever the shape,
    and openings inside the island (eye) stay open."""
    import igl
    from scipy.sparse import coo_matrix, diags
    from scipy.sparse.linalg import spsolve
    loops = [np.asarray(l) for l in igl.boundary_loop_all(T)]
    lens = [np.linalg.norm(P[l] - P[np.roll(l, -1)], axis=1).sum() for l in loops]; bnd = loops[int(np.argmax(lens))]
    s = np.r_[0, np.cumsum(np.linalg.norm(P[np.roll(bnd, -1)] - P[bnd], axis=1))]; a = 2 * np.pi * s[:-1] / s[-1]
    U = np.zeros((len(P), 2)); U[bnd] = np.stack([np.cos(a), np.sin(a)], -1) * s[-1] / (2 * np.pi)
    E = np.array([(f[i], f[(i + 1) % len(f)]) for f in polys for i in range(len(f))]); E = np.r_[E, E[:, ::-1]]
    A = coo_matrix((np.ones(len(E)), (E[:, 0], E[:, 1])), shape=(len(P), len(P))).tocsr(); A.data[:] = 1.0
    L = (A - diags(np.asarray(A.sum(1)).ravel())).tocsr(); inn = np.setdiff1d(np.arange(len(P)), bnd)
    U[inn] = np.stack([spsolve(L[inn][:, inn].tocsc(), -L[inn][:, bnd] @ U[bnd, c]) for c in (0, 1)], -1)
    return U


def flatten(halves):
    """the halves of the skin {side: (vertices P in SL, faces)} -> ({side: flat coordinates in SL, turned to the side view},
    report). Each quad counts through both of its diagonals (and each triangle twice, to weigh the same), and the halves
    are relaxed in step and stop together, so the left and right halves of a mirror-symmetric cage, whose faces are wound
    opposite ways, come out as mirror twins to a fraction of a texel (split along one diagonal only, they were up to
    10 texels apart at 4K)."""
    import igl
    st, rep = {}, {}
    for sg, (P, polys) in halves.items():
        T = np.array([[f[a] for a in t] for f in polys for t in ([(0, 1, 2)] * 2 if len(f) == 3 else [(0, 1, 2), (0, 2, 3), (0, 1, 3), (1, 2, 3)])])
        U = tutte(P, polys, np.array([[f[a] for a in t] for f in polys for t in ([(0, 1, 2)] if len(f) == 3 else [(0, 1, 2), (0, 2, 3)])]))
        if signed_areas(U, T).sum() < 0: U[:, 0] = -U[:, 0]          # SLIM works on counter-clockwise triangles
        flips0 = int((signed_areas(U, T) <= 0).sum()); rep[sg] = dict(flips_before=flips0, relaxed=False)
        data = None
        if not flips0:          # SLIM needs a fold-free start and keeps it fold-free
            data = igl.slim_precompute(np.asfortranarray(P), np.asfortranarray(T.astype(np.int32)), np.asfortranarray(U),
                                       igl.MappingEnergyType.SYMMETRIC_DIRICHLET, np.zeros(0, np.int32), np.zeros((0, 2)), 0.0)
        st[sg] = [P, T, U, data]
    for it in range(SLIM_STEP, SLIM_MAX + 1, SLIM_STEP):
        move = 0.0
        for h in st.values():
            if h[3] is not None: Un = igl.slim_solve(h[3], SLIM_STEP); move = max(move, float(np.abs(Un - h[2]).max())); h[2] = Un
        if move < SLIM_TOL: break
    out = {}
    for sg, (P, T, U, data) in st.items():
        if data is not None: rep[sg] = dict(flips_before=0, flips_after=int((signed_areas(U, T) <= 0).sum()), relaxed=True, slim_iterations=it)
        # same handedness as the side view of this half: the left island is wound one way and the right the other (P5
        # reads a face against its side), and both lie head left, back up, so the right island is the left one's twin
        XY = P[:, :2]
        if signed_areas(XY, T).sum() < 0: U = U * [-1.0, 1.0]
        # turn to the side view: the rotation (never a mirror) that best lays the island over its own (x, y)
        Uc, Xc = U - U.mean(0), XY - XY.mean(0); W, _, Vt = np.linalg.svd(Uc.T @ Xc)
        out[sg] = Uc @ (W @ np.diag([1.0, np.sign(np.linalg.det(W @ Vt))]) @ Vt)
    return out, rep
