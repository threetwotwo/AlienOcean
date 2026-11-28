"""Finish the cage: one consistent winding over skin + cavity + passages, then snap the skin onto the full form (bone plates,
orbit) with displacement continuity for the rings that must not snap themselves.
"""
from collections import defaultdict, deque
import numpy as np
from ..mesh import INNER_TAGS, vnormals


def orient(B, V):
    """propagate one orientation across shared edges, then flip all if the outer skin faces in (per-region guessing cannot
    orient an inner surface)."""
    T, form, mesh = B.T, B.form, B.mesh; faces = mesh.faces

    def out_(f):
        P = V[f]; n = np.cross(P[1] - P[0], P[-1] - P[0]) if len(f) == 3 else np.cross(P[2] - P[0], P[3] - P[1])
        c = P.mean(0); cc = np.array([c[0], float(form.sec(np.clip(c[0], 0, form.XEND))[0]), 0.0])
        if c[0] <= T.X0 or c[0] >= T.X1: cc = np.array([0.5, cc[1], 0.0])
        return np.dot(n, c - cc)
    EDG = defaultdict(list)
    for k, f in enumerate(faces):
        for i in range(len(f)): EDG[frozenset((f[i], f[(i + 1) % len(f)]))].append(k)
    seen = np.zeros(len(faces), bool)
    for s0 in range(len(faces)):
        if seen[s0]: continue
        seen[s0] = True; dq = deque([s0])
        while dq:
            k = dq.popleft(); f = faces[k]
            for i in range(len(f)):
                a, b = f[i], f[(i + 1) % len(f)]
                for kk in EDG[frozenset((a, b))]:
                    if kk == k or seen[kk]: continue
                    g = faces[kk]
                    if any(g[m] == a and g[(m + 1) % len(g)] == b for m in range(len(g))): faces[kk] = g[::-1]
                    seen[kk] = True; dq.append(kk)
    if np.mean([out_(faces[k]) > 0 for k, t in enumerate(mesh.ftag) if t == 'body']) < 0.5:
        mesh.faces = [f[::-1] for f in faces]
    split_from_corners(B)


def split_from_corners(B):
    """a quad at a slit corner is split by the diagonal from the corner vertex (quads split 0-2). The other diagonal
    skips the corner and leaves a sliver along the closed slit, which flips at the first degrees of opening (anthias:
    the skin over the rictus crossed the lip roll at gape 5)."""
    rank = {}
    for ch in B.commissures:
        for k, v in enumerate(ch): rank.setdefault(v, k)
    # the mouth corner's spoke carries the corner out over the skin: every loop turns back on itself there, and the
    # diagonal that skips the spoke vertex leaves a sliver along the spoke (trevally: 0.9e-6 SL2, flipped at gape 10)
    NT = len(B.mouth.MROWS[0])
    for j in (B.mouth.jr, NT - B.mouth.jr):
        for k, r in enumerate(B.mouth.MROWS): rank.setdefault(int(r[j]), k)
    faces = B.mesh.faces
    for k, f in enumerate(faces):
        c = [(rank[v], i) for i, v in enumerate(f) if v in rank]
        if len(f) == 4 and c and min(c)[1] % 2: faces[k] = f[1:] + f[:1]


SNAP_REACH = 0.008      # DEFAULT: a vertex moves at most 0.8 % SL along its normal (plates and the orbit ring are thinner)
SNAP_SCAN = 16          # DEFAULT: samples per reach when looking for the surface: 0.05 % SL apart, a quarter of the dense
                        # form's cell (0.2 % SL), so nothing the bake can see is stepped over


def snap(P, N, f, reach=SNAP_REACH, it=22):
    """move each point along its normal onto the zero set of f: the outermost crossing within reach, which is the surface
    the bake's rays meet first. (Plain bisection from the point itself was a coin toss wherever the form has a second
    surface above the body, a bone plate's edge or the orbit ring: every template vertex starts exactly on the loft, where
    f is zero to rounding, so the sign of a 1e-18 decided between staying on the body and jumping onto the plate, and it
    fell differently on the two sides of 7 of the 28 traced species: mouth corners up to 0.6 % SL apart.)
    A point with the form above it all the way out goes to +reach, one with none within reach to -reach, as before."""
    ms = np.linspace(reach, -reach, 2 * SNAP_SCAN + 1)                      # from outside in
    ins = np.stack([f(P + N * m) < 0 for m in ms], 1)                       # (points, samples)
    k = np.where(ins.any(1), ins.argmax(1), len(ms) - 1)                    # first sample inside the form
    hi = np.where(k > 0, ms[np.maximum(k - 1, 0)], reach); lo = np.where(ins.any(1), ms[k], -reach)
    for _ in range(it):
        m = (lo + hi) / 2; inside = f(P + N * m[:, None]) < 0
        lo = np.where(inside, m, lo); hi = np.where(inside, hi, m)
    return P + N * ((lo + hi) / 2)[:, None]


def snap_to_form(B, V):
    """local feature snap onto the full form. Interiors and the tail pole do not move. Rims, orbit linings and the first lip
    loop follow the snap of their neighbours (harmonic fill of the offset field), so an unsnapped ring never sits below a
    snapped one (the eye-front fold, round 3). Returns (V, VN)."""
    mesh, M, E = B.mesh, B.mouth, B.eye; faces, ftag = mesh.faces, mesh.ftag
    VN = vnormals(V, faces)
    feat = np.array([True] * len(V)); feat[[B.tail]] = False
    inner = set(v for f, t in zip(faces, ftag) if t in INNER_TAGS for v in f)          # cavity, passages, lips, slit lips
    feat[list(inner)] = False
    for _, t_ in E['tucks']: feat[t_] = False     # the orbit lining lies inside the socket (v0.2.0 had 21 folds from snapping it)
    feat[M.MROWS[1]] = False                      # first loop round the lips: the closed-lip groove would pull it into a fold
    for _, r in E['rims']: feat[r] = False
    free = np.zeros(len(V), bool)
    for _, t_ in E['tucks']: free[t_] = True
    for _, r in E['rims']: free[r] = True
    free[M.MROWS[1]] = True
    # the skin snaps onto the form without its mouth cleft: the cage has its own lips there, and a loop vertex that lay on
    # the mouth line was pulled to the bottom of the cleft, through the lip lining (damsel, barracuda at the rictus)
    D = np.zeros_like(V); D[feat] = snap(V[feat], VN[feat], lambda P: B.form.sd_full(P, cleft=False)) - V[feat]
    nb = [[] for _ in range(len(V))]
    for f in faces:
        for a, b in zip(f, f[1:] + f[:1]): nb[a].append(b); nb[b].append(a)
    fi = np.where(free)[0]
    for _ in range(30):
        D[fi] = np.array([D[nb[v]].mean(0) for v in fi])
    V = V + D
    return V, vnormals(V, faces)
