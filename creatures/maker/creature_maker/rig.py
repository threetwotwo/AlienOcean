"""Stage 8a, RIG (numpy, no Blender): the bones and skin weights the export binds, in record units (SL, x snout -> tail, y up, z left).

Bones
  spine_00               the HEAD: one rigid bone from the snout to the head's end (head_end: the gill cover's rear line, record
                         cover.rear, no further back than the pectoral fin's base). Every vertex ahead of the head's end rides it
                         alone, so the cranium does not bend in a swim or a turn (check RG1)
  spine_01 .. spine_NN   the trunk and tail chain, evenly from the head's end to the caudal base (record body.motion.bones counts the
                         head, at most 10). The first sideways bend starts at the head's end; weights blend linearly between bone centres
  fin_<fin>_root, _tip   paired fins (pectoral, pelvic): a chain along the fin's long axis, weights by the fin's own T (0 root, 1 edge)
  fin_caudal_root, fin_caudal_upper, fin_caudal_lower   the tail fin past the peduncle and its two lobes
                         The fin chains trail the body in the swim clip (swim_clip.fin_lag: secondary motion; checks RG2, RG3)
  jaw                    lower jaw: pivot = openings.jaw_joint, turns about +z (gape opens the mouth downward), parent = spine bone at the joint
  opercleL / opercleR    gill covers: pivot = openings.opercle_hinge on each side's skin, turn about the vertical axis (flare swings the
                         cover outward), parent = spine bone at the hinge. Named as the swim engine (motion/swim.js) names them, so its
                         breathing drives them with no mapping.

Weights: the jaw and the covers take EXACTLY the weights the gape and flare stress tests use (pose.jaw_weights, pose.cover_weights,
already softened), split left/right by the sign of z for the covers. What they leave goes to the spine by body position. With the spine
at rest, linear blend skinning of the jaw bone turned by g degrees is V + w (R V - V), which is pose.gape: the in-engine mouth is the
pose the stress test passed, to float precision (export check EX1/EX2).
"""
import math
import numpy as np
from .pose import jaw_weights, cover_weights, gape, flare


HEAD_FRONT = 0.02    # DEFAULT (SL): the head bone starts this far behind the snout tip (the chain's first station since v0.2)
TAIL_BACK = 0.03     # DEFAULT (SL): the chain ends this far ahead of the body's end (as since v0.2: the last joint inside the peduncle)
FIN_CHAIN = 2        # DEFAULT: bones along a paired fin (root, tip). Observed on the reference rigs: pectorals pivot at the base AND
                     # flex along the blade, so at least 2. A third (mid) bone works here (names root, mid, tip) but 10 spine + jaw + 2
                     # covers + 4 fins x 3 + 3 caudal = 28 bones, over the export's P7 budget of 24; 2 a fin lands on 24
PAIRED = ('pectoral', 'pelvic')
LOBE_BLEND = 0.25    # DEFAULT: the two caudal lobes share the fork's middle over this share of the fin's half height (no tear at the fork)


def head_end(rec):
    """x (SL) where the rigid head ends: the rearmost point of the gill cover's rear line (record cover.rear), and no further back
    than the pectoral fin's base (record fins.pectoral.x: the girdle the cover closes on; a rear line traced past it sweeps down the
    belly). Observed on the reference rigs: the first bend starts right behind the gill covers and the pectoral girdle."""
    x = float(np.asarray(rec['cover']['rear'], float)[:, 0].max())
    pec = (rec.get('fins') or {}).get('pectoral')
    if pec and pec.get('x') is not None: x = min(x, float(pec['x']))
    return x


def spine_stations(C):
    """joints of the chain, x in SL: the head bone from HEAD_FRONT to the head's end, the other bones evenly from there to the tail.
    C['rig_fault'] == 'even' is the old rule (every bone the same length from the snout: the skull bends), kept for the planted test."""
    NB = int(C['bones']); x1 = C['xend'] - TAIL_BACK
    if C.get('rig_fault') == 'even': return NB, np.linspace(HEAD_FRONT, x1, NB + 1)
    if 'head_end' not in C: raise KeyError('head_end: the cage carries no head end (rig.head_end(record)); rebuild it')
    he = float(C['head_end'])
    if not HEAD_FRONT < he < x1 or NB < 2: raise ValueError(f'head_end {he} outside the chain ({HEAD_FRONT} .. {x1}) or fewer than 2 bones')
    return NB, np.r_[HEAD_FRONT, np.linspace(he, x1, NB)]


def spine_index(C, x):
    NB, xs = spine_stations(C); return int(np.clip(np.searchsorted(xs, x) - 1, 0, NB - 1))


def spine_weights(C, x):
    """per vertex x: (bone index, weight) pairs. Ahead of the head's end the head bone alone; behind it linear from the head's end to
    the first trunk bone's centre, then between bone centres."""
    NB, xs = spine_stations(C); ctrs = (xs[:-1] + xs[1:]) / 2
    if C.get('rig_fault') != 'even': ctrs[0] = xs[1]
    f = np.interp(x, ctrs, np.arange(NB)); i0 = np.floor(f).astype(int); a = f - i0
    i1 = np.minimum(i0 + 1, NB - 1); return i0, 1 - a, i1, np.where(i0 + 1 < NB, a, 0.0)


def spine_groups(C, x, share=1.0):
    """{spine bone name: weight per x} of spine_weights, times share."""
    x = np.atleast_1d(np.asarray(x, float)); i0, a0, i1, a1 = spine_weights(C, x); g = {}; sh = np.broadcast_to(share, x.shape)
    for i, a in ((i0, a0), (i1, a1)):
        for b in np.unique(i): g.setdefault(f'spine_{b:02d}', np.zeros(len(x)))[i == b] += (a * sh)[i == b]
    return g


def _chain_levels(n): return ['root', 'tip'] if n == 2 else ['root'] + [f'mid{j}' if n > 3 else 'mid' for j in range(1, n - 1)] + ['tip']


def fin_bones(C):
    """bones of the fins that move on their own: per paired fin a chain of FIN_CHAIN bones from the root row's middle to the free
    edge's middle; for the caudal fin a root bone over the inner half and one bone per lobe. Each: name, head, tail (record units),
    parent, connect, fin, level (0 at the root), levels. Bone names end in _root/_mid/_tip/_upper/_lower: the fin's mesh node is
    fin_<fin> (or <fin> on a blockout) and Godot renames a bone that shares a node's name."""
    out = []
    for k, f in C['fins'].items():
        V = np.asarray(f['V'], float); T = np.asarray(f['T'], float); root = V[T <= T.min() + 1e-6].mean(0); edge = V[T >= T.max() - 1e-6]
        par = f'spine_{spine_index(C, root[0]):02d}'
        if k.startswith(PAIRED):
            n = FIN_CHAIN; tip = edge.mean(0); P = [root + (tip - root) * j / n for j in range(n + 1)]
            for j, lv in enumerate(_chain_levels(n)):
                out.append(dict(name=f'fin_{k}_{lv}', head=P[j].tolist(), tail=P[j + 1].tolist(), parent=par if j == 0 else out[-1]['name'],
                                connect=False, fin=k, level=j, levels=n))
        elif k == 'caudal':
            up, lo = edge[edge[:, 1] >= root[1]], edge[edge[:, 1] < root[1]]
            if not len(up) or not len(lo): up = lo = edge
            mid = root + 0.5 * (edge.mean(0) - root)
            out.append(dict(name='fin_caudal_root', head=root.tolist(), tail=mid.tolist(), parent=par, connect=False, fin=k, level=0, levels=2))
            for nm, e in (('upper', up), ('lower', lo)):
                t = e.mean(0); out.append(dict(name=f'fin_caudal_{nm}', head=(root + 0.5 * (t - root)).tolist(), tail=t.tolist(), parent='fin_caudal_root',
                                               connect=False, fin=k, level=1, levels=2))
    return out


def fin_groups(C, k, fault=None):
    """skin weights of fin k's vertices: {bone name: array}. Every fin vertex follows the spine at its own x (median fins wholly: they
    bend with the trunk); a fin with bones hands over to them from root (T = 0) to edge (T = 1), and along the chain by T, linear
    between the bones' middles. The caudal fin's outer half is split between its lobes by height, shared over LOBE_BLEND at the fork.
    fault 'rigid': all of the fin's share on its root bone (the old one-bone fin)."""
    f = C['fins'][k]; V = np.asarray(f['V'], float); T = np.clip(np.asarray(f['T'], float), 0, 1)
    paired = k.startswith(PAIRED); n = FIN_CHAIN if paired else 2 if k == 'caudal' else 0
    if not n: return spine_groups(C, V[:, 0])
    g = spine_groups(C, V[:, 0], 1 - T)
    u = np.interp(T, (np.arange(n) + 0.5) / n, np.arange(n))          # place along the chain, in bones
    if fault == 'rigid': u = np.zeros(len(T))
    if paired:
        for j, lv in enumerate(_chain_levels(n)): g[f'fin_{k}_{lv}'] = T * np.clip(1 - np.abs(u - j), 0, 1)
    else:
        y0 = float(V[T <= T.min() + 1e-6][:, 1].mean()); h = max(float(np.abs(V[:, 1] - y0).max()), 1e-9)
        a = np.clip(0.5 + (V[:, 1] - y0) / (2 * LOBE_BLEND * h), 0, 1)
        g['fin_caudal_root'] = T * (1 - u); g['fin_caudal_upper'] = T * u * a; g['fin_caudal_lower'] = T * u * (1 - a)
    return g


def hinge_z(C, V):
    """skin z at the opercle hinge (as pose.posers finds it)."""
    hx, hy = C['openings']['opercle_hinge']
    near = np.argsort(np.hypot(V[:, 0] - hx, V[:, 1] - hy) + 10 * (V[:, 2] < 0))[:3]
    return float(np.abs(V[near, 2]).mean())


def bones(C, V, rec):
    """bone list: name, head, tail (record units), parent, and for the posable head bones the pivot and axis."""
    NB, xs = spine_stations(C); out = []
    for i in range(NB):
        out.append(dict(name=f'spine_{i:02d}', head=[xs[i], 0, 0], tail=[xs[i + 1], 0, 0], parent=f'spine_{i - 1:02d}' if i else None, connect=bool(i)))
    xj, yj = C['openings']['jaw_joint']
    ml = np.array(rec['mouth']['line']); tip = ml[np.argmin(ml[:, 0])]                 # front of the mouth line: the jaw's tip
    out.append(dict(name='jaw', head=[xj, yj, 0], tail=[float(tip[0]), float(tip[1]), 0], parent=f'spine_{spine_index(C, xj):02d}',
                    connect=False, pivot=[xj, yj, 0], axis=[0, 0, 1], pose='gape'))
    hx, hy = C['openings']['opercle_hinge']; zh = hinge_z(C, V)
    rear = np.array(rec['cover']['rear']); xr = float(rear[:, 0].max())
    for nm, sg in (('opercleL', 1), ('opercleR', -1)):
        # flare(): the +z cover turns about +y by -deg, the -z cover by +deg (pose.flare), so each cover's opening axis is -sg * y
        out.append(dict(name=nm, head=[hx, hy, sg * zh], tail=[xr, hy, sg * zh], parent=f'spine_{spine_index(C, hx):02d}', connect=False,
                        pivot=[hx, hy, sg * zh], axis=[0, -sg, 0], pose='flare'))
    return out


def weights(C, V, rec, jaw_w=None):
    """skin weights of the body cage: {bone name: array over V}. Rows sum to 1."""
    wj = jaw_weights(C, V, rec) if jaw_w is None else jaw_w; wc = cover_weights(C, V, rec)
    wL = np.where(V[:, 2] > 0, wc, 0.0); wR = np.where(V[:, 2] <= 0, wc, 0.0)
    head = wj + wL + wR; over = head > 1
    if over.any():                                   # jaw and cover never share a vertex on the board so far; if they do, scale them down
        wj = np.where(over, wj / head, wj); wL = np.where(over, wL / head, wL); wR = np.where(over, wR / head, wR); head = np.minimum(head, 1)
    rest = 1 - head; NB, _ = spine_stations(C)
    W = {f'spine_{i:02d}': np.zeros(len(V)) for i in range(NB)}
    i0, a0, i1, a1 = spine_weights(C, V[:, 0])
    for k in range(len(V)):
        W[f'spine_{i0[k]:02d}'][k] += rest[k] * a0[k]; W[f'spine_{i1[k]:02d}'][k] += rest[k] * a1[k]
    W['jaw'] = wj; W['opercleL'] = wL; W['opercleR'] = wR
    return W, dict(jaw_cover_overlap=int(over.sum()))


def rot(axis, deg):
    a = np.asarray(axis, float); a /= np.linalg.norm(a); t = math.radians(deg); c, s = math.cos(t), math.sin(t)
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]]); return np.eye(3) + s * K + (1 - c) * K @ K


def skin(V, W, bl, deg):
    """linear blend skinning of the head bones only (spine at rest): {bone name: degrees} -> posed V. The export check compares this
    with pose.gape / pose.flare; Blender's evaluated mesh is compared with this."""
    P = V.copy(); B = {b['name']: b for b in bl}
    for n, d in deg.items():
        b = B[n]; p = np.array(b['pivot']); R = rot(b['axis'], d); P += W[n][:, None] * ((V - p) @ R.T + p - V)
    return P


def stress_pose(C, V, rec, name, deg):
    """the stress test's own pose, for comparison."""
    O = C['openings']
    if name == 'gape': return gape(V, jaw_weights(C, V, rec), O['jaw_joint'], deg)
    return flare(V, cover_weights(C, V, rec), O['opercle_hinge'], deg, hinge_z(C, V))
