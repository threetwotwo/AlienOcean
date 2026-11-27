"""kf_paint.py 0.1.0 (Dress the lagoon thread, 27 Nov 2026): the key frame material family, evaluated per vertex into COLOR_0.

PORT of world/textures/keyframe/kf_family.py (Style/Textures, 15-21 Nov; archive/ue_era world bundle): the same palette (art bible
v1.8, sRGB hex -> linear), the same saturation unlock (CRUST_SAT 2.2, CORAL_SAT 1.35, table x1.7), the same zones (Up, Turf, Under,
Tip from pointiness) and the same one-gradient rules (rock: lit olive-gold top over a wall that grades by height above the sand to a
blue-grey foot, wall gain 0.75, 18 cm sand film; mounds: pale warm crown -> side -> dark underside; branching: paler tips by height;
table: paler rim). What is NOT ported, and why: the AO hollow zone (Godot's SSAO/GI does occlusion at run time), the 0.25-0.9 m near
detail maps and displacement (a look/ shader job for the engine thread), the 0.6/0.8 m noise breakups (noise is not detail; the
mesh's own grown form carries the edge). Colour in the asset, so the shared water-lit look/seabed_surface shader stays generic.

paint(kind, V, N, E, vc=None, z0=0.0) -> (n, 4) linear RGBA. V/N: vertex positions/normals in the piece frame (Z up, metres, sand at
z0); E: (m, 2) edges; vc: the maker's own vertex colour (colony maker pattern), used as a value ratio as kf_family did.
"""
import json, os
import numpy as np

PAL = dict(rock='#797265', crev='#5f5a50', turf='#7b8164', crust='#a98a8e', sand='#cdcac4', table='#e7985e')
CRUST_SAT, CORAL_SAT = 2.2, 1.35
# Art direction for the Godot water (Fable critique r2, 27 Nov): under Godot's blue water light the kf_family top (olive-gold, sat 1.1)
# reads lime and the wall sits at the fog's value. Gary 27 Nov: art direction trumps realism. One family, value from light:
TOP_CHROMA = 0.5    # x the top zone's saturation (sage, not lime)
WALL_DARK = 0.90    # x the wall values (edge survives the haze; r6 Fable: 0.82 read 10 % too dark against the key frame)
WALL_CHROMA = 0.80  # x the wall saturation (r6 Fable: walls 20 % too chromatic under the blue light)
TABLE_SAT = 1.2     # x CORAL_SAT for the table (kf_family 1.7; r6 Fable: still orange with yellow tips under Godot light, key frame reads even salmon-peach)
TABLE_TIP = '#f2a99c'   # the table coral's rim: paler salmon-pink (r6 Fable: #f3b08c still read yellow at the rim)
LAGOON = '/mnt/project-files/life/colony_maker/'
CORAL_KINDS = {
    'table':    dict(under=0.38, tips='rim', groove=0.30, colours='coral_table_crown'),
    'staghorn': dict(under=0.70, tips='height', groove=0.25, colours='coral_staghorn_thicket'),
    'finger':   dict(under=0.70, tips='height', groove=0.25, colours=None),
    'boulder':  dict(under=0.55, tips='crown', groove=0.20, colours='coral_boulder_head'),
    'brain':    dict(under=0.55, tips='crown', groove=0.45, colours=None, vc=1.4),
}

def lin(h, k=1.0):
    h = h.lstrip('#'); c = np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)])
    return k * np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
def srgb_to_lin(c): return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
def sat(c, k):
    y = c @ np.array([0.2126, 0.7152, 0.0722]) if c.ndim > 1 else float(c @ np.array([0.2126, 0.7152, 0.0722]))
    return np.maximum(0.0, (y[..., None] if c.ndim > 1 else y) + (c - (y[..., None] if c.ndim > 1 else y)) * k)
def mixl(a, b, t): return a + (b - a) * t
def smooth(x, a, b, invert=False):
    t = np.clip((x - a) / (b - a), 0, 1); s = t * t * (3 - 2 * t); return 1 - s if invert else s
def mix(t, a, b):   # Blender MixRGB: fac t from a to b, per vertex
    t = np.asarray(t)[..., None]; return a + (b - a) * t

def pointiness(V, N, E):
    """Blender's pointiness, approximately: 0.5 on flat skin, above on convex tips, below in concave creases."""
    d = V[E[:, 1]] - V[E[:, 0]]; L = np.linalg.norm(d, axis=1) + 1e-9; d /= L[:, None]
    acc = np.zeros(len(V)); cnt = np.zeros(len(V))
    np.add.at(acc, E[:, 0], -(N[E[:, 0]] * d).sum(1)); np.add.at(acc, E[:, 1], (N[E[:, 1]] * d).sum(1))
    np.add.at(cnt, E[:, 0], 1); np.add.at(cnt, E[:, 1], 1)
    return 0.5 + 0.5 * acc / np.maximum(cnt, 1)

def zones(V, N, E):
    up = N[:, 2]; p = pointiness(V, N, E)
    side = smooth(np.abs(up), 0.45, 0.90, invert=True)
    return dict(Up=up, Turf=smooth(up, 0.30, 0.75), Under=smooth(up, -0.65, -0.15, invert=True), Tip=smooth(p, 0.52, 0.60) * side, P=p)

def rock(V, N, E, z0=0.0):
    Z = zones(V, N, E); h = V[:, 2] - z0
    top_hi = sat(mixl(lin(PAL['turf']), lin('#c99a50'), 0.90), 1.10 * TOP_CHROMA); top_lo = sat(mixl(lin(PAL['turf']), lin('#c99a50'), 0.75), 1.05 * TOP_CHROMA)
    wall_hi = sat(mixl(lin(PAL['rock'], 1.5), lin('#a39a8c', 1.5), 0.4), 0.85 * WALL_CHROMA) * 0.75 * WALL_DARK
    wall_lo = sat(mixl(lin(PAL['rock'], 1.4), lin('#8d9ba2', 1.4), 0.5), 0.45 * WALL_CHROMA) * 0.75 * WALL_DARK
    topm = smooth(Z['Up'], 0.35, 0.80)
    top = mix(smooth(Z['Up'], 0.70, 0.98), top_lo, top_hi)
    wall = mix(smooth(h, 0.0, 1.4), wall_lo, wall_hi)
    col = mix(topm, wall, top)
    col = mix(Z['Under'] * 0.35, col, wall_lo)
    foot = mixl(lin(PAL['sand']), wall_hi, 0.25)
    col = mix(smooth(h, 0.0, 0.18, invert=True) * 0.85, col, foot)
    return col

def coral_colours(kind):
    spec = CORAL_KINDS[kind]['colours']
    try:
        if spec: return dict(json.load(open(LAGOON + 'plate_corals/b1/%s_spec.json' % spec))['pieces'][0]['colours'])
    except Exception: pass
    try: base = json.load(open(LAGOON + 'lagoon_slice/kinds_v27/colours.json'))['g_' + kind]
    except Exception: base = PAL['table']
    def mixh(h, t, k):
        a = [int(h[i:i + 2], 16) for i in (1, 3, 5)]; b = [int(t[i:i + 2], 16) for i in (1, 3, 5)]
        return '#' + ''.join('%02x' % round(x + (y - x) * k) for x, y in zip(a, b))
    return dict(base=base, tip=mixh(base, '#ffffff', 0.30), groove=mixh(base, '#000000', 0.25), crown=mixh(base, '#ffffff', 0.15))

def coral(kind, V, N, E, vc=None):
    K = CORAL_KINDS[kind]; C = coral_colours(kind); Z = zones(V, N, E); k = CORAL_SAT
    if kind == 'table': k *= TABLE_SAT
    if K['tips'] == 'crown':   # mounds (_build_mound): crown -> side -> under, one gradient
        base = lin(C['base'], 1.25)
        crown = sat(mixl(base, lin('#f6e2b8'), 0.22), k * 1.15)
        side = sat(mixl(base, lin('#5f9c9a'), 0.15), k * 1.05) * 0.80
        under = sat(mixl(base, lin('#2e5c64'), 0.50), k) * 0.60
        col = mix(smooth(Z['Up'], -0.15, 0.85), side, crown)
        col = mix(Z['Under'] * 0.9, col, under)
    else:
        base = sat(lin(C['base']), k); tip = sat(lin(TABLE_TIP if kind == 'table' else C.get('tip', C['base'])), k)
        if K['tips'] == 'rim': tipm = Z['Tip'] * 0.8
        else:
            hz = (V[:, 2] - V[:, 2].min()) / max(1e-6, np.ptp(V[:, 2]))
            tipm = np.maximum(smooth(hz, 0.62, 0.95), Z['Tip'] * 0.6)
        col = mix(tipm, base, tip)
        col = mix(Z['Under'], col, sat(lin(C['base'], K['under']), k))
    if vc is not None:   # the colony maker's own pattern kept as a value ratio around the base value
        bw = vc[:, :3] @ np.array([0.2126, 0.7152, 0.0722]); y = float(lin(C['base']) @ np.array([0.2126, 0.7152, 0.0722]))
        ratio = np.clip(bw / max(y, 1e-3), 0.25, 1.8)
        col = col * (1.0 + (ratio - 1.0) * K.get('vc', 1.0))[:, None]
    return col

def paint(kind, V, N, E, vc=None, z0=0.0):
    col = rock(V, N, E, z0) if kind == 'rock' else coral(kind, V, N, E, vc)
    return np.concatenate([np.clip(col, 0, 1), np.ones((len(V), 1))], 1)

def grass(vc, uv):
    """kf_grass.build_grass_material (Textures 15 Nov) per vertex: the leaf's own colour (as the key frame rig read it: the stored
    COLOR_0 values, which is what Gary approved) at saturation 1.2, older leaves (alpha) browner toward the tip, both margins
    (uv.x < 0.10 or > 0.90, the modelled thickened edge) paler and warmer: the drawn outline. uv.y: 0 base .. 1 tip (glTF V)."""
    col = sat(np.clip(vc[:, :3], 0, 1), 1.2)
    u, v = uv[:, 0], uv[:, 1]
    age_tip = vc[:, 3] * smooth(v, 0.55, 1.0)
    col = mix(age_tip * 0.55, col, lin('#6f6a3a'))
    edge = np.maximum(smooth(u, 0.03, 0.10, invert=True), smooth(u, 0.90, 0.97))
    pale = mixl(col, lin('#d9e6a0'), 0.55)
    col = col + (pale - col) * (edge * 0.85)[:, None]
    return np.concatenate([np.clip(col, 0, 1), np.ones((len(col), 1))], 1)
