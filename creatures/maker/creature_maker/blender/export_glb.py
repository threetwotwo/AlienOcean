"""Stage 7, EXPORT (Blender Python, bpy): cage + form -> Blender bake (selected-to-active, MikkTSpace normal + AO) -> rigged glTF LOD0-2 + renders.
Usage: python -m creature_maker glb OUTDIR [--res 2048] [--views] [--wire] [--form] [--samples N]
"""
import bpy, bmesh, json, sys, os, math
import numpy as np
from mathutils import Vector, Matrix

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
# underwater skin: reflectance 0.01-0.06 % (lessons, fins handover s5) -> IOR of water-skin, not 1.5
for m_ in (body_m, fin_m):
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

# ---------------------------------------------------------------- rig: spine chain + fin bones, weights from body coordinate u
arm = bpy.data.armatures.new('rig'); rig = bpy.data.objects.new('rig', arm); scn.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig; bpy.ops.object.mode_set(mode='EDIT')
NB = C['bones']; xs = np.linspace(0.02, C['xend'] - 0.03, NB + 1); spine = []
for i in range(NB):
    eb = arm.edit_bones.new(f'spine_{i:02d}'); eb.head = B([xs[i], 0, 0]); eb.tail = B([xs[i + 1], 0, 0])
    if spine: eb.parent = spine[-1]; eb.use_connect = True
    spine.append(eb)
def fin_bone(name, verts, parent):
    v = np.array(verts); root = v[: len(v) // 6].mean(0); tip = v[-len(v) // 6:].mean(0)
    eb = arm.edit_bones.new(name); eb.head = B(root); eb.tail = B(root + (tip - root) * 0.6); eb.parent = parent; return eb
def spine_at(x): return spine[int(np.clip(np.searchsorted(xs, x) - 1, 0, NB - 1))]
for k, f in C['fins'].items():
    v = np.array(f['V']); fin_bone('fin_' + k, f['V'], spine_at(v[:, 0].mean()))
bpy.ops.object.mode_set(mode='OBJECT')
names = [f'spine_{i:02d}' for i in range(NB)]; ctrs = (xs[:-1] + xs[1:]) / 2
def bind(ob, weights_fn):
    for n in names + ['fin_' + k for k in C['fins']]: ob.vertex_groups.new(name=n)
    for v in ob.data.vertices:
        p = v.co; x = p.x / S
        for n, w in weights_fn(x, v.index):
            if w > 1e-3: ob.vertex_groups[n].add([v.index], float(w), 'REPLACE')
    md = ob.modifiers.new('rig', 'ARMATURE'); md.object = rig  # no object parenting: glTF wants skinned meshes at the root (validator NODE_SKINNED_MESH_NON_ROOT)
def spine_w(x):
    f = np.interp(x, ctrs, np.arange(NB)); i0 = int(np.floor(f)); a = f - i0
    return [(names[i0], 1 - a)] + ([(names[i0 + 1], a)] if i0 + 1 < NB else [])
bind(body, lambda x, i: spine_w(x))
for k, ob in fin_obs.items():
    nv = len(ob.data.vertices); M = len(np.array(C['fins'][k]['V']))
    rows = None
    def wf(x, i, k=k):
        t = (i // max(1, (len(C['fins'][k]['UV']) and 1)))
        v = np.array(C['fins'][k]['UV'][i]); return [(n, w * 0.4) for n, w in spine_w(x)] + [('fin_' + k, 0.6)]
    bind(ob, wf)
for ob in eye_obs: bind(ob, lambda x, i: [(names[0], 1.0)])
# a gentle swim pose action so the export carries an animation (S-wave down the chain)
act = bpy.data.actions.new('swim'); rig.animation_data_create(); rig.animation_data.action = act
bpy.context.view_layer.objects.active = rig; bpy.ops.object.mode_set(mode='POSE')
for fr in range(0, 25, 3):
    for i, n in enumerate(names):
        pb = rig.pose.bones[n]; pb.rotation_mode = 'XYZ'
        amp = 0.03 + 0.11 * (i / (NB - 1)) ** 2
        pb.rotation_euler = (0, 0, amp * math.sin(2 * math.pi * fr / 24 - i * 0.7)); pb.keyframe_insert('rotation_euler', frame=fr)
bpy.ops.object.mode_set(mode='OBJECT'); scn.frame_set(0)
for i, n in enumerate(names): rig.pose.bones[n].rotation_euler = (0, 0, 0)

# ---------------------------------------------------------------- export
glb = os.path.join(OUT, 'fish.glb')
EXP = dict(export_format='GLB', export_animations=True, export_skins=True, export_tangents=True, export_image_format='AUTO',
           export_vertex_color='ACTIVE')
def _exp(path, **kw):
    try: bpy.ops.export_scene.gltf(filepath=path, **EXP, **kw)
    except TypeError:
        e2 = dict(EXP); e2.pop('export_vertex_color'); bpy.ops.export_scene.gltf(filepath=path, **e2, **kw)
_exp(glb)
# LOD chain: collapse-decimate copies (seams kept by the exporter's split), eyes dropped at LOD2
lods = {}
for lod, ratio in ((1, 0.4), (2, 0.14)):
    mods = []
    for o in [body] + list(fin_obs.values()):
        md = o.modifiers.new('lod', 'DECIMATE'); md.ratio = ratio if o is body else max(ratio * 1.6, 0.3)
        md.use_collapse_triangulate = True
        while o.modifiers[0].name != 'lod': bpy.ops.object.modifier_move_up({'object': o}, modifier='lod') if False else o.modifiers.move(o.modifiers.find('lod'), 0)
        mods.append((o, md))
    for o in scn.objects: o.select_set(False)
    keep = [body, rig] + list(fin_obs.values()) + (eye_obs if lod == 1 else [])
    for o in keep: o.select_set(True)
    pth = os.path.join(OUT, f'fish_LOD{lod}.glb'); _exp(pth, use_selection=True, export_apply=True)
    dg = bpy.context.evaluated_depsgraph_get(); t = 0
    for o in keep:
        if o.type == 'MESH': t += sum(len(p.vertices) - 2 for p in o.evaluated_get(dg).data.polygons)
    lods[f'LOD{lod}'] = dict(tris=t, kb=round(os.path.getsize(pth) / 1024))
    for o, md in mods: o.modifiers.remove(md)
stats = dict(glb_kb=round(os.path.getsize(glb) / 1024), objects=len([o for o in scn.objects if o.type == 'MESH']))
tris = 0
for o in scn.objects:
    if o.type == 'MESH': tris += sum(len(p.vertices) - 2 for p in o.data.polygons)
stats['tris_total'] = tris; stats['normal_specks_fixed'] = SPECKS_FIXED; stats['bones'] = len(arm.bones); stats['lods'] = lods; stats['blender_bake_s'] = bake_s
json.dump(stats, open(os.path.join(OUT, 'glb_stats.json'), 'w')); print('EXPORT', stats)

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
            if o.type == 'MESH': o.hide_render = (only is not None and o.name not in only)
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
