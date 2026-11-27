"""Pose stress tests: open the mouth (gape) and flare the gill covers in steps, and check that the neighbouring parts (lips,
cheeks, eye socket, gill cover, throat floor, cavity) never cross or poke through each other.

Weights come from the cage's own structure, not from paint: the lower lip and the loops below the rictus, the chin and
throat skin in front of the jaw joint and below the mouth line, and the cavity floor follow the lower jaw; the gill flap
and the cover skin behind the opercle hinge follow the cover. Pivots: record jaw joint and opercle hinge (or DEFAULT).
The same weights become the jaw and opercle bones in the export.
"""
import math
from collections import defaultdict
import numpy as np


def smooth(t): t = np.clip(t, 0, 1); return t * t * (3 - 2 * t)


def jaw_weights(C, V, rec):
    O = C['openings']; NT = len(O['mouth_rows'][0]); jr = O['jr']; xj, yj = O['jaw_joint']
    ml = np.array(rec['mouth']['line']); ml = ml[np.argsort(ml[:, 0])]
    L = ml[-1, 0] - ml[0, 0]; h2 = 0.35 * L
    bx = np.r_[ml[:, 0], xj]; by = np.r_[ml[:, 1], yj]          # jaw boundary in the side view: mouth line, then to the joint

    def below(x, y):
        return y < np.interp(x, bx, by)
    back = smooth((xj + 0.5 * h2 - V[:, 0]) / h2)                 # fades out behind the jaw joint
    w = np.where(below(V[:, 0], V[:, 1]), 1.0, 0.0) * back
    # lips and mouth loops: by column (lower lip = columns past the rictus), so the closed lips separate cleanly
    def lower_col(j):      # the corner blends over 2 columns each way, so the commissure stretches instead of pinching
        jj = j if j <= NT // 2 else NT - j
        return float(smooth((jj - jr + 2.5) / 5.0))
    for row in O['mouth_rows'][:-1]:
        for j, v in enumerate(row): w[v] = lower_col(j) * back[v]
    for r, row in enumerate(O['cavity_rows'][:-1]):
        for j, v in enumerate(row):
            if r <= 1: w[v] = lower_col(j) * back[v]               # lip roll follows its lip
            else:
                ps = 2 * math.pi * j / NT                          # cavity ring angle: cos < 0 is the floor
                w[v] = float(smooth(-math.cos(ps) / 0.6 + 0.5)) * back[v]
    eye = set(v for f, t in zip(C['faces'], C['ftag']) if t == 'eye' for v in f)
    gill = set(v for f, t in zip(C['faces'], C['ftag']) if t == 'gill' for v in f)
    w[list(eye | gill)] = 0.0
    return w


def cover_weights(C, V, rec):
    O = C['openings']; hx, hy = O['opercle_hinge']
    rear = np.array(rec['cover']['rear']); preop = np.array(rec['cover']['preop'])
    ylo, yhi = min(rear[:, 1].min(), preop[:, 1].min()), max(rear[:, 1].max(), hy)
    xr = lambda y: np.interp(y, rear[np.argsort(rear[:, 1]), 1], rear[np.argsort(rear[:, 1]), 0])
    xp = lambda y: np.interp(y, preop[np.argsort(preop[:, 1]), 1], preop[np.argsort(preop[:, 1]), 0])
    x, y = V[:, 0], V[:, 1]
    inside = (y > ylo) & (y < yhi) & (x < xr(y) + 1e-4) & (x > xp(y) - 0.01)
    hwt = np.array(rec['outline']['hw']); hw = np.interp(x, hwt[:, 0], hwt[:, 1])
    # the two covers swing apart: weight fades out toward the ventral and dorsal midline, where left meets right
    w = inside * smooth((x - xp(y) + 0.01) / 0.02) * smooth((np.abs(V[:, 2]) - 0.25 * hw) / (0.35 * hw))
    flaps = set(v for s in O['gill_flaps'] for v in s)
    skin = set(v for f, t in zip(C['faces'], C['ftag']) if t in ('body',) for v in f)
    w = np.where([v in skin or v in flaps for v in range(len(V))], w, 0.0)
    for v in flaps: w[v] = 1.0
    for rows in O.get('gill_rows', []):          # the body lip of the slit (under the flap) stays with the body
        for v in rows[0]:
            if v not in flaps: w[v] = 0.0
    # passage rows: the flap side of each row follows the flap, fading to the fixed hole in the cavity wall
    for rows in O.get('gill_rows', []):
        side_A = [k for k, v in enumerate(rows[0]) if v in flaps]
        for r, row in enumerate(rows[1:-1], 1):
            for k in side_A: w[row[k]] = 1.0 - r / (len(rows) - 1)
    return w


def gape(V, w, joint, deg):
    a = math.radians(deg); c, s = math.cos(a), math.sin(a); xj, yj = joint
    dx, dy = V[:, 0] - xj, V[:, 1] - yj
    R = V.copy(); R[:, 0] = xj + c * dx - s * dy; R[:, 1] = yj + s * dx + c * dy
    return V + w[:, None] * (R - V)


def flare(V, w, hinge, deg, zh):
    """each cover swings outward about a vertical axis through the opercle hinge (x, z on the skin at the hinge)."""
    a = math.radians(deg); hx = hinge[0]; P = V.copy()
    for sg in (1, -1):
        m = V[:, 2] * sg > 0; dx = V[m, 0] - hx; dz = V[m, 2] - sg * zh
        c, s = math.cos(a), math.sin(a) * sg
        P[m, 0] = hx + c * dx - s * dz; P[m, 2] = sg * zh + s * dx + c * dz
    return V + w[:, None] * (P - V)


# ---- triangle-triangle intersection (vectorised edge-through-triangle test on grid-hashed candidates)
def triangles(faces):
    T = []
    for f in faces:
        T.append(f[:3])
        if len(f) == 4: T.append([f[0], f[2], f[3]])
    return np.array(T, int)


def _seg_tri(P0, P1, A, B, C):
    e1, e2 = B - A, C - A; d = P1 - P0
    h = np.cross(d, e2); a = (e1 * h).sum(1); ok = np.abs(a) > 1e-14
    f = np.where(ok, 1 / np.where(ok, a, 1), 0); s = P0 - A
    u = f * (s * h).sum(1); q = np.cross(s, e1); v = f * (d * q).sum(1); t = f * (e2 * q).sum(1)
    eps = 1e-9
    return ok & (u > eps) & (v > eps) & (u + v < 1 - eps) & (t > eps) & (t < 1 - eps)


def self_intersections(V, T):
    tv = V[T]; lo, hi = tv.min(1), tv.max(1)
    cell = float(np.median(np.linalg.norm(tv[:, 1] - tv[:, 0], axis=1))) * 2 + 1e-9
    grid = defaultdict(list)
    for k in range(len(T)):
        a = np.floor(lo[k] / cell).astype(int); b = np.floor(hi[k] / cell).astype(int)
        for i in range(a[0], b[0] + 1):
            for j in range(a[1], b[1] + 1):
                for l in range(a[2], b[2] + 1): grid[(i, j, l)].append(k)
    pairs = set()
    for ks in grid.values():
        if len(ks) < 2: continue
        ks = np.array(ks)
        I, J = np.triu_indices(len(ks), 1); pairs.update(zip(ks[I].tolist(), ks[J].tolist()))
    if not pairs: return 0, []
    pr = np.array(sorted(pairs)); a, b = pr[:, 0], pr[:, 1]
    share = (T[a][:, :, None] == T[b][:, None, :]).any((1, 2))
    ov = np.all(lo[a] <= hi[b], 1) & np.all(lo[b] <= hi[a], 1)
    a, b = a[~share & ov], b[~share & ov]
    hit = np.zeros(len(a), bool)
    for X, Y in ((a, b), (b, a)):
        for e in ((0, 1), (1, 2), (2, 0)):
            hit |= _seg_tri(V[T[X, e[0]]], V[T[X, e[1]]], V[T[Y, 0]], V[T[Y, 1]], V[T[Y, 2]])
    return int(hit.sum()), list(zip(a[hit].tolist(), b[hit].tolist()))


def stress(C, V, rec, gape_steps=(0, 10, 20, 30), flare_steps=(0, 10, 20), jaw_w=None):
    """returns per step: crossing triangle pairs (new versus rest), flipped faces, eye rim drift; and the pass flags."""
    T = triangles(C['faces']); n0, _ = self_intersections(V, T)
    def normals(P):
        n = np.cross(P[T[:, 1]] - P[T[:, 0]], P[T[:, 2]] - P[T[:, 0]]); return n / (np.linalg.norm(n, axis=1, keepdims=True) + 1e-15)
    hair = set(v for ch in C.get('commissures', []) for v in ch)
    free = np.array([not (set(t) & hair) for t in T.tolist()])
    N0 = normals(V); rims = [v for r in C['rolls'][2 + len(C.get('junctions', [])):-1] for v in r]
    out = dict(rest_crossings=n0, GP0_pass=n0 == 0, gape={}, flare={})
    wj = jaw_weights(C, V, rec) if jaw_w is None else jaw_w; wc = cover_weights(C, V, rec)
    hx, hy = C['openings']['opercle_hinge']; near = np.argsort(np.hypot(V[:, 0] - hx, V[:, 1] - hy) + 10 * (V[:, 2] < 0))[:3]
    zh = float(np.abs(V[near, 2]).mean())                          # skin z at the hinge
    for deg in gape_steps:
        P = gape(V, wj, C['openings']['jaw_joint'], deg); n, _ = self_intersections(P, T)
        out['gape'][deg] = dict(new_crossings=n - n0, flipped=int((((normals(P) * N0).sum(1) < 0) & free).sum()),
                                eye_rim_drift_pctSL=round(float(np.abs(P[rims] - V[rims]).max()) * 100, 3) if rims else 0.0)
    for deg in flare_steps:
        P = flare(V, wc, C['openings']['opercle_hinge'], deg, zh); n, _ = self_intersections(P, T)
        out['flare'][deg] = dict(new_crossings=n - n0, flipped=int((((normals(P) * N0).sum(1) < 0) & free).sum()))
    out['GP1_pass'] = all(s['new_crossings'] <= 0 and s['flipped'] == 0 and s['eye_rim_drift_pctSL'] < 0.05 for s in out['gape'].values())
    out['GF1_pass'] = all(s['new_crossings'] <= 0 and s['flipped'] == 0 for s in out['flare'].values())
    out['jaw_weighted_verts'] = int((wj > 0.01).sum()); out['cover_weighted_verts'] = int((wc > 0.01).sum())
    return out
