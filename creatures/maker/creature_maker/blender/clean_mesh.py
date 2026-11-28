"""Clean blockout meshes (bpy): exact booleans on finely faceted primitives, in record units.

Gary 28 Nov: "not clean enough", "output has to be much cleaner / spotless". The numpy blockout meshed its cut bones by marching cubes
(lumps, a saw-toothed mouth rim, a pillowed cover plate) and left neighbouring blocks overlapping at a shallow angle with 14 x 8
facets each (torn zig-zag lines where they cross). Here every solid is built from the blockout's own primitive specs
(blockout.json: segments, prims, kit3) with Blender's EXACT boolean solver:

  bone    the union of the chain's blocks, cut square to the bone's own slab of the spine [x_i, x_i+1] (a jointed toy: a hairline
          seam per joint at rest, the joint spheroid showing in the wedge a bend opens), minus the head cutters (the jaw's place, gill
          slits, eye sockets)
  jaw     the jaw lozenge inside the head's blocks, minus the mouth cavity
  cover   a smooth shell over the head's blocks inside the cover's side outline, its inner face the blocks' surface with the rib
          valleys bridged, off the midline (covers)
  eye     a finely faceted sphere
"""
import bpy, bmesh
import numpy as np
from creature_maker.blockout import _ellipsoid

SEG_HI, RINGS_HI = 48, 24     # DEFAULT: a body block's facets (longitude x latitude). 14 x 8 tore where blocks crossed; at 48 x 24 a
                              # crossing line is smooth at a 1600 px close-up of a 50 cm fish
SEG_PRIM, RINGS_PRIM = 32, 16 # DEFAULT: joint spheroids, root lozenges (hidden at rest); the jaw, cutters and eyes, seen close, at SEG_HI
SLIT_TAPER = 0.2              # DEFAULT: the slit narrows to nothing over this share of its length at each end
COVER_T = 0.035               # DEFAULT: the cover plate's thickness, x the head's half-width
COVER_GAP = 0.01              # DEFAULT: the plate's outer face stands at least this x the head's half-width over every block
COVER_MID = 0.5               # DEFAULT: the plates stop where the surface comes nearer the midline than this x the head's half-width
COVER_BRIDGE = 0.25           # DEFAULT: rib valleys under the plate are bridged over this share of the plate's length
COVER_GRID = 0.002            # DEFAULT (SL): the height grid the plate is read from
COVER_STEP = 0.006            # DEFAULT (SL): the plate's triangle size
COVER_SEAT = 0.0              # DEFAULT (SL): the plate's rim comes down onto the blocks over this band inside its outline (off: at
                              # 0.005-0.012 the rim followed the ribs and read crumpled or pillowed; a plate standing proud reads cleaner)
COVER_ROUND = 0.008           # DEFAULT (SL): the plate outline's kinks, tabs and notches under twice this are rounded off


def _tris(F):
    out = []
    for f in F:
        out += [[f[0], f[k], f[k + 1]] for k in range(1, len(f) - 1)]
    return out


def obj(name, V, F):
    me = bpy.data.meshes.new(name); me.from_pydata([tuple(map(float, v)) for v in V], [], [list(map(int, f)) for f in F]); me.update()
    o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o); return o


def prim(q, name='p', hi=False):
    sg, rg = (SEG_HI, RINGS_HI) if hi else (SEG_PRIM, RINGS_PRIM)
    v, f = _ellipsoid(q['c'], q['r'], sg, rg, q.get('R'), q.get('n'), q.get('ry_lo'))
    return obj(name, v, f)


def box(name, lo, hi):
    x0, y0, z0 = lo; x1, y1, z1 = hi
    V = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
    F = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return obj(name, V, F)


def prism(name, poly, z0, z1):
    """the side outline poly (x, y; counter-clockwise or not) extruded from z0 to z1."""
    P = np.asarray(poly, float)
    if (np.roll(P[:, 0], -1) * P[:, 1] - P[:, 0] * np.roll(P[:, 1], -1)).sum() > 0: P = P[::-1]     # clockwise in (x, y) seen from +z
    n = len(P); V = [(p[0], p[1], z0) for p in P] + [(p[0], p[1], z1) for p in P]
    F = [tuple(range(n)), tuple(range(2 * n - 1, n - 1, -1))] + [(i, n + i, n + (i + 1) % n, (i + 1) % n) for i in range(n)]
    o = obj(name, V, F); bm = bmesh.new(); bm.from_mesh(o.data); bmesh.ops.recalc_face_normals(bm, faces=bm.faces); bm.to_mesh(o.data); bm.free()
    return o


def _apply(o, other, op):
    m = o.modifiers.new('b', 'BOOLEAN'); m.operation = op; m.solver = 'EXACT'; m.object = other
    dg = bpy.context.evaluated_depsgraph_get(); me = bpy.data.meshes.new_from_object(o.evaluated_get(dg))
    o.modifiers.remove(m); old = o.data; o.data = me; bpy.data.meshes.remove(old)
    return o


def combine(parts, op):
    """parts[0] op parts[1] op ...; the other objects are removed."""
    a = parts[0]
    for b in parts[1:]:
        _apply(a, b, op); bpy.data.objects.remove(b)
    return a


def arrays(o):
    """(V, F) of an object, record units, triangles and quads as the boolean left them."""
    me = o.data; V = np.array([v.co[:] for v in me.vertices]); F = [list(p.vertices) for p in me.polygons]
    return V, F


def drop(o): bpy.data.objects.remove(o)


def bones(D, cutters_on=True):
    """{spine index: (V, F)} for every spine bone, each its blocks' union cut to its slab, the head cutters taken out."""
    from creature_maker import rig as RIG
    C = dict(bones=D['bones'], xend=D['xend'], head_end=D['head_end']); NB, xs = RIG.spine_stations(C)
    BIG = 10.0; out = {}
    cut = [q for q in (D.get('kit3') or {}).get('cutters', []) if q.get('target') == 'head'] if cutters_on else []
    # the whole chain's union, then each bone's slab of it: at rest neighbours meet in the same section (a hairline seam, no step);
    # a bone made of its own blocks alone stood a step proud of the next at every joint, its cap catching the light as a stroke
    whole = combine([prim(q, 'seg', hi=True) for q in D['segments']], 'UNION')
    for i in range(NB):
        if not any(q['bone'] == i for q in D['segments']): continue
        a = whole.copy(); a.data = whole.data.copy(); bpy.context.scene.collection.objects.link(a)
        x0 = -BIG if i == 0 else xs[i]; x1 = BIG if i == NB - 1 else xs[i + 1]
        combine([a, box('slab', (x0, -BIG, -BIG), (x1, BIG, BIG))], 'INTERSECT')
        if cut:
            V, _ = arrays(a); lo, hi = V.min(0), V.max(0)
            near = [q for q in cut if _overlaps(q, lo, hi) and q['kind'] != 'cut_gill']
            slits = _slits([q for q in cut if q['kind'] == 'cut_gill' and _overlaps(q, lo, hi)])
            if near or slits: combine([a] + [prim(q, 'cut', hi=True) for q in near] + slits, 'DIFFERENCE')
        out[i] = arrays(a); drop(a)
    drop(whole); return out


def _slits(blades):
    """one prism per side for the gill slit: the blades' centre line widened to their width, from a flat floor (the blades' own floor,
    their median) outward. A chain of overlapping blades, cut one by one, left a ladder of slivers in the slit (clean pass round 2);
    one recess with a flat floor is a plain dark slit that fades where the head's side falls under its floor, at both ends."""
    out = []
    for sg in (1, -1):
        B = [q for q in blades if np.sign(q['c'][2]) == sg]
        if len(B) < 2: continue
        C = np.array([q['c'][:2] for q in B]); w = float(np.median([q['r'][1] for q in B]))
        t = np.gradient(C, axis=0); t /= np.maximum(np.linalg.norm(t, axis=1, keepdims=True), 1e-12); n = np.c_[-t[:, 1], t[:, 0]]
        a = np.r_[0, np.cumsum(np.linalg.norm(np.diff(C, axis=0), axis=1))]; e = np.minimum(a, a[-1] - a) / max(SLIT_TAPER * a[-1], 1e-9)
        wv = w * np.sqrt(np.clip(e, 0.02, 1))[:, None]                 # rounded ends (square ends read as a black card at flare)
        poly = np.vstack([C + n * wv, (C - n * wv)[::-1]])
        floor = float(np.median([abs(q['c'][2]) - q['r'][2] for q in B]))
        out.append(prism('slit', poly, floor, 1.0) if sg > 0 else prism('slit', poly, -1.0, -floor))
    return out


def _overlaps(q, lo, hi):
    c = np.asarray(q['c']); r = max(max(q['r']), q.get('ry_lo') or 0)
    return bool(((c + r) >= lo).all() and ((c - r) <= hi).all())


def jaw(D):
    K = D.get('kit3') or {}; J = [q for q in K.get('blocks', []) if q['kind'] == 'jaw']
    if not J: return None
    a = prim(J[0], 'jaw', hi=True)
    head = [q for q in D['segments'] if _overlaps(J[0], *(_box_of(q)))]
    if head: combine([a, combine([prim(q, 'h', hi=True) for q in head], 'UNION')], 'INTERSECT')
    cav = [q for q in K.get('cutters', []) if q['kind'] == 'cut_mouth']
    if cav: combine([a, prim(cav[0], 'cav', hi=True)], 'DIFFERENCE')
    V, F = arrays(a); drop(a); return (V, F) if len(F) else None


def _box_of(q):
    c = np.asarray(q['c']); r = np.asarray(q['r'], float).copy(); r[:] = max(r.max(), q.get('ry_lo') or 0); return c - r, c + r


def _zup(blocks, X, Y, zmax):
    """z of the blocks' union surface over each (x, y) on the +z side (0 off the blocks): every block is centred on the midline, so
    the union's measure rises with |z| and a bisection finds it."""
    from creature_maker.blockout import _f
    lo = np.zeros(X.size); hi = np.full(X.size, zmax); x, y = X.ravel(), Y.ravel()
    inside0 = _f(np.c_[x, y, lo], blocks).min(1) <= 1
    for _ in range(28):
        m = (lo + hi) / 2; ok = _f(np.c_[x, y, m], blocks).min(1) <= 1; lo = np.where(ok, m, lo); hi = np.where(ok, hi, m)
    return np.where(inside0, lo, 0.0).reshape(X.shape)


def covers(D, poly):
    """the two cover plates as smooth shells (clean pass round 2: a shell between the blocks and the blocks grown, Blender-cut, kept
    every rib of the blocks under it and read as three faceted strips). Over the side outline poly the plate's inner face is the head
    blocks' surface with its rib valleys bridged (a grey closing along the body as long as COVER_BRIDGE of the head, then smoothed),
    its outer face COVER_T x the head's half-width further out, lifted smoothly where a block would stand through; it keeps to where that surface stands COVER_MID x the half-width off
    the midline, its outline the side outline's hull cleaned of kinks. Returns {'opercleL': (V, F), 'opercleR': (V, F)}, record units."""
    from scipy import ndimage as ndi
    from skimage.measure import find_contours, approximate_polygon
    from PIL import Image, ImageDraw
    from creature_maker.blockout import _plate2d
    P = np.asarray(poly, float); lo = np.r_[P.min(0) - 0.05, -1.0]; hi = np.r_[P.max(0) + 0.05, 1.0]
    head = [q for q in D['segments'] + [p for p in D['prims'] if p['kind'] == 'joint'] if _overlaps(q, lo, hi)]
    if not head: return {}
    zs = max(q['c'][2] + q['r'][2] for q in head); h = COVER_GRID
    gx = np.arange(lo[0], hi[0], h); gy = np.arange(lo[1], hi[1], h); X, Y = np.meshgrid(gx, gy)
    Z = _zup(head, X, Y, 1.5 * zs)
    k = max(int(round(COVER_BRIDGE * (gx[-1] - gx[0]) / h)), 1)
    Zs = ndi.gaussian_filter(ndi.grey_closing(Z, size=(1, 2 * k + 1)), k / 2); Zo = Zs + COVER_T * zs
    for _ in range(4):        # lifted, smoothly, wherever a block would stand through the outer face (a hard max printed the ribs)
        d = np.maximum(Z + COVER_GAP * zs - Zo, 0)
        if d.max() <= 0: break
        Zo = Zo + ndi.gaussian_filter(ndi.grey_dilation(d, size=(2 * k + 1, 2 * k + 1)), k / 2) * 1.2
    Zo = np.maximum(Zo, Z + COVER_GAP * zs)
    # the outline's hull (a traced preopercle's forward lower arm stood off the plate as a tab), down to where the bridged surface
    # (not the ribbed one: its contour scalloped the plate's lower edge) comes COVER_MID x the half-width off the midline
    from scipy.spatial import ConvexHull
    Hh = P[ConvexHull(P).vertices]
    im = Image.new('L', (len(gx), len(gy)), 0); ImageDraw.Draw(im).polygon([tuple((q - lo[:2]) / h) for q in Hh], fill=1)
    M = (np.asarray(im, bool)) & (Zs >= COVER_MID * zs) & (Z > 0)
    r = max(int(round(COVER_ROUND / h)), 1); disk = np.add.outer(np.arange(-r, r + 1) ** 2, np.arange(-r, r + 1) ** 2) <= r * r
    M = ndi.binary_opening(ndi.binary_closing(np.pad(M, 2 * r + 2), disk), disk)[2 * r + 2:-2 * r - 2, 2 * r + 2:-2 * r - 2]
    lab, n = ndi.label(M)
    if n == 0: return {}
    M = lab == (np.argmax(np.bincount(lab.ravel())[1:]) + 1)
    C = max(find_contours(ndi.gaussian_filter(np.pad(M, 2).astype(float), 1.0), 0.5), key=len) - 2
    Q = approximate_polygon(C, 0.35)[:-1][:, ::-1] * h + lo[:2]
    P2, T, nb = _plate2d(Q, COVER_STEP, border=True)
    ij = [(P2[:, 1] - lo[1]) / h, (P2[:, 0] - lo[0]) / h]
    zo = ndi.map_coordinates(Zo, ij, order=1); zb = ndi.map_coordinates(Z, ij, order=1) + COVER_GAP * zs
    # the rim seats on the blocks: within COVER_SEAT of the outline the outer face comes down onto the ribs (bridging them to the very
    # edge, the plate stood off every rib valley as a dark hole in the top and front views, clean pass round 2)
    Bq = P2[:nb]; dist = np.min(np.linalg.norm(P2[:, None] - Bq[None], axis=2), 1)
    w = np.clip(dist / COVER_SEAT, 0, 1) if COVER_SEAT > 0 else np.ones(len(P2)); w = w * w * (3 - 2 * w)
    zo = zb + w * (zo - zb); zi = zo - COVER_T * zs; n = len(P2)
    V = np.r_[np.c_[P2, zo], np.c_[P2, zi]]
    e1, e2 = P2[T[:, 1]] - P2[T[:, 0]], P2[T[:, 2]] - P2[T[:, 0]]
    T = np.where((e1[:, 0] * e2[:, 1] - e1[:, 1] * e2[:, 0])[:, None] < 0, T[:, ::-1], T)    # counter-clockwise seen from +z
    F = [list(t) for t in T] + [[n + t[0], n + t[2], n + t[1]] for t in T]              # outer face up, inner face down
    B = P2[:nb]; ccw = (B[:, 0] * np.roll(B[:, 1], -1) - np.roll(B[:, 0], -1) * B[:, 1]).sum() > 0
    F += [[n + i, n + (i + 1) % nb, (i + 1) % nb, i] if ccw else [i, (i + 1) % nb, n + (i + 1) % nb, n + i] for i in range(nb)]   # the rim, outward
    out = {'opercleL': (V, F)}
    Vr = V * [1, 1, -1]; out['opercleR'] = (Vr, [f[::-1] for f in F])
    return out
