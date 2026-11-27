"""The designed quad template: NU rings along the body by NT columns round it, evaluated on the loft in (x, theta).

Features cut holes in the template (eye blocks, the rings in front of the mouth) and fill them with their own designed
patches, so every feature keeps the template's edge flow at its border.
"""
import numpy as np

NU, NT = 50, 36                 # rings along the body, columns round the section (16 per side + 2 midline columns)


class Template:
    def __init__(self, form):
        self.NU, self.NT = NU, NT
        self.X0, self.X1 = 0.004, form.XEND - 0.004
        s = np.linspace(0, 1, NU); self.XS = self.X0 + (self.X1 - self.X0) * (0.5 * s + 0.5 * s ** 1.9)   # denser at the head
        self.TH = np.linspace(0, 2 * np.pi, NT, endpoint=False)
        self.grid = -np.ones((NU, NT), int)

    def J(self, j): return j % self.NT

    def blk_col(self, j, sg):
        """column index unwrapped for a block on side sg (right-side blocks may run past NT)."""
        return j if sg > 0 or j >= self.NT // 2 else j + self.NT


def build_grid(B):
    """template vertices and body quads outside the feature holes. Reads B.blk, B.mouth.iK, B.mouth.XK, B.gill.ring_dx, B.gill.col_dth."""
    T, form, mesh = B.T, B.form, B.mesh; NU, NT, XS, TH, grid = T.NU, T.NT, T.XS, T.TH, T.grid
    blk, iK, XK, ring_dx, col_dth = B.blk, B.mouth.iK, B.mouth.XK, B.gill.ring_dx, B.gill.col_dth

    def in_block(i, j):
        for (i0, i1, j0, j1, sg) in blk:
            if i0 < i < i1 and j0 < T.blk_col(j, sg) < j1: return True
        return False
    for i, x in enumerate(XS):
        if i < iK: continue                       # in front of the rictus: replaced by the loops round the mouth
        for j, th in enumerate(TH):
            if in_block(i, j): continue
            xx = XK[j] if i == iK else x + ring_dx(i, j)
            th = th + col_dth(i, j)                 # the gill V bends one ventral column (gill.plan_leg)
            grid[i, j] = len(mesh.verts); mesh.verts.append(form.loft_point(np.array(xx), np.array(th))); mesh.vuv.append((xx, th))
    for i in range(NU - 1):
        for j in range(NT):
            q = [grid[i, j], grid[i + 1, j], grid[i + 1, T.J(j + 1)], grid[i, T.J(j + 1)]]
            if min(q) < 0: continue
            if any(i0 <= i < i1 and j0 <= T.blk_col(j, sg) < j1 for (i0, i1, j0, j1, sg) in blk): continue
            mesh.add_face(q, 'body')


def build_tail_cap(B):
    """tail-root end: one pole (valence NT), hidden under the caudal fin root."""
    T, form, mesh = B.T, B.form, B.mesh
    tail = mesh.add_v([form.XEND, float(form.sec(form.XEND)[0]), 0.0], form.XEND, 0.0)
    for j in range(T.NT):
        mesh.add_face([tail, T.grid[T.NU - 1, T.J(j + 1)], T.grid[T.NU - 1, j]], 'cap')
    B.tail = tail
    B.tail_ring = [int(T.grid[T.NU - 1, j]) for j in range(T.NT)]
