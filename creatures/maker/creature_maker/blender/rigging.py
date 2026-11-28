"""Rig and clips (bpy). Bones and weights come from creature_maker.rig (numpy, tested without Blender); clips from
creature_maker.swim_clip (the project swim engine). This file only turns them into Blender bones, vertex groups and actions.

Frames: record (x snout -> tail, y up, z left, SL units) -> Blender B(p) = (x, -z, y) * SL metres (export_glb.B).
The swim engine's frame (snout +X, up +Y, left -Z, metres) -> Blender: (X, Y, Z) -> (-X, Z, Y), a proper rotation; a world transform
T in the engine frame becomes A T A^-1 in Blender.
"""
import math
import numpy as np
import bpy
from mathutils import Matrix, Vector, Quaternion

A3 = Matrix(((-1, 0, 0), (0, 0, 1), (0, 1, 0)))        # engine frame -> Blender frame: record = (-X, Y, -Z), Blender = (x, -z, y) -> (-X, Z, Y); det +1
A4 = A3.to_4x4(); A4i = A4.inverted()


def build_armature(scn, bone_list, B):
    """bone_list: creature_maker.rig bones (spine, jaw, covers) + rig.fin_bones (fin chains), parents before children."""
    arm = bpy.data.armatures.new('rig'); rig = bpy.data.objects.new('rig', arm); scn.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig; bpy.ops.object.mode_set(mode='EDIT'); eb = {}
    for b in bone_list:
        e = arm.edit_bones.new(b['name']); e.head = B(b['head']); e.tail = B(b['tail'])
        if b['parent']: e.parent = eb[b['parent']]; e.use_connect = b['connect']
        eb[b['name']] = e
    bpy.ops.object.mode_set(mode='OBJECT')
    return rig


def bind_groups(ob, rig, groups):
    """groups: {bone name: per-vertex weight array}."""
    for n, w in groups.items():
        g = ob.vertex_groups.new(name=n); idx = np.where(w > 1e-4)[0]
        for i in idx: g.add([int(i)], float(w[i]), 'REPLACE')
    md = ob.modifiers.new('rig', 'ARMATURE'); md.object = rig   # no object parenting: glTF wants skinned meshes at the root


def key_clip(rig, action_name, frames, fps_scene):
    """frames: list of (t seconds, {bone: armature-space pose matrix}); writes each bone's basis so its pose is exactly P.
    basis = (Pp_rest^-1 B_rest)^-1 Pp^-1 P, with Pp the parent's pose matrix in the same frame (rest if not given)."""
    act = bpy.data.actions.new(action_name); rig.animation_data_create(); rig.animation_data.action = act
    bones = rig.data.bones
    for t, Ps in frames:
        fr = t * fps_scene
        for name, P in Ps.items():
            b = bones[name]; pb = rig.pose.bones[name]; pb.rotation_mode = 'QUATERNION'
            if b.parent is None: basis = b.matrix_local.inverted() @ P
            else:
                Pp = Ps.get(b.parent.name, b.parent.matrix_local)
                basis = (b.parent.matrix_local.inverted() @ b.matrix_local).inverted() @ Pp.inverted() @ P
            loc, q, _ = basis.decompose()
            pb.rotation_quaternion = q; pb.keyframe_insert('rotation_quaternion', frame=fr)
            if b.parent is None or not b.use_connect:
                pb.location = loc; pb.keyframe_insert('location', frame=fr)
    for fc in _fcurves(act):
        for kp in fc.keyframe_points: kp.interpolation = 'LINEAR'
    tr = rig.animation_data.nla_tracks.new(); tr.name = action_name
    st = tr.strips.new(action_name, int(frames[0][0] * fps_scene), act); tr.mute = True
    rig.animation_data.action = None
    for pb in rig.pose.bones: pb.location = (0, 0, 0); pb.rotation_quaternion = (1, 0, 0, 0)
    return act


def _fcurves(act):
    try: return list(act.fcurves)
    except AttributeError:   # Blender 5 slotted actions: curves live in layers -> strips -> channelbags
        out = []
        for ly in act.layers:
            for s in ly.strips:
                for cb in s.channelbags: out += list(cb.fcurves)
        return out


def engine_frames(rig, clip, chain_map, scale_m=1.0):
    """swim engine frames -> per frame {bone: armature-space pose matrix}. chain_map: engine joint name -> Blender bone name."""
    names, rest, W, Q = clip; out = []
    for k in range(len(W)):
        Ps = {}
        for jn, bn in chain_map.items():
            i = names.index(jn); b = rig.data.bones[bn]
            q = Quaternion((Q[k][i][3], Q[k][i][0], Q[k][i][1], Q[k][i][2]))
            T = Matrix.Translation(Vector(W[k][i])) @ q.to_matrix().to_4x4() @ Matrix.Translation(-Vector(rest[i]))
            Ps[bn] = A4 @ T @ A4i @ b.matrix_local
        out.append(Ps)
    return out


def hinge_pose(rig, specs, deg):
    """armature-space pose matrices of head bones turned about their pivots (Blender frame): specs = [(bone, pivot, axis)]."""
    Ps = {}
    for bone, pv, ax in specs:
        R = Matrix.Rotation(math.radians(deg), 4, Vector(ax))
        Ps[bone] = Matrix.Translation(Vector(pv)) @ R @ Matrix.Translation(-Vector(pv)) @ rig.data.bones[bone].matrix_local
    return Ps


def hinge_frames(rig, specs, peak_deg, seconds=1.0, n=None):
    """head bones opened and closed again: 0 -> peak -> 0 with a smooth ease (sin^2), peak at half time. Keyed at swim_clip.KEY_HZ
    (was 24 keys a second: straight lines between them kink the ease at every key, a shudder at 120 Hz; no jitter, Gary 28 Nov)."""
    if n is None:
        from creature_maker.swim_clip import KEY_HZ
        n = int(math.ceil(KEY_HZ * seconds))
    return [(k / n * seconds, hinge_pose(rig, specs, peak_deg * math.sin(math.pi * k / n) ** 2)) for k in range(n + 1)]
