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
# the skin's shading stops where the skin does: the edges between a skin face and an interior face (the lip rolls, the gill
# slits' lips) are sharp, so a lip vertex takes its normal from the skin faces only. Averaged with the lining, which turns
# inward there, the lip normals leaned up to 90 deg into the opening and the bake wrote the opposite lean over every skin face
# that touches a lip: one large face at the corner of the gill slit carried most of the map's steepest texels and all but one
# of its specks (export r5).
_ek = {}
for _p in body.data.polygons:
    for _k in _p.edge_keys: _ek.setdefault(_k, set()).add(C['ftag'][_p.index] in interior.INNER)
SHARP = sum(1 for _e in body.data.edges if len(_ek.get(tuple(sorted(_e.vertices)), ())) == 2)
if os.environ.get('CREATURE_PLANT_BAKE_FAULT', '') != 'lips_shaded_with_lining':   # tests only: the lean back, to show P6 catches it
    for _e in body.data.edges: _e.use_edge_sharp = len(_ek.get(tuple(sorted(_e.vertices)), ())) == 2
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
# the linings are lit as they are seen: with the mouth open to the record's gape (interior.setup)
from creature_maker import pose as _pose
_rec0 = adapt(sys.argv[sys.argv.index('--record') + 1], C.get('style'))
_Vg = _pose.gape(np.asarray(V, float), _pose.jaw_weights(C, np.asarray(V, float), _rec0), C['openings']['jaw_joint'], _rec0.get('gape_deg', 30.0))
INT_IDX, INT_STATS = interior.setup(body, body_m, C, OUT, INT_IDX, INT_SKIP, V=V, open_co=[tuple(B(v)) for v in _Vg])
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

# eyes: three low shells per eye in the cage's eye opening (iris with its pupil pit, lens, cornea window), placed by the
# cage's eye optics (cage.eye.optics). The look is in the maps and the materials, not the mesh: iris fibres, collarette and
# limbal step in a normal map; the argentea (the iris mirror) as metal in the ORM map, broken into platelet cells; the
# pupil pit and the lens black and glossy; the cornea a clear window. Triangle budget: checks EX7.
IRIS_SEG, LENS_SEG, CORNEA_SEG = 16, 10, 16      # DEFAULTS: segments round each shell. 126 triangles an eye; at the eye's size on a
                                                 # 10k fish the rim's own ring (the cage, about 30 sides) is the finer silhouette
IRIS_OVER = 1.04                                 # DEFAULT: the iris root reaches this far under the rim (x eye radius), no gap at a glancing view
EYE_TEX = 256                                    # DEFAULT: eye maps, pixels a side (an eye is about 1/40 of the body's length)
EYE_ROUGH = 0.2                                  # DEFAULT: iris roughness (old iris shine designer: rough 0.2)
def eye_tex():
    """iris maps in the disc's own coords (uv radius 1 = the iris root). Base = pigment only (the old Eyes finding: a grey
    "still share" of the mirror baked into colour washed the iris out; the mirror is a material, here metal in ORM)."""
    from PIL import Image
    R = EYE_TEX; yy, xx = np.mgrid[0:R, 0:R] / (R - 1) * 2 - 1; r = np.sqrt(xx ** 2 + yy ** 2); a = np.arctan2(yy, xx)
    iris = np.array(C['eye']['iris']); o = C['eyes'][0]['optics']; pup = o['pupil_r'] / (IRIS_OVER * C['eyes'][0]['r'])
    t = np.clip((r - pup) / (1 - pup), 0, 1)                                  # 0 at the pupil's edge, 1 at the root
    fib = 0.5 + 0.5 * np.cos(a * 37 + 3 * np.sin(a * 5)) * np.cos(a * 11)     # radial fibres
    coll = np.exp(-((t - 0.22) / 0.10) ** 2)                                  # collarette: the bright ring near the pupil
    col = iris[None, None] * (0.55 + 0.30 * t ** 0.5 + 0.30 * coll)[..., None] * (0.8 + 0.2 * fib)[..., None]
    limb = np.clip((r - 0.90) / 0.05, 0, 1)                                   # thin dark limbal line (old look layout: mirror over most of the iris)
    col = col * (1 - 0.7 * limb)[..., None]; col = np.where((r < pup)[..., None], 0.004, col)
    Image.fromarray((np.clip(col, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)).save(os.path.join(OUT, 'eye_base.png'))
    # height: fibres as furrows, the collarette a ridge, the limbus a step down to the root, the pupil's edge rolled
    h = 0.5 * fib * t * (1 - limb) + 0.8 * coll - 0.6 * limb + 0.5 * np.exp(-((r - pup) / 0.03) ** 2)
    gy, gx = np.gradient(h); k_ = R / 24.0; nrm = np.dstack([-gx * k_, -gy * k_, np.ones_like(h)]); nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    Image.fromarray(((nrm * 0.5 + 0.5) * 255).astype(np.uint8)).save(os.path.join(OUT, 'eye_normal.png'))
    # ORM: the mirror share (record paint.eye.silver) as metal over the iris, in platelet cells so it glints unevenly
    rng = np.random.default_rng(7); cell = rng.random((R // 4, R // 4)).repeat(4, 0).repeat(4, 1)
    metal = C['eye'].get('silver', 0.42) * (0.3 + 1.4 * cell ** 2) * (r > pup) * (1 - limb)      # mean = the mirror share x 0.77; a few cells flash
    rough = np.where(r < pup, 0.05, EYE_ROUGH * (0.7 + 0.6 * cell))
    Image.fromarray((np.dstack([np.ones_like(r), np.clip(rough, 0, 1), np.clip(metal, 0, 1)]) * 255).astype(np.uint8)).save(os.path.join(OUT, 'eye_orm.png'))
eye_tex()
eye_m = pbr('eye', image('eye_base', 'eye_base.png'), image('eye_normal', 'eye_normal.png', True), image('eye_orm', 'eye_orm.png', True))
lens_m = bpy.data.materials.new('eye_lens'); lens_m.use_nodes = True; lb = lens_m.node_tree.nodes['Principled BSDF']
lb.inputs['Base Color'].default_value = (0.004, 0.004, 0.006, 1); lb.inputs['Roughness'].default_value = 0.05
cor_m = bpy.data.materials.new('cornea'); cor_m.use_nodes = True; cb = cor_m.node_tree.nodes['Principled BSDF']
cb.inputs['Roughness'].default_value = 0.02; cb.inputs['Alpha'].default_value = 0.08
try: cor_m.surface_render_method = 'BLENDED'
except Exception: pass
def lathe(c, n, prof, seg, name, mat, uv_r):
    """a shell of revolution round the eye's axis: prof = [(radius, height over the rim plane)] from the outer edge in; a
    last radius of 0 is a pole. UV = the disc, radius / uv_r."""
    n = np.array(n); c = np.array(c); t = np.cross(n, [0, 1, 0]); t /= np.linalg.norm(t); b = np.cross(n, t)
    pole = prof[-1][0] <= 0; rings = prof[:-1] if pole else prof; vs, uvs = [], []
    for rad, hgt in rings:
        for s in range(seg):
            ph = 2 * math.pi * s / seg; d = t * math.cos(ph) + b * math.sin(ph)
            vs.append(c + n * hgt + d * rad); rr = min(rad / uv_r, 1.0); uvs.append((0.5 + 0.5 * rr * math.cos(ph), 0.5 + 0.5 * rr * math.sin(ph)))
    fs = [[k * seg + s, k * seg + (s + 1) % seg, (k + 1) * seg + (s + 1) % seg, (k + 1) * seg + s] for k in range(len(rings) - 1) for s in range(seg)]
    if pole:
        vs.append(c + n * prof[-1][1]); uvs.append((0.5, 0.5))
        fs += [[(len(rings) - 1) * seg + s, (len(rings) - 1) * seg + (s + 1) % seg, len(vs) - 1] for s in range(seg)]
    return mesh_obj(name, vs, [f[::-1] for f in fs], [[uvs[i] for i in f[::-1]] for f in fs], mat)
eye_obs = []
cb.inputs['IOR'].default_value = 1.376     # cornea
for e in C['eyes']:
    sd = 'L' if e['side'] > 0 else 'R'; o = e['optics']; r = e['r']; rL, zL, sag = o['lens_r'], o['lens_z'], o['cornea_sag']
    eye_obs.append(lathe(e['c'], e['n'], [(IRIS_OVER * r, o['iris_seat']), (o['pupil_r'], o['iris_z']), (0, o['iris_z'] - 0.3 * rL)], IRIS_SEG, 'eye_iris_' + sd, eye_m, IRIS_OVER * r))
    eye_obs.append(lathe(e['c'], e['n'], [(rL, zL), (rL * math.cos(math.pi / 4), zL + rL * math.sin(math.pi / 4)), (0, zL + rL)], LENS_SEG, 'eye_lens_' + sd, lens_m, rL))
    Rs = (r * r + sag * sag) / (2 * sag); mid = r * math.sqrt(0.5)                 # the window: a low cap of a sphere on the rim
    eye_obs.append(lathe(e['c'], e['n'], [(r, 0.0), (mid, math.sqrt(Rs * Rs - mid * mid) - (Rs - sag)), (0, sag)], CORNEA_SEG, 'eye_cornea_' + sd, cor_m, r))
for ob in eye_obs:
    for p in ob.data.polygons: p.flip()
    colour0(ob, np.ones(len(ob.data.vertices)))

# ---------------------------------------------------------------- rig: spine chain, jaw, gill covers (creature_maker.rig), fin bones
REC_PATH = sys.argv[sys.argv.index('--record') + 1] if '--record' in sys.argv else None
if REC_PATH is None: raise SystemExit('glb needs --record RECORD.json (jaw, cover and swim come from the record)')
REC = adapt(REC_PATH, C.get('style')); RAW = json.load(open(REC_PATH))
BL = RIG.bones(C, V, REC) + RIG.fin_bones(C); NB, xs = RIG.spine_stations(C)
rig = rigging.build_armature(scn, BL, B)
W_body, RIG_INFO = RIG.weights(C, V, REC)
rigging.bind_groups(body, rig, W_body)
spine_groups = lambda xv: RIG.spine_groups(C, xv)
for k, ob in fin_obs.items():
    # every fin vertex follows the spine at its own x, so median fins bend with the body; paired fins and the caudal fin hand over to
    # their own bone chains from root (T = 0) to edge (T = 1) (rig.fin_groups); median fins have no bones (they follow the trunk)
    rigging.bind_groups(ob, rig, RIG.fin_groups(C, k))
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
# the shipped clips open only as far as the stress test found clean (SR1_safe): a clip past it would ship a measured fold. The real
# angle stays in pose_limits.real, and SR1 keeps failing upstream until the cage reaches it.
_safe = CHK.get('SR1_safe') or {}
GAPE_CLIP = min(GAPE_REAL, float(_safe.get('gape', GAPE_REAL))); FLARE_CLIP = min(FLARE_REAL, float(_safe.get('flare', FLARE_REAL)))
FPS = 120; scn.render.fps = FPS; scn.render.fps_base = 1.0
cmap = {j: b for b, j in swim_clip.bone_joints(NB).items()}; cmap.update({b['name']: b['name'] for b in BL if b.get('fin')})   # engine joint -> bone
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
rigging.key_clip(rig, 'gape', rigging.hinge_frames(rig, JAW, GAPE_CLIP), FPS)
rigging.key_clip(rig, 'flare', rigging.hinge_frames(rig, COVERS, FLARE_CLIP), FPS)
SW['extras']['clips']['gape']['peak_deg'] = GAPE_CLIP; SW['extras']['clips']['flare']['peak_deg'] = FLARE_CLIP
SW['extras']['clips']['gape']['peak_rule'] = SW['extras']['clips']['flare']['peak_rule'] = 'min(real angle, SR1_safe): the clip never opens past the clean stress-test range'
SW['extras']['head_bones'] = {n: dict(pivot_m=[round(c, 6) for c in (B(bspec[n]['pivot']).x, B(bspec[n]['pivot']).z, -B(bspec[n]['pivot']).y)],
                                      axis_gltf=[round(c, 6) for c in (hinge(n)[2].x, hinge(n)[2].z, -hinge(n)[2].y)],
                                      opens='positive angle about axis_gltf (armature space, right hand)') for n in ('jaw', 'opercleL', 'opercleR')}
RG = swim_clip.rig_checks(C, V, W_body, BL, SW); SW['extras']['rig']['checks'] = RG; print('RG', {k: v for k, v in RG.items() if k.endswith('_pass') or k.endswith('pctBL')})
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
# LOD chain = the Unreal-era intake rule (tools/optimise/creature_meter.py K2, proven on the v107 exports): level 0 is needed only
# inside reach0, the distance where its own triangle count gives 2-pixel edges (1920 px, 90 deg view); each later level has 4 x fewer
# triangles and starts at twice the distance, down to about 300 triangles. Targets are triangle counts, met by scaling the ratio
# down until the level is inside its count; the switch distances ride in the extras for the engine's LOD ranges. The simplifier's error
# bound doubles per level with the distance, so the error stays the same size on screen at each level's first distance.
T0 = tris_of(LOD0)
def area_of(objs):
    a = 0.0
    for o in objs:
        if o.type != 'MESH' or o.name.startswith('col_'): continue
        M = o.matrix_world; W = [M @ v.co for v in o.data.vertices]
        for p in o.data.polygons:
            vs = [W[i] for i in p.vertices]; a += sum(((vs[i] - vs[0]).cross(vs[i + 1] - vs[0])).length / 2 for i in range(1, len(vs) - 1))
    return a
PPM = 960.0; A0 = area_of(LOD0); REACH0 = math.sqrt(A0 / (0.433 * T0)) * PPM / 2.0
CHAIN = [dict(lod=0, tris=T0, from_m=0.0)]; _tc, _dc = T0, REACH0
while _tc / 4.0 >= 300 and len(CHAIN) < 3:
    _tc = int(_tc / 4.0); CHAIN.append(dict(lod=len(CHAIN), tris=_tc, from_m=round(_dc, 3))); _dc *= 2.0
for lod, ratio, budget in [(c['lod'], 0.4 if c['lod'] == 1 else 0.14, c['tris']) for c in CHAIN[1:]]:
    for attempt in range(6):
        obs = []
        for o in [body] + list(fin_obs.values()):
            lo, nt = LODS.simplify(o, ratio if o is body else max(ratio * 1.6, 0.3 * min(1.0, ratio / 0.14)), f'{o.name}_LOD{lod}', error=0.02 * 2 ** (lod - 1), lock=CREASES if (o is body and lod == 1) else ()); lo.hide_render = True; obs.append(lo)
        got = tris_of(obs + (eye_obs if lod == 1 else []))
        if got <= budget or attempt == 5: break
        for lo in obs: bpy.data.objects.remove(lo, do_unlink=True)
        ratio *= 0.97 * budget / got
    CHAIN[lod]['tris_built'] = got
    keep = obs + [rig] + (eye_obs if lod == 1 else [])
    pth = os.path.join(OUT, f'fish_LOD{lod}.glb'); _exp(pth, keep); finish(pth, lod)
    lint = sum(1 for p in obs[0].data.polygons if p.material_index == INT_IDX)
    lods[f'LOD{lod}'] = dict(tris=tris_of(keep), kb=round(os.path.getsize(pth) / 1024), interior_tris=lint); lod_obs[lod] = obs
SW['extras']['lod_chain'] = dict(levels=CHAIN, reach0_m=round(REACH0, 3), area_m2=round(A0, 5),
    rule='Unreal-era intake rule (tools/optimise/creature_meter.py K2): level 0 is needed inside reach0 (2 px edges at 1920 px, 90 deg); each level 4 x fewer triangles from twice the distance; from_m = first distance to draw that level')
for _p, _l in [(glb, 0)] + [(os.path.join(OUT, f'fish_LOD{c["lod"]}.glb'), c['lod']) for c in CHAIN[1:]]: finish(_p, _l)
json.dump(dict(SW['extras']), open(os.path.join(OUT, 'swim.json'), 'w'), indent=1, default=float)
stats = dict(glb_kb=round(os.path.getsize(glb) / 1024), objects=len([o for o in LOD0 if o.type == 'MESH' and not o.name.startswith('col_')]))
stats['tris_total'] = tris_of(LOD0); stats['normal_specks_fixed'] = SPECKS_FIXED; stats['bones'] = len(rig.data.bones); stats['lods'] = lods; stats['lod_chain'] = SW['extras']['lod_chain']; stats['blender_bake_s'] = bake_s
stats.update(INT_STATS); stats.update(RIG_INFO); stats.update(EXS); stats.update(RG)
stats['eye_shell_tris'] = tris_of(eye_obs); stats['eye_patch_tris'] = sum(len(f) - 2 for f, t in zip(C['faces'], C['ftag']) if t == 'eye')
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
