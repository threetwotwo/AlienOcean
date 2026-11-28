"""export_pieces.py 0.1.0 (Dress the lagoon thread, 27 Nov 2026): ports the approved key frame's content to Godot pieces.

PORT, DON'T REBUILD: the sources are the assets the key frame (papers/process/art_bible/style_level/keyframe/src/scene.py,
layout.json, Blender 15 Nov) already used, unchanged:
  rocks   seabed/handover/reef_kit_v18/SB_Bommie_<n>.fbx (+ SB_Skirt_<n>.fbx sand skirt), their own UCX hulls (CoACD era kit)
  corals  life/colony_maker/lagoon_slice/kinds_v27/obj/<kind>.obj, hulls from tools/collision/acd_hulls.py (CoACD)
  grass   island/lagoon/lagoon_slice_v24.zip LG_seagrass_*_L0.glb (the colony maker's grown meadow tiles), soft: no blocking hull
One GLB per source, mesh at its own origin, Godot axes (glTF Y up: godot = (x, z, -y) of Blender). Collision rides in the same GLB as
mesh nodes named <piece>_COL_<k> (convex hulls) or <piece>_TRI (concave, static only); world_dress/dress_cell.gd turns them into shapes.
COLOR_0 is written linear (glTF spec; LESSONS world: meadow/colony/debris wrote sRGB bytes until 21 Nov).

Run:  <bpy python> export_pieces.py <out_dir> [slice_dir]
Writes <out_dir>/<piece>.glb and <out_dir>/pieces.json {piece: {tris, hulls, collision, src, src_md5}}.
"""
import bpy, bmesh, sys, os, json, glob, hashlib, math
from mathutils import Vector, Matrix
import numpy as np

P = '/mnt/project-files/'
KIT = P + 'seabed/handover/reef_kit_v18/'
CORAL = P + 'life/colony_maker/lagoon_slice/kinds_v27/obj/'
OUT = sys.argv[1]
SLICE = sys.argv[2] if len(sys.argv) > 2 else '/home/user/w/ue/slice_zip/'
LAYOUT = json.load(open(P + 'papers/process/art_bible/style_level/keyframe/src/layout.json'))
sys.path.insert(0, P + 'tools/collision'); from acd_hulls import decompose
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import kf_paint
os.environ.setdefault('RUBBLE_PIECE', 'fracture')   # Terrain's v11 rule as the reef kit runs it: pieces broken out of the rock by cause, aged
sys.path.insert(0, P + 'seabed/tools'); import rubble_rule as rr
sys.path.insert(0, P + 'papers/process/art_bible/style_level/keyframe/src')   # habitat.py: the key frame rig's habitat rules
import random
# skirt edge (AO thread 28 Nov: CORTAO showed the bank skirts' 5 cm-grid outer edge as a stair-step line on the sand): past the bank
# (habitat.bank is 0 beyond w = 0.45 m) the skirt ramps down EDGE_DROP to its 0.6 m edge, so the drawn sand covers the edge
EDGE_DROP = float(os.environ.get('SKIRT_EDGE_DROP', 0.04))
CORAL_R = {}    # coral piece -> half its plan extent (the v7 rig's colony radius from the bound box)
ROCK_MESH = {}  # rock piece -> (V, F) in its piece frame, for seating loose pieces on rock tops
OUTLINES = {}   # piece -> ground outline (centre, 72 bin radii) in the piece frame, for the habitat rules
MANIFEST = json.load(open(os.environ['DRESS_MANIFEST'])) if os.environ.get('DRESS_MANIFEST') else None
HEADS = P + 'world/rock/lagoon/heads_v18c/'   # Rock's heads_v18c (Gary chose v18c, 21 Nov); fitted onto the kit frame as the key frame rig did
HEADS_FIT = P + 'papers/process/art_bible/style_level/keyframe/src/heads_v18c_fit.json'
os.makedirs(OUT, exist_ok=True)
REPORT = {}

def md5(p): return hashlib.md5(open(p, 'rb').read()).hexdigest()
def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)
def meshes(): return [o for o in bpy.data.objects if o.type == 'MESH']

def hull_obj(name, pts):
    me = bpy.data.meshes.new(name); bm = bmesh.new()
    for p in pts: bm.verts.new(Vector(p))
    bmesh.ops.convex_hull(bm, input=bm.verts); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o); return o

def mesh_arrays(o):
    me = o.data; me.calc_loop_triangles() if hasattr(me, 'calc_loop_triangles') else None
    V = np.array([v.co[:] for v in me.vertices]); N = np.array([v.normal[:] for v in me.vertices]); E = np.array([e.vertices[:] for e in me.edges])
    return V, N, E

def set_paint(o, rgba, name='kf_paint'):
    me = o.data
    for a in list(me.color_attributes): me.color_attributes.remove(a)
    a = me.color_attributes.new(name, 'FLOAT_COLOR', 'POINT'); a.data.foreach_set('color', rgba.astype(np.float32).ravel())
    me.color_attributes.active_color = a; me.color_attributes.render_color_index = 0

def get_vc(o):
    ca = o.data.color_attributes
    if not len(ca): return None
    a = ca[0]; n = len(a.data); c = np.empty(n * 4, np.float32); a.data.foreach_get('color', c); c = c.reshape(-1, 4)
    if a.domain == 'CORNER':   # to points
        idx = np.empty(len(o.data.loops), np.int64); o.data.loops.foreach_get('vertex_index', idx)
        out = np.zeros((len(o.data.vertices), 4)); cnt = np.zeros(len(o.data.vertices)); np.add.at(out, idx, c); np.add.at(cnt, idx, 1)
        c = out / np.maximum(cnt, 1)[:, None]
    return c

def outline(V, z0=-0.05, z1=0.25, bins=72):
    """habitat.outline (Style 15 Nov): the rock's ground outline, centre + outer radius by bearing of the skin between z0 and z1."""
    W = V[(V[:, 2] > z0) & (V[:, 2] < z1)]; c = W[:, :2].mean(0); d = W[:, :2] - c
    k = ((np.arctan2(d[:, 1], d[:, 0]) + math.pi) / (2 * math.pi) * bins).astype(int) % bins; R = np.zeros(bins)
    np.maximum.at(R, k, np.hypot(d[:, 0], d[:, 1]))
    for _ in range(3):
        z = R == 0; R[z] = np.maximum(np.roll(R, 1), np.roll(R, -1))[z]
    return c, R

def head_r_of(R):
    return lambda a: float(R[int((a + math.pi) / (2 * math.pi) * len(R)) % len(R)])

def tris(o): return sum(len(p.vertices) - 2 for p in o.data.polygons)

def finish(piece, body, cols, kind, src):
    """body: the visible mesh objects (joined to one); cols: collision objects; export one GLB at the body's own origin."""
    bpy.context.view_layer.update()
    for o in [body] + cols:
        o.select_set(True)
    bpy.ops.object.select_all(action='DESELECT')
    body.name = piece; body.data.name = piece
    ca = body.data.color_attributes
    if len(ca): ca.active_color = ca[0]; ca.render_color_index = 0
    bpy.ops.object.select_all(action='SELECT')
    path = OUT + piece + '.glb'
    bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', use_selection=True, export_yup=True, export_apply=True,
                              export_vertex_color='ACTIVE', export_all_vertex_colors=False, export_materials='NONE',
                              export_normals=True, export_texcoords=True, export_animations=False)
    REPORT[piece] = {'kind': kind, 'tris': tris(body), 'hulls': len([c for c in cols if '_COL_' in c.name]),
                     'collision': ('convex hulls' if any('_COL_' in c.name for c in cols) else 'concave trimesh' if cols else 'soft (no blocking hull)'),
                     'src': src.replace(P, ''), 'src_md5': md5(src) if os.path.isfile(src) else ''}
    print('PIECE', piece, REPORT[piece])

def join(objs):
    objs = [o for o in objs if o.type == 'MESH']
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs: o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1: bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return o

# ---------- rocks (heads) + their sand skirts ----------
rock_files = sorted({r['f'] for r in LAYOUT['rocks'] + LAYOUT['rocks_far']})
for f in rock_files:
    clear(); bpy.ops.import_scene.fbx(filepath=KIT + f)
    ms = meshes(); ucx = [o for o in ms if o.name.upper().startswith('UCX')]; body = [o for o in ms if o not in ucx]
    for o in ms:   # bake parent/axis transforms
        o.select_set(True)
    bpy.context.view_layer.objects.active = ms[0]
    bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM'); bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    piece = f.replace('.fbx', '')
    b = join(body)
    V, N, E = mesh_arrays(b); set_paint(b, kf_paint.paint('rock', V, N, E)); OUTLINES[f.replace('.fbx', '')] = outline(V)
    ROCK_MESH[piece] = (V.copy(), np.array([p.vertices[:] for p in b.data.polygons if len(p.vertices) == 3]))
    for k, u in enumerate(sorted(ucx, key=lambda o: o.name)): u.name = '%s_COL_%02d' % (piece, k)
    finish(piece, b, ucx, 'rock', KIT + f)
    sk = KIT + f.replace('Bommie', 'Skirt')
    if os.path.exists(sk):
        clear(); bpy.ops.import_scene.fbx(filepath=sk); ms = meshes()
        for o in ms: o.select_set(True)
        bpy.context.view_layer.objects.active = ms[0]
        bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM'); bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
        s = join([o for o in ms if not o.name.upper().startswith('UCX')]); sp = piece.replace('Bommie', 'Skirt')
        tri = s.copy(); tri.data = s.data.copy(); bpy.context.scene.collection.objects.link(tri); tri.name = sp + '_TRI'
        finish(sp, s, [tri], 'skirt', sk)

# ---------- Rock's heads_v18c b0 (the arch), fitted onto SB_Bommie_0's frame, CoACD hulls (the gate stays open) ----------
for kit_f, HF in json.load(open(HEADS_FIT)).items():
    clear(); bpy.ops.wm.obj_import(filepath=HEADS + HF['obj'], forward_axis='Y', up_axis='Z')
    b = join(meshes())
    b.data.transform(Matrix.Translation((HF['dx'], HF['dy'], 0)) @ Matrix.Rotation(math.radians(HF['yaw_deg']), 4, 'Z'))
    b.data.polygons.foreach_set('use_smooth', [True] * len(b.data.polygons)); b.data.update()
    V, N, E = mesh_arrays(b); set_paint(b, kf_paint.paint('rock', V, N, E))
    F = np.array([p.vertices[:] for p in b.data.polygons if len(p.vertices) == 3])
    hulls = decompose(V, F, max_hulls=32)
    piece = kit_f.replace('.fbx', '') + '_v18c'
    cols = [hull_obj('%s_COL_%02d' % (piece, k), h) for k, h in enumerate(hulls)]
    finish(piece, b, cols, 'rock', HEADS + HF['obj'])
    OUTLINES[piece] = outline(V); ROCK_MESH[piece] = (V.copy(), F.copy())
    # its foot (Fable r5: "the head stands on a hard base line"): (1) the gate fall, Terrain's seabed/tools/gate_fall.py v3 grown from
    # this head's own handoff_terrain.json (Rock's fall record: 14 blocks at both mouths, roof and wear chips), run on a flat seat with
    # the turned layout's local wave bearing 40 (the key frame rig's arch_seat_v18c_r5_w40), env GATE_FALL = its gate_fall.obj, head-local
    # like the head, so the same fit carries it; (2) the scatter apron, rubble_rule.apron v11 'fracture' (habitat.rubble in the rig),
    # settled round the head's real ground outline. Paint: every piece takes the kit's own colour ramp (reef_rock_rgb of its age shade,
    # x WALL_DARK); the rig's KF_Rock on gate-fall blocks put the 18 cm sand film over a whole low block (white chip, Style 21 Nov open
    # item: the film is a wall-foot rule), seen again in r6a. Blocks block (one hull each); chips are one concave mesh.
    c, R = OUTLINES[piece]; rf = float(np.median(R)); hr = head_r_of(R)
    fit = np.array(Matrix.Translation((HF['dx'], HF['dy'], 0)) @ Matrix.Rotation(math.radians(HF['yaw_deg']), 4, 'Z'))
    parts = []   # (kind, V, F, rgb or None)
    if os.environ.get('GATE_FALL'):
        Vs, Cs, cur_o, objs = [], [], None, []
        for ln in open(os.environ['GATE_FALL']):
            t = ln.split()
            if not t: continue
            if t[0] == 'o': objs.append([t[1], len(Vs), []])
            elif t[0] == 'v': Vs.append([float(x) for x in t[1:4]]); Cs.append([float(x) for x in t[4:6]])
            elif t[0] == 'f': objs[-1][2].append([int(x.split('/')[0]) - 1 for x in t[1:4]])
        Vs = np.array(Vs); Vs = Vs @ fit[:3, :3].T + fit[:3, 3]; Cs = np.array(Cs)
        for name, v0, Fo in objs:
            Fo = np.array(Fo); lo, hi = Fo.min(), Fo.max() + 1
            parts.append((name.split('_')[0], Vs[lo:hi], Fo - lo, rr.reef_rock_rgb(*Cs[lo])))
    ap = rr.apron(random.Random(21), rf, (0.7071, -0.7071), floor=lambda dx, dy: 0.0, head_r=hr, wave_deg=40.0)
    for pc in ap:
        rgb = rr.reef_rock_rgb(pc['shade'][0], pc['shade'][1])
        for Vp, Fp in pc['parts']:
            parts.append(('chip', rr.place(np.asarray(Vp), pc['yaw'], (c[0] + pc['dx'], c[1] + pc['dy'], 0.0)), np.asarray(Fp), rgb))
    clear(); me = bpy.data.meshes.new(piece + '_apron'); bm = bmesh.new(); cols_ = []; blk = []; chipV = []; chipF = []; nchip = 0
    for kind, Vp, Fp, rgb in parts:
        vs = [bm.verts.new(Vector(w)) for w in Vp]
        for fc in Fp:
            try: bm.faces.new([vs[i] for i in fc])
            except ValueError: pass
        cols_.append((kind, len(vs), rgb, Vp))
        if kind == 'block': blk.append(Vp)
        else: chipF.append(np.asarray(Fp) + nchip); chipV.append(Vp); nchip += len(Vp)
    bm.to_mesh(me); bm.free(); ao = bpy.data.objects.new(piece + '_apron', me); bpy.context.scene.collection.objects.link(ao)
    rgba = np.ones((sum(n for _k, n, _c, _v in cols_), 4)); k = 0
    for kind, n, rgb, _ in cols_:
        rgba[k:k + n, :3] = np.clip(np.asarray(rgb) * kf_paint.WALL_DARK, 0, 1); k += n
    set_paint(ao, rgba)
    cols = [hull_obj('%s_apron_COL_%02d' % (piece, j), b) for j, b in enumerate(blk)]
    tm = bpy.data.meshes.new(piece + '_apron_TRI'); tm.from_pydata(np.concatenate(chipV).tolist(), [], np.concatenate(chipF).tolist())
    tri = bpy.data.objects.new(piece + '_apron_TRI', tm); bpy.context.scene.collection.objects.link(tri)
    finish(piece + '_apron', ao, cols + [tri], 'rubble', P + 'seabed/tools/gate_fall.py + rubble_rule.py')
    print('FOOT', len(blk), 'blocks,', len(parts) - len(blk), 'chips, rf', round(rf, 2))
    # its sand skirt: the kit heads carry SB_Skirt_<n>; v18c has none (no_skirt) and Terrain's arch_seat_v18c is gone. So the key frame
    # rig's own rule for the hard contact line: habitat.bank (sand banked against the foot, Style 15 Nov), h 0.12 as arch_set.sh ran it,
    # on a 5 cm grid out to 0.6 m past the outline, inner edge kept 0.3 m under the rock. Concave collision (as the kit skirts).
    import habitat
    cell = 0.05; ext = float(R.max()) + 0.7
    xs = np.arange(c[0] - ext, c[0] + ext + 1e-9, cell); ys = np.arange(c[1] - ext, c[1] + ext + 1e-9, cell)
    GX, GY = np.meshgrid(xs, ys); Hb = habitat.bank(GX.ravel(), GY.ravel(), [((c[0], c[1]), hr, rf)], h=0.12).reshape(GX.shape)
    d = np.hypot(GX - c[0], GY - c[1]) - np.array([hr(a) for a in np.arctan2(GY - c[1], GX - c[0]).ravel()]).reshape(GX.shape)
    live = (d > -0.3) & (d < 0.6)
    idx = -np.ones(GX.shape, int); idx[live] = np.arange(live.sum())
    Vk = np.stack([GX[live], GY[live], Hb[live] - 0.005 - EDGE_DROP * np.clip((d[live] - 0.45) / 0.15, 0, 1)], 1); Fk = []
    for r_ in range(GX.shape[0] - 1):
        for c2 in range(GX.shape[1] - 1):
            a, b, e, f = idx[r_, c2], idx[r_, c2 + 1], idx[r_ + 1, c2], idx[r_ + 1, c2 + 1]
            if min(a, b, e, f) >= 0: Fk += [[a, b, f], [a, f, e]]
    clear(); sm = bpy.data.meshes.new(piece + '_skirt'); sm.from_pydata(Vk.tolist(), [], Fk); sm.update()
    so = bpy.data.objects.new(piece.replace('Bommie', 'Skirt'), sm); bpy.context.scene.collection.objects.link(so)
    so.data.polygons.foreach_set('use_smooth', [True] * len(so.data.polygons)); so.data.update()
    tri = so.copy(); tri.data = sm.copy(); bpy.context.scene.collection.objects.link(tri); tri.name = piece.replace('Bommie', 'Skirt') + '_TRI'
    finish(piece.replace('Bommie', 'Skirt'), so, [tri], 'skirt', P + 'papers/process/art_bible/style_level/keyframe/src/habitat.py bank')
    print('SKIRT', len(Vk), 'verts, bank max', round(float(Hb[live].max()), 3))

# ---------- corals: kinds_v27, CoACD hulls ----------
for c in sorted({c['f'] for c in LAYOUT['corals']}):
    clear(); bpy.ops.wm.obj_import(filepath=CORAL + c + '.obj', forward_axis='Y', up_axis='Z')
    b = join(meshes())
    V, N, E = mesh_arrays(b); set_paint(b, kf_paint.paint(c.split('_')[0], V, N, E, vc=get_vc(b)))
    F = np.array([p.vertices[:] for p in b.data.polygons if len(p.vertices) == 3])
    hulls = decompose(V, F)
    cols = [hull_obj('kf_%s_COL_%02d' % (c, k), h) for k, h in enumerate(hulls)]
    OUTLINES['kf_' + c] = outline(V, z0=-0.5, z1=0.3); CORAL_R['kf_' + c] = 0.5 * float(max(np.ptp(V[:, 0]), np.ptp(V[:, 1])))
    finish('kf_' + c, b, cols, 'coral', CORAL + c + '.obj')


def layout_heads():
    """Every rock and coral item of the place (MANIFEST), as habitat's heads [(c, head_r, rf)] and corals [(x, y, r)], key-frame metres."""
    heads, corals = [], []
    for it in MANIFEST['items']:
        p_ = it['p']
        if p_ not in OUTLINES: continue
        c_, R_ = OUTLINES[p_]; sc = float(it.get('s', 1.0)); rot = float(it.get('rot', 0.0))
        dz = float(it['at'][2]) if len(it['at']) > 2 else 0.0
        if p_ in ROCK_MESH and (abs(dz) > 1e-3 or abs(sc - 1.0) > 1e-3):   # a sunk or scaled rock: its ground outline where it meets OUR sand (v7: habitat.outline of the placed mesh)
            V0 = ROCK_MESH[p_][0] * sc; V0 = V0 + np.array([0.0, 0.0, dz]); c_, R_ = outline(V0); c_ = c_ / sc; R_ = R_ / sc
        M = Matrix.Translation(Vector(it['at'][:2] + [0.0])) @ Matrix.Rotation(rot, 4, 'Z')
        w = M @ Vector((c_[0] * sc, c_[1] * sc, 0))
        if p_.startswith('SB_') and not p_.endswith('_apron'):
            heads.append(((w.x, w.y), (lambda R2, r0, k: (lambda a: k * float(R2[int((a - r0 + math.pi) / (2 * math.pi) * len(R2)) % len(R2)])))(R_, rot, sc), sc * float(np.median(R_))))
        elif p_.startswith('kf_'):
            corals.append((w.x, w.y, float(np.median(R_))))
    return heads, corals

# ---------- sand banks for sunk rocks (key frame v7 patch rock): habitat.bank round the outline where the rock meets OUR sand ----------
# The v7 rig banks sand (h = bank arg, 0.12) against every rock's foot in its drawn floor; the kit heads carry their own SB_Skirt, the
# arch got SB_Skirt_0_v18c above. A manifest rock item with "bank": h (and "with": "<SB_Skirt_n_bank>") gets the same rule as a piece in
# the rock's own frame: outline taken from the rock as placed (scale s, sunk at.z), heights lifted by -at.z so the skirt lands on the sand
# when it is seated with the rock, all divided by s (the item's scale multiplies the piece).
BANKS = []   # (item, verts in key-frame metres as placed) for the rubble seat
if MANIFEST:
    import habitat
    for it in MANIFEST['items']:
        if not it.get('bank') or it['p'] not in ROCK_MESH: continue
        sc = float(it.get('s', 1.0)); dz = float(it['at'][2]) if len(it['at']) > 2 else 0.0; hb_ = float(it['bank'])
        V0 = ROCK_MESH[it['p']][0] * sc + np.array([0.0, 0.0, dz]); c, R = outline(V0); hr = head_r_of(R); rf = float(np.median(R))
        cell = 0.05; ext = float(R.max()) + 0.7
        xs = np.arange(c[0] - ext, c[0] + ext + 1e-9, cell); ys = np.arange(c[1] - ext, c[1] + ext + 1e-9, cell)
        GX, GY = np.meshgrid(xs, ys); Hb = habitat.bank(GX.ravel(), GY.ravel(), [((c[0], c[1]), hr, rf)], h=hb_).reshape(GX.shape)
        d = np.hypot(GX - c[0], GY - c[1]) - np.array([hr(a) for a in np.arctan2(GY - c[1], GX - c[0]).ravel()]).reshape(GX.shape)
        live = (d > -0.3) & (d < 0.6)
        idx = -np.ones(GX.shape, int); idx[live] = np.arange(live.sum())
        Vk = np.stack([GX[live], GY[live], Hb[live] - 0.005 - EDGE_DROP * np.clip((d[live] - 0.45) / 0.15, 0, 1)], 1); Fk = []
        for r_ in range(GX.shape[0] - 1):
            for c2 in range(GX.shape[1] - 1):
                a, b, e, f = idx[r_, c2], idx[r_, c2 + 1], idx[r_ + 1, c2], idx[r_ + 1, c2 + 1]
                if min(a, b, e, f) >= 0: Fk += [[a, b, f], [a, f, e]]
        r0 = float(it.get('rot', 0.0)); cz, sz = math.cos(r0), math.sin(r0)
        BANKS.append((it, Vk @ np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1.0]]).T + np.array([it['at'][0], it['at'][1], 0.0]), np.array(Fk)))
        Vp = (Vk - np.array([0.0, 0.0, dz])) / sc   # piece frame: seated with the rock at its sunk at.z, scaled by s
        name = it['p'].replace('Bommie', 'Skirt') + '_bank'
        clear(); sm = bpy.data.meshes.new(name); sm.from_pydata(Vp.tolist(), [], Fk); sm.update()
        so = bpy.data.objects.new(name, sm); bpy.context.scene.collection.objects.link(so)
        so.data.polygons.foreach_set('use_smooth', [True] * len(so.data.polygons)); so.data.update()
        tri = so.copy(); tri.data = sm.copy(); bpy.context.scene.collection.objects.link(tri); tri.name = name + '_TRI'
        finish(name, so, [tri], 'skirt', P + 'papers/process/art_bible/style_level/keyframe/src/habitat.py bank')
        print('BANK', name, len(Vk), 'verts, h', hb_, 'outline rf', round(rf, 2), 'sunk', dz)

# ---------- coral rubble aprons (key frame v7): Debris Maker coral_apron.py v2 from coral_rubble_kit_v3, resting on rock or sand ----------
RUBBLE_KIT = os.environ.get('RUBBLE_KIT', P + 'assets/world/coral_rubble_kit_v3/')
if MANIFEST and os.environ.get('CORAL_APRON'):
    import importlib.util as _iu
    _sp = _iu.spec_from_file_location('coral_apron', os.environ['CORAL_APRON']); CA = _iu.module_from_spec(_sp); _sp.loader.exec_module(CA)
    from mathutils.bvhtree import BVHTree
    kit = json.load(open(RUBBLE_KIT + 'index.json'))['pieces']
    heads, _c = layout_heads()
    cols_ = [(it['at'][0], it['at'][1], CORAL_R[it['p']], next(k for k in ('table', 'staghorn', 'finger', 'brain', 'boulder') if k in it['p']))
             for it in MANIFEST['items'] if it['p'] in CORAL_R]
    RV, RF, o = [], [], 0   # the near rocks as placed (v7 seat_z: a piece rests on what is under it)
    for it in MANIFEST['items']:
        if it['p'] in ROCK_MESH and float(np.hypot(*it['at'][:2])) < 20:
            V0, F0 = ROCK_MESH[it['p']]; sc = float(it.get('s', 1.0)); r0 = float(it.get('rot', 0.0)); cz, sz = math.cos(r0), math.sin(r0)
            W = (V0 * sc) @ np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1.0]]).T + np.array(it['at'], float)
            RV.append(W); RF.append(F0 + o); o += len(W)
    for _it, Wb, Fb in BANKS:   # the banked sand too (v7: SEAT_Z = max(rock, FL.H) and FL.H carries the bank)
        RV.append(Wb); RF.append(Fb + o); o += len(Wb)
    T = BVHTree.FromPolygons(np.concatenate(RV).tolist(), np.concatenate(RF).tolist())
    def seat_z(x, y):
        hit = T.ray_cast(Vector((x, y, 10.0)), Vector((0, 0, -1.0)))
        return max(0.0, hit[0].z) if hit[0] is not None else 0.0
    CR = CA.aprons(cols_, heads, lambda x, y: 0.0, kit, (0.7, -0.7))
    CR = [(f, x, y, z + seat_z(x, y), yaw) for f, x, y, z, yaw in CR]
    clear(); bm = bmesh.new(); cache_ = {}; colsv = []
    for f, x, y, z, yaw in CR:
        if f not in cache_:
            clear(); bpy.ops.import_scene.gltf(filepath=RUBBLE_KIT + f); ob = join(meshes())
            Vk = np.array([v.co[:] for v in ob.data.vertices]); Fk = [p.vertices[:] for p in ob.data.polygons]
            ca = ob.data.color_attributes; Ck = np.ones((len(Vk), 3)) * 0.5
            if len(ca):
                a = ca[0]; buf = np.empty(len(a.data) * 4); a.data.foreach_get('color', buf); buf = buf.reshape(-1, 4)[:, :3]
                if a.domain == 'POINT': Ck = buf
                else:
                    li = np.empty(len(ob.data.loops), np.int64); ob.data.loops.foreach_get('vertex_index', li); Ck = np.zeros((len(Vk), 3)); Ck[li] = buf
            cache_[f] = (Vk, Fk, Ck)
        Vk, Fk, Ck = cache_[f]; cz, sz = math.cos(yaw), math.sin(yaw)
        W = Vk @ np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1.0]]).T + np.array([x, y, z])
        vs = [bm.verts.new(Vector(w)) for w in W]
        for fc in Fk:
            try: bm.faces.new([vs[i] for i in fc])
            except ValueError: pass
        colsv.append(Ck)
    clear(); me = bpy.data.meshes.new('kf_coral_rubble'); bm.to_mesh(me); bm.free()
    ro = bpy.data.objects.new('kf_coral_rubble', me); bpy.context.scene.collection.objects.link(ro)
    C = np.concatenate(colsv); set_paint(ro, np.concatenate([np.clip(C, 0, 1), np.ones((len(C), 1))], 1))
    # game budget (test level thread 28 Nov: 462k tris / 94 MB with flat-shaded unshared verts): the kit pieces are ~7k tris each,
    # so decimate the merged apron to RUBBLE_TRIS (80k; runtime LODs go lower), smooth by angle so the glTF verts stay shared,
    # and a coarse concave collider (RUBBLE_COL_TRIS, 6k) instead of a full-detail copy.
    def _decimate(o, target):
        n0 = tris(o)
        if n0 <= target: return
        bpy.context.view_layer.objects.active = o; bpy.ops.object.select_all(action='DESELECT'); o.select_set(True)
        m_ = o.modifiers.new('dec', 'DECIMATE'); m_.decimate_type = 'COLLAPSE'; m_.ratio = target / n0; m_.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier=m_.name)
    bpy.context.view_layer.objects.active = ro; bpy.ops.object.select_all(action='DESELECT'); ro.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT'); bpy.ops.mesh.remove_doubles(threshold=0.0005); bpy.ops.object.mode_set(mode='OBJECT')
    tri = ro.copy(); tri.data = me.copy(); bpy.context.scene.collection.objects.link(tri); tri.name = 'kf_coral_rubble_TRI'; tri.data.name = 'kf_coral_rubble_TRI'
    _decimate(ro, int(os.environ.get('RUBBLE_TRIS', 80000))); _decimate(tri, int(os.environ.get('RUBBLE_COL_TRIS', 6000)))
    bpy.ops.object.select_all(action='DESELECT'); ro.select_set(True); bpy.context.view_layer.objects.active = ro
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(40))
    print('RUBBLE TRIS', tris(ro), 'collider', tris(tri))
    finish('kf_coral_rubble', ro, [tri], 'rubble', os.environ['CORAL_APRON'] + ' + ' + RUBBLE_KIT)
    print('CORAL RUBBLE', len(CR), 'pieces,', len(cache_), 'kit meshes, on rock', sum(1 for r in CR if r[3] > 0.05))

# ---------- seagrass: the meadow tiles the key frame used, at their own tile offsets ----------
# Placed (not keep) tiles are recentred as the v7 rig's add_glb(recentre=True) did: plan centre to the origin, lowest point to z 0, each as
# its own piece kf_<tile>_r culled for its own place (r12: a tile used in the meadow AND alone shared one mesh in meadow frame, so the lone
# one stood at its meadow offset from its place and was culled for the meadow's place).
def _src_of(p_):
    t = p_[3:]; t = t[:-2] if t.endswith('_r') else t
    return t + ('.glb' if t.endswith(('_L1', '_L2', '_L3')) else '_L0.glb')
GRASS = sorted({(i['p'], _src_of(i['p'])) for i in MANIFEST['items'] if 'seagrass' in i['p']}) if MANIFEST else sorted({('kf_' + g['f'].replace('.glb', '').replace('_L0', ''), g['f']) for g in LAYOUT['grass']})
for gp, g in GRASS:
    clear(); bpy.ops.import_scene.gltf(filepath=SLICE + g)
    for o in list(bpy.data.objects):
        if o.type == 'MESH' and o.name.startswith('Icosphere'): bpy.data.objects.remove(o, do_unlink=True)
    ms = meshes()
    for o in ms: o.select_set(True)
    bpy.context.view_layer.objects.active = ms[0]
    bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
    b = join(ms)
    vc = get_vc(b)
    if vc is not None:   # kf_grass (the key frame's blade material) per vertex: outline, age browning, saturation
        me = b.data; uvl = me.uv_layers[0].data; idx = np.empty(len(me.loops), np.int64); me.loops.foreach_get('vertex_index', idx)
        luv = np.empty(len(me.loops) * 2); uvl.foreach_get('uv', luv); luv = luv.reshape(-1, 2)
        uv = np.zeros((len(me.vertices), 2)); uv[idx] = luv
        uv[:, 1] = 1.0 - uv[:, 1]   # Blender's glTF import flips V; back to 0 base .. 1 tip
        set_paint(b, kf_paint.grass(vc, uv))
    if gp.endswith('_r'):
        Vr = np.array([v.co[:] for v in b.data.vertices]); cxy = 0.5 * (Vr[:, :2].min(0) + Vr[:, :2].max(0))
        b.data.transform(Matrix.Translation((-float(cxy[0]), -float(cxy[1]), -float(Vr[:, 2].min())))); b.data.update()
    if MANIFEST:   # the key frame rig's habitat.cull_meadow for THIS layout: whole blades whose root fails the habitat field go
        import habitat
        def place_of(p):
            it = next((i for i in MANIFEST['items'] if i['p'] == p), None)
            return None if it is None else (Matrix.Translation(Vector(it['at'])) @ Matrix.Rotation(float(it.get('rot', 0.0)), 4, 'Z'))
        heads, corals = layout_heads()
        lanes = [(*k['from'], *k['to'], k['w']) for k in MANIFEST.get('keep_clear', []) if 'from' in k]
        b.matrix_world = place_of(gp) or Matrix()
        kept, tot = habitat.cull_meadow([b], heads, corals, lanes)
        b.matrix_world = Matrix(); print('CULL', gp, kept, '/', tot, 'blades kept')
    finish(gp, b, [], 'grass', SLICE + g)

json.dump(REPORT, open(OUT + 'pieces.json', 'w'), indent=1)
print('DONE', len(REPORT))
