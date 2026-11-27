"""Collision (numpy + scipy): convex hulls of the body's own form (form_mc.npz, the closed signed-distance solid the bake reads),
never of the shipped cage, whose mouth and gill openings would split the hulls.

Why segments along the spine and not a free convex decomposition: a fish body is close to convex at rest, so a concavity-driven
decomposition (CoACD, tried 27 Nov: threshold 0.05 -> 4 hulls, the whole trunk 0.27-0.86 SL in ONE hull) cuts where the surface
dents, not where the body bends. A hull must ride one bone, or the swimming tail leaves its hull behind. So the form is cut at the
spine stations into runs of SPAN bones, each run's hull rides the run's first bone, and neighbours overlap by OVERLAP so the
joints stay covered when the body bends. CoACD stays the tool for rigid assets (tools/collision/).
Measured (check EX5): share of form-interior points inside a hull (coverage, must be >= 0.99) and hull volume over form volume
(excess, must stay <= 1.3 (raw hulls of the trevally: 1.12; 64-point hulls 1.26): a hull much bigger than the body makes contacts the eye can see).
Fins carry no collision: thin, soft, they fold on contact; a body hull is what a diver, a rock or another fish meets.
"""
import numpy as np
from scipy.spatial import ConvexHull

SPAN = 2          # DEFAULT: bones per hull (10 spine bones -> 5 hulls); one bone per hull doubles physics cost for no visible gain
OVERLAP = 0.01    # DEFAULT: SL each hull reaches past its run, so a bent joint keeps no gap
MAX_VERTS = 64    # DEFAULT: points per hull (Jolt and Godot keep convex shapes small; a smooth form's raw hull has thousands)


def hulls(V, F, xs, span=SPAN, overlap=OVERLAP):
    """V, F the form (SL units); xs the spine stations (NB + 1). Returns [(hull verts, hull faces, bone index)]."""
    V = np.asarray(V, float); NB = len(xs) - 1; out = []
    cuts = list(range(0, NB, span)) + [NB]
    for a, b in zip(cuts[:-1], cuts[1:]):
        x0 = -1e9 if a == 0 else xs[a]; x1 = 1e9 if b == NB else xs[b]
        P = V[(V[:, 0] >= x0 - overlap) & (V[:, 0] <= x1 + overlap)]
        if len(P) < 8: continue
        h = ConvexHull(P); P = reduce(P[h.vertices], MAX_VERTS); h = ConvexHull(P); hv = P[h.vertices]; remap = {v: i for i, v in enumerate(h.vertices)}
        hf = np.array([[remap[v] for v in s] for s in h.simplices])
        c = hv.mean(0)                                         # outward winding
        for k, f in enumerate(hf):
            n = np.cross(hv[f[1]] - hv[f[0]], hv[f[2]] - hv[f[0]])
            if n @ (hv[f[0]] - c) < 0: hf[k] = f[::-1]
        out.append((hv, hf, a))   # the run's first bone: a 2-bone run has no middle bone; the overlap covers the second's bend
    return out


def reduce(P, k):
    """at most k hull points: farthest-point sampling on the raw hull's points (keeps the extremes: snout tip, belly, back), then
    each kept point pushed out from the centre by the worst miss among the raw points nearest it, until the reduced hull holds
    every raw point (it never shrinks the body)."""
    if len(P) <= k: return P
    c = P.mean(0); sel = [int(np.argmax(np.linalg.norm(P - c, axis=1)))]; d = np.linalg.norm(P - P[sel[0]], axis=1)
    while len(sel) < k:
        i = int(np.argmax(d)); sel.append(i); d = np.minimum(d, np.linalg.norm(P - P[i], axis=1))
    Q = P[sel].copy()
    for _ in range(40):                                   # each kept point moves out by the worst miss among the raw points nearest it
        h = ConvexHull(Q); out = (P @ h.equations[:, :3].T + h.equations[:, 3]).max(1)
        if out.max() <= 1e-6 * np.ptp(P, 0).max(): break
        near = np.argmin(((P[:, None, :] - Q[None]) ** 2).sum(-1), 1); push = np.zeros(len(Q))
        np.maximum.at(push, near, np.maximum(out, 0))
        dirs = (Q - c) / np.linalg.norm(Q - c, axis=1, keepdims=True); Q = Q + dirs * (push * 1.1)[:, None]
    return Q


def volume(V, F):
    V = np.asarray(V); F = np.asarray(F)
    return float(abs(np.einsum('ij,ij->i', V[F[:, 0]], np.cross(V[F[:, 1]], V[F[:, 2]])).sum()) / 6)


def coverage(form_V, form_F, H, n=6000, seed=0):
    """share of points inside the form that lie inside at least one hull (sampled), and hull volume / form volume."""
    import trimesh
    from scipy.spatial import Delaunay
    rng = np.random.default_rng(seed); lo, hi = form_V.min(0), form_V.max(0)
    tm = trimesh.Trimesh(form_V, form_F, process=True)
    if len(tm.faces) > 20000:                    # the marching-cubes form has ~360k faces: simplify before ray tests (memory)
        import meshoptimizer as mo
        Vf = np.asarray(tm.vertices, np.float32); I = np.asarray(tm.faces, np.uint32).ravel(); d = np.zeros_like(I)
        k = mo.simplify(d, I, Vf, target_index_count=60000, target_error=0.002); f = d[:k].reshape(-1, 3)
        u = np.unique(f); r = -np.ones(len(Vf), int); r[u] = np.arange(len(u)); tm = trimesh.Trimesh(Vf[u].astype(float), r[f], process=False)
    P = rng.uniform(lo, hi, (n, 3)); Pin = P[tm.contains(P)]
    hit = np.zeros(len(Pin), bool)
    for h in H: hit |= Delaunay(h[0]).find_simplex(Pin) >= 0
    return (float(hit.mean()) if len(Pin) else 0.0), sum(volume(h[0], h[1]) for h in H) / max(abs(tm.volume), 1e-12)
