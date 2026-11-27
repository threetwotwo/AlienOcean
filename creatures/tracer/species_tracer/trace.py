"""Photo trace -> record frame. A trace (alien-ocean photo trace, the shared tracer's output: plans/text_species/tools/autotrace.py)
holds landmarks and silhouette edge pieces in percent of the photo. This module turns them into curves in the record frame.

Record frame (the same as parts_from_trace.Frame, so old fields stay comparable): u runs along the line from the snout landmark
(upper jaw tip) to the caudal base landmark (end of SL), scaled so that line is the record's SL; y is perpendicular to it, up
positive; the snout tip sits at (0, 0).

Body edge rule (photo only): the silhouette's own pixels give the edge wherever the body edge is free. Under a fin base the edge is
hidden by the fin, so it is BRIDGED: through the fin-base points read on the same photo where there are any (monotone cubic), else
by a convex arc between the two free pieces (end slopes from those pieces), which is an ESTIMATE when the gap is long. Nothing from another species or a template is used (WHOLE CREATURE rule). Bridged spans are reported.
"""
import numpy as np

BRIDGE_DSLOPE = 0.8
BASE_GAP = 0.10       # share of SL: the widest stretch of hidden body edge that may be bridged without a measured base point
CORNER_DEG = 35      # a turn away from the body sharper than this, near a fin gap, is where the fin's own edge starts
CORNER_SPAN = 0.15   # share of SL from the gap end searched for that corner


def trim_fin_edge(P, side, at_end, SL):
    """cut the fin's own leading (or trailing) edge off a piece's gap-side end. The fin starts at a CONCAVE corner: walking toward
    the gap, the edge turns away from the body by more than CORNER_DEG within CORNER_SPAN of the gap. A body profile that is
    simply steep (butterflyfish forehead) has no such corner and is kept. (Fin-base landmarks read on a spine tip, not the base:
    parrotfish, surgeonfish, 27 Nov.)"""
    Q = P if at_end else P[::-1]                                    # Q runs toward the gap
    sg = 1 if side == 'top' else -1
    s = np.r_[0, np.cumsum(np.linalg.norm(np.diff(Q, axis=0), axis=1))]
    step = 0.008 * SL; t = np.arange(0, s[-1], step)
    if len(t) < 4: return P
    X = np.c_[np.interp(t, s, Q[:, 0]), np.interp(t, s, Q[:, 1])]
    d = np.diff(X, axis=0); ang = np.unwrap(np.arctan2(sg * d[:, 1], d[:, 0])); ang = np.degrees(ang)   # + = heading away from the body
    w = 2                                                            # turn between the 2 steps before and the 2 after a sample
    turn = np.full(len(X), -999.0)
    for j in range(w, len(X) - w): turn[j] = ang[j:j + w].mean() - ang[j - w:j].mean()
    near = t >= t[-1] - CORNER_SPAN * SL
    cand = np.where(near & (turn > CORNER_DEG))[0]
    if not len(cand): return P
    j = int(cand[np.argmax(turn[cand])])                             # the corner sample
    cut = t[j]; keep = s <= cut + 1e-9
    Qk = np.vstack([Q[keep], X[j]]) if keep.sum() >= 1 else Q
    return Qk if at_end else Qk[::-1]


class Frame:
    def __init__(self, T, SL):
        W, H = T['px']; self.W, self.H = W, H
        self.a = np.array([T['snout'][0] * W / 100, T['snout'][1] * H / 100])
        b = np.array([T['cbase'][0] * W / 100, T['cbase'][1] * H / 100])
        d = b - self.a; self.Lpx = float(np.linalg.norm(d)); self.ex = d / self.Lpx
        self.ey = np.array([self.ex[1], -self.ex[0]])                    # image y points down: up = (ex_y, -ex_x)
        if T.get('facing', 'left') == 'right': self.ey = -self.ey
        self.k = SL / self.Lpx                                           # record units per photo pixel

    def to_rec(self, P):
        P = np.atleast_2d(np.asarray(P, float))[:, :2]
        q = np.c_[P[:, 0] * self.W / 100, P[:, 1] * self.H / 100] - self.a
        return np.c_[q @ self.ex, q @ self.ey] * self.k

    def to_px(self, P):
        P = np.atleast_2d(np.asarray(P, float))[:, :2] / self.k
        return self.a + P[:, :1] * self.ex + P[:, 1:2] * self.ey


def as_function(Pl, side):
    """a traced arc -> y(u) samples. Where the arc folds back along u (a fin lobe over the peduncle, an overhanging lip) keep the
    crossing nearest the body (from parts_from_trace.as_function, 20 Nov root fix)."""
    Pl = np.asarray(Pl, float); du = np.diff(Pl[:, 0])
    if (du >= 0).all() or (du <= 0).all(): return Pl[np.argsort(Pl[:, 0], kind='stable')]
    out = []
    for u in np.unique(Pl[:, 0]):
        ys = [a[1] + (b[1] - a[1]) * ((u - a[0]) / (b[0] - a[0]) if b[0] != a[0] else 0.0)
              for a, b in zip(Pl[:-1], Pl[1:]) if min(a[0], b[0]) <= u <= max(a[0], b[0])]
        out.append([u, min(ys) if side == 'top' else max(ys)])
    return np.array(out)


def end_slope(P, at_end, near, far):
    """slope of a piece's free edge next to a gap, by least squares on the stretch from `near` to `far` record units away from the
    gap end. The last `near` units are left out: there the edge already turns up the fin's leading edge (or the gap's fillet),
    which is fin, not body (20 Nov fin-base rule)."""
    P = P[np.argsort(P[:, 0])]; e = P[-1, 0] if at_end else P[0, 0]; d = np.abs(P[:, 0] - e)
    sel = P[(d >= near) & (d <= far)]
    if len(sel) < 3: sel = P[d <= far]
    if len(sel) < 2: sel = P[-2:] if at_end else P[:2]
    return float(np.polyfit(sel[:, 0], sel[:, 1], 1)[0])



def convex_arc(u0, y0, m0, u1, y1, m1, uu):
    """quadratic Bezier from (u0, y0) to (u1, y1) whose control point is where the end tangents meet (straight when they are parallel)."""
    if abs(m0 - m1) < 1e-9: return y0 + (uu - u0) * (y1 - y0) / (u1 - u0)
    uc = (y1 - y0 + m0 * u0 - m1 * u1) / (m0 - m1); uc = min(max(uc, u0), u1); yc = y0 + m0 * (uc - u0)
    t = np.linspace(0, 1, 400); bu = (1 - t) ** 2 * u0 + 2 * t * (1 - t) * uc + t ** 2 * u1; by = (1 - t) ** 2 * y0 + 2 * t * (1 - t) * yc + t ** 2 * y1
    return np.interp(uu, bu, by)


def body_edge(T, fr, side, SL):
    """dense (u, y) body edge for one side, from the photo only. Returns (edge, bridges), bridges = [(u0, u1, kind)] spans under
    fins: kind 'measured' (fin-base points read on the photo, no anchor gap over BASE_GAP), 'short' (arc over a gap under
    BASE_GAP) or 'estimate' (arc over a longer gap with no base points: a prior, not a measurement)."""
    if side in T: raw = [fr.to_rec(T[side])]
    else: raw = [fr.to_rec(T[k]) for k in (f'head_{side}', f'mid_{side}', f'ped_{side}') if k in T]
    if not raw: raise KeyError(f'trace has no {side} edge')
    raw = sorted(raw, key=lambda p: p[:, 0].min()); trimmed = []
    for i, P in enumerate(raw):
        P = P[np.argsort(P[:, 0], kind='stable')] if (np.diff(P[:, 0]) >= 0).all() or (np.diff(P[:, 0]) <= 0).all() else P
        if P[0, 0] > P[-1, 0]: P = P[::-1]
        if i < len(raw) - 1: P = trim_fin_edge(P, side, True, SL)
        if i > 0: P = trim_fin_edge(P, side, False, SL)
        trimmed.append(P)
    pieces = [as_function(P, side) for P in trimmed]
    near, far = 0.015 * SL, 0.06 * SL
    base = fr.to_rec(T['fin_base'][side]) if T.get('fin_base', {}).get(side) else np.zeros((0, 2))
    if len(base):
        # a base point read on the photo wins over the traced piece: inside each run of base points (no step over BASE_GAP) the
        # piece is cut out, so a piece that ran onto a fin root, spine or flap (triggerfish pelvic spine) gives way to the reads
        b = np.sort(base[:, 0]); runs = np.split(b, np.nonzero(np.diff(b) > BASE_GAP * SL)[0] + 1); cut = []
        for P in pieces:
            keep = np.ones(len(P), bool)
            for r in runs: keep &= ~((P[:, 0] > r[0]) & (P[:, 0] < r[-1]))
            idx = np.nonzero(keep)[0]
            for g in np.split(idx, np.nonzero(np.diff(idx) > 1)[0] + 1):
                if len(g) >= 2: cut.append(P[g])
        pieces = cut
    pieces = sorted(pieces, key=lambda p: p[0, 0]); out = [pieces[0]]; bridges = []
    for A, B in zip(pieces[:-1], pieces[1:]):
        u0, u1 = A[-1, 0], B[0, 0]
        if u1 - u0 > 1e-6:
            uu = np.linspace(u0, u1, max(4, int((u1 - u0) / (0.005 * SL))))[1:-1]
            bp = base[(base[:, 0] > u0 + 0.002 * SL) & (base[:, 0] < u1 - 0.002 * SL)] if len(base) else base
            if len(bp):
                # MEASURED FIN BASE: the body edge under the fin goes through the base points read on the photo (monotone cubic,
                # no overshoot), from the free edge on one side to the free edge on the other (Fable critique 27 Nov, fault 1)
                from scipy.interpolate import PchipInterpolator
                anc = np.vstack([A[-1], bp[np.argsort(bp[:, 0])], B[0]])
                yy = PchipInterpolator(anc[:, 0], anc[:, 1])(uu)
                kind = 'measured' if np.diff(anc[:, 0]).max() <= BASE_GAP * SL else 'estimate'
                out.append(np.c_[uu, yy]); bridges.append((round(float(u0), 2), round(float(u1), 2), kind)); out.append(B); continue
            # CONVEX BRIDGE: a fish body is convex under its fin bases (no inflection; the fin, not the body, makes the concave corner).
            # End slopes are clamped to keep the arc convex (top: m0 >= chord >= m1, bottom: the reverse) and within BRIDGE_DSLOPE
            # of the chord; the arc is the quadratic Bezier on the two end tangents. A Hermite curve swung outside the body
            # (parrotfish) or made an S under long fins (angelfish), 27 Nov overlays.
            ch = (B[0, 1] - A[-1, 1]) / (u1 - u0); sg = 1 if side == 'top' else -1
            m0 = float(np.clip(end_slope(A, True, near, far), ch - BRIDGE_DSLOPE, ch + BRIDGE_DSLOPE))
            m1 = float(np.clip(end_slope(B, False, near, far), ch - BRIDGE_DSLOPE, ch + BRIDGE_DSLOPE))
            ok0, ok1 = sg * (m0 - ch) > 0, sg * (ch - m1) > 0
            if ok0 and ok1: yy = convex_arc(u0, A[-1, 1], m0, u1, B[0, 1], m1, uu)
            elif ok0 or ok1:      # one end's slope is convex-consistent (the other is a concave fillet, e.g. into the peduncle):
                h = u1 - u0         # the parabola on that tangent through both ends (convex by construction)
                if ok0: c = (B[0, 1] - A[-1, 1] - m0 * h) / h ** 2; yy = A[-1, 1] + m0 * (uu - u0) + c * (uu - u0) ** 2
                else: c = (A[-1, 1] - B[0, 1] + m1 * h) / h ** 2; yy = B[0, 1] + m1 * (uu - u1) + c * (uu - u1) ** 2
            else: yy = A[-1, 1] + (uu - u0) * ch
            out.append(np.c_[uu, yy]); bridges.append((round(float(u0), 2), round(float(u1), 2), 'short' if u1 - u0 <= BASE_GAP * SL else 'estimate'))
        out.append(B)
    E = np.vstack(out); E = E[np.argsort(E[:, 0], kind='stable')]
    return E, bridges


def landmarks(T, fr):
    """photo landmarks in the record frame (only those present in the trace)."""
    L = {}
    if 'eye' in T:
        e = fr.to_rec(T['eye'][:2])[0]; L['eye'] = dict(u=float(e[0]), y=float(e[1]))
        if len(T['eye']) > 2: L['eye']['r'] = float(T['eye'][2] / 100 * T['px'][0] * fr.k)
    if 'rictus' in T: L['rictus'] = fr.to_rec(T['rictus'])[0].tolist()
    if 'gill' in T: L['gill'] = fr.to_rec(T['gill']).tolist()
    for k in ('preop', 'subop', 'interop'):          # cover margins, when the trace carries them (by-eye reads, newest landmark set)
        if k in T: L[k] = fr.to_rec(T[k]).tolist()
    fins = T.get('fins', {})
    for k in ('d1', 'd2', 'an', 'd'):
        if k in fins and 'edge' in fins[k]:
            E = fr.to_rec(fins[k]['edge']); L[k] = [float(E[0, 0]), float(E[-1, 0])]
    for k in ('pect', 'pelvic'):
        if k in fins and 'base' in fins[k]: L[k] = fr.to_rec(fins[k]['base'])[0].tolist()
    return L
