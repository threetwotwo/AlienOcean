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
# Structure rule: skin turns in round a rim. The underside of a gill cover's margin, the body lip tucked under it and the
# roll of a lip are skin (pigmented epidermis); the lining's own tissue starts further in. A lining coloured mucosa pink
# and shaded with the passage's occlusion right from the rim showed through every opening that is a lens at rest: a pink
# line along the closed mouth and along the belly's silhouette under the gill cover, a black sliver under the cover
# (export r6). So within RIM_SKIN of a rim (along the lining) the lining carries its rim's skin colour and no occlusion
# of its own, and by RIM_FADE it has gone over to its tissue.
AO_SAMPLES = 128                # DEFAULT: rays per texel of the linings' occlusion bake
AO_SMOOTH = 1.5                 # DEFAULT (texels): the occlusion map is smoothed over this radius inside the island
RIM_SKIN = 0.006                # DEFAULT (SL): the slit's first passage row lies 0.47-0.52 % SL in from the flap edge and the lip (cage/gill.py):
                                # what can be seen through the closed lens. A lip's roll is one lip thickness (0.3 % SL)
RIM_FADE = 0.014                # DEFAULT (SL): tissue colour from here in (the second passage row)


def rim_blend(C, V, out):
    """per vertex: (share of its own tissue 0..1, the skin colour (linear RGB) of the rim it is nearest to along the lining).
    Rim vertices are the ones shared by a skin face and an interior face; distance runs along the interior's edges."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import dijkstra
    from PIL import Image
    nv = len(V); inner = [t in INNER for t in C['ftag']]
    vin = set(v for f, i in zip(C['faces'], inner) if i for v in f); vsk = set(v for f, i in zip(C['faces'], inner) if not i for v in f)
    rim = sorted(vin & vsk); w = np.ones(nv); col = np.zeros((nv, 3))
    if not rim: return w, col, rim
    img = np.asarray(Image.open(os.path.join(out, 'body_base.png')).convert('RGB'), float) / 255
    img = np.where(img <= 0.04045, img / 12.92, ((img + 0.055) / 1.055) ** 2.4); H, W = img.shape[:2]
    acc = np.zeros((nv, 3)); cnt = np.zeros(nv); rs = set(rim)
    for f, uv, i in zip(C['faces'], C['uv'], inner):
        if i: continue
        for v, (u_, v_) in zip(f, uv):
            if v in rs: acc[v] += img[int(np.clip((1 - v_) * H, 0, H - 1)), int(np.clip(u_ * W, 0, W - 1))]; cnt[v] += 1
    E = set()
    for f, i in zip(C['faces'], inner):
        if i: E |= {tuple(sorted((f[k], f[(k + 1) % len(f)]))) for k in range(len(f))}
    E = np.array(sorted(E)); L = np.linalg.norm(V[E[:, 0]] - V[E[:, 1]], axis=1)
    G = coo_matrix((np.r_[L, L], (np.r_[E[:, 0], E[:, 1]], np.r_[E[:, 1], E[:, 0]])), shape=(nv, nv)).tocsr()
    dist, _, src = dijkstra(G, indices=rim, min_only=True, return_predecessors=True)
    ok = np.isfinite(dist); u = np.clip((dist[ok] - RIM_SKIN) / (RIM_FADE - RIM_SKIN), 0, 1)
    w[ok] = u * u * (3 - 2 * u); col[ok] = (acc / np.maximum(cnt, 1)[:, None])[src[ok]]
    return w, col, rim


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


def setup(body, body_m, C, out, idx, skip, res=512, V=None, open_co=None):
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
    plant = os.environ.get('CREATURE_PLANT_BAKE_FAULT', '') == 'lining_pink_at_rim'      # tests only: the fault back, to show EX9 catches it
    rw, rcol, rim = rim_blend(C, np.asarray(V, float), out) if V is not None and not plant else (np.ones(len(col)), col, [])
    col = rw[:, None] * col + (1 - rw)[:, None] * rcol
    # Structure rule: the mouth's wall is mucosa all over; gill red belongs to the passage behind the hole in that wall. The
    # tissue is therefore set per face corner: a cavity face is mucosa at every corner, a passage face grades to red. Set per
    # vertex, the hole's own loop was red for the cavity faces round it too, and where the hole turns forward along the floor
    # (a gill V) the red ran out over the floor of the mouth in streaks (export r7).
    red_wall = os.environ.get('CREATURE_PLANT_BAKE_FAULT', '') == 'gill_red_on_cavity_wall'      # tests only: per vertex again, to show EX10 catches it
    lv = np.zeros(len(me.loops), int); me.loops.foreach_get('vertex_index', lv); lgill = np.zeros(len(me.loops), bool)
    for p in me.polygons: lgill[p.loop_start:p.loop_start + p.loop_total] = C['ftag'][p.index] == 'gill' or red_wall
    mcol = rw[:, None] * np.array(MUCOSA) + (1 - rw)[:, None] * rcol
    lcol = np.where(lgill[:, None], col[lv], mcol[lv])
    ca = me.color_attributes.new('tissue', 'FLOAT_COLOR', 'CORNER'); ca.data.foreach_set('color', np.c_[lcol, np.ones(len(lcol))].ravel())
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
    ca.data.foreach_set('color', np.c_[rw, rw, rw, np.ones(len(rw))][lv].ravel()); own = bake('EMIT', 'interior_own', 1)[..., 0]
    # Structure rule: a lining is lit as it is seen, and the mouth's lining is only seen with the mouth open. Baked with the
    # lips closed the whole cavity is a sealed tube: every texel at the floor but the few a ray reaches through the lips'
    # gap, so the lining was one flat near-black with a black dither where it meets the rim's skin band (export r7). The
    # occlusion is baked with the jaw at the record's gape (open_co: the body's vertices in that pose) and smoothed over
    # AO_SMOOTH texels inside the island: occlusion has no detail finer than the passage it comes from.
    at_rest = os.environ.get('CREATURE_PLANT_BAKE_FAULT', '') == 'lining_lit_with_the_mouth_shut'      # tests only: the old bake, to show EX11 catches it
    co0 = np.zeros(3 * len(me.vertices)); me.vertices.foreach_get('co', co0)
    if open_co is not None and not at_rest: me.vertices.foreach_set('co', np.asarray(open_co, float).ravel()); me.update()
    ao4 = bake('AO', 'interior_ao', AO_SAMPLES); ao = ao4[..., 0]
    me.vertices.foreach_set('co', co0); me.update()
    if not at_rest:
        from scipy.ndimage import gaussian_filter
        m_ = (ao4[..., 3] > 0).astype(float); ao = np.where(m_ > 0, gaussian_filter(ao * m_, AO_SMOOTH) / np.maximum(gaussian_filter(m_, AO_SMOOTH), 1e-6), ao)
        ao = np.where(m_ > 0, np.maximum(ao, 1e-4), ao)      # a texel of the island stays one (0 means outside it, below)
    ao = np.where(ao > 0, 1 - own * (1 - ao), ao)      # a rim is lit as the skin it is
    me.color_attributes.remove(me.color_attributes['tissue'])
    from PIL import Image
    srgb = lambda c: np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.clip(c, 0, 1) ** (1 / 2.4) - 0.055)
    Image.fromarray((srgb(base[::-1]) * 255 + 0.5).clip(0, 255).astype(np.uint8)).save(os.path.join(out, 'interior_base.png'))
    orm = np.dstack([np.clip(ao[::-1], 0.15, 1), np.full_like(ao, ROUGH_WET), np.zeros_like(ao)])
    Image.fromarray((orm * 255 + 0.5).astype(np.uint8)).save(os.path.join(out, 'interior_orm.png'))
    me.materials[0] = body_m
    return idx, dict(rim_vertices=len(rim),
                     interior_faces=int(inner.sum()), interior_tex=[W, H], interior_ao_mean=round(float(ao[ao > 0].mean()) if (ao > 0).any() else 0, 3))
