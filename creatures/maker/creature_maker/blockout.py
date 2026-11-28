"""Stage 0, BLOCKOUT (numpy): a stand-in for any species, made from its record in under a second, to test motion before detail.

Gary 28 Nov: the maker's first step for every species is a blockout. Swimming, schooling, collision, riding and scale next to the girl
are tested on it. Muscle, skin and face detail come only after the blockout moves right.

  body    a chain of ellipsoids along the spine, following the record's traced side outline (top, bottom) and top view (half-width).
          Each ellipsoid rides ONE spine bone rigidly, so a bend shows as the segments turning, as a jointed toy does.
  fins    flat plates at their true sizes: the same fin cards the full build makes (fins.build_fins, from the record's traced fin
          outlines and base lines), drawn untextured.
  rig     the export's own bones (rig.py: spine chain, jaw, gill covers) and fin root bones. The jaw and covers carry no weight here:
          they are in the rig so the engine's clips and extras are the same for a blockout and a finished fish.
  scale   record size.SL_mm (real adult size), as the full export.

Checks (in blockout.json, all from the record, no picture):
  BK1  side outline: IoU of the ellipsoids' side view against the record's traced outline (top and bottom), snout to caudal base
  BK2  top view: the same against the record's half-width
  BK3  fins: each fin plate seen from the side covers the record's traced fin outline (true size); for a traced paired fin, the plate's
       side view is its traced outline by construction, so this catches a plate that is rescaled or set off its base line
"""
import json, os, time
import numpy as np
from PIL import Image, ImageDraw
from .record import adapt
from .form import Form
from .fins import build_fins
from . import rig as RIG

PER_BONE = 2          # DEFAULT: ellipsoids per spine bone. One per bone leaves the outline scalloped between segments; two keep the
                      # side view within BK1's line on the traced set at 10 bones
OVERLAP = 1.5         # DEFAULT: each ellipsoid's half-length, in centre spacings. At 1.5 the union between two centres keeps 94 % of
                      # the smaller one's height (sqrt(1 - (1/3)^2)); at 1.0 it would drop to 87 % (visible notches)
SEG, RINGS = 14, 8    # DEFAULT: an ellipsoid's mesh (longitude x latitude): 14 x 8 = 196 triangles, ~4k for a 20-segment body
BK1_MIN = 0.90        # DEFAULT: the blockout reads as the species from the side (SIL1, the full build's own gate, is 0.90)
BK2_MIN = 0.85        # DEFAULT: top view, looser: an ellipse has no flat flank
BK3_MIN = 0.85        # DEFAULT: a fin plate's side view against its record outline, clear of the body. The full build's own cards
                      # (fins.edge_card) measure 0.75-0.99 on trevally: resampled to EDGE_RAYS columns they cut across a concave trailing
                      # edge (dorsal2 0.75). A plate rescaled by 1.25 or set off its base drops well under 0.85 (planted in the tests)


def _ellipsoid(c, r, seg=SEG, rings=RINGS):
    """vertices and quad/tri faces of an axis-aligned ellipsoid, centre c, semi-axes r (x, y, z), poles on the x axis (snout-tail)."""
    V = [c + np.array([r[0], 0, 0]), c - np.array([r[0], 0, 0])]
    for i in range(1, rings):
        t = np.pi * i / rings; x = np.cos(t)
        for j in range(seg):
            p = 2 * np.pi * j / seg; V.append(c + r * np.array([x, np.sin(t) * np.cos(p), np.sin(t) * np.sin(p)]))
    F = []
    ring = lambda i, j: 2 + (i - 1) * seg + j % seg
    for j in range(seg): F.append([0, ring(1, j + 1), ring(1, j)])
    for i in range(1, rings - 1):
        for j in range(seg): F.append([ring(i, j), ring(i, j + 1), ring(i + 1, j + 1), ring(i + 1, j)])
    for j in range(seg): F.append([1, ring(rings - 1, j), ring(rings - 1, j + 1)])
    return np.array(V), F


def segments(form, rec):
    """the ellipsoid chain: list of dict(c, r, bone). Centres are spaced so the first ellipsoid's front reaches the snout tip and the
    last one's back reaches the caudal base."""
    NB = int(rec['bones']); n = NB * PER_BONE
    x_end = float(min(form.XEND, rec['fins']['caudal']['x']))
    dx = x_end / (n - 1 + 2 * OVERLAP); ax = OVERLAP * dx
    xc = ax + dx * np.arange(n)
    C = dict(bones=NB, xend=form.XEND)
    out = []
    for x in xc:
        t, b, w = float(form.TOP(x)), float(form.BOT(x)), float(form.HW(x))
        out.append(dict(c=[float(x), (t + b) / 2, 0.0], r=[float(ax), max((t - b) / 2, 1e-3), max(w, 1e-3)], bone=RIG.spine_index(C, x)))
    return out, x_end


def body_mesh(segs):
    V, F, B = [], [], []
    for s in segs:
        v, f = _ellipsoid(np.array(s['c']), np.array(s['r'])); o = len(V) if not V else sum(len(q) for q in V)
        V.append(v); F += [[o + i for i in q] for q in f]; B += [s['bone']] * len(v)
    return np.vstack(V), F, np.array(B)


def _iou(a, b):
    return float((a & b).sum() / max((a | b).sum(), 1))


def checks(form, segs, x_end, fins, rec, n=600):
    """BK1-BK3 by raster in record units."""
    R = {}
    xs = np.linspace(0, x_end, n); T, Bt, W = form.TOP(xs), form.BOT(xs), form.HW(xs)
    lo, hi = float(min(Bt.min(), min(s['c'][1] - s['r'][1] for s in segs))), float(max(T.max(), max(s['c'][1] + s['r'][1] for s in segs)))
    ys = np.linspace(lo, hi, n)[:, None]
    ref = (ys <= T[None]) & (ys >= Bt[None])
    zmax = float(max(W.max(), max(s['r'][2] for s in segs))); zs = np.linspace(-zmax, zmax, n)[:, None]
    reft = np.abs(zs) <= W[None]
    side = np.zeros_like(ref); top = np.zeros_like(reft)
    for s in segs:
        (cx, cy, _), (ax, ay, az) = s['c'], s['r']
        u = np.clip(1 - ((xs - cx) / ax) ** 2, 0, None)[None]
        side |= ((ys - cy) / ay) ** 2 <= u; top |= (zs / az) ** 2 <= u
    R['BK1_side_iou'] = round(_iou(side, ref), 4); R['BK1_pass'] = R['BK1_side_iou'] >= BK1_MIN
    R['BK2_top_iou'] = round(_iou(top, reft), 4); R['BK2_pass'] = R['BK2_top_iou'] >= BK2_MIN
    # BK3: each fin card's side view (its quads filled) against the record outline of that fin: root row + traced free edge
    # only the part of a fin that stands clear of the body counts: a card's root row runs under the skin and a traced outline closes
    # with a chord across the body, and neither is seen
    fin_iou = {}; xb = np.linspace(0, form.XEND, 400)
    body = np.vstack([np.c_[xb, form.TOP(xb)], np.c_[xb, form.BOT(xb)][::-1]])
    for k, f in fins.items():
        V = np.asarray(f['V'])[:, :2]; edge = _fin_outline(rec, k, form)
        if edge is None: continue
        lo2 = np.minimum(V.min(0), edge.min(0)); sc = 400 / max(float((np.maximum(V.max(0), edge.max(0)) - lo2).max()), 1e-9)
        px = lambda P: [tuple(q) for q in ((np.asarray(P) - lo2) * sc).tolist()]
        card = Image.new('1', (402, 402)); d = ImageDraw.Draw(card)
        for q in f['F']: d.polygon(px(V[q]), fill=1)
        rf = Image.new('1', (402, 402)); ImageDraw.Draw(rf).polygon(px(edge), fill=1)
        bm = Image.new('1', (402, 402)); ImageDraw.Draw(bm).polygon(px(body), fill=1)
        clear = np.ones((402, 402), bool) if k.startswith(('pectoral', 'pelvic')) else ~np.array(bm)   # paired fins lie over the body
        fin_iou[k] = round(_iou(np.array(card) & clear, np.array(rf) & clear), 4)
    R['BK3_fin_iou'] = fin_iou; R['BK3_pass'] = (not fin_iou) or min(fin_iou.values()) >= BK3_MIN
    if not fin_iou: R['BK3_note'] = 'no traced fin outline in the record: fins from its fin tables, nothing to compare'
    R['BK_pass'] = R['BK1_pass'] and R['BK2_pass'] and R['BK3_pass']
    return R


def _fin_outline(rec, k, form=None):
    """the record's own side outline of fin k (traced edge closed along its root), or None when the record has no traced edge."""
    F = rec['fins']; name = k.rsplit('_', 1)[0] if k.endswith(('_L', '_R')) else k
    if name == 'caudal': f = F['caudal']
    elif name in ('pectoral', 'pelvic'): f = F.get(name)
    else: f = next((m for m in F['median'] if m['name'] == name), None)
    if not f or not f.get('edge'): return None
    E = np.asarray(f['edge'], float)
    if name in ('pectoral', 'pelvic'):
        if not f.get('base_line'): return None
        BL = np.asarray(f['base_line'], float)
        if np.linalg.norm(E[-1] - BL[0]) > np.linalg.norm(E[-1] - BL[-1]): BL = BL[::-1]   # close from the edge's end
        return np.vstack([E, BL])
    if name == 'caudal' or form is None: return E
    # a median fin closes along the body's own outline between its ends: a fin split in two (spiny and soft parts of one outline)
    # ends in the air at the split, and a straight chord there would cut away fin the card rightly fills down to the body
    edge_y = form.TOP if f['top'] else form.BOT; xa, xb = float(E[0, 0]), float(E[-1, 0])
    xr = np.linspace(xb, xa, 60); return np.vstack([E, np.c_[xr, edge_y(xr)]])


def blockout(record_path, out, style=None, log=print):
    T0 = time.time(); os.makedirs(out, exist_ok=True)
    rec = adapt(record_path, style); form = Form(rec)
    segs, x_end = segments(form, rec)
    V, F, VB = body_mesh(segs)
    fins = build_fins(form, rec, out)
    R = checks(form, segs, x_end, fins, rec)
    tris = sum(len(q) - 2 for q in F) + sum(2 * len(v['F']) for v in fins.values())
    D = dict(kind='blockout', species=rec['species'], SL_mm=rec['SL_mm'], xend=form.XEND, x_end_body=x_end, bones=rec['bones'],
             jaw_joint=rec['jaw_joint'], opercle_hinge=rec['opercle_hinge'], mouth_line=np.asarray(rec['mouth']['line']).tolist(),
             cover_rear=np.asarray(rec['cover']['rear']).tolist(),
             segments=segs, V=V.tolist(), F=F, vbone=VB.tolist(),
             fins={k: dict(V=np.asarray(v['V']).tolist(), F=v['F'], T=v['T']) for k, v in fins.items()},
             checks=R, tris=tris,
             rules=dict(PER_BONE=PER_BONE, OVERLAP=OVERLAP, SEG=SEG, RINGS=RINGS),
             inputs=rec['provenance'], defaults_used=rec['defaults_used'], build_s=round(time.time() - T0, 2))
    json.dump(D, open(os.path.join(out, 'blockout.json'), 'w'))
    log(f"{rec['species']}: {len(segs)} ellipsoids, {tris} tris, BK1 {R['BK1_side_iou']} BK2 {R['BK2_top_iou']} "
        f"BK3 {min(R['BK3_fin_iou'].values()) if R['BK3_fin_iou'] else None} pass {R['BK_pass']} ({D['build_s']} s)")
    return D


def board(out, sources, glb=True, log=print):
    """a blockout of every record under sources (files or folders, *.json, Species records only) -> OUT/<name>/ + board_blockout.json."""
    import glob, subprocess, sys
    recs = []
    for s in sources:
        if s.startswith('--'): continue
        recs += sorted(glob.glob(os.path.join(s, '*.json'))) if os.path.isdir(s) else [s]
    os.makedirs(out, exist_ok=True); rows = {}
    script = os.path.join(os.path.dirname(__file__), 'blender', 'export_blockout.py')
    for rp in recs:
        name = os.path.basename(rp)[:-5]; od = os.path.join(out, name)
        try:
            D = blockout(rp, od, log=log); row = dict(record=rp, species=D['species'], tris=D['tris'], build_s=D['build_s'], **D['checks'])
        except Exception as e:                       # not a Species record, or one the adapter cannot read: listed, not fatal
            rows[name] = dict(record=rp, error=f'{type(e).__name__}: {e}'[:200]); log(f'{name}: {rows[name]["error"]}'); continue
        if glb:
            r = subprocess.run([sys.executable, script, od, '--record', rp], capture_output=True, text=True)
            st = os.path.join(od, 'blockout_glb.json')
            row['glb'] = json.load(open(st)) if r.returncode == 0 and os.path.exists(st) else dict(error=(r.stderr or r.stdout)[-300:])
        rows[name] = row
    ok = [r for r in rows.values() if 'error' not in r]
    summary = dict(records=len(rows), built=len(ok), BK_pass=sum(r['BK_pass'] for r in ok),
                   glb_ok=sum(1 for r in ok if 'glb' in r and 'error' not in r['glb']),
                   failing={n: [k for k in ('BK1_pass', 'BK2_pass', 'BK3_pass') if not r[k]] for n, r in rows.items() if 'error' not in r and not r['BK_pass']})
    json.dump(dict(summary=summary, rows=rows), open(os.path.join(out, 'board_blockout.json'), 'w'), indent=1, default=float)
    log(json.dumps(summary)); return summary
