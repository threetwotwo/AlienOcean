"""The cage under construction: vertices, their chart coordinates, tagged faces, and the designed-crease registers.

Every vertex carries (x, theta) for the body UV chart; interior vertices carry NaN there (they get their own UV island).
Designed creases are registered where they are made, so the fold check can tell design from fault:
  rolls        closed loops where the skin turns on purpose (lips, lip roll, slit loops, eye rims, tail ring)
  junctions    closed loops where one tube joins another (gill passage meets the cavity wall)
  commissures  open chains along the corner of a closed slit (mouth corners, slit ends)
"""
import numpy as np

SKIN_TAGS = ('body', 'eye', 'mouth', 'cap')
INNER_TAGS = ('cavity', 'gill')


class CageMesh:
    def __init__(self):
        self.verts, self.vuv, self.faces, self.ftag = [], [], [], []

    def add_v(self, p, x, th):
        self.verts.append(np.array(p, float)); self.vuv.append((float(x), float(th))); return len(self.verts) - 1

    def add_face(self, f, tag):
        self.faces.append(f); self.ftag.append(tag)

    def band(self, a, b, tag, closed=True):
        """quads between two vertex rows of equal length (a -> b), wrapping if closed."""
        L = len(a); n = L if closed else L - 1
        for m in range(n):
            self.add_face([a[m], b[m], b[(m + 1) % L], a[(m + 1) % L]], tag)

    def fan(self, ring, pole, tag):
        L = len(ring)
        for j in range(L):
            self.add_face([ring[j], pole, ring[(j + 1) % L]], tag)


def vnormals(V, faces):
    N = np.zeros_like(V)
    for f in faces:
        P = V[f]; n = np.cross(P[1] - P[0], P[-1] - P[0]) if len(f) == 3 else np.cross(P[2] - P[0], P[3] - P[1])
        N[f] += n
    return N / (np.linalg.norm(N, axis=1, keepdims=True) + 1e-12)


def relax_rings(QS, it, pin=()):
    """relax the inner rings of a ring stack (list of (L, d) arrays; first and last fixed). Across rings: full Laplacian
    (even spacing along the spokes). Along a ring: tangential part only, so rings slide to even spacing but never shrink
    across a corner of the outer loop (plain Laplacian pulled the eye ring onto the rim at the patch corner, round 3)."""
    for _ in range(it):
        for k in range(1, len(QS) - 1):
            Q = QS[k]; nx, pv = np.roll(Q, -1, 0), np.roll(Q, 1, 0)
            t = nx - pv; t /= np.linalg.norm(t, axis=1, keepdims=True) + 1e-12
            La = 0.5 * (nx + pv) - Q; La = (La * t).sum(1, keepdims=True) * t
            Lx = 0.5 * (QS[k - 1] + QS[k + 1]) - Q
            Qn = Q + 0.25 * La + 0.25 * Lx; Qn[list(pin)] = Q[list(pin)]; QS[k] = Qn
