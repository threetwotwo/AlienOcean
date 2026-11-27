"""Stage 8a, RIG (numpy, no Blender): the bones and skin weights the export binds, in record units (SL, x snout -> tail, y up, z left).

Bones
  spine_00 .. spine_NN   the body chain (record body.motion.bones, at most 10), as the export always had
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


def spine_stations(C):
    NB = int(C['bones']); xs = np.linspace(0.02, C['xend'] - 0.03, NB + 1)
    return NB, xs


def spine_index(C, x):
    NB, xs = spine_stations(C); return int(np.clip(np.searchsorted(xs, x) - 1, 0, NB - 1))


def spine_weights(C, x):
    """per vertex x: (bone index, weight) pairs, linear between the two nearest bone centres (the export's rule since v0.2)."""
    NB, xs = spine_stations(C); ctrs = (xs[:-1] + xs[1:]) / 2
    f = np.interp(x, ctrs, np.arange(NB)); i0 = np.floor(f).astype(int); a = f - i0
    i1 = np.minimum(i0 + 1, NB - 1); return i0, 1 - a, i1, np.where(i0 + 1 < NB, a, 0.0)


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
