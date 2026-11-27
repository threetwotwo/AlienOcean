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
    OUTLINES[piece] = outline(V)
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

# ---------- corals: kinds_v27, CoACD hulls ----------
for c in sorted({c['f'] for c in LAYOUT['corals']}):
    clear(); bpy.ops.wm.obj_import(filepath=CORAL + c + '.obj', forward_axis='Y', up_axis='Z')
    b = join(meshes())
    V, N, E = mesh_arrays(b); set_paint(b, kf_paint.paint(c.split('_')[0], V, N, E, vc=get_vc(b)))
    F = np.array([p.vertices[:] for p in b.data.polygons if len(p.vertices) == 3])
    hulls = decompose(V, F)
    cols = [hull_obj('kf_%s_COL_%02d' % (c, k), h) for k, h in enumerate(hulls)]
    OUTLINES['kf_' + c] = outline(V, z0=-0.5, z1=0.3)
    finish('kf_' + c, b, cols, 'coral', CORAL + c + '.obj')

# ---------- seagrass: the meadow tiles the key frame used, at their own tile offsets ----------
for g in sorted({g['f'] for g in LAYOUT['grass']}):
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
    gp = 'kf_' + g.replace('_L0.glb', '')
    if MANIFEST:   # the key frame rig's habitat.cull_meadow for THIS layout: whole blades whose root fails the habitat field go
        import habitat
        def place_of(p):
            it = next((i for i in MANIFEST['items'] if i['p'] == p), None)
            return None if it is None else (Matrix.Translation(Vector(it['at'])) @ Matrix.Rotation(float(it.get('rot', 0.0)), 4, 'Z'))
        heads, corals = [], []
        for p_, (c_, R_) in OUTLINES.items():
            M = place_of(p_)
            if M is None: continue
            w = M @ Vector((c_[0], c_[1], 0)); rot = float(next(i for i in MANIFEST['items'] if i['p'] == p_).get('rot', 0.0))
            if p_.startswith('SB_') and not p_.endswith('_apron'):
                heads.append(((w.x, w.y), (lambda R2, r0: (lambda a: float(R2[int((a - r0 + math.pi) / (2 * math.pi) * len(R2)) % len(R2)])))(R_, rot), float(np.median(R_))))
            elif p_.startswith('kf_'):
                corals.append((w.x, w.y, float(np.median(R_))))
        lanes = [(*k['from'], *k['to'], k['w']) for k in MANIFEST.get('keep_clear', []) if 'from' in k]
        b.matrix_world = place_of(gp) or Matrix()
        kept, tot = habitat.cull_meadow([b], heads, corals, lanes)
        b.matrix_world = Matrix(); print('CULL', gp, kept, '/', tot, 'blades kept')
    finish(gp, b, [], 'grass', SLICE + g)

json.dump(REPORT, open(OUT + 'pieces.json', 'w'), indent=1)
print('DONE', len(REPORT))
