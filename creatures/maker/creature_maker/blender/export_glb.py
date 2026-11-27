"""Stage 8, EXPORT (Blender Python, bpy): cage + form -> Blender bake (selected-to-active, MikkTSpace normal + AO) -> interior slot,
rig (spine, jaw, gill covers), clips (swim_loop, breathe_loop, gape, flare), swim extras, LODs (meshoptimizer), collision (CoACD) ->
fish.glb, fish_LOD1.glb, fish_LOD2.glb + glb_stats.json + renders.
Usage: python -m creature_maker glb OUTDIR --record RECORD.json [--res 2048] [--views] [--wire] [--form] [--samples N]
"""
import bpy, bmesh, json, sys, os, math
import numpy as np
from mathutils import Vector, Matrix
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))   # the maker root: creature_maker
from creature_maker import rig as RIG, swim_clip, collision, glbpatch
from creature_maker.record import adapt
from creature_maker.blender import interior, rigging, lods as LODS

OUT = sys.argv[1]; C = json.load(open(os.path.join(OUT, 'cage.json'))); Z = np.load(os.path.join(OUT, 'cage.npz'))
S = C['SL_mm'] / 1000.0
def B(p): return Vector((p[0] * S, -p[2] * S, p[1] * S))     # record (x fwd-to-tail, y up, z left) -> Blender Z-up, metres

bpy.ops.wm.read_factory_settings(use_empty=True)
scn = bpy.context.scene

def image(name, path, non_color=False):
    im = bpy.data.images.load(os.path.join(OUT, path)); im.name = name
    if non_color: im.colorspace_settings.name = 'Non-Color'
    return im

def pbr(name, base, normal=None, orm=None, alpha=False, two_sided=False):
    m = bpy.data.materials.new(name); m.use_nodes = True; nt = m.node_tree; bs = nt.nodes['Principled BSDF']
    tb = nt.nodes.new('ShaderNodeTexImage'); tb.image = base; nt.links.new(tb.outputs['Color'], bs.inputs['Base Color'])
    if alpha:
        # alpha MASK (clip at 0.5): the exporter writes alphaMode MASK for 1 - (alpha < cutoff); no sorting in schools
        lt = nt.nodes.new('ShaderNodeMath'); lt.operation = 'LESS_THAN'; lt.inputs[1].default_value = 0.5
        sb = nt.nodes.new('ShaderNodeMath'); sb.operation = 'SUBTRACT'; sb.inputs[0].default_value = 1.0
        nt.links.new(tb.outputs['Alpha'], lt.inputs[0]); nt.links.new(lt.outputs[0], sb.inputs[1]); nt.links.new(sb.outputs[0], bs.inputs['Alpha'])
        m.blend_method = 'CLIP' if hasattr(m, 'blend_method') else None
        try: m.surface_render_method = 'DITHERED'
        except Exception: pass
    if normal:
        tn = nt.nodes.new('ShaderNodeTexImage'); tn.image = normal
        nm = nt.nodes.new('ShaderNodeNormalMap'); nt.links.new(tn.outputs['Color'], nm.inputs['Color']); nt.links.new(nm.outputs['Normal'], bs.inputs['Normal'])
    if orm:
        to = nt.nodes.new('ShaderNodeTexImage'); to.image = orm
        sp = nt.nodes.new('ShaderNodeSeparateColor'); nt.links.new(to.outputs['Color'], sp.inputs['Color'])
        nt.links.new(sp.outputs['Green'], bs.inputs['Roughness']); nt.links.new(sp.outputs['Blue'], bs.inputs['Metallic'])
        # glTF exporter takes occlusion from a 'glTF Material Output' group; AO is R of the same ORM texture (occlusionTexture)
        g = bpy.data.node_groups.get('glTF Material Output')
        if g is None:
            g = bpy.data.node_groups.new('glTF Material Output', 'ShaderNodeTree')
            g.interface.new_socket('Occlusion', in_out='INPUT', socket_type='NodeSocketFloat')
        gn = nt.nodes.new('ShaderNodeGroup'); gn.node_tree = g; nt.links.new(sp.outputs['Red'], gn.inputs['Occlusion'])
    m.use_backface_culling = not two_sided
    return m

from PIL import Image as _PI
RES = int(sys.argv[sys.argv.index('--res') + 1]) if '--res' in sys.argv else _PI.open(os.path.join(OUT, 'body_base.png')).size[0]  # match the cage maps
fin_m = pbr('fins', image('fin_base', 'fin_base.png'), image('fin_normal', 'fin_normal.png', True), alpha=True, two_sided=True)
fin_m.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.5
# no KHR_materials_transmission on fins: engines differ (Godot ignores it); translucency is an engine-side shader choice

def mesh_obj(name, verts, faces, uvs, mat, smooth=True):
    me = bpy.data.meshes.new(name); me.from_pydata([B(v) for v in verts], [], faces); me.update()
    uvl = me.uv_layers.new(name='UV0')
    for poly, fuv in zip(me.polygons, uvs):
        for li, uv in zip(poly.loop_indices, fuv): uvl.data[li].uv = (uv[0], uv[1])
    for p in me.polygons: p.use_smooth = smooth
    me.materials.append(mat); ob = bpy.data.objects.new(name, me); scn.collection.objects.link(ob); return ob

V = Z['V']
# ---------------------------------------------------------------- BAKE: the professional step, in Blender's own tangent frame
tmp_m = bpy.data.materials.new('bake_tmp'); tmp_m.use_nodes = True
body = mesh_obj('body', V, C['faces'], C['uv'], tmp_m)
INT_IDX, INT_SKIP = interior.slot(body, C)     # interior faces off the skin's bake target before anything is baked
# orbit linings (the tuck ring of each eye patch) turn into the socket and lie inside the form by design, up to 1.6 % SL deep,
# further than the bake cage reaches out: their rays start inside the solid and hit the form's far side from behind. They do not
# sample the form: they wait on the throwaway slot too, and take a flat tangent normal (the cage's own shading) and the rim's AO.
_tuck = set(v for rings in C['openings']['eye_rings'] for v in rings[-1])
LINING = [k for k, (f, t) in enumerate(zip(C['faces'], C['ftag'])) if t == 'eye' and _tuck & set(f)]
for k in LINING: body.data.polygons[k].material_index = INT_IDX
PLANT = os.environ.get('CREATURE_PLANT_BAKE_FAULT', '')   # tests only: puts the 0.3.0 fault back, to show P6 catches it
_inner = [k for k, t in enumerate(C['ftag']) if t in interior.INNER]
if PLANT == 'interior_on_skin':
    for k in _inner: body.data.polygons[k].material_index = 0
Fm = np.load(os.path.join(OUT, 'form_mc.npz'))
me = bpy.data.meshes.new('form'); me.from_pydata([B(v) for v in Fm['V']], [], Fm['F'].tolist()); me.update()
for p_ in me.polygons: p_.use_smooth = True
form = bpy.data.objects.new('form', me); scn.collection.objects.link(form)
scn.render.engine = 'CYCLES'; scn.cycles.device = 'CPU'; scn.cycles.samples = 64
def bake(kind, img):
    nt = tmp_m.node_tree; tn = nt.nodes.new('ShaderNodeTexImage'); tn.image = img; nt.nodes.active = tn
    for o in scn.objects: o.select_set(False)
    form.select_set(True); body.select_set(True); bpy.context.view_layer.objects.active = body
    bpy.ops.object.bake(type=kind, use_selected_to_active=True, cage_extrusion=0.012 * S, max_ray_distance=0.03 * S,
                        normal_space='TANGENT', margin=16, use_clear=True)
    return np.array(img.pixels[:], np.float32).reshape(RES, RES, 4)
import time as _t; t0 = _t.time()
imn = bpy.data.images.new('bake_n', RES, RES, float_buffer=True); imn.colorspace_settings.name = 'Non-Color'
NB_ = bake('NORMAL', imn)[..., :3] * 2 - 1
ima = bpy.data.images.new('bake_ao', RES, RES, float_buffer=True); ima.colorspace_settings.name = 'Non-Color'
scn.cycles.samples = 32; AO = bake('AO', ima)[..., 0]
bake_s = round(_t.time() - t0, 1)
for k in LINING: body.data.polygons[k].material_index = 0
for k in _inner: body.data.polygons[k].material_index = INT_IDX
if LINING:
    from scipy.ndimage import distance_transform_edt
    from creature_maker.maps import raster
    _sk = [k for k, t in enumerate(C['ftag']) if t in ('body', 'eye', 'mouth', 'cap')]; _ln = set(LINING)
    _F = raster([C['faces'][k] for k in _sk], [np.array(C['uv'][k]) for k in _sk], V, Z['VN'], RES)[3]     # face per texel, Blender's row order
    _lin = np.isin(_F, [i for i, k in enumerate(_sk) if k in _ln]); _src = (_F >= 0) & ~_lin
    _iy, _ix = distance_transform_edt(~_src, return_distances=False, return_indices=True)
    NB_[_lin] = (0.0, 0.0, 1.0); AO[_lin] = AO[_iy[_lin], _ix[_lin]]
# fine relief: UV-space height -> tangent normal, combined with the baked form normal (reoriented normal mapping)
H = np.load(os.path.join(OUT, 'body_height.npy')); Mk = np.load(os.path.join(OUT, 'body_mask.npy'))
if H.shape[0] != RES:
    from PIL import Image as _I
    H = np.asarray(_I.fromarray(H).resize((RES, RES), _I.BILINEAR)); Mk = np.asarray(_I.fromarray(Mk.astype(np.uint8) * 255).resize((RES, RES))) > 127
k = C['hamp'] * RES * C.get('s_uv', 0.94 / (C['xend'] + 0.02))
gx = np.gradient(H, axis=1) * k; gy = np.gradient(H, axis=0) * k
Nd = np.stack([-gx, -gy, np.ones_like(H)], -1); Nd /= np.linalg.norm(Nd, axis=-1, keepdims=True)
t_ = NB_ + np.array([0, 0, 1.0]); u_ = Nd * np.array([-1, -1, 1.0])
NRM = t_ * (t_ * u_).sum(-1, keepdims=True) / t_[..., 2:3] - u_
NRM /= np.linalg.norm(NRM, axis=-1, keepdims=True)
# bake specks: ISOLATED texels (more than 25 deg from all 8 neighbours: a ray that hit the wrong side) get their 3x3 median.
# Scale and plate edges are never isolated (their neighbours along the edge agree), so real relief is untouched.
from scipy.ndimage import median_filter, binary_dilation
def isolated(Nn, deg=25):
    best = np.full(Nn.shape[:2], -1.0)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy or dx: best = np.maximum(best, (Nn * np.roll(np.roll(Nn, dy, 0), dx, 1)).sum(-1))
    return best < np.cos(np.radians(deg))
SPECKS_FIXED = 0; _roi = binary_dilation(Mk, iterations=3)   # H/Mk share Blender's row order with NRM
for _pass in range(3):   # pairs of bad texels become isolated singles after one pass
    _bad = isolated(NRM) & _roi
    if not _bad.any(): break
    SPECKS_FIXED += int(_bad.sum())
    _med = np.stack([median_filter(NRM[..., c], size=3) for c in range(3)], -1); _med /= np.linalg.norm(_med, axis=-1, keepdims=True) + 1e-9
    NRM[_bad] = _med[_bad]
from PIL import Image as _I
_I.fromarray(((NRM[::-1] * 0.5 + 0.5) * 255 + 0.5).clip(0, 255).astype(np.uint8)).save(os.path.join(OUT, 'body_normal.png'))
orm = np.asarray(_I.open(os.path.join(OUT, 'body_orm_pre.png'))).astype(np.float32) / 255
orm = orm.copy(); orm[..., 0] = np.clip(AO[::-1] * (1 - 0.25 * (1 - H[::-1]) * (H[::-1] > 0)), 0.3, 1)
_I.fromarray((orm * 255 + 0.5).astype(np.uint8)).save(os.path.join(OUT, 'body_orm.png'))
bpy.data.objects.remove(form)
body_m = pbr('body', image('body_base', 'body_base.png'), image('body_normal', 'body_normal.png', True), image('body_orm', 'body_orm.png', True))
body.data.materials[0] = body_m
# interior slot: cavity + gill passage faces on their own material 'interior' (engine contract), maps baked from the cage itself
INT_IDX, INT_STATS = interior.setup(body, body_m, C, OUT, INT_IDX, INT_SKIP)
int_m = pbr('interior', image('interior_base', 'interior_base.png'), None, image('interior_orm', 'interior_orm.png', True), two_sided=False)
body.data.materials[INT_IDX] = int_m
# underwater skin: reflectance 0.01-0.06 % (lessons, fins handover s5) -> IOR of water-skin, not 1.5
for m_ in (body_m, fin_m, int_m):
    try: m_.node_tree.nodes['Principled BSDF'].inputs['IOR'].default_value = 1.33
    except Exception: pass
def colour0(ob, vals):
    ca = ob.data.color_attributes.new('Col', 'FLOAT_COLOR', 'POINT')
    ca.data.foreach_set('color', np.repeat(np.stack([vals, np.ones_like(vals), np.ones_like(vals), np.ones_like(vals)], -1), 1, 0).ravel())
    ob.data.color_attributes.active_color = ca
colour0(body, np.ones(len(body.data.vertices)))
fin_obs = {}
for k, f in C['fins'].items():
    fv = np.array(f['V']); fuv = np.array(f['UV'])
    fin_obs[k] = mesh_obj('fin_' + k, fv, f['F'], [[fuv[i] for i in q] for q in f['F']], fin_m)
    colour0(fin_obs[k], 1 - 0.85 * np.array(f['T']))   # COLOR_0 R = fin thickness (FUNDAMENTALS: fish exports), root 1 -> edge 0.15

# eyes: iris dome + cornea, 2 shells, sitting in the template's eye opening
def eye_tex():
    import numpy as np
    from PIL import Image
    R = 256; yy, xx = np.mgrid[0:R, 0:R] / (R - 1) * 2 - 1; r = np.sqrt(xx ** 2 + yy ** 2)
    iris = np.array(C['eye']['iris']); pup = C['eye']['pupil']
    a = np.arctan2(yy, xx); streak = 0.85 + 0.15 * np.cos(a * 37) * np.cos(a * 11)
    col = iris[None, None] * (0.55 + 0.45 * np.clip((r - pup) / (1 - pup), 0, 1)[..., None] ** 0.5) * streak[..., None]
    col = np.where((r > 0.86)[..., None], col * 0.35, col)                 # limbal ring
    col = np.where((r < pup)[..., None], 0.01, col)
    col = col ** (1 / 2.2)
    Image.fromarray((np.clip(col, 0, 1) * 255).astype(np.uint8)).save(os.path.join(OUT, 'eye_base.png'))
eye_tex()
eye_m = pbr('eye', image('eye_base', 'eye_base.png')); eye_m.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value = 0.25
cor_m = bpy.data.materials.new('cornea'); cor_m.use_nodes = True; cb = cor_m.node_tree.nodes['Principled BSDF']
cb.inputs['Roughness'].default_value = 0.02; cb.inputs['Alpha'].default_value = 0.08
try: cor_m.surface_render_method = 'BLENDED'
except Exception: pass
def cap(c, n, r, h, seg=24, rings=5, name='cap', mat=None, uvmap=True):
    n = np.array(n); c = np.array(c); t = np.cross(n, [0, 1, 0]); t /= np.linalg.norm(t); b = np.cross(n, t)
    Rs = (r * r + h * h) / (2 * h); ctr = c - n * (Rs - h)
    vs, uvs = [], []
    for k in range(rings + 1):
        al = math.asin(min(r / Rs, 1)) * (1 - k / rings)
        for s in range(seg):
            ph = 2 * math.pi * s / seg; d = n * math.cos(al) + (t * math.cos(ph) + b * math.sin(ph)) * math.sin(al)
            vs.append(ctr + Rs * d); rr = math.sin(al) / (r / Rs); uvs.append((0.5 + 0.5 * rr * math.cos(ph), 0.5 + 0.5 * rr * math.sin(ph)))
    vs.append(c + n * h); uvs.append((0.5, 0.5))
    fs = [[k * seg + s, k * seg + (s + 1) % seg, (k + 1) * seg + (s + 1) % seg, (k + 1) * seg + s] for k in range(rings - 1) for s in range(seg)]
    fs += [[(rings - 1) * seg + s, (rings - 1) * seg + (s + 1) % seg, len(vs) - 1] for s in range(seg)]
    fs = [f for f in fs if True]
    return mesh_obj(name, vs, [f[::-1] if True else f for f in fs], [[uvs[i] for i in f[::-1]] for f in fs], mat)
eye_obs = []
cb.inputs['IOR'].default_value = 1.376     # cornea
for e in C['eyes']:
    sd = 'L' if e['side'] > 0 else 'R'
    eye_obs.append(cap(np.array(e['c']) - np.array(e['n']) * 0.004, e['n'], e['r'] * 1.12, e['r'] * 0.30, name='eye_iris_' + sd, mat=eye_m))
    eye_obs.append(cap(np.array(e['c']) - np.array(e['n']) * 0.002, e['n'], e['r'] * 1.14, e['r'] * 0.45, name='eye_cornea_' + sd, mat=cor_m))
for ob in eye_obs:
    for p in ob.data.polygons: p.flip()
    colour0(ob, np.ones(len(ob.data.vertices)))

# ---------------------------------------------------------------- rig: spine chain, jaw, gill covers (creature_maker.rig), fin bones
REC_PATH = sys.argv[sys.argv.index('--record') + 1] if '--record' in sys.argv else None
if REC_PATH is None: raise SystemExit('glb needs --record RECORD.json (jaw, cover and swim come from the record)')
REC = adapt(REC_PATH, C.get('style')); RAW = json.load(open(REC_PATH))
BL = RIG.bones(C, V, REC); NB, xs = RIG.spine_stations(C)
spine_at = lambda x: f'spine_{RIG.spine_index(C, x):02d}'
rig = rigging.build_armature(scn, BL, C['fins'], B, spine_at)
W_body, RIG_INFO = RIG.weights(C, V, REC)
rigging.bind_groups(body, rig, W_body)
def spine_groups(xv, share=1.0):
    i0, a0, i1, a1 = RIG.spine_weights(C, np.atleast_1d(xv)); g = {}
    for k in range(len(i0)):
        for i, a in ((i0[k], a0[k]), (i1[k], a1[k])):
            n = f'spine_{i:02d}'; g.setdefault(n, np.zeros(len(i0)))[k] += a * share
    return g
for k, ob in fin_obs.items():
    # every fin vertex follows the spine at its own x, so median fins bend with the body; paired fins (pectoral, pelvic) hand over to
    # their own root bone from root (T = 0) to edge (T = 1), where they are articulated; median fins give their bone no weight yet
    # (fin ray bones are the next step: HARD_PROBLEMS EXP-FIN-1)
    fv = np.array(C['fins'][k]['V']); T = np.clip(np.array(C['fins'][k]['T'], float), 0, 1)
    share = T if k.startswith(('pectoral', 'pelvic')) else np.zeros(len(fv))
    g = {n: w * (1 - share) for n, w in spine_groups(fv[:, 0]).items()}; g['fin_' + k + '_root'] = share
    rigging.bind_groups(ob, rig, g)
for ob in eye_obs:   # a rigid shell: the skin weights at the eye centre, for every shell vertex (eyes ride with the skin round them)
    e = C['eyes'][0 if ob.name.endswith('L') == (C['eyes'][0]['side'] > 0) else 1]
    g = {n: np.full(len(ob.data.vertices), float(w[0])) for n, w in spine_groups(np.array([e['c'][0]])).items()}
    rigging.bind_groups(ob, rig, g)

# ---------------------------------------------------------------- clips: swim engine (swim_loop, breathe_loop) + head hinges (gape, flare)
CHK = {}
_cp = os.path.join(OUT, 'checks.json')
if os.path.exists(_cp):
    _c = json.load(open(_cp)); CHK = dict(SR1_safe=_c.get('SR1_safe'))
from creature_maker.pose import FLARE_REAL
GAPE_REAL = float(REC.get('gape_deg', 30.0)); CHK['real_gape_deg'] = GAPE_REAL; CHK['real_flare_deg'] = FLARE_REAL
SW = swim_clip.clips(C, V, RAW, BL, CHK)
FPS = 120; scn.render.fps = FPS; scn.render.fps_base = 1.0
chain = swim_clip.chain_names(NB); cmap = {chain[i]: f'spine_{i:02d}' for i in range(NB)}
def timed(clip, fps):
    return [(k / fps, P) for k, P in enumerate(rigging.engine_frames(rig, clip, cmap))]
cmap_b = dict(opercleL='opercleL', opercleR='opercleR')   # breathe keys the covers only, so it layers over swim
def timed_b(clip, fps):
    return [(k / fps, P) for k, P in enumerate(rigging.engine_frames(rig, clip, cmap_b))]
bspec = {b['name']: b for b in BL}
def hinge(name):
    b = bspec[name]; ax = B(b['axis']) / S; return (name, B(b['pivot']), ax)   # B scales by S: axis back to unit length
JAW = [hinge('jaw')]; COVERS = [hinge('opercleL'), hinge('opercleR')]
rigging.key_clip(rig, 'swim_loop', timed(SW['swim'], SW['swim_fps']), FPS)
rigging.key_clip(rig, 'breathe_loop', timed_b(SW['breathe'], SW['breathe_fps']), FPS)
rigging.key_clip(rig, 'gape', rigging.hinge_frames(rig, JAW, GAPE_REAL), FPS)
rigging.key_clip(rig, 'flare', rigging.hinge_frames(rig, COVERS, FLARE_REAL), FPS)
SW['extras']['clips']['gape']['peak_deg'] = GAPE_REAL; SW['extras']['clips']['flare']['peak_deg'] = FLARE_REAL
SW['extras']['head_bones'] = {n: dict(pivot_m=[round(c, 6) for c in (B(bspec[n]['pivot']).x, B(bspec[n]['pivot']).z, -B(bspec[n]['pivot']).y)],
                                      axis_gltf=[round(c, 6) for c in (hinge(n)[2].x, hinge(n)[2].z, -hinge(n)[2].y)],
                                      opens='positive angle about axis_gltf (armature space, right hand)') for n in ('jaw', 'opercleL', 'opercleR')}
json.dump(dict(SW['extras']), open(os.path.join(OUT, 'swim.json'), 'w'), indent=1, default=float)

# EX1/EX2: Blender's skinning at the real gape / flare equals the stress test's pose (creature_maker.pose), vertex for vertex
def posed_body(Ps):
    for n, P in Ps.items():
        b = rig.data.bones[n]; pb = rig.pose.bones[n]; pb.rotation_mode = 'QUATERNION'
        Pp = b.parent.matrix_local; basis = (Pp.inverted() @ b.matrix_local).inverted() @ Pp.inverted() @ P
        loc, q, _ = basis.decompose(); pb.rotation_quaternion = q; pb.location = loc
    dg = bpy.context.evaluated_depsgraph_get(); ev = body.evaluated_get(dg).data
    P = np.array([v.co[:] for v in ev.vertices]); 
    for pb in rig.pose.bones: pb.location = (0, 0, 0); pb.rotation_quaternion = (1, 0, 0, 0)
    return np.c_[P[:, 0], P[:, 2], -P[:, 1]] / S                          # Blender -> record units
EXS = {}
for tag, specs, deg, name in (('EX1_gape', JAW, GAPE_REAL, 'gape'), ('EX2_flare', COVERS, FLARE_REAL, 'flare')):
    Pb = posed_body(rigging.hinge_pose(rig, specs, deg)); Ps = RIG.stress_pose(C, V, REC, name, deg)
    EXS[tag + '_max_err_pctSL'] = round(float(np.abs(Pb - Ps).max()) * 100, 5); EXS[tag + '_moved_pctSL'] = round(float(np.abs(Ps - V).max()) * 100, 3)
print('EX', EXS)

# ---------------------------------------------------------------- collision: CoACD hulls of the form, each on its nearest spine bone
Fm = np.load(os.path.join(OUT, 'form_mc.npz')); HUL = collision.hulls(Fm['V'], Fm['F'], xs)
cov, vol = collision.coverage(np.asarray(Fm['V']), np.asarray(Fm['F']), HUL)
col_obs = []
for k, (hv, hf, bi) in enumerate(HUL):
    me_ = bpy.data.meshes.new(f'col_{k:02d}'); me_.from_pydata([B(v) for v in hv], [], hf.tolist()); me_.update()
    ob = bpy.data.objects.new(f'col_{k:02d}-convcolonly', me_); scn.collection.objects.link(ob)
    ob.parent = rig; ob.parent_type = 'BONE'; ob.parent_bone = f'spine_{bi:02d}'
    bpy.context.view_layer.update(); ob.matrix_world = Matrix.Identity(4); ob.hide_render = True
    col_obs.append(ob)
bpy.context.view_layer.update()

# ---------------------------------------------------------------- export
EXP = dict(export_format='GLB', export_animations=True, export_skins=True, export_tangents=True, export_image_format='AUTO',
           export_vertex_color='ACTIVE', export_animation_mode='NLA_TRACKS', export_force_sampling=True, export_extras=False,
           export_optimize_animation_size=True, export_optimize_animation_keep_anim_armature=False)   # a clip carries only the bones it moves
def _exp(path, objs, **kw):
    for o in scn.objects: o.select_set(False)
    for o in objs: o.select_set(True)
    try: bpy.ops.export_scene.gltf(filepath=path, use_selection=True, **EXP, **kw)
    except TypeError:
        e2 = dict(EXP); e2.pop('export_vertex_color'); bpy.ops.export_scene.gltf(filepath=path, use_selection=True, **e2, **kw)
anim_x = {n: dict(loop=n.endswith('_loop')) for n in ('swim_loop', 'breathe_loop', 'gape', 'flare')}
def tris_of(objs):
    return sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objs if o.type == 'MESH' and not o.name.startswith('col_'))
def finish(path, lod):
    glbpatch.patch(path, node_extras={'rig': {'alien_ocean': dict(swim=SW['extras'], lod=lod, species=C['species'])}}, anim_extras=anim_x)
glb = os.path.join(OUT, 'fish.glb'); LOD0 = [body, rig] + list(fin_obs.values()) + eye_obs + col_obs
_exp(glb, LOD0); finish(glb, 0)
# LOD chain: meshoptimizer on seam-split copies (blender/lods.py); eyes dropped at LOD2, collision only on LOD0
lods = {}; lod_obs = {}; CREASES = set(v for r in C['rolls'] for v in r)
# targets are budgets (P1: LOD1 <= 60 % of LOD0, LOD2 <= 1,000 tris), not fixed ratios: a fish with bigger traced fins or more cage
# rows gets a lower ratio. Start from the usual ratio, then scale it down until the LOD is inside its budget with a 5 % margin.
T0 = tris_of(LOD0)
for lod, ratio, budget in ((1, 0.4, 0.57 * T0), (2, 0.14, 950)):
    for attempt in range(4):
        obs = []
        for o in [body] + list(fin_obs.values()):
            lo, nt = LODS.simplify(o, ratio if o is body else max(ratio * 1.6, 0.3 * min(1.0, ratio / 0.14)), f'{o.name}_LOD{lod}', lock=CREASES if (o is body and lod == 1) else ()); lo.hide_render = True; obs.append(lo)
        got = tris_of(obs + (eye_obs if lod == 1 else []))
        if got <= budget or attempt == 3: break
        for lo in obs: bpy.data.objects.remove(lo, do_unlink=True)
        ratio *= 0.97 * budget / got
    keep = obs + [rig] + (eye_obs if lod == 1 else [])
    pth = os.path.join(OUT, f'fish_LOD{lod}.glb'); _exp(pth, keep); finish(pth, lod)
    lint = sum(1 for p in obs[0].data.polygons if p.material_index == INT_IDX)
    lods[f'LOD{lod}'] = dict(tris=tris_of(keep), kb=round(os.path.getsize(pth) / 1024), interior_tris=lint); lod_obs[lod] = obs
stats = dict(glb_kb=round(os.path.getsize(glb) / 1024), objects=len([o for o in LOD0 if o.type == 'MESH' and not o.name.startswith('col_')]))
stats['tris_total'] = tris_of(LOD0); stats['normal_specks_fixed'] = SPECKS_FIXED; stats['bones'] = len(rig.data.bones); stats['lods'] = lods; stats['blender_bake_s'] = bake_s
stats.update(INT_STATS); stats.update(RIG_INFO); stats.update(EXS)
stats['clips'] = {n: dict(loop=v['loop']) for n, v in anim_x.items()}; stats['swim_loop_closure_BL'] = SW['loop_err']
stats['collision'] = dict(hulls=len(HUL), coverage=round(cov, 4), hull_over_form_volume=round(vol, 3), verts=[len(h[0]) for h in HUL], bones=[f'spine_{h[2]:02d}' for h in HUL])
json.dump(stats, open(os.path.join(OUT, 'glb_stats.json'), 'w'), default=float); print('EXPORT', stats)
for o in sum(lod_obs.values(), []): o.hide_render = True; o.hide_viewport = True

# ---------------------------------------------------------------- turnaround renders
if '--views' in sys.argv or '--wire' in sys.argv or '--form' in sys.argv:
    smp = int(sys.argv[sys.argv.index('--samples') + 1]) if '--samples' in sys.argv else 32
    scn.render.engine = 'CYCLES'; scn.cycles.samples = smp; scn.cycles.device = 'CPU'
    try: scn.cycles.use_denoising = True
    except Exception: pass
    scn.render.resolution_x, scn.render.resolution_y = 900, 560; scn.render.film_transparent = False
    w = bpy.data.worlds.new('w'); scn.world = w; w.use_nodes = True
    bg = w.node_tree.nodes['Background']; bg.inputs['Color'].default_value = (0.035, 0.05, 0.085, 1); bg.inputs['Strength'].default_value = 2.2
    sun = bpy.data.objects.new('sun', bpy.data.lights.new('sun', 'SUN')); sun.data.energy = 3.2; sun.rotation_euler = (math.radians(35), math.radians(-25), math.radians(20))
    scn.collection.objects.link(sun)
    fill = bpy.data.objects.new('fill', bpy.data.lights.new('fill', 'SUN')); fill.data.energy = 0.8; fill.data.color = (0.6, 0.75, 1.0)
    fill.rotation_euler = (math.radians(150), 0, math.radians(-30)); scn.collection.objects.link(fill)
    scn.view_settings.view_transform = 'AgX' if 'AgX' in [v for v in ['AgX']] else 'Filmic'
    cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); scn.collection.objects.link(cam); scn.camera = cam
    cam.data.type = 'ORTHO'; cam.data.ortho_scale = 0.46 * C['SL_mm'] / 300 * 1.0 * 1.0
    ctr = Vector((0.55 * S, 0, 0)); D = 2.0
    VIEWS = {'side_L': (0, 1, 0), 'side_R': (0, -1, 0), 'top': (0, 0, 1), 'bottom': (0, 0, -1), 'front': (-1, 0, 0), 'back': (1, 0, 0),
             'q_above': (-0.6, 0.7, 0.45), 'q_below': (-0.6, 0.7, -0.45)}
    def shoot(tag, only=None):
        for o in scn.objects:
            if o.type == 'MESH': o.hide_render = o.name.startswith('col_') or '_LOD' in o.name or (only is not None and o.name not in only)
        for vn, d in VIEWS.items():
            if tag != 'view' and vn not in ('side_L', 'q_above', 'front', 'bottom'): continue
            d = Vector(d).normalized(); cam.location = ctr + d * D
            up = Vector((0, 1, 0)) if abs(d.z) > 0.9 else Vector((0, 0, 1))
            if abs(d.z) < 0.9: cam.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler()
            else: cam.rotation_euler = (0, 0, 0) if d.z > 0 else (math.pi, 0, 0)
            cam.data.ortho_scale = (0.30 if vn in ('front', 'back') else 0.46) * S / 0.3 * 1.05
            scn.render.filepath = os.path.join(OUT, f'{tag}_{vn}.png'); bpy.ops.render.render(write_still=True)
    if '--views' in sys.argv:
        shoot('view')
        # silhouette mask from alpha (P11): the shaded render's colour is not a reliable key
        scn.render.film_transparent = True; d = Vector(VIEWS['side_R']); cam.location = ctr + d * D
        cam.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler(); cam.data.ortho_scale = 0.46 * S / 0.3 * 1.05
        scn.render.image_settings.color_mode = 'RGBA'; scn.render.filepath = os.path.join(OUT, 'mask_side_R.png'); bpy.ops.render.render(write_still=True)
        scn.render.film_transparent = False; scn.render.image_settings.color_mode = 'RGB'
    if '--wire' in sys.argv:
        scn.render.use_freestyle = True; vl = scn.view_layers[0]; vl.use_freestyle = True
        fs = vl.freestyle_settings; ls = fs.linesets.new('wire') if not fs.linesets else fs.linesets[0]
        ls.select_by_edge_types = True; ls.select_edge_mark = True; ls.select_silhouette = True; ls.select_border = True
        ls.visibility = 'VISIBLE'
        if ls.linestyle is None: ls.linestyle = bpy.data.linestyles.new('wire')
        ls.linestyle.thickness = 0.8; ls.linestyle.color = (0.02, 0.02, 0.02)
        for o in scn.objects:
            if o.type == 'MESH':
                at = o.data.attributes.get('freestyle_edge') or o.data.attributes.new('freestyle_edge', 'BOOLEAN', 'EDGE')
                at.data.foreach_set('value', [True] * len(o.data.edges))
        clay = bpy.data.materials.new('clay'); clay.use_nodes = True; clay.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.75, 0.75, 0.75, 1)
        saved = {o.name: list(o.data.materials) for o in scn.objects if o.type == 'MESH'}
        for o in scn.objects:
            if o.type == 'MESH' and not o.name.startswith('eye_cornea'): o.data.materials[0] = clay
        shoot('wire', only=[o.name for o in scn.objects if o.type == 'MESH' and not o.name.startswith('eye_cornea')])
        for o in scn.objects:
            if o.type == 'MESH': o.data.materials[0] = saved[o.name][0]
        scn.render.use_freestyle = False
    if '--form' in sys.argv and os.path.exists(os.path.join(OUT, 'form_mc.npz')):
        Fm = np.load(os.path.join(OUT, 'form_mc.npz'))
        me = bpy.data.meshes.new('form2'); me.from_pydata([B(v) for v in Fm['V']], [], Fm['F'].tolist()); me.update()
        for p in me.polygons: p.use_smooth = True
        clay2 = bpy.data.materials.new('clay2'); clay2.use_nodes = True; clay2.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.7, 0.7, 0.72, 1)
        me.materials.append(clay2); fo = bpy.data.objects.new('form', me); scn.collection.objects.link(fo)
        shoot('form', only=['form'])
