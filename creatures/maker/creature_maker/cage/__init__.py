"""Stage 3, CAGE: the designed low-poly topology, built feature by feature on the template.

Order (each step names what it reads and writes on the builder):
  template   rings x columns on the loft                         -> B.T
  eye.blocks eye holes in the template                            -> B.blk
  mouth.plan lip loop, shared head ring iK (clamps the eye blocks) -> B.mouth
  gill.plan  slit ring and its bend onto the cover edge; ventral leg and its column bend onto the gill V -> B.gill
  grid       template vertices and body quads                     -> mesh
  eye        eye patches + orbit tucks                            -> B.eye
  mouth      loops round the lips, cavity, pharynx dome, gill holes (gill.holes) -> B.mouth
  gill       slits + passages to the cavity holes                 -> B.gill.slits
  cap        tail-root pole                                       -> B.tail
  finish     winding, snap onto the full form                     -> V, VN
"""
import os
import numpy as np
from ..mesh import CageMesh
from . import template, eye, mouth, gill, finish


class CageBuilder:
    def __init__(self, form, chart, rec, debug_dir=None):
        self.form, self.chart, self.rec = form, chart, rec
        self.T = template.Template(form); self.mesh = CageMesh(); self.debug_dir = debug_dir

    def debug(self, name, **arrays):
        if self.debug_dir: np.savez(os.path.join(self.debug_dir, f'dbg_{name}.npz'), **arrays)

    def build(self):
        self.blk = eye.blocks(self)
        mouth.plan(self)
        gill.plan(self)
        template.build_grid(self)
        eye.build_patches(self)
        mouth.build_loops(self)
        mouth.build_cavity(self)
        gill.build_slits(self)
        self.commissures = commissures(self)
        template.build_tail_cap(self)
        V = np.array(self.mesh.verts, float)
        finish.orient(self, V)
        self.V, self.VN = finish.snap_to_form(self, V)
        return self

    # ---- designed-crease registers (the fold check skips these; see mesh.py)
    def rolls(self):
        M = self.mouth
        return [list(map(int, M.LIPV)), list(map(int, M.CROWS[1]))] + [list(map(int, s['loop'])) for s in self.gill.slits] + \
               [list(map(int, r)) for _, r in self.eye['rims']] + [self.tail_ring]

    def junctions(self):
        return [list(map(int, s['hole'])) for s in self.gill.slits]


def commissures(B):
    """a closed slit is a lens, and its two corners are hairpins by design until the slit opens. Mouth: the rictus spokes
    through the lip roll and the first cavity rings. Gill: the two ends of the slit loop through every passage row (the
    passage is a flat duct, like the real opercular chamber)."""
    M, NT = B.mouth, B.T.NT
    out = [[int(M.CROWS[c_][jc]) for c_ in range(0, 4)] for jc in (M.jr, NT - M.jr)]
    for s in B.gill.slits:
        L_ = len(s['loop'])
        for e_ in (0, L_ // 2): out.append([int(r[e_]) for r in s['rows']])
    return out


def build_cage(form, chart, rec, debug_dir=None):
    return CageBuilder(form, chart, rec, debug_dir).build()
