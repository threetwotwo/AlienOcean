"""Stage 0b, BLOCKOUT EXPORT (Blender Python, bpy): blockout.json -> fish_blockout.glb with the full export's rig, swim clips, extras and
collision, so a blockout drops into the same engine code (swim, schools, collision, riding, scale) as a finished fish.

Usage: python -m creature_maker blockout OUT --record RECORD.json        (writes blockout.json, then runs this)
Differences from blender/export_glb.py: no bake, no maps, no interior, no eyes, no LODs. Body segments are rigid (one bone each), the
jaw and gill covers are bones with no weight (their clips move nothing), and colours are flat greys: alternate segments differ in
shade so the bend reads in a test scene.
"""
import bpy, json, sys, os
import numpy as np
from mathutils import Vector, Matrix
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from creature_maker import rig as RIG, swim_clip, collision, glbpatch
from creature_maker.blender import rigging

OUT = sys.argv[1]; D = json.load(open(os.path.join(OUT, 'blockout.json')))
REC_PATH = sys.argv[sys.argv.index('--record') + 1]; RAW = json.load(open(REC_PATH))
S = D['SL_mm'] / 1000.0
def B(p): return Vector((p[0] * S, -p[2] * S, p[1] * S))     # record (x snout-to-tail, y up, z left) -> Blender Z-up, metres

bpy.ops.wm.read_factory_settings(use_empty=True)
scn = bpy.context.scene

def flat(name, rgb, two_sided=False):
    m = bpy.data.materials.new(name); m.use_nodes = True; bs = m.node_tree.nodes['Principled BSDF']
    bs.inputs['Base Color'].default_value = (*rgb, 1.0); bs.inputs['Roughness'].default_value = 0.7
    m.use_backface_culling = not two_sided; return m

GREY_A, GREY_B, GREY_FIN = (0.42, 0.44, 0.46), (0.30, 0.32, 0.34), (0.62, 0.64, 0.66)   # DEFAULT: test-scene greys (no paint on a blockout)
mat_a, mat_b, mat_f = flat('seg_a', GREY_A), flat('seg_b', GREY_B), flat('fin_plate', GREY_FIN, two_sided=True)

V = np.array(D['V']); F = D['F']; VB = np.array(D['vbone'])
me = bpy.data.meshes.new('body'); me.from_pydata([B(v) for v in V], [], F); me.update()
me.materials.append(mat_a); me.materials.append(mat_b)
for p in me.polygons:
    p.use_smooth = True; p.material_index = int(VB[p.vertices[0]] % 2)
body = bpy.data.objects.new('body', me); scn.collection.objects.link(body)

fin_obs = {}
for k, f in D['fins'].items():
    m_ = bpy.data.meshes.new(k); m_.from_pydata([B(v) for v in f['V']], [], f['F']); m_.update(); m_.materials.append(mat_f)
    ob = bpy.data.objects.new(k, m_); scn.collection.objects.link(ob); fin_obs[k] = ob

# ---------------------------------------------------------------- rig: the full export's bones (rig.bones needs a cage-like C)
C = dict(bones=D['bones'], xend=D['xend'], SL_mm=D['SL_mm'], species=D['species'], fins=D['fins'],
         openings=dict(jaw_joint=D['jaw_joint'], opercle_hinge=D['opercle_hinge']),
         faces=F, ftag=['body'] * len(F))
REC = dict(mouth=dict(line=D['mouth_line']), cover=dict(rear=D['cover_rear']))
BL = RIG.bones(C, V, REC); NB, xs = RIG.spine_stations(C)
spine_at = lambda x: f'spine_{RIG.spine_index(C, x):02d}'
rig = rigging.build_armature(scn, BL, D['fins'], B, spine_at)
W = {f'spine_{i:02d}': (VB == i).astype(float) for i in range(NB)}                 # rigid segments
W.update(jaw=np.zeros(len(V)), opercleL=np.zeros(len(V)), opercleR=np.zeros(len(V)))
rigging.bind_groups(body, rig, W)
for k, ob in fin_obs.items():   # as export_glb: fin vertices follow the spine at their x, paired fins hand over to their root bone
    fv = np.array(D['fins'][k]['V']); T = np.clip(np.array(D['fins'][k]['T'], float), 0, 1)
    share = T if k.startswith(('pectoral', 'pelvic')) else np.zeros(len(fv))
    i0, a0, i1, a1 = RIG.spine_weights(C, fv[:, 0]); g = {}
    for j in range(len(fv)):
        for i, a in ((i0[j], a0[j]), (i1[j], a1[j])):
            g.setdefault(f'spine_{i:02d}', np.zeros(len(fv)))[j] += a * (1 - share[j])
    g['fin_' + k + '_root'] = share
    rigging.bind_groups(ob, rig, g)

# ---------------------------------------------------------------- clips: the swim engine on the blockout's own mass model
SW = swim_clip.clips(C, V, RAW, BL, None)
FPS = 120; scn.render.fps = FPS; scn.render.fps_base = 1.0
chain = swim_clip.chain_names(NB); cmap = {chain[i]: f'spine_{i:02d}' for i in range(NB)}
rigging.key_clip(rig, 'swim_loop', [(k / SW['swim_fps'], P) for k, P in enumerate(rigging.engine_frames(rig, SW['swim'], cmap))], FPS)
cmap_b = dict(opercleL='opercleL', opercleR='opercleR')
rigging.key_clip(rig, 'breathe_loop', [(k / SW['breathe_fps'], P) for k, P in enumerate(rigging.engine_frames(rig, SW['breathe'], cmap_b))], FPS)
SW['extras']['clips'].pop('gape', None); SW['extras']['clips'].pop('flare', None)
SW['extras']['blockout'] = dict(rule='rigid ellipsoid segments, one spine bone each; fin plates from the record; jaw and covers unweighted',
                                checks=D['checks'], segments=len(D['segments']))

# ---------------------------------------------------------------- collision: hulls of the segments, each run on its first bone
HUL = collision.hulls(V, np.array([q[:3] for q in F]), xs)
col_obs = []
for k, (hv, hf, bi) in enumerate(HUL):
    m_ = bpy.data.meshes.new(f'col_{k:02d}'); m_.from_pydata([B(v) for v in hv], [], hf.tolist()); m_.update()
    ob = bpy.data.objects.new(f'col_{k:02d}-convcolonly', m_); scn.collection.objects.link(ob)
    ob.parent = rig; ob.parent_type = 'BONE'; ob.parent_bone = f'spine_{bi:02d}'
    bpy.context.view_layer.update(); ob.matrix_world = Matrix.Identity(4); ob.hide_render = True
    col_obs.append(ob)
bpy.context.view_layer.update()

EXP = dict(export_format='GLB', export_animations=True, export_skins=True, export_animation_mode='NLA_TRACKS', export_force_sampling=True,
           export_extras=False, export_optimize_animation_size=True, export_optimize_animation_keep_anim_armature=False)
objs = [body, rig] + list(fin_obs.values()) + col_obs
for o in scn.objects: o.select_set(False)
for o in objs: o.select_set(True)
glb = os.path.join(OUT, 'fish_blockout.glb')
bpy.ops.export_scene.gltf(filepath=glb, use_selection=True, **EXP)
glbpatch.patch(glb, node_extras={'rig': {'alien_ocean': dict(swim=SW['extras'], lod='blockout', species=D['species'])}},
               anim_extras={n: dict(loop=True) for n in ('swim_loop', 'breathe_loop')})
tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in [body] + list(fin_obs.values()))
stats = dict(glb=os.path.basename(glb), kb=round(os.path.getsize(glb) / 1024), tris=tris, bones=len(rig.data.bones),
             hulls=len(HUL), swim_loop_closure_BL=SW['loop_err'], beat_Hz=SW['extras']['clips']['swim_loop']['beat_Hz'],
             swim_keys_hz=round(SW['swim_fps'], 1), jitter=SW['extras']['jitter'])
json.dump(stats, open(os.path.join(OUT, 'blockout_glb.json'), 'w'), indent=1)
print('BLOCKOUT_GLB', json.dumps(stats))
