"""Stage 0, BLOCKOUT (numpy): a stand-in for any species, made from its record in under a second, to test motion before detail.

Gary 28 Nov: the maker's first step for every species is a blockout. Swimming, schooling, collision, riding and scale next to the girl
are tested on it. Muscle, skin and face detail come only after the blockout moves right.

  body    a chain of ellipsoids along the spine, following the record's traced side outline (top, bottom) and top view (half-width).
          Each ellipsoid rides ONE spine bone rigidly, so a bend shows as the segments turning, as a jointed toy does.
  fins    flat plates at their true sizes: the same fin cards the full build makes (fins.build_fins, from the record's traced fin
          outlines and base lines), drawn untextured.
  rig     the export's own bones (rig.py: spine chain, jaw, gill covers) and fin root bones, so the engine's clips and extras are the
          same for a blockout and a finished fish.
  head    tier 3 cutters (blockout_cut): a mouth cavity behind a lower-jaw block on the jaw bone, gill slits under cover plates on
          the opercle bones, eye sockets with eyeballs. gape and flare open them. Off: CUTTERS = False.
  tiers   1 masses (spine segments), 2 forms (joints, roots, fin plates, jaw, covers, eyeballs), 3 surgical (cutters); exported as
          LOD0 (all), LOD1 (masses, joints, roots, fins: no cutters or head pieces), LOD2 (masses and fins).
  scale   record size.SL_mm (real adult size), as the full export.

Checks (in blockout.json, all from the record, no picture):
  BK1  side outline: IoU of the ellipsoids' side view against the record's traced outline (top and bottom), snout to caudal base
  BK2  top view: the same against the record's half-width
  BK3  fins: each fin plate seen from the side covers the record's traced fin outline (true size); for a traced paired fin, the plate's
       side view is its traced outline by construction, so this catches a plate that is rescaled or set off its base line
  BK4-BK6 fin roots inside, bend gap, sections (below); CT1-CT3 jaw in its cut, slits under the covers, eyes in sockets (blockout_cut)
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


def _sq(u, e):
    """signed power: the superellipse's parameter map."""
    return np.sign(u) * np.abs(u) ** e


def _ellipsoid(c, r, seg=SEG, rings=RINGS, R=None, n=None, ry_lo=None):
    """vertices and quad/tri faces of an ellipsoid, centre c, semi-axes r along the columns of R (default the x, y, z axes), poles on
    its first axis (snout-tail for a body segment)."""
    R = np.eye(3) if R is None else np.asarray(R, float); c = np.asarray(c, float); r = np.asarray(r, float)
    V = [c + R @ np.array([r[0], 0, 0]), c - R @ np.array([r[0], 0, 0])]
    for i in range(1, rings):
        t = np.pi * i / rings; x = np.cos(t)
        for j in range(seg):
            p = 2 * np.pi * j / seg; cy, cz = np.cos(p), np.sin(p)
            if n is not None:   # superellipse section |y|^n + |z|^n = 1, its own exponent above and below the midline
                e = 2.0 / (n[0] if cy >= 0 else n[1]); cy, cz = _sq(cy, e), _sq(cz, e)
            rr = r if (ry_lo is None or cy >= 0) else np.array([r[0], ry_lo, r[2]])
            V.append(c + R @ (rr * np.array([x, np.sin(t) * cy, np.sin(t) * cz])))
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
        q = dict(kind='segment', c=[float(x), (t + b) / 2, 0.0], r=[float(ax), max((t - b) / 2, 1e-3), max(w, 1e-3)], bone=RIG.spine_index(C, x))
        if SUPER:
            s0 = widest(form, x); h = (t - b) / 2; cy = (t + b) / 2 + s0 * h
            q['c'][1] = cy; q['r'][1] = max(t - cy, 1e-3); q['ry_lo'] = max(cy - b, 1e-3); q['s0'] = s0
            q['n'] = section_exponents(form, x, s0)
        out.append(q)
    return out, x_end


SUPER = True          # DEFAULT: segments are superquadrics, their section a superellipse fitted to the record's own section at the
                      # segment's centre, one exponent above the midline and one below. Stress test 28 Nov (BK6): plain ellipse
                      # sections match the record's sections at IoU 0.83 (angelfish), 0.84 (lionfish, hawkfish) .. 0.98
N_RANGE = (1.0, 6.0)  # DEFAULT: exponents fitted inside this range (1: a diamond, a keeled back or belly; 6: a box-like flank, boxfish)
BK6_MIN = 0.90        # DEFAULT: every segment's section against the record's section at its centre (front view). Stress test 28 Nov,
                      # superquadric blocks split at the widest line: trunk 0.95-0.97 on angelfish, lionfish, hawkfish; the two head
                      # blocks 0.90-0.94 (the eye tissue and jaws shape the head's sections: tier 2, the forms)


def _sect_iou(w, e):
    return float(np.minimum(w, e).sum() / max(np.maximum(w, e).sum(), 1e-12))


def widest(form, x, k=81):
    """normalised height (-1 bottom .. 1 top) of the record section's widest point at x: a section's widest line is rarely its midline
    (a deep-bellied fish is widest low, a flat-backed one high)."""
    s_ = np.linspace(-0.9, 0.9, k); w = np.array([float(form.wnorm(x, v)) for v in s_])
    return float(np.mean(s_[w >= w.max() - 1e-6]))


def section_exponents(form, x, s0=0.0, k=41):
    """the superellipse exponents (above, below the widest line at s0) that best match the record's section at x."""
    out = []
    for sg in (1, -1):
        t_ = np.linspace(0, 1, k); s_ = s0 + sg * t_ * (1 - sg * s0); w = np.array([float(form.wnorm(x, v)) for v in s_]) / max(float(form.wnorm(x, s0)), 1e-9)
        s_ = sg * t_
        ns = np.linspace(N_RANGE[0], N_RANGE[1], 47)
        sc = [_sect_iou(w, np.clip(1 - np.abs(s_) ** n, 0, 1) ** (1 / n)) for n in ns]
        out.append(round(float(ns[int(np.argmax(sc))]), 3))
    return out


def section_check(form, segs, k=81):
    """BK6: each segment's section (ellipse, or its superellipse) against the record's section at its centre."""
    s_ = np.linspace(-1, 1, k); worst = 1.0; at = None
    for q in segs:
        x = q['c'][0]; w = np.array([float(form.wnorm(x, v)) for v in s_]); s0 = q.get('s0', 0.0)
        u = np.where(s_ >= s0, (s_ - s0) / max(1 - s0, 1e-9), (s_ - s0) / max(1 + s0, 1e-9))     # the block's own height, -1..1
        if q.get('n') is None: e = np.sqrt(np.clip(1 - u ** 2, 0, 1))
        else: nn = np.where(u >= 0, q['n'][0], q['n'][1]); e = np.clip(1 - np.abs(u) ** nn, 0, 1) ** (1 / nn)
        e = e * max(w.max(), 1e-9) if q.get('s0') is not None else e   # the block's width is the record's widest
        v = _sect_iou(w, e)
        if v < worst: worst, at = v, round(float(x), 3)
    return dict(BK6_section_iou_worst=round(worst, 4), BK6_worst_x=at, BK6_pass=bool(worst >= BK6_MIN))


def body_mesh(segs, carved=None):
    """one mesh of every block, each vertex labelled with its spine bone. carved {bone: (V, F)}: bones meshed from their field with
    the tier 3 cutters taken out (blockout_cut), in place of their block meshes."""
    V, F, B = [], [], []; carved = carved or {}
    for b, (v, f) in sorted(carved.items()):
        o = sum(len(q) for q in V); V.append(np.asarray(v)); F += [[o + i for i in q] for q in f]; B += [b] * len(v)
    for s in segs:
        if s['bone'] in carved: continue
        sg, rg = (SEG, RINGS) if s.get('kind', 'segment') == 'segment' else PRIM_RES
        v, f = _ellipsoid(s['c'], s['r'], sg, rg, s.get('R'), s.get('n'), s.get('ry_lo')); o = len(V) if not V else sum(len(q) for q in V)
        V.append(v); F += [[o + i for i in q] for q in f]; B += [s['bone']] * len(v)
    return np.vstack(V), F, np.array(B)


def _iou(a, b):
    return float((a & b).sum() / max((a | b).sum(), 1))


def checks(form, segs, x_end, fins, rec, n=600):
    """BK1-BK3 by raster in record units."""
    R = {}
    xs = np.linspace(0, x_end, n); T, Bt, W = form.TOP(xs), form.BOT(xs), form.HW(xs)
    lo, hi = float(min(Bt.min(), min(s['c'][1] - s.get('ry_lo', s['r'][1]) for s in segs))), float(max(T.max(), max(s['c'][1] + s['r'][1] for s in segs)))
    ys = np.linspace(lo, hi, n)[:, None]
    ref = (ys <= T[None]) & (ys >= Bt[None])
    zmax = float(max(W.max(), max(s['r'][2] for s in segs))); zs = np.linspace(-zmax, zmax, n)[:, None]
    reft = np.abs(zs) <= W[None]
    side = np.zeros_like(ref); top = np.zeros_like(reft)
    for s in segs:
        (cx, cy, _), (ax, ay, az) = s['c'], s['r']
        u = np.clip(1 - ((xs - cx) / ax) ** 2, 0, None)[None]
        ayl = s.get('ry_lo', ay); side |= ((ys - cy) / np.where(ys >= cy, ay, ayl)) ** 2 <= u; top |= (zs / az) ** 2 <= u
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


# ---------------------------------------------------------------- the primitive kit: building blocks that close the chain's gaps
# Gary 28 Nov: "if there are gaps, could you create primitive shapes/building blocks to close them?" Each kind closes one gap that
# BK4 / BK5 measure:
#   joint   (off by default, JOINTS) at every spine joint, a spheroid round the vertical line through the joint (x and z semi-axes equal: the section's
#           half-width; y: its half-height). A swimming bend turns each bone about that vertical line, and a spheroid round its own
#           axis of turning is the same shape at every angle, so it fills the outside of the bend whatever the angle (BK5).
#   root    under each fin's root row, flat lozenges that reach from the plate's root into the body, so no fin floats off the
#           ellipsoids, whose sections are rounder than the record's (BK4).
JOINTS = True         # DEFAULT: joint spheroids on. Measured (BK5, the swim clip): trevally 0.126 % SL with or without (two
                      # overlapping ellipsoids per bone already close a narrow body's bend); pufferfish 0.544 -> 0.252 % SL with them
                      # (a wide body's blocks swing their flanks apart). ~100 triangles a joint
PRIM_RES = (10, 6)    # DEFAULT: a primitive's mesh (longitude x latitude): small shapes, 100 triangles each
JOINT_FILL = 0.97     # DEFAULT: a joint spheroid stays this far inside the section (it must not swell the side or top view)
ROOT_PAD = 0.15       # DEFAULT: a root lozenge reaches this share of its length further into the body than the gap (so the edge sinks)
ROOT_T = 0.25         # DEFAULT: a root lozenge's thickness, x the local body half-width (a fleshy fin base, thinner than the body)
ROOT_STEP = 0.04      # DEFAULT (SL): one lozenge per this much root row (a row along the back bends; one long lozenge would not)
BK4_MAX = 1.0         # every fin root point inside the body: the worst point's ellipsoid measure (1 = on the surface)
BK5_MIN_PCT = 0.2     # DEFAULT (% SL): BK5's least limit (1 mm on a 52 cm trevally)
CUTTERS = True        # DEFAULT: tier 3 cutters (mouth cavity with a moving jaw, gill slits under moving covers, eye sockets): blockout_cut
# BK5's limit for a fish is what its blockout already differs from the record at rest: between two block centres the union dips
# to sqrt(1 - (1 / (2 OVERLAP))^2) of the block's half-height (OVERLAP 1.5: 5.7 %), so a bend that opens less than that dip shows
# nothing the resting blockout does not already show. The limit is that dip on the deepest block, at least BK5_MIN_PCT.


def _f(P, prims):
    """ellipsoid measure of points P (N,3) against each primitive: <= 1 inside. (N, K)"""
    out = []
    for q in prims:
        R = np.asarray(q.get('R', np.eye(3)), float); L = (np.asarray(P) - np.asarray(q['c'])) @ R / np.asarray(q['r'])
        if q.get('ry_lo') is not None: L[:, 1] = np.where(L[:, 1] < 0, L[:, 1] * q['r'][1] / q['ry_lo'], L[:, 1])
        if q.get('n') is None: out.append((L ** 2).sum(1)); continue
        nn = np.where(L[:, 1] >= 0, q['n'][0], q['n'][1])        # superquadric: (|y|^n + |z|^n)^(2/n) + x^2
        out.append((np.abs(L[:, 1]) ** nn + np.abs(L[:, 2]) ** nn) ** (2 / nn) + L[:, 0] ** 2)
    return np.stack(out, 1)


def joints(form, rec, segs):
    C = dict(bones=rec['bones'], xend=form.XEND); NB, xs = RIG.spine_stations(C); out = []
    x_last = max(s['c'][0] + s['r'][0] for s in segs)
    for i in range(1, NB):
        x = float(xs[i])
        if x >= x_last: break
        t, b, w = float(form.TOP(x)), float(form.BOT(x)), float(form.HW(x))
        out.append(dict(kind='joint', c=[x, (t + b) / 2, 0.0], r=[JOINT_FILL * w, JOINT_FILL * (t - b) / 2, JOINT_FILL * w], bone=i))
    return out


def sink_roots(form, prims, fins):
    """median fins and caudal: each root-row point that stands off the blocks moves straight into the body until it is inside (the
    plate itself closes the gap). Lozenges there (round 1) stood as a rope along the back over the plate's root in every 3/4 view."""
    for k, f in fins.items():
        if k.startswith(('pectoral', 'pelvic')): continue
        V = np.asarray(f['V'], float); Mb = len(f['lens'])
        for j in range(Mb):
            p = V[j]; x = float(np.clip(p[0], 0, form.XEND))
            c = np.array([x - 0.05, float(form.sec(max(x - 0.05, 0))[0]), 0.0]) if k == 'caudal' else np.array([x, float(form.sec(x)[0]), 0.0])
            if _f(p[None], prims).min() <= 0.9: continue
            d = c - p; L = np.linalg.norm(d); d /= max(L, 1e-9); t = np.linspace(0, L, 80)
            hit = np.where(_f(p + t[:, None] * d, prims).min(1) <= 0.9)[0]
            if not len(hit):            # a root end past the body's last block (a trailing fin lobe): head for the nearest block's centre
                cs = np.array([q['c'] for q in prims]); c = cs[np.argmin(np.linalg.norm(cs - p, axis=1))]
                d = c - p; L = np.linalg.norm(d); d /= max(L, 1e-9); t = np.linspace(0, L, 80)
                hit = np.where(_f(p + t[:, None] * d, prims).min(1) <= 0.9)[0]
            if len(hit): V[j] = p + t[hit[0]] * d
        f['V'] = V


def roots(form, rec, prims, fins):
    """lozenges under every fin root row that stands outside the body's blocks."""
    C = dict(bones=rec['bones'], xend=form.XEND); out = []
    for k, f in fins.items():
        Vf = np.asarray(f['V'], float); Mb = len(f['lens']); root = Vf[:Mb]
        arc = np.r_[0, np.cumsum(np.linalg.norm(np.diff(root, axis=0), axis=1))]
        for a in np.arange(0, arc[-1] + 1e-9, ROOT_STEP) if arc[-1] > 0 else [0.0]:
            j0 = max(int(np.searchsorted(arc, a)) - 1, 0); j1 = min(int(np.searchsorted(arc, a + ROOT_STEP)) + 1, Mb - 1)   # stretches share their end points
            pts = root[j0:j1 + 1]; p = pts.mean(0)
            if _f(pts, prims).min(1).max() <= 1.0: continue        # this stretch of root is already inside the body
            x = float(np.clip(p[0], 0, form.XEND)); c = np.array([x, float(form.sec(x)[0]), 0.0])
            if k == 'caudal': c = np.array([x - 0.05, float(form.sec(max(x - 0.05, 0))[0]), 0.0])
            d = c - p; d /= max(np.linalg.norm(d), 1e-9)              # inward: toward the section centre (caudal: into the peduncle)
            tang = pts[-1] - pts[0]; tang = tang - (tang @ d) * d; n = np.linalg.norm(tang)
            tang = tang / n if n > 1e-9 else np.cross(d, [0, 0, 1.0]) / max(np.linalg.norm(np.cross(d, [0, 0, 1.0])), 1e-9)
            nrm = np.cross(tang, d); R = np.stack([tang, d, nrm], 1)
            # each point's own way in: march along d until inside the blocks; the lozenge spans every point and every landing
            reach = []
            for q in pts:
                t = np.linspace(0, 0.3, 120); hit = np.where(_f(q + t[:, None] * d, prims).min(1) <= 0.9)[0]
                reach.append(float(t[hit[0]]) if len(hit) else 0.3)
            L = (pts - p) @ R; reach = np.array(reach)
            u0, u1 = float(L[:, 0].min()), float(L[:, 0].max()); v0 = float(L[:, 1].min()); v1 = float((L[:, 1] + reach).max())
            ctr = p + R @ np.array([(u0 + u1) / 2, (v0 + v1) / 2, 0.0])
            # an ellipsoid through the corners of the box (half sides a, b, c) has semi-axes a sqrt 3, b sqrt 3, c sqrt 3
            ru = max((u1 - u0) / 2, 0.004) * 1.74; rv = max((v1 - v0) / 2, 0.002) * 1.74 * (1 + ROOT_PAD)
            out.append(dict(kind='root', fin=k, c=ctr.tolist(), R=R.tolist(),
                            r=[ru, rv, max(ROOT_T * float(form.HW(x)), 0.002, 1.74 * float(np.abs(L[:, 2]).max()))], bone=RIG.spine_index(C, x)))
    return out


def gap_checks(prims, fins, C, V, F, rec, raw, bend=1.0):
    """BK4 fin roots inside the body at rest; BK5 the smoothly bent skin (linear blend of neighbouring spine bones, as the full
    fish is skinned) inside the rigid blocks at every frame of the swim clip."""
    R = {}; worst = {}
    for k, f in fins.items():
        Mb = len(f['lens']); worst[k] = round(float(_f(np.asarray(f['V'])[:Mb], prims).min(1).max()), 3)
    R['BK4_root_worst'] = worst; R['BK4_pass'] = max(worst.values()) <= BK4_MAX
    try:
        from . import swim_clip
        BL = RIG.bones(C, V, dict(mouth=rec['mouth'], cover=rec['cover'])); names, rest, W, Q = swim_clip.clips(C, V, raw, BL, None)['swim']
    except Exception as e:
        R['BK5_note'] = f'no swim clip: {type(e).__name__}: {e}'[:160]; R['BK5_pass'] = None; return R
    segs = [q for q in prims if q['kind'] == 'segment']; cen = np.array([q['c'] for q in segs]); rad = np.array([q['r'] for q in segs])
    S = []
    for q in segs:                    # samples on each block's own surface (its mesh at a finer grid), a hair inside
        v, _ = _ellipsoid(q['c'], q['r'], 28, 18, None, q.get('n'), q.get('ry_lo')); S.append(np.asarray(q['c']) + 0.985 * (v - np.asarray(q['c'])))
    S = np.vstack(S); S = S[(_f(S, segs) > 1.0005).sum(1) >= len(segs) - 1]          # samples on the chain's own surface
    m = rec['SL_mm'] / 1000; to = lambda p: np.c_[-p[:, 0] * m, p[:, 1] * m, -p[:, 2] * m]; back = lambda p: np.c_[-p[:, 0] / m, p[:, 1] / m, -p[:, 2] / m]
    rot = lambda q: np.array([[1 - 2 * (q[1] ** 2 + q[2] ** 2), 2 * (q[0] * q[1] - q[2] * q[3]), 2 * (q[0] * q[2] + q[1] * q[3])],
                              [2 * (q[0] * q[1] + q[2] * q[3]), 1 - 2 * (q[0] ** 2 + q[2] ** 2), 2 * (q[1] * q[2] - q[0] * q[3])],
                              [2 * (q[0] * q[2] - q[1] * q[3]), 2 * (q[1] * q[2] + q[0] * q[3]), 1 - 2 * (q[0] ** 2 + q[1] ** 2)]])
    i0, a0, i1, a1 = RIG.spine_weights(C, S[:, 0]); NB = int(C['bones']); Pe = to(S); worst5 = 0.0; share = 0.0
    for k in range(len(W)):
        Rs = [rot(Q[k][i]) for i in range(NB)]
        if bend != 1.0:   # a harder bend than the clip (a turn): each bone's turn scaled, the chain rebuilt from the root
            from scipy.spatial.transform import Rotation as _Rot
            Rs = [_Rot.from_rotvec(_Rot.from_matrix(r_).as_rotvec() * bend).as_matrix() for r_ in Rs]
            Wk = [np.asarray(W[k][0], float)]
            for i in range(1, NB): Wk.append(Wk[-1] + Rs[i - 1] @ (np.asarray(rest[i]) - np.asarray(rest[i - 1])))
        else: Wk = W[k]
        sm = np.zeros_like(Pe)
        for idx, a in ((i0, a0), (i1, a1)):
            for b in range(NB):
                mk = idx == b
                if mk.any(): sm[mk] += a[mk, None] * ((Pe[mk] - rest[b]) @ Rs[b].T + Wk[b])
        fb = np.full(len(S), np.inf)
        for q in prims:
            if q['kind'] == 'root': continue
            b = q['bone']; fb = np.minimum(fb, (np.sqrt(_f(back((sm - Wk[b]) @ Rs[b] + rest[b]), [q])[:, 0]) - 1) * min(q['r']))
        g = fb; share = max(share, float((g > BK5_MIN_PCT / 100).mean()))
        if g.max() > worst5: worst5 = float(g.max()); R['BK5_worst_at'] = dict(frame=k, rest_xyz=np.round(S[int(g.argmax())], 3).tolist())
    lim = max(BK5_MIN_PCT / 100, (1 - np.sqrt(1 - (0.5 / OVERLAP) ** 2)) * float(rad[:, 1].max()))
    R['BK5_bend_gap_worst_pctSL'] = round(worst5 * 100, 3); R['BK5_limit_pctSL'] = round(lim * 100, 3); R['BK5_share_outside'] = round(share, 4)
    R['BK5_pass'] = bool(worst5 <= lim)
    return R


def blockout(record_path, out, style=None, log=print, kit=True, gaps=True):
    T0 = time.time(); os.makedirs(out, exist_ok=True)
    rec = adapt(record_path, style); form = Form(rec)
    segs, x_end = segments(form, rec)
    fins = build_fins(form, rec, out)
    prims = segs + (joints(form, rec, segs) if kit and JOINTS else [])
    if kit:
        sink_roots(form, prims, fins); prims += roots(form, rec, prims, [k for k in fins if k.startswith(('pectoral', 'pelvic'))] and
                                                      {k: v for k, v in fins.items() if k.startswith(('pectoral', 'pelvic'))})
    for q in prims: q.setdefault('tier', 1 if q['kind'] == 'segment' else 2)
    kit3, carved, pieces = None, {}, []
    if kit and CUTTERS:      # tier 3: mouth, gill and eye cutters, and the moving head blocks they uncover
        from . import blockout_cut as CUT
        kit3 = CUT.head_kit(rec, segs); carved, pieces = CUT.build(prims, kit3)
        Cb = dict(bones=rec['bones'], xend=form.XEND)
        for p in pieces:
            if p['bone'] == 'head': p['bone'] = f"spine_{RIG.spine_index(Cb, float(np.mean(np.asarray(p['V'])[:, 0]))):02d}"
    V, F, VB = body_mesh(prims, carved)
    R = checks(form, segs, x_end, fins, rec); R.update(section_check(form, segs))
    R['BK_pass'] = R['BK_pass'] and R['BK6_pass']
    C = dict(bones=rec['bones'], xend=form.XEND, SL_mm=rec['SL_mm'], species=rec['species'], fins={k: dict(V=np.asarray(v['V']).tolist()) for k, v in fins.items()},
             openings=dict(jaw_joint=rec['jaw_joint'], opercle_hinge=rec['opercle_hinge']), faces=F, ftag=['body'] * len(F))
    if gaps:
        raw = json.load(open(record_path)); R.update(gap_checks(prims, fins, C, V, F, rec, raw))
        if R.get('BK5_pass') is not None: R['BK5_turn_x3_gap_pctSL'] = gap_checks(prims, fins, C, V, F, rec, raw, bend=3.0)['BK5_bend_gap_worst_pctSL']
    R['BK_pass'] = R['BK_pass'] and R.get('BK4_pass', True) is not False and R.get('BK5_pass', True) is not False
    R['kit'] = dict(joints=sum(q['kind'] == 'joint' for q in prims), roots=sum(q['kind'] == 'root' for q in prims)) if kit else None
    if kit3 is not None:
        R.update(CUT.cut_checks(kit3, pieces))
        R['BK_pass'] = R['BK_pass'] and R['CT_pass'] is not False
        R['cut'] = dict(cutters={k: sum(q['kind'] == k for q in kit3['cutters']) for k in ('cut_jaw', 'cut_mouth', 'cut_gill', 'cut_eye')},
                        carved_bones=sorted(int(b) for b in carved), pieces=[p['name'] for p in pieces], notes=kit3['notes'])
    tris = sum(len(q) - 2 for q in F) + sum(2 * len(v['F']) for v in fins.values()) + sum(len(p['F']) for p in pieces)
    D = dict(kind='blockout', species=rec['species'], SL_mm=rec['SL_mm'], xend=form.XEND, x_end_body=x_end, bones=rec['bones'],
             jaw_joint=rec['jaw_joint'], opercle_hinge=rec['opercle_hinge'], mouth_line=np.asarray(rec['mouth']['line']).tolist(),
             cover_rear=np.asarray(rec['cover']['rear']).tolist(), gape_deg=float(rec.get('gape_deg', 30.0)),
             segments=segs, prims=[{k: v for k, v in q.items()} for q in prims if q['kind'] != 'segment'], V=V.tolist(), F=F, vbone=VB.tolist(),
             fins={k: dict(V=np.asarray(v['V']).tolist(), F=v['F'], T=v['T']) for k, v in fins.items()},
             pieces=[dict(name=p['name'], bone=p['bone'], mat=p['mat'], V=np.asarray(p['V']).tolist(), F=[list(map(int, f)) for f in p['F']]) for p in pieces],
             kit3=None if kit3 is None else dict(blocks=kit3['blocks'], cutters=kit3['cutters']),
             tiers={1: 'masses: spine segments', 2: 'forms: joints, roots, fin plates, jaw, covers, eyeballs', 3: 'surgical: cutters'},
             lods={n: dict(zip(('V', 'F', 'vbone'), (m[0].tolist(), m[1], m[2].tolist()))) for n, m in
                   ((1, body_mesh(prims)), (2, body_mesh([q for q in prims if q['tier'] == 1])))} if kit3 is not None else {},
             checks=R, tris=tris,
             rules=dict(PER_BONE=PER_BONE, OVERLAP=OVERLAP, SEG=SEG, RINGS=RINGS),
             inputs=rec['provenance'], defaults_used=rec['defaults_used'], build_s=round(time.time() - T0, 2))
    json.dump(D, open(os.path.join(out, 'blockout.json'), 'w'), default=lambda o: o.item() if hasattr(o, 'item') else str(o))
    log(f"{rec['species']}: {len(segs)} ellipsoids, {tris} tris, BK1 {R['BK1_side_iou']} BK2 {R['BK2_top_iou']} "
        f"BK3 {min(R['BK3_fin_iou'].values()) if R['BK3_fin_iou'] else None} BK4 {max(R['BK4_root_worst'].values()) if 'BK4_root_worst' in R else None} "
        f"BK5 {R.get('BK5_bend_gap_worst_pctSL')}%SL CT {[R.get(k) for k in ('CT1_pass', 'CT2_pass', 'CT3_pass')]} kit {R['kit']} pass {R['BK_pass']} ({D['build_s']} s)")
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
            if 'error' not in row['glb']:              # the blockout test kit's layout: one flat folder, <species_id>_blockout.glb
                import shutil; os.makedirs(os.path.join(out, 'glb'), exist_ok=True)
                shutil.copy(os.path.join(od, 'fish_blockout.glb'), os.path.join(out, 'glb', f'{name}_blockout.glb'))
                for n in (1, 2):                          # the tier LODs beside it: <species_id>_blockout_LOD1.glb, _LOD2.glb
                    src = os.path.join(od, f'fish_blockout_LOD{n}.glb')
                    if os.path.exists(src): shutil.copy(src, os.path.join(out, 'glb', f'{name}_blockout_LOD{n}.glb'))
        rows[name] = row
    ok = [r for r in rows.values() if 'error' not in r]
    summary = dict(records=len(rows), built=len(ok), BK_pass=sum(r['BK_pass'] for r in ok),
                   glb_ok=sum(1 for r in ok if 'glb' in r and 'error' not in r['glb']),
                   failing={n: [k for k in ('BK1_pass', 'BK2_pass', 'BK3_pass', 'BK4_pass', 'BK5_pass', 'BK6_pass', 'CT1_pass', 'CT2_pass', 'CT3_pass') if r.get(k) is False] for n, r in rows.items() if 'error' not in r and not r['BK_pass']})
    json.dump(dict(summary=summary, rows=rows), open(os.path.join(out, 'board_blockout.json'), 'w'), indent=1, default=float)
    log(json.dumps(summary)); return summary
