"""Blockout tier 3, SURGICAL: cutters (holes) and the moving head blocks they uncover. numpy + skimage marching cubes.

Gary 28 Nov: "blockouts can be used for holes too? mouth anatomy etc." and "group the primitives based on resolution: big/mid
blockouts, and then another set for surgical precision, crevices". The blockout's primitives come in three tiers, and each tier is
also a level of detail (a far fish needs only the first):

  tier 1  masses    the spine chain's superquadric segments (blockout.segments)
  tier 2  forms     joint spheroids, fin-root lozenges, fin plates, and the moving head blocks made here: the lower jaw (on the jaw
                    bone), the two gill-cover plates (on the opercle bones), the eyeballs
  tier 3  surgical  cutters: the mouth cavity, the gill slits, the eye sockets

A cutter is an ellipsoid (the same measure as every block, blockout._f) subtracted from the blocks of the bones it touches. A bone
with a cutter is meshed from its field (max(blocks, -cutters)) by marching cubes instead of from its block meshes; every other bone
keeps its plain block meshes, so a blockout without cutters is unchanged. All positions come from the record: mouth line and jaw joint
(mouth), gill cover rear and preopercle lines and opercle hinge (gills), skeleton.eye (eyes).

  mouth   the lower jaw is the half lozenge under the line from the mouth tip to the jaw joint, a block on the jaw bone with the mouth
          cavity cut into it (open on top). The head's blocks lose the same half lozenge (a hair larger), so at rest the jaw fills
          its own place and the palate closes the cavity; the gape clip turns the jaw down about the joint and the cavity shows.
  gills   each cover is a plate over the head's skin between the preopercle and the rear line, standing a hair proud, on its opercle
          bone; a slit is cut into the head just behind the rear line, under the plate's overhang. The flare clip swings the plate out
          and the slit shows.
  eyes    a socket is cut where the eye sits on the blocks' surface, and an eyeball (a sphere of the eye's own size) is set into it,
          standing record eye.bulge eye radii past the skin.
"""
import numpy as np
from PIL import Image, ImageDraw
from skimage.measure import marching_cubes
from scipy.ndimage import distance_transform_edt
from .blockout import _f, _ellipsoid

CUT_VOX = 0.006          # DEFAULT: marching-cubes voxel of a carved bone, SL (a 0.6 % SL step: finer than the slit and the socket rim)
JAW_PAD = 1.03           # DEFAULT: the head's jaw cut stands this much outside the jaw block (a hairline seam at rest)
JAW_TOP = 0.05           # DEFAULT: the jaw block's lens above the jaw line, share of its depth (the jaw line is the block's flat top)
JAW_DEPTH = 0.85         # DEFAULT: the lower jaw's depth under the jaw line at its middle, share of the head blocks' depth there
CAVITY_W, CAVITY_H = 0.70, 0.70   # DEFAULT: the mouth cavity in the jaw block: share of the jaw's half-width and of its depth
CAVITY_BACK = 0.12       # DEFAULT: the cavity starts this share of the jaw's length behind the tip (the chin stays solid)
SLIT_W = 0.012           # DEFAULT: gill slit width behind the cover's rear line, SL
SLIT_DEPTH = 0.45        # DEFAULT: the slit's reach into the head, share of the head's half-width there
COVER_SOFT = 0.04        # DEFAULT: the soft minimum's width, block measure
COVER_PROUD = 1.04       # DEFAULT: the cover plate's outer face, in block measure (1 = the skin): a plate a hair over the skin
COVER_IN = 0.80          # DEFAULT: its inner face, in block measure (hidden inside the head)
COVER_OVER = 1.2         # DEFAULT: the plate overhangs the slit by this many slit widths, so at rest the slit is hidden
COVER_MID = 0.25         # DEFAULT: the plates stop this share of the half-width short of the midline (left and right swing apart),
                         # as pose.cover_weights holds the midline
SOCKET = 1.15            # DEFAULT: eye socket radius over the eye's radius (a ring of shadow round the eyeball)
SOCKET_DEPTH = 1.2       # DEFAULT: the socket's depth into the head over the eye's radius


def _zsurf(blocks, x, y, zmax):
    """z of the blocks' surface at (x, y) on the +z side (0 when (x, y) is outside every block)."""
    z = np.linspace(0, zmax, 400); f = _f(np.c_[np.full_like(z, x), np.full_like(z, y), z], blocks).min(1)
    out = np.where(f > 1)[0]
    return float(z[out[0]]) if len(out) and out[0] > 0 else 0.0


def _frame(e2):
    """rotation whose columns are: along e2 (x, y), square to it toward +y, and +z."""
    e = np.array([e2[0], e2[1], 0.0]); e /= np.linalg.norm(e); n = np.array([-e[1], e[0], 0.0])
    if n[1] < 0: n = -n
    return np.stack([e, n, [0, 0, 1.0]], 1)


def mouth(rec, blocks):
    """the lower jaw block (tier 2) and two cutters: the jaw's place out of the head, the cavity out of the jaw."""
    ml = np.asarray(rec['mouth']['line'], float); tip = ml[np.argmin(ml[:, 0])]; J = np.asarray(rec['jaw_joint'], float)
    L = float(np.linalg.norm(J - tip))
    if L < 1e-3: return None
    R = _frame(J - tip); m = (tip + J) / 2; c = np.array([m[0], m[1], 0.0])
    # depth: the head blocks' depth under the jaw line at its middle (down to where the blocks end)
    y = np.linspace(m[1], m[1] - 1.0, 400); f = _f(np.c_[np.full_like(y, m[0]), y, np.zeros_like(y)], blocks).min(1)
    below = np.where(f > 1)[0]; d = JAW_DEPTH * float(m[1] - y[below[0]]) if len(below) else 0.3 * L
    w = _zsurf(blocks, m[0], m[1] - d / 2, 1.0)
    if d < 1e-3 or w < 1e-3: return None
    jaw = dict(kind='jaw', tier=2, c=c.tolist(), r=[L / 2, JAW_TOP * d, w], ry_lo=d, R=R.tolist(), bone='jaw')
    cut_head = dict(kind='cut_jaw', tier=3, c=c.tolist(), r=[JAW_PAD * L / 2, JAW_PAD * JAW_TOP * d, JAW_PAD * w], ry_lo=JAW_PAD * d,
                    R=R.tolist(), target='head')
    cc = c + R[:, 0] * CAVITY_BACK * L / 2
    cavity = dict(kind='cut_mouth', tier=3, c=cc.tolist(), r=[(1 - CAVITY_BACK / 2) * L / 2, 0.5 * d, CAVITY_W * w], ry_lo=CAVITY_H * d,
                  R=R.tolist(), target='jaw')
    return dict(jaw=jaw, cutters=[cut_head, cavity], L=L, depth=d, width=w)


def _cover_poly(rec):
    """the cover plate's side outline: from the preopercle line to the rear line pushed out along its own normal by the overhang
    (pushed back in x alone, the rear line's lower arm, which runs forward under the cover, left its slit uncovered: anthias)."""
    rear = np.asarray(rec['cover']['rear'], float); pre = np.asarray(rec['cover']['preop'], float)
    # each line keeps its own order (the preopercle's lower arm runs forward along the throat: sorted by height it crossed itself,
    # filefish), turned so the rear line runs up and the preopercle down
    if rear[0, 1] > rear[-1, 1]: rear = rear[::-1]
    if pre[0, 1] < pre[-1, 1]: pre = pre[::-1]
    hy = float(rec['opercle_hinge'][1]); yhi = max(rear[-1, 1], pre[0, 1], hy)
    mid = np.vstack([rear, pre]).mean(0); t = np.gradient(rear, axis=0); t /= np.maximum(np.linalg.norm(t, axis=1, keepdims=True), 1e-9)
    n = np.c_[t[:, 1], -t[:, 0]]; n *= np.sign(((rear - mid) * n).sum(1, keepdims=True) + 1e-12)       # outward: away from the cover
    ro = rear + n * COVER_OVER * SLIT_W; o = COVER_OVER * SLIT_W
    ro = np.vstack([ro[0] - t[0] * o, ro, ro[-1] + t[-1] * o])          # and past both ends of the slit
    top = [[ro[-1, 0], yhi + 0.5 * SLIT_W], [pre[0, 0] - 0.01, yhi + 0.5 * SLIT_W]]
    return np.vstack([ro, top, pre - [0.01, 0]]), rear


def gills(rec, blocks):
    """two cover plates (tier 2, on the opercle bones, made from the voxel field in carve) and the slit cutters behind each rear line."""
    if not rec.get('cover') or 'rear' not in rec['cover'] or 'preop' not in rec['cover']: return None
    poly, rear = _cover_poly(rec); cut = []
    for sg in (1, -1):
        for a, b in zip(rear[:-1], rear[1:]):
            t = b - a; s = float(np.linalg.norm(t))
            if s < 1e-6: continue
            R = _frame(t); nb = R[:, 1] if R[0, 1] > 0 else -R[:, 1]          # the curve's normal pointing back (+x side)
            mid = (a + b) / 2 + nb[:2] * SLIT_W / 2; zs = _zsurf(blocks, mid[0], mid[1], 1.0)
            if zs <= 0: continue
            cut.append(dict(kind='cut_gill', tier=3, c=[float(mid[0]), float(mid[1]), sg * zs], r=[0.7 * s, SLIT_W / 2, SLIT_DEPTH * zs],
                            R=R.tolist(), target='head'))
    return dict(poly=poly.tolist(), cutters=cut)


def eyes(rec, blocks):
    E = rec['eye']; er = E['d'] / 2; x, y = E['x'], E['y']; zs = _zsurf(blocks, x, y, 1.0)
    if zs <= 0: return None
    balls, cut = [], []; sink = 1.0 - float(E.get('bulge', 0.12))     # the eye stands record eye.bulge eye radii past the skin, as in form.py
    for sg in (1, -1):
        balls.append(dict(kind='eyeball', tier=2, c=[x, y, sg * (zs - sink * er)], r=[er, er, er], bone='head'))
        cut.append(dict(kind='cut_eye', tier=3, c=[x, y, sg * zs], r=[SOCKET * er, SOCKET * er, SOCKET_DEPTH * er], target='head'))
    return dict(balls=balls, cutters=cut)


def _grid(lo, hi, h):
    n = np.maximum(np.ceil((hi - lo) / h).astype(int) + 1, 2)
    ax = [lo[i] + h * np.arange(n[i]) for i in range(3)]
    X, Y, Z = np.meshgrid(*ax, indexing='ij'); return np.c_[X.ravel(), Y.ravel(), Z.ravel()], n


def _bbox(q):
    """a box round a primitive: its semi-axes on the x, y, z axes, or its largest semi-axis every way when it is turned."""
    c = np.asarray(q['c'], float); r = np.asarray(q['r'], float).copy()
    if q.get('R') is not None: r[:] = max(r.max(), q.get('ry_lo') or 0); return c - r, c + r
    lo = c - r; hi = c + r
    if q.get('ry_lo') is not None: lo[1] = c[1] - q['ry_lo']
    return lo, hi


def _samples(q):
    """points through a primitive's volume: its centre and its mesh shrunk to 0.9, 0.6 and 0.3."""
    v, _ = _ellipsoid(q['c'], q['r'], 10, 6, q.get('R'), q.get('n'), q.get('ry_lo')); c = np.asarray(q['c'], float)
    return np.vstack([c[None]] + [c + k * (v - c) for k in (0.9, 0.6, 0.3)])


def _mesh(field, n, lo, h):
    vol = field.reshape(n)
    if vol.min() > 0 or vol.max() < 0: return None
    V, F, _, _ = marching_cubes(vol, 0.0, spacing=(h, h, h), gradient_direction='descent')
    return V + lo, F.tolist()


def carve(blocks, cutters, h=CUT_VOX):
    """mesh of the union of blocks minus the cutters, by marching cubes. None when nothing is left."""
    lo = np.min([_bbox(q)[0] for q in blocks], 0) - 2 * h; hi = np.max([_bbox(q)[1] for q in blocks], 0) + 2 * h
    P, n = _grid(lo, hi, h)
    u = _f(P, blocks).min(1) - 1.0
    if cutters: u = np.maximum(u, -(_f(P, cutters).min(1) - 1.0))
    return _mesh(u, n, lo, h)


def cover_plates(blocks, poly, h=CUT_VOX):
    """the two cover plates: the shell of the head's blocks between block measure COVER_IN and COVER_PROUD, inside the cover's side
    outline (poly, x y), off the midline. A side-outline mask is a signed distance from a raster of the outline."""
    poly = np.asarray(poly, float); pad = 3 * h
    lo2, hi2 = poly.min(0) - pad, poly.max(0) + pad
    zmax = max(_zsurf(blocks, *p, 1.0) for p in poly) * 1.2 + pad
    lo = np.array([lo2[0], lo2[1], 0.0]); hi = np.array([hi2[0], hi2[1], zmax])
    P, n = _grid(lo, hi, h)
    im = Image.new('L', (int(n[0]), int(n[1])), 0)
    ImageDraw.Draw(im).polygon([((p[0] - lo[0]) / h, (p[1] - lo[1]) / h) for p in poly], fill=1)
    inside = np.array(im, bool).T                                          # (nx, ny)
    sd = (distance_transform_edt(~inside) - distance_transform_edt(inside)) * h   # < 0 inside the outline
    sd = np.repeat(sd[:, :, None], n[2], 2).ravel()
    # ~ radial share of the skin (1 on it), the blocks joined by a soft minimum: a plain minimum keeps the crest where two blocks
    # meet, and a plate offset from it stood in folds at every block (round 1)
    fk = np.sqrt(_f(P, blocks)); fm = -COVER_SOFT * np.log(np.exp(-(fk - fk.min(1, keepdims=True)) / COVER_SOFT).sum(1)) + fk.min(1)
    zs = np.array([_zsurf(blocks, *p, 1.0) for p in poly]).max()
    u = np.maximum.reduce([fm - COVER_PROUD, COVER_IN - fm, sd, COVER_MID * zs - P[:, 2]])
    out = []
    for sg in (1, -1):
        m = _mesh(u, n, lo, h)
        if m is None: return []
        V, F = m; V = V * np.array([1, 1, sg])
        if sg < 0: F = [f[::-1] for f in F]
        out.append(dict(name='opercleL' if sg > 0 else 'opercleR', V=V, F=F))
    return out


def head_kit(rec, segs):
    """the tier 2 head blocks and tier 3 cutters for a record. segs: the spine chain (tier 1)."""
    out = dict(blocks=[], cutters=[], notes=[])
    mo = mouth(rec, segs)
    if mo: out['blocks'].append(mo['jaw']); out['cutters'] += mo['cutters']
    else: out['notes'].append('no mouth: jaw line too short or outside the blocks')
    gi = gills(rec, segs)
    if gi: out['cutters'] += gi['cutters']; out['cover_poly'] = gi['poly']
    else: out['notes'].append('no gill cover lines in the record')
    ey = eyes(rec, segs)
    if ey: out['blocks'] += ey['balls']; out['cutters'] += ey['cutters']
    else: out['notes'].append('eye outside the blocks')
    return out


def _touch(q, blocks):
    """the cutter takes something out of these blocks: a point through its volume lies inside one of them."""
    return bool((_f(_samples(q), blocks).min(1) <= 1).any())


# meshoptimizer (zeux/meshoptimizer, MIT; as blender/lods.py) thins a marching-cubes mesh: the lattice's even triangles, many times
# what the blocks' own meshes spend, carry nothing a blockout needs. The PyPI wrapper declares no argtypes, so the C signature is here.
import ctypes as _C
import meshoptimizer.simplifier as _ms
_P = _C.POINTER; _simp = _ms.lib.meshopt_simplify
_simp.argtypes = [_P(_C.c_uint), _P(_C.c_uint), _C.c_size_t, _P(_C.c_float), _C.c_size_t, _C.c_size_t, _C.c_size_t, _C.c_float, _C.c_uint,
                  _P(_C.c_float)]
_simp.restype = _C.c_size_t
MC_TRIS = 1500           # DEFAULT: a carved bone's mesh after thinning, triangles (a plain bone spends 2 x 196 + joint ~120)
PIECE_TRIS = 600         # DEFAULT: a moving piece's (jaw, cover plate) mesh after thinning
MC_ERR = 0.004           # DEFAULT: the thinning's largest error, share of the mesh's extent


def thin(V, F, tris, err=MC_ERR):
    idx = np.ascontiguousarray(np.asarray(F, np.uint32).ravel()); P = np.ascontiguousarray(V, np.float32); dst = np.zeros_like(idx)
    if len(idx) // 3 <= tris: return V, F
    n = _simp(dst.ctypes.data_as(_P(_C.c_uint)), idx.ctypes.data_as(_P(_C.c_uint)), len(idx), P.ctypes.data_as(_P(_C.c_float)), len(P), 12,
              int(tris) * 3, float(err), 0, None)
    T = dst[:n].reshape(-1, 3); used = np.unique(T); remap = np.full(len(V), -1); remap[used] = np.arange(len(used))
    return np.asarray(V)[used], remap[T].tolist()


def build(prims, kit, h=CUT_VOX):
    """carve every spine bone a head cutter touches and mesh the moving pieces. Returns (carved: {bone: (V, F)}, pieces: [dict(name,
    bone, V, F, mat)]) where bone is a spine index or the name of a head bone."""
    head_cut = [q for q in kit['cutters'] if q['target'] == 'head']; carved = {}
    for b in sorted(set(q['bone'] for q in prims)):
        bl = [q for q in prims if q['bone'] == b]; cu = [q for q in head_cut if _touch(q, bl)]
        if not cu: continue
        m = carve(bl, cu, h)
        if m: carved[b] = thin(*m, MC_TRIS)
    pieces = []
    jaw = [q for q in kit['blocks'] if q['kind'] == 'jaw']
    if jaw:
        m = carve(jaw, [q for q in kit['cutters'] if q['target'] == 'jaw'], h / 2)
        if m: V_, F_ = thin(*m, PIECE_TRIS); pieces.append(dict(name='jaw', bone='jaw', V=V_, F=F_, mat='jaw'))
    if kit.get('cover_poly'):
        segs = [q for q in prims if q['kind'] == 'segment']
        for p in cover_plates(segs, kit['cover_poly'], h / 2):
            V_, F_ = thin(p['V'], p['F'], PIECE_TRIS); pieces.append(dict(name=p['name'], bone=p['name'], V=V_, F=F_, mat='cover'))
    for k, q in enumerate(q for q in kit['blocks'] if q['kind'] == 'eyeball'):
        v, f = _ellipsoid(q['c'], q['r'], 12, 8); pieces.append(dict(name=f'eye_{"L" if q["c"][2] > 0 else "R"}', bone='head', V=v, F=f, mat='eye'))
    return carved, pieces


CT_IN = 0.99             # DEFAULT: share of the jaw block's vertices inside the head's jaw cut at rest (the jaw fills its own place)


def cut_checks(kit, pieces):
    """CT1 the jaw block lies inside the jaw's cut out of the head at rest (no jaw through the skull), with a cavity cut in it;
    CT2 every gill slit lies under its cover plate's overhang at rest (side view), and both plates were made;
    CT3 each eyeball's centre lies in its socket. A part the record cannot place (no cover lines) is noted, not failed."""
    R = {}; P = {p['name']: p for p in pieces}; cut = {k: [q for q in kit['cutters'] if q['kind'] == k] for k in ('cut_jaw', 'cut_mouth', 'cut_gill', 'cut_eye')}
    if 'jaw' in P and cut['cut_jaw']:
        R['CT1_jaw_in_cut'] = round(float((_f(np.asarray(P['jaw']['V']), cut['cut_jaw']).min(1) <= 1.0).mean()), 3)
        R['CT1_pass'] = R['CT1_jaw_in_cut'] >= CT_IN and bool(cut['cut_mouth'])
    else: R['CT1_pass'] = None
    if cut['cut_gill'] and kit.get('cover_poly'):
        poly = np.asarray(kit['cover_poly']); im = Image.new('L', (2000, 2000), 0); lo = poly.min(0) - 0.05; k = 2000 / (poly.max(0) - lo + 0.05).max()
        ImageDraw.Draw(im).polygon([tuple((q - lo) * k) for q in poly], fill=1); M = np.array(im, bool)
        c = np.array([q['c'][:2] for q in cut['cut_gill']]); ij = ((c - lo) * k).astype(int)
        R['CT2_slits_covered'] = round(float(M[ij[:, 1].clip(0, 1999), ij[:, 0].clip(0, 1999)].mean()), 3)
        R['CT2_pass'] = R['CT2_slits_covered'] >= CT_IN and 'opercleL' in P and 'opercleR' in P
    else: R['CT2_pass'] = None
    balls = [q for q in kit['blocks'] if q['kind'] == 'eyeball']
    if balls and cut['cut_eye']:
        R['CT3_eye_in_socket'] = bool((_f(np.array([q['c'] for q in balls]), cut['cut_eye']).min(1) <= 1.0).all()); R['CT3_pass'] = R['CT3_eye_in_socket']
    else: R['CT3_pass'] = None
    R['CT_pass'] = None if all(R[k] is None for k in ('CT1_pass', 'CT2_pass', 'CT3_pass')) else all(R[k] is not False for k in ('CT1_pass', 'CT2_pass', 'CT3_pass'))
    return R
