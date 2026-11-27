"""LOD chain (bpy + meshoptimizer). Replaces Blender's collapse decimate, which ignored UV seams and skin weights.

meshoptimizer (zeux/meshoptimizer, MIT) simplifies an indexed triangle list. We hand it the mesh split at every UV seam and material
border (one vertex per distinct (vertex, uv, material)), so seams and the interior/skin border are attribute seams it keeps whole:
it collapses along a seam only when both sides agree. The kept triangles are mapped back to the original vertices, so a LOD
shares the LOD0 vertices' skin weights, COLOR_0 and smooth normals exactly, and binds to the same rig.
"""
import numpy as np
import bpy
import ctypes as C
import meshoptimizer.simplifier as _ms

# meshopt_simplifyWithAttributes, called through the wrapper's loaded library with the C signature declared here: the wrapper
# (meshoptimizer 0.2.30a0 on PyPI) declares no argtypes and segfaults on this entry point (tested 27 Nov on a 20x20 grid).
_P = C.POINTER
_f = _ms.lib.meshopt_simplifyWithAttributes
_f.argtypes = [_P(C.c_uint), _P(C.c_uint), C.c_size_t, _P(C.c_float), C.c_size_t, C.c_size_t, _P(C.c_float), C.c_size_t,
               _P(C.c_float), C.c_size_t, _P(C.c_ubyte), C.c_size_t, C.c_float, C.c_uint, _P(C.c_float)]
_f.restype = C.c_size_t


def simplify_attr(idx, P, A, weights, lock, target, error):
    idx = np.ascontiguousarray(idx, np.uint32); P = np.ascontiguousarray(P, np.float32); A = np.ascontiguousarray(A, np.float32)
    w = np.ascontiguousarray(weights, np.float32); lk = np.ascontiguousarray(lock, np.uint8); dst = np.zeros_like(idx)
    n = _f(dst.ctypes.data_as(_P(C.c_uint)), idx.ctypes.data_as(_P(C.c_uint)), len(idx), P.ctypes.data_as(_P(C.c_float)), len(P), 12,
           A.ctypes.data_as(_P(C.c_float)), A.shape[1] * 4, w.ctypes.data_as(_P(C.c_float)), len(w), lk.ctypes.data_as(_P(C.c_ubyte)),
           int(target), float(error), 0, None)
    return dst[:n]


def simplify(ob, ratio, name, error=0.02, lock=()):
    me = ob.data; me.calc_loop_triangles()
    uvl = me.uv_layers['UV0'].data; nt = len(me.loop_triangles)
    keys = {}; split_pos = []; split_src = []; split_uv = []; split_mat = []; idx = np.empty(nt * 3, np.uint32)
    V = np.array([v.co[:] for v in me.vertices], np.float32)
    for k, lt in enumerate(me.loop_triangles):
        for c in range(3):
            li = lt.loops[c]; vi = lt.vertices[c]; uv = tuple(np.round(uvl[li].uv[:], 6)); key = (vi, uv, lt.material_index)
            j = keys.get(key)
            if j is None:
                j = keys[key] = len(split_src); split_src.append(vi); split_uv.append(uv); split_mat.append(lt.material_index); split_pos.append(V[vi])
            idx[3 * k + c] = j
    P = np.array(split_pos, np.float32)
    # the vertex normal rides as an attribute, so a collapse that would fold the surface (lip roll, gill slit lip) costs error;
    # the designed creases (cage rolls: lips, lip roll, gill slits, eye rims) are locked, so every LOD keeps its openings' rims
    me.calc_normals_split() if hasattr(me, 'calc_normals_split') else None
    VN = np.array([v.normal[:] for v in me.vertices], np.float32); NA = np.ascontiguousarray(VN[np.array(split_src)])
    lk = np.array([s_ in set(lock) for s_ in split_src], np.uint8)
    target = int(len(idx) * ratio) // 3 * 3
    out = simplify_attr(idx, P, NA, [0.5, 0.5, 0.5], lk, target, error)
    T = out.reshape(-1, 3); src = np.array(split_src); uvs = np.array(split_uv); mats = np.array(split_mat)
    # a triangle whose corners map to fewer than 3 original vertices (two seam copies of one vertex), or with no area in space or
    # in UV, is dropped: it has no normal or no tangent (validator ACCESSOR_VECTOR3_NON_UNIT on TANGENT) and draws nothing
    S3 = src[T]; Vs = V[S3]; area = np.linalg.norm(np.cross(Vs[:, 1] - Vs[:, 0], Vs[:, 2] - Vs[:, 0]), axis=1)
    U3 = np.array(split_uv)[T]; e1, e2 = U3[:, 1] - U3[:, 0], U3[:, 2] - U3[:, 0]; uva = np.abs(e1[:, 0] * e2[:, 1] - e1[:, 1] * e2[:, 0])
    ok = (S3[:, 0] != S3[:, 1]) & (S3[:, 1] != S3[:, 2]) & (S3[:, 0] != S3[:, 2]) & (area > 1e-3 * np.median(area)) & (uva > 1e-3 * np.median(uva)); T = T[ok]   # slivers under 0.1 % of the median have no stable tangent
    faces = src[T].tolist()
    lm = bpy.data.meshes.new(name); lm.from_pydata([v.co[:] for v in me.vertices], [], faces); lm.update()
    lu = lm.uv_layers.new(name='UV0')
    for p, tri in zip(lm.polygons, T):
        p.use_smooth = True; p.material_index = int(mats[tri[0]])
        for li, j in zip(p.loop_indices, tri): lu.data[li].uv = uvs[j]
    for m in me.materials: lm.materials.append(m)
    if 'Col' in me.color_attributes:
        src_c = np.zeros(len(me.vertices) * 4, np.float32); me.color_attributes['Col'].data.foreach_get('color', src_c)
        ca = lm.color_attributes.new('Col', 'FLOAT_COLOR', 'POINT'); ca.data.foreach_set('color', src_c); lm.color_attributes.active_color = ca
    lo = bpy.data.objects.new(name, lm); bpy.context.scene.collection.objects.link(lo)
    for g in ob.vertex_groups: lo.vertex_groups.new(name=g.name)
    for v in me.vertices:
        for ge in v.groups: lo.vertex_groups[ob.vertex_groups[ge.group].name].add([v.index], ge.weight, 'REPLACE')
    for md in ob.modifiers:
        if md.type == 'ARMATURE': m2 = lo.modifiers.new('rig', 'ARMATURE'); m2.object = md.object
    return lo, len(T)
