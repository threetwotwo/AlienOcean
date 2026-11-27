"""Turnaround sheets: each built fish from eight angles (front, back, left, right, top, bottom, three-quarter from above,
three-quarter from below) plus the head close up from both three-quarters, at rest, at real size (every pose at the size the species really makes, all at once) and at
its stylized target (all at once), so a fault hidden from the side shows up from below or behind. Faces that cross or
fold in a pose (pose.py measures) are painted magenta. The rest sheet paints faces that already cross at rest. Body cage only: fin cards do not follow the poses yet.

Runs in a Python that can import bpy (Cycles on the CPU). Writes OUT/sheet_<pose>.jpg.
"""
import json, os, sys
import numpy as np
from PIL import Image, ImageDraw

COLS = {'body': (0.80, 0.82, 0.86), 'eye': (0.35, 0.55, 1.0), 'mouth': (1.0, 0.76, 0.32), 'cap': (0.72, 0.72, 0.72),
        'cavity': (0.88, 0.30, 0.30), 'gill': (0.30, 0.85, 0.45), 'fault': (1.0, 0.0, 0.85)}
# camera direction (from the fish to the camera) in cage axes: x snout to tail, y up, z the fish's left
VIEWS = [('front', (-1, 0, 0)), ('back', (1, 0, 0)), ('left', (0, 0, 1)), ('right', (0, 0, -1)), ('top', (0, 1, 0)),
         ('bottom', (0, -1, 0)), ('3/4 above', (-0.8, 0.7, 0.9)), ('3/4 below', (-0.8, -0.7, 0.9)),
         ('head, 3/4 above', (-0.8, 0.7, 0.9)), ('head, 3/4 below', (-0.8, -0.7, 0.9))]   # the openings, close up
HEAD = 0.35          # close-ups frame the body in front of this x (SL): mouth, eyes, gill covers
POSES = [('rest', None), ('real size', 80), ('stylized target', 100)]     # combo percent (pose.targets: 80 = real size)
TILE = (480, 300)


def faults(C, V, P):
    """triangles that cross or newly fold in pose P (pose.range_sweep rules), as face indices."""
    from .pose import triangles, self_intersections, tri_pairs
    T = triangles(C['faces']); tf = [k for k, f in enumerate(C['faces']) for _ in range(1 if len(f) == 3 else 2)]
    _, p0 = self_intersections(V, T); _, p1 = self_intersections(P, T); bad = set()
    for a, b in set(map(tuple, p1)) - set(map(tuple, p0)): bad |= {tf[a], tf[b]}
    def nrm(Q):
        n = np.cross(Q[T[:, 1]] - Q[T[:, 0]], Q[T[:, 2]] - Q[T[:, 0]]); return n / (np.linalg.norm(n, axis=1, keepdims=True) + 1e-15)
    hair = set(v for ch in C.get('commissures', []) for v in ch); PR = tri_pairs(T); N0, N = nrm(V), nrm(P)
    for a, b in PR:
        if (N0[a] * N0[b]).sum() > 0.5 and (N[a] * N[b]).sum() < 0 and not (set(T[a]) | set(T[b])) & hair: bad |= {tf[a], tf[b]}
    return bad


def rest_faults(C, V):
    """faces that already cross at rest (GP0)."""
    from .pose import triangles, self_intersections
    T = triangles(C['faces']); tf = [k for k, f in enumerate(C['faces']) for _ in range(1 if len(f) == 3 else 2)]
    return {tf[k] for p in self_intersections(V, T)[1] for k in p}


def render(C, P, bad, out_png):
    import bpy
    from mathutils import Vector, Matrix
    bpy.ops.wm.read_factory_settings(use_empty=True); scn = bpy.context.scene
    F = C['faces']; tags = ['fault' if k in bad else (t if t in COLS else 'body') for k, t in enumerate(C['ftag'])]
    me = bpy.data.meshes.new('cage'); me.from_pydata([(v[0], -v[2], v[1]) for v in P], [], F); me.update()
    for t, c in COLS.items():
        m = bpy.data.materials.new(t); m.use_nodes = True; bs = m.node_tree.nodes['Principled BSDF']
        bs.inputs['Base Color'].default_value = (*c, 1); bs.inputs['Roughness'].default_value = 0.6; me.materials.append(m)
    for p, t in zip(me.polygons, tags): p.material_index = list(COLS).index(t)
    ob = bpy.data.objects.new('cage', me); scn.collection.objects.link(ob)
    wire = bpy.data.objects.new('wire', me.copy()); scn.collection.objects.link(wire)
    wm = wire.modifiers.new('w', 'WIREFRAME'); wm.thickness = 0.0012; wm.use_replace = True
    mw = bpy.data.materials.new('wire'); mw.use_nodes = True
    mw.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.12, 0.14, 0.2, 1)
    wire.data.materials.clear(); wire.data.materials.append(mw)
    scn.render.engine = 'CYCLES'; scn.cycles.samples = 10; scn.cycles.device = 'CPU'
    scn.render.resolution_x, scn.render.resolution_y = TILE
    w = bpy.data.worlds.new('w'); scn.world = w; w.use_nodes = True; bg = w.node_tree.nodes['Background']
    bg.inputs['Strength'].default_value = 1.0; bg.inputs['Color'].default_value = (0.9, 0.92, 0.95, 1)
    sun = bpy.data.objects.new('sun', bpy.data.lights.new('sun', 'SUN')); sun.data.energy = 3; sun.rotation_euler = (0.5, 0.2, -0.6)
    scn.collection.objects.link(sun)
    cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); scn.collection.objects.link(cam); scn.camera = cam
    cam.data.type = 'ORTHO'
    B = np.array([(v[0], -v[2], v[1]) for v in P]); c = 0.5 * (B.min(0) + B.max(0))
    tiles = []
    for name, d in VIEWS:
        dv = np.array([d[0], -d[2], d[1]], float); dv /= np.linalg.norm(dv)
        up = np.array([0, 0, 1.0]) if abs(dv[2]) < 0.95 else np.array([0, 1.0, 0])
        ax_r = np.cross(up, dv); ax_r /= np.linalg.norm(ax_r); ax_u = np.cross(dv, ax_r)
        Bv = B[P[:, 0] < HEAD] if name.startswith('head') else B
        qr, qu = (Bv - c) @ ax_r, (Bv - c) @ ax_u         # centre on the projected box: an oblique view shifts it
        cam.data.ortho_scale = float(max(np.ptp(qr), np.ptp(qu) * TILE[0] / TILE[1]) * 1.08)
        mid = c + ax_r * 0.5 * (qr.min() + qr.max()) + ax_u * 0.5 * (qu.min() + qu.max())
        cam.location = Vector((mid + dv * 3).tolist())
        cam.rotation_euler = Matrix(np.stack([ax_r, ax_u, dv], 1).tolist()).to_euler()   # camera looks down its -Z
        f = out_png + f'.{len(tiles)}.png'; scn.render.filepath = f; bpy.ops.render.render(write_still=True)
        tiles.append((name, f))
    return tiles


def sheet(out, record_path, poses=POSES, log=print):
    from .record import adapt
    from .pose import posers
    C = json.load(open(os.path.join(out, 'cage.json'))); V = np.load(os.path.join(out, 'cage.npz'))['V']
    rec = adapt(record_path, C.get('style')); pose, TG = posers(C, V, rec); paths = []
    for label, pc in poses:
        P = V if pc is None else pose('combo', pc); bad = rest_faults(C, V) if pc is None else faults(C, V, P)
        tiles = render(C, P, bad, os.path.join(out, '_tile'))
        W = Image.new('RGB', (TILE[0] * 5, TILE[1] * 2 + 44), (245, 246, 248)); dr = ImageDraw.Draw(W)
        what = '' if pc is None else (f"  gape {TG['gape'] * pc / 100:.0f}, flare {(TG['flare'] or 0) * pc / 100:.0f}, "
                                      f"S-wave {(TG['wave'] or 0) * pc / 100:.0f} deg")
        verdict = (f'   {len(bad)} faces cross or fold (magenta)' if bad else '   clean') + ('' if pc is None else ' (new in this pose)')
        dr.text((12, 14), f"{C.get('species') or os.path.basename(out)}: {label}{what}{verdict}", fill=(20, 22, 30))
        for i, (name, f) in enumerate(tiles):
            x, y = TILE[0] * (i % 5), 44 + TILE[1] * (i // 5)
            W.paste(Image.open(f).convert('RGB'), (x, y)); dr.text((x + 8, y + 6), name, fill=(40, 44, 60)); os.remove(f)
        p = os.path.join(out, f"sheet_{label.replace(' ', '_')}.jpg"); W.save(p, quality=88); paths.append(p)
        log(f'{p}: {len(bad)} fault faces')
    return paths


if __name__ == '__main__':
    sheet(sys.argv[1], sys.argv[2])
