"""The interior material slot (bpy): every cage face tagged 'cavity' (mouth cavity, throat, pharynx dome) or 'gill' (gill passages)
goes on its own material, named 'interior' (engine contract), with its own textures, so the engine can shade the inside of the mouth
apart from the skin (wet, no scales, no coat).

Its maps come from the cage itself, not from paint:
  AO          Cycles ambient occlusion of the body mesh on itself: the throat and the passages darken with depth because the
              mouth's own walls hide the sky from them
  base colour tissue by tag: mouth lining (buccal mucosa) on the cavity, grading along each gill passage from the lining at the
              slit to gill-filament red where it opens into the cavity (the gill arches sit there)
  ORM         R = AO, G = roughness of wet mucosa, B = 0
STAND-IN colours (the record has no interior colour field yet; HARD_PROBLEMS row EXP-INT-1): MUCOSA and GILL_RED below, linear RGB.
"""
import os
import numpy as np
import bpy

MUCOSA = (0.62, 0.42, 0.40)     # STAND-IN: pale pink buccal lining (teleost mouth lining, linear RGB)
GILL_RED = (0.42, 0.05, 0.05)   # STAND-IN: gill filaments (blood in the lamellae)
ROUGH_WET = 0.35                # DEFAULT: wet mucosa, rougher than the eye, smoother than skin
INNER = ('cavity', 'gill')


def island_box(C):
    U = np.array([uv for f, t, u in zip(C['faces'], C['ftag'], C['uv']) if t in INNER for uv in u])
    lo, hi = U.min(0), U.max(0); return lo, hi


def tissue(C, nv):
    """per vertex: 0 = mucosa, 1 = gill red. Gill passage rows: row 0 is the slit (lining), the last row the hole in the cavity wall."""
    t = np.zeros(nv)
    for rows in C['openings'].get('gill_rows', []):
        n = len(rows) - 1
        for r, row in enumerate(rows):
            for v in row: t[v] = max(t[v], (r / max(n, 1)) ** 1.5)
    skin = set(v for f, tg in zip(C['faces'], C['ftag']) if tg not in INNER for v in f)
    for v in skin: t[v] = 0.0                                       # the lip roll and the slit lip are skin-side: lining colour
    return t


def slot(body, C):
    """puts every interior face on its own material slot, with a throwaway bake target, and returns (slot index, that material).
    Called before the skin is baked: Blender bakes every face of the object into its material's active image, and the interior
    island lies over the skin islands in 0-1 UV space (it belongs to another texture), so on one shared material the cavity and
    passage faces baked the form from the inside straight over the cheek, throat and tail-root texels of the skin maps."""
    me = body.data; idx = len(me.materials); inner = np.array([t in INNER for t in C['ftag']])
    dummy = bpy.data.images.new('bake_dummy', 8, 8); skip = bpy.data.materials.new('bake_skip'); skip.use_nodes = True
    tn = skip.node_tree.nodes.new('ShaderNodeTexImage'); tn.image = dummy; skip.node_tree.nodes.active = tn
    me.materials.append(skip)
    for p in me.polygons:
        if inner[p.index]: p.material_index = idx
    return idx, skip


def setup(body, body_m, C, out, idx, skip, res=512):
    """remaps the interior UV island to fill its own texture, bakes its maps and returns (slot index, stats). idx and skip come
    from slot()."""
    me = body.data
    inner = np.array([t in INNER for t in C['ftag']])
    lo, hi = island_box(C); asp = (hi[0] - lo[0]) / max(hi[1] - lo[1], 1e-9)
    W = res; H = int(2 ** round(np.log2(max(64, res / max(asp, 1e-3))))) if asp > 1 else res
    if asp < 1: W = int(2 ** round(np.log2(max(64, res * asp))))
    m = 0.02; uvl = me.uv_layers['UV0']
    for p in me.polygons:
        if inner[p.index]:
            for li in p.loop_indices:
                u, v = uvl.data[li].uv; uvl.data[li].uv = (m + (1 - 2 * m) * (u - lo[0]) / (hi[0] - lo[0]), m + (1 - 2 * m) * (v - lo[1]) / (hi[1] - lo[1]))
    # bake materials: the body slot gets the throwaway target so the skin maps already in memory are never overwritten
    tmp = bpy.data.materials.new('interior_bake'); tmp.use_nodes = True; nt = tmp.node_tree
    at = nt.nodes.new('ShaderNodeAttribute'); at.attribute_name = 'tissue'; at.attribute_type = 'GEOMETRY'
    em = nt.nodes.new('ShaderNodeEmission'); nt.links.new(at.outputs['Color'], em.inputs['Color'])
    outn = nt.nodes['Material Output']; nt.links.new(em.outputs['Emission'], outn.inputs['Surface'])
    t = tissue(C, len(me.vertices)); col = (1 - t)[:, None] * np.array(MUCOSA) + t[:, None] * np.array(GILL_RED)
    ca = me.color_attributes.new('tissue', 'FLOAT_COLOR', 'POINT'); ca.data.foreach_set('color', np.c_[col, np.ones(len(col))].ravel())
    me.materials[0] = skip; me.materials[idx] = tmp
    scn = bpy.context.scene
    for o in scn.objects: o.select_set(False)
    body.select_set(True); bpy.context.view_layer.objects.active = body
    def bake(kind, name, samples):
        img = bpy.data.images.new(name, W, H, float_buffer=True); img.colorspace_settings.name = 'Non-Color'
        n = nt.nodes.new('ShaderNodeTexImage'); n.image = img; nt.nodes.active = n
        scn.cycles.samples = samples
        bpy.ops.object.bake(type=kind, use_selected_to_active=False, margin=8, use_clear=True)
        return np.array(img.pixels[:], np.float32).reshape(H, W, 4)
    base = bake('EMIT', 'interior_emit', 1)[..., :3]
    ao = bake('AO', 'interior_ao', 64)[..., 0]
    me.color_attributes.remove(me.color_attributes['tissue'])
    from PIL import Image
    srgb = lambda c: np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.clip(c, 0, 1) ** (1 / 2.4) - 0.055)
    Image.fromarray((srgb(base[::-1]) * 255 + 0.5).clip(0, 255).astype(np.uint8)).save(os.path.join(out, 'interior_base.png'))
    orm = np.dstack([np.clip(ao[::-1], 0.15, 1), np.full_like(ao, ROUGH_WET), np.zeros_like(ao)])
    Image.fromarray((orm * 255 + 0.5).astype(np.uint8)).save(os.path.join(out, 'interior_orm.png'))
    me.materials[0] = body_m
    return idx, dict(interior_faces=int(inner.sum()), interior_tex=[W, H], interior_ao_mean=round(float(ao[ao > 0].mean()) if (ao > 0).any() else 0, 3))
