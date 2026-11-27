"""Pose stress tests: open the mouth (gape) and flare the gill covers in steps, and check that the neighbouring parts (lips,
cheeks, eye socket, gill cover, throat floor, cavity) never cross or poke through each other.

Weights come from the cage's own structure, not from paint: the jaw is one field in the side view round the rictus and
the jaw joint (jaw_weights); the gill flap and the cover skin behind the opercle hinge follow the cover. Pivots: record
jaw joint and opercle hinge (or DEFAULT).
The same weights become the jaw and opercle bones in the export.
"""
import math
from collections import defaultdict
import numpy as np


def smooth(t): t = np.clip(t, 0, 1); return t * t * (3 - 2 * t)


SOFTEN_IT = 12      # DEFAULT: neighbour-averaging passes over the structural weights


def soften(C, w, pins, it=SOFTEN_IT):
    """average each free weight with its mesh neighbours, holding the pinned ones. The structural rules (by column, by
    region, by tag) leave steps where two rules meet: a vertex at 1 beside one at 0 folds the face between them once the
    pose is large (the stylized range found these at gape 50 and flare 15). Skinning wants weights that vary smoothly."""
    nb = [[] for _ in range(len(w))]
    for f in C['faces']:
        for a, b in zip(f, f[1:] + f[:1]): nb[a].append(b); nb[b].append(a)
    free = np.array([bool(nb[v]) for v in range(len(w))]); free[list(pins)] = False; fi = np.where(free)[0]
    w = w.copy()
    for _ in range(it): w[fi] = np.array([w[nb[v]].mean() for v in fi])
    return w


HINGE = 3.0                 # DEFAULT: the corner blends over this many times the gap it must take up (gape x rictus-to-joint)
HINGE_MIN = 0.009           # DEFAULT: and never over less than three lip thicknesses (SL)
FAN = 45.0                  # DEFAULT: half-angle of the blend between rictus and joint (deg)
FADE = (30.0, 170.0)        # DEFAULT: the jaw fades out between these angles about the joint, from the jaw line downward (deg)


def jaw_weights(C, V, rec):
    """one field in the side view (x, y), the same for the skin and for the lining under it. The jaw turns about an axis
    across the body, so a field that does not change with z moves the skin and the lining under it together: a wall keeps
    its thickness, and a face folds only where the field itself is too steep. It is built round the two points of the hinge:
      rictus   the upper lip stays (0), the lower lip goes (1), and they blend to 1/2 toward the corner over the length the
               corner has to stretch (the real rictal fold has that much spare skin). A blend by column count was too short
               on a sparse lower lip and too long on a dense one.
      between  rictus and joint the blend is a lens through both points (circle arcs), narrow at both ends
      joint    behind and below the joint the jaw fades out by angle about the joint. A fade by x squeezed the throat
               skin far below the joint: how far a point moves grows with its distance from the joint, an angle does not."""
    O = C['openings']; NT = len(O['mouth_rows'][0]); jr = O['jr']; J = np.array(O['jaw_joint'], float)
    ml = np.array(rec['mouth']['line']); ml = ml[np.argsort(ml[:, 0])]; R = ml[-1]
    u = J - R; d = float(np.linalg.norm(u)); u = u / d; n = np.array([-u[1], u[0]]) * (1 if u[0] > 0 else -1)   # n: skull side
    P = V[:, :2]; a, b = P - R, P - J
    # which side: in front of the rictus the slit divides (lips, their lining and the loops by column: closed lips touch);
    # behind it the line from rictus to joint
    front = a @ u < 0
    up = np.where(front, P[:, 1] >= np.interp(P[:, 0], ml[:, 0], ml[:, 1]), a @ n >= 0)
    for row in O['mouth_rows'][:-1] + O['cavity_rows'][:O.get('mouth_lining_rows', 2)]:
        for j, v in enumerate(row):
            jj = j if j <= NT // 2 else NT - j
            if jj != jr and front[v]: up[v] = jj < jr
    ra, rb = np.linalg.norm(a, axis=1), np.linalg.norm(b, axis=1)
    lens = np.pi - np.arccos(np.clip((a * b).sum(1) / (ra * rb + 1e-15), -1, 1))     # 0 on the segment rictus-joint, pi beyond its ends
    w = smooth(0.5 - np.where(up, lens, -lens) / (2 * np.radians(FAN)))
    w = 0.5 + (w - 0.5) * smooth(ra / max(HINGE * np.radians(rec.get('gape_deg', 30.0)) * d, HINGE_MIN))
    psi = np.degrees(np.arctan2(-(b @ n), -(b @ u))); psi = np.where(psi < -90, psi + 360, psi)    # 0 toward the rictus, 90 below
    w = w * smooth((FADE[1] - psi) / (FADE[1] - FADE[0]))
    for row in O['cavity_rows'][1:O.get('mouth_lining_rows', 2)]: w[row] = w[O['cavity_rows'][0]]    # a lip's lining goes with its lip
    still = set(v for f, t in zip(C['faces'], C['ftag']) if t in ('eye', 'gill') for v in f)
    w[list(still)] = 0.0
    used = np.zeros(len(V), bool); used[[v for f in C['faces'] for v in f]] = True
    return np.where(used, w, 0.0)


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
    eye = set(v for f, t in zip(C['faces'], C['ftag']) if t == 'eye' for v in f)
    inner = set(v for f, t in zip(C['faces'], C['ftag']) if t in ('cavity', 'mouth') for v in f)
    lip = set(v for rows in O.get('gill_rows', []) for v in rows[0] + rows[-1]) - flaps
    for v in eye | inner: w[v] = 0.0
    mid = set(np.where(np.abs(V[:, 2]) < 0.25 * hw)[0].tolist()) - flaps    # left and right swing apart: the midline holds
    w[list(mid)] = 0.0
    return soften(C, w, flaps | lip | eye | inner | mid)              # flap, body lip, cavity hole, eye, mouth, midline stay put


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


def stress(C, V, rec, gape_steps=None, flare_steps=(0, 10, 20), jaw_w=None):
    """gape steps run to the record's real gape (jaw.linkage.gape, DEFAULT 30) in 10 deg steps. Returns per step: crossing triangle pairs (new versus rest), flipped faces, eye rim drift; and the pass flags."""
    if gape_steps is None: g = rec.get('gape_deg', 30.0); gape_steps = sorted(set(list(range(0, int(g), 10)) + [g]))
    T = triangles(C['faces']); n0, p0 = self_intersections(V, T); rest = set(map(tuple, p0))
    def new_pairs(P): return len(set(map(tuple, self_intersections(P, T)[1])) - rest)     # a pair fixed elsewhere hides nothing
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
        P = gape(V, wj, C['openings']['jaw_joint'], deg)
        out['gape'][deg] = dict(new_crossings=new_pairs(P), flipped=int((((normals(P) * N0).sum(1) < 0) & free).sum()),
                                eye_rim_drift_pctSL=round(float(np.abs(P[rims] - V[rims]).max()) * 100, 3) if rims else 0.0)
    for deg in flare_steps:
        P = flare(V, wc, C['openings']['opercle_hinge'], deg, zh)
        out['flare'][deg] = dict(new_crossings=new_pairs(P), flipped=int((((normals(P) * N0).sum(1) < 0) & free).sum()))
    out['GP1_pass'] = all(s['new_crossings'] <= 0 and s['flipped'] == 0 and s['eye_rim_drift_pctSL'] < 0.05 for s in out['gape'].values())
    out['GF1_pass'] = all(s['new_crossings'] <= 0 and s['flipped'] == 0 for s in out['flare'].values())
    out['jaw_weighted_verts'] = int((wj > 0.01).sum()); out['cover_weighted_verts'] = int((wc > 0.01).sum())
    return out


# ---- stylized range (SR1): big poses for art direction and animation, each swept until the first crossing or fold.
# GP1/GF1 above test the real fish. SR1 asks how far past that the cage holds, so an animator or a stylized art direction
# knows the safe range per species, and a rule change that shrinks it shows up on the board. Each target is what this
# species can really do, times a stylized HEADROOM, so no fish is asked for a pose its body could never make (Gary 17:24Z:
# no S-wave for a puffer, no gape past 45 for a small-mouthed reef fish):
#   gape   the record gape (jaw.linkage.gape), capped at 65 deg
#   bend, wave, arch   the muscle strain limit: the inside of a bend shortens by curvature x half-width (half-depth for
#          the arch), and fish muscle shortens at most STRAIN; a C-bend of heading H over the body length Lb has curvature
#          H / Lb, an S-wave of peak heading H has 2 pi H / Lb
#   flare  FLARE_REAL (no record field yet)
#   combo  gape, flare and wave together at 1 / HEADROOM of their targets: the real fish feeding while it swims
# A target under DROP is no test at all and is skipped. A step fails on a new crossing pair, a new fold, or a crush (a
# skin triangle squeezed under CRUSH of its rest area: it pinches on screen). Ladders stop at twice the target.
HEADROOM, STRAIN, FLARE_REAL, GAPE_MAX, DROP, CRUSH = 1.3, 0.3, 23.0, 65.0, 10.0, 0.1      # DEFAULTS of the test
STEP = dict(gape=5, flare=5, bend=15, wave=5, arch=5, combo=10)
CAP = dict(bend=180, wave=60, arch=60)      # past these no fish body goes, however slender (a C-start tops out near 180)
UNIT = dict(gape='deg', flare='deg', bend='deg tail heading', wave='deg peak heading', arch='deg tail heading',
            combo='% of every target at once')


def body_frame(C, rec):
    """the bending part of the body (behind the gill cover, as a fish rig's spine), its length and widest half-width and
    half-depth there, and the axis height at its root."""
    x0 = float(max(p[0] for p in rec['cover']['rear'])); xend = float(C['xend'])
    O = rec['outline']; hw, top, bot = (np.array(O[k]) for k in ('hw', 'top', 'bot')); xs = np.linspace(x0, xend, 50)
    w = float(np.interp(xs, hw[:, 0], hw[:, 1]).max())
    d = float((np.interp(xs, top[:, 0], top[:, 1]) - np.interp(xs, bot[:, 0], bot[:, 1])).max() / 2)
    yc = float(0.5 * (np.interp(x0, top[:, 0], top[:, 1]) + np.interp(x0, bot[:, 0], bot[:, 1])))
    return x0, xend, w, d, yc


def targets(C, rec):
    """per pose: the stylized target, or None where the species could never make the pose (skipped)."""
    x0, xend, w, d, _ = body_frame(C, rec); Lb = xend - x0; deg = np.degrees
    T = dict(gape=min(GAPE_MAX, HEADROOM * rec.get('gape_deg', 30.0)), flare=HEADROOM * FLARE_REAL,
             bend=HEADROOM * deg(STRAIN * Lb / w), wave=HEADROOM * deg(STRAIN * Lb / (2 * np.pi * w)),
             arch=HEADROOM * deg(STRAIN * Lb / d))
    T = {k: min(v, CAP.get(k, 1e9)) for k, v in T.items()}
    T = {k: (float(max(STEP[k], round(v / STEP[k]) * STEP[k])) if v >= DROP else None) for k, v in T.items()}   # on the ladder
    T['combo'] = 80.0                         # about 1 / HEADROOM: every pose at its real size, all at once
    return T


def gape_target(rec): return min(GAPE_MAX, HEADROOM * rec.get('gape_deg', 30.0))


def body_pose(V, x0, xend, phi, plane, yc=0.0):
    """bend the body behind x0 along a centreline whose heading is phi(u) (u = 0 at x0, 1 at the tail end), in the side
    plane ('z': swimming C-bend and S-wave) or the vertical plane ('y': arch about the axis height yc). Cross-sections stay
    square to the centreline, so the inside of a bend compresses as on an animated body. The head in front of x0 is rigid,
    as on a fish rig whose spine starts behind the skull."""
    L = xend - x0; u = np.linspace(0, 1, 801); a = phi(u); am = 0.5 * (a[1:] + a[:-1]); du = np.diff(u) * L
    cx = x0 + np.r_[0, np.cumsum(np.cos(am) * du)]; cs = np.r_[0, np.cumsum(np.sin(am) * du)]
    k = 2 if plane == 'z' else 1; c0 = 0.0 if plane == 'z' else yc
    P = V.copy(); m = V[:, 0] > x0
    uu = (V[m, 0] - x0) / L; past = np.maximum(uu - 1, 0) * L              # beyond the tail end: straight on
    ang = np.interp(uu, u, a); X = np.interp(uu, u, cx) + past * np.cos(a[-1]); S = np.interp(uu, u, cs) + past * np.sin(a[-1])
    off = V[m, k] - c0
    P[m, 0] = X - off * np.sin(ang); P[m, k] = c0 + S + off * np.cos(ang)
    return P


def tri_pairs(T):
    """pairs of triangles sharing an edge."""
    E = defaultdict(list)
    for k, t in enumerate(T.tolist()):
        for i in range(3): E[frozenset((t[i], t[(i + 1) % 3]))].append(k)
    return np.array([p[:2] for p in E.values() if len(p) >= 2], int)


def posers(C, V, rec, jaw_w=None):
    """pose(name, amplitude) for gape, flare, bend, wave, arch and combo (percent of every target at once), and the targets.
    Used by the sweep and by the turnaround sheets, so both show the same poses."""
    wj = jaw_weights(C, V, rec) if jaw_w is None else jaw_w; wc = cover_weights(C, V, rec)
    O = C['openings']; hx, hy = O['opercle_hinge']
    near = np.argsort(np.hypot(V[:, 0] - hx, V[:, 1] - hy) + 10 * (V[:, 2] < 0))[:3]; zh = float(np.abs(V[near, 2]).mean())
    x0, xend, _, _, yc = body_frame(C, rec); TG = targets(C, rec)
    def pose(name, a):
        r = np.radians(a)
        if name == 'gape': return gape(V, wj, O['jaw_joint'], a)
        if name == 'flare': return flare(V, wc, O['opercle_hinge'], a, zh)
        if name == 'bend': return body_pose(V, x0, xend, lambda u: r * u, 'z')
        if name == 'wave': return body_pose(V, x0, xend, lambda u: r * np.sin(2 * np.pi * u), 'z')
        if name == 'arch': return body_pose(V, x0, xend, lambda u: r * u, 'y', yc)
        f = a / 100.0                                                # combo: every pose at once, a fraction of its target
        P = gape(V, wj, O['jaw_joint'], f * (TG['gape'] or 0)); P = flare(P, wc, O['opercle_hinge'], f * (TG['flare'] or 0), zh)
        rw = np.radians(f * (TG['wave'] or 0))
        return body_pose(P, x0, xend, lambda u: rw * np.sin(2 * np.pi * u), 'z')
    return pose, TG


def range_sweep(C, V, rec, jaw_w=None, only=None):
    """per pose: the largest clean amplitude (no new crossing pair, no new fold), the first failing step and what failed,
    and the worst skin squash (smallest triangle area ratio) inside the clean range. A new fold is two neighbouring
    triangles turning past 90 deg that were within 60 deg at rest; it is rotation-free, so a whole bent tail is not a fault."""
    T = triangles(C['faces']); _, p0 = self_intersections(V, T); rest = set(map(tuple, p0))
    hair = set(v for ch in C.get('commissures', []) for v in ch)
    tfree = np.array([not (set(t) & hair) for t in T.tolist()]); PR = tri_pairs(T); PR = PR[tfree[PR[:, 0]] & tfree[PR[:, 1]]]
    def nrm(P):
        n = np.cross(P[T[:, 1]] - P[T[:, 0]], P[T[:, 2]] - P[T[:, 0]]); a = np.linalg.norm(n, axis=1); return n / (a[:, None] + 1e-15), a
    N0, A0 = nrm(V); ok0 = (N0[PR[:, 0]] * N0[PR[:, 1]]).sum(1) > 0.5; big = A0 > np.median(A0) * 0.05
    pose, TG = posers(C, V, rec, jaw_w)
    out = {}
    for name in (only or STEP):
        tg = TG[name]
        if tg is None: out[name] = dict(skipped=f'target under {DROP:g} deg: not a pose this body makes', unit=UNIT[name]); continue
        st = STEP[name]; mx = int(np.ceil(min(2 * tg, GAPE_MAX if name == 'gape' else 1e9) / st) * st)
        clean = 0; fail = None; squash = 1.0
        for a in range(st, mx + 1, st):
            P = pose(name, a); _, pp = self_intersections(P, T); new = len(set(map(tuple, pp)) - rest)
            N, A = nrm(P); folds = int((ok0 & ((N[PR[:, 0]] * N[PR[:, 1]]).sum(1) < 0)).sum())
            sq = float((A[big] / A0[big]).min())
            if new or folds or sq < CRUSH: fail = dict(at=a, new_crossings=new, new_folds=folds, squash=round(sq, 3)); break
            clean = a; squash = min(squash, sq)
        out[name] = dict(safe=clean, max=mx, target=tg, unit=UNIT[name], first_fail=fail, worst_squash=round(squash, 3))
    return out
