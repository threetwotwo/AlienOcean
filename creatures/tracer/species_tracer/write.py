"""Write a photo trace into a native Species record (alien-ocean/sculptor-record/1), in place of the drafted (template-scaled) values.

Order (one rule for every species, no species names):
 1. outline.top / outline.bot at dense stations from the photo's body edge (trace.body_edge). Stations past the last traced
    station keep the record's own tail stub, shifted to meet the trace (Species v2 rule).
 2. reseat.reseat(): every absolute head / fin-base position the photo does not give keeps its section fraction on the new outline
    (Species / Sculptor generator rule, 20 Nov).
 3. Photo overrides: eye (u, y, R), mouth seam (snout tip to the closed-lip junction), gill opening and opercle margin (gill
    polyline), cover margins when the trace has them, fin roots (median fin base ends, pectoral and pelvic base). Eye-anchored
    parts (eye muscles, nostrils) move with the eye.
 4. A `_trace` block lists every field with MEASURED (read from the photo) or ESTIMATE (kept from the draft, re-seated), the
    photo, the trace and the tool version.
"""
import copy, json, numpy as np
from . import trace as TR, reseat as RS, size as SZ

VERSION = '0.1.0'
ADAPT_TOL = 0.0015  # share of SL: the most a straight run between outline stations may leave the photo edge
LIP_U = 0.006       # share of SL behind the snout tip where the photo's lip block is read
EYE_MARGIN = 0.003  # share of SL kept between the eye circle and the outline
# station layout, share of SL: dense at the head where the profile turns fastest (forehead, snout), even along the trunk
STATIONS = [0, .005, .01, .015, .02, .03, .04, .05, .06, .075, .09, .105, .12, .14, .16, .18, .2, .225, .25, .28, .31, .35, .4,
            .45, .5, .55, .6, .65, .7, .75, .8, .85, .9, .93, .95, .97, .98, .99]


def refine(E, st, tol):
    """stations: the fixed layout plus, where a straight run between two stations leaves the photo edge by more than tol, the edge
    point farthest from it (repeated): a corner such as the pelvic-fin root is kept, not cut (27 Nov SIL2 check, 7 fish)."""
    E = np.asarray(E, float); E = E[np.argsort(E[:, 0])]; st = sorted(st)
    for _ in range(200):
        y = np.interp(E[:, 0], st, np.interp(st, E[:, 0], E[:, 1])); inside = (E[:, 0] > st[1]) & (E[:, 0] < st[-1])
        err = np.where(inside, np.abs(y - E[:, 1]), 0); i = int(np.argmax(err))
        if err[i] <= tol: break
        st = sorted(st + [float(E[i, 0])])
    return st


def interp(P, u):
    P = np.asarray(P, float); P = P[np.argsort(P[:, 0])]; return float(np.interp(u, P[:, 0], P[:, 1]))


def resample_poly(P, n):
    P = np.asarray(P, float); s = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
    t = np.linspace(0, s[-1], n); return np.c_[np.interp(t, s, P[:, 0]), np.interp(t, s, P[:, 1])]


r2 = lambda v: round(float(v), 2)


PARTS = ('eye', 'mouth', 'gill', 'cover', 'fins')


def apply(D, T, trace_name, photo, parts=PARTS):
    """D = native record dict (edited copy returned), T = photo trace dict. Returns (D, report)."""
    D = copy.deepcopy(D); R = D['record']; O = R['outline']; SL = float(O['end'])
    fr = TR.Frame(T, SL); rep = dict(species=D.get('species'), trace=trace_name, measured=[], estimate=[], notes=[], bridges=[])
    old_top = [list(p) for p in O['top']]; old_bot = [list(p) for p in O['bot']]

    # 1. outline from the photo
    edges = {}
    for side in ('top', 'bot'):
        E, br = TR.body_edge(T, fr, side, SL); edges[side] = E
        for u0, u1, kind in br:
            rep['bridges'].append(dict(side=side, u=[u0, u1], kind=kind, share=round((u1 - u0) / SL, 3)))
            if kind == 'estimate': rep['notes'].append(f'ESTIMATE {side} edge under a fin at u {u0}-{u1} ({(u1 - u0) / SL:.0%} SL): convex arc, no fin-base points read')
    ends = {}
    for side, old in (('top', old_top), ('bot', old_bot)):
        E = edges[side]; u_last = min(E[-1, 0], SL)                     # each side runs as far as its own traced edge
        st = [s * SL for s in STATIONS if s * SL <= u_last - 0.005 * SL]; ends[side] = r2(st[-1])
        new = [[r2(u), r2(interp(E, u))] for u in refine(E, st, ADAPT_TOL * SL)]
        new = [p for i, p in enumerate(new) if i == 0 or p[0] > new[i - 1][0]]     # strictly increasing u after rounding (maker PCHIP)
        # u 0: the photo edge closes to the snout landmark, but the closed lips there have height; the first station takes the
        # photo's own section at LIP_U (the lip block), so the snout is the photo's blunt lip front, not a knife point
        if new: new[0][1] = r2(interp(E, LIP_U * SL))
        stub = [p for p in sorted(old) if p[0] > st[-1] + 0.005 * SL]
        if stub:                                                         # tail stub: the record's own, shifted to meet the trace
            d = interp(E, stub[0][0]) - stub[0][1] if stub[0][0] <= E[-1, 0] else interp(E, E[-1, 0]) - interp(old, E[-1, 0])
            new += [[p[0], r2(p[1] + d)] for p in stub]
        O[side] = new
    est = [b for b in rep['bridges'] if b['kind'] == 'estimate']
    O['_origin_traced'] = (f'MEASURED: top and bot from the body edge on the species\' own photo ({photo}), trace {trace_name}, '
                           f'species_tracer {VERSION}. Under fin bases the edge runs through fin-base points read on the same photo '
                           f'(monotone cubic); gaps under {TR.BASE_GAP:.0%} SL are bridged by a convex arc from the free edge either side. '
                           + (f'ESTIMATE spans (convex arc, no base points): {[(b["side"], b["u"]) for b in est]}. ' if est else '')
                           + f'Stations past u {ends} keep the record\'s tail stub shifted to meet it.')
    O['_bridges'] = rep['bridges']
    for side in ('top', 'bot'):
        (rep['estimate'] if any(b['side'] == side for b in est) else rep['measured']).append(f'outline.{side}' + (' (part ESTIMATE under a fin)' if any(b['side'] == side for b in est) else '')); rep['estimate'] += ['outline.hw (no top view read)', 'outline.nUp/nLo']

    # 2. carry every untraced absolute position to the new outline
    sk = R['skeleton']; e_old = dict(u=sk['eye']['u'], y=sk['eye']['y'])
    log = RS.reseat(R, old_top, old_bot); rep['reseated'] = len(log['moved'])

    # 3. photo overrides
    L = TR.landmarks(T, fr)
    want = {'eye': ['eye'], 'mouth': ['rictus'], 'gill': ['gill'], 'cover': ['preop', 'subop', 'interop'], 'fins': ['d1', 'd2', 'an', 'd', 'pect', 'pelvic']}
    L = {k: v for k, v in L.items() if any(k in want[p] for p in parts)}
    rep['parts'] = list(parts)
    if 'eye' in L:
        E = sk['eye']; du, dy = L['eye']['u'] - E['u'], L['eye']['y'] - E['y']
        E['u'], E['y'] = r2(L['eye']['u']), r2(L['eye']['y'])
        if 'r' in L['eye']:
            E['R'] = r2(L['eye']['r'])
            if 'MEASURED' not in str(E.get('_origin', '')) or 'orbitR' not in str(E.get('_origin', '')): E['orbitR'] = r2(E['R'] / 0.8)
        E['_origin_traced'] = 'MEASURED: u, y, R = centre and radius of the visible eyeball on the photo (trace landmark)'
        # an eye that bulges past the head profile on the photo (pufferfish) cannot sit in the maker's head: the radius is held
        # EYE_MARGIN inside the traced outline, and the clip is reported
        dense = lambda P: (lambda Q: np.c_[np.linspace(Q[0, 0], Q[-1, 0], 400), np.interp(np.linspace(Q[0, 0], Q[-1, 0], 400), Q[:, 0], Q[:, 1])])(np.array(sorted(P), float))
        room = min(float(np.min(np.hypot(*(dense(O[sd_]) - [E['u'], E['y']]).T))) for sd_ in ('top', 'bot')) - EYE_MARGIN * SL
        if E.get('R') and E['R'] > room:
            rep['notes'].append(f'eye R {E["R"]} held to {r2(room)}: the photo eye reaches the head profile (ESTIMATE radius)')
            E['_origin_traced'] += f'; R ESTIMATE: held to {r2(room)} from the photo {E["R"]}, {EYE_MARGIN:.1%} SL inside the outline'
            E['R'] = r2(room); E['orbitR'] = r2(max(E.get('orbitR', 0) if E.get('orbitR', 0) <= room / 0.8 else 0, min(E['R'] / 0.8, room + EYE_MARGIN * SL)))
        for g, v in (R.get('muscles', {}).get('eye') or {}).items():          # eye-anchored parts move with the eye
            if isinstance(v, list) and len(v) == 3: R['muscles']['eye'][g] = [r2(v[0] + du), r2(v[1] + dy), v[2]]
        for k in ('nostrilA', 'nostrilP'):
            if isinstance(R.get(k), dict) and 'u' in R[k]: R[k]['u'] = r2(R[k]['u'] + du); R[k]['y'] = r2(R[k]['y'] + dy)
        rep['measured'] += ['skeleton.eye.u', 'skeleton.eye.y', 'skeleton.eye.R']
    if 'rictus' in L:
        M = R['mouth']; ur, yr = L['rictus']; old_seam = np.array(M['seam'], float)
        n = len(old_seam); uu = np.linspace(0.02 * ur, ur, n)
        seam = [[r2(u), r2(yr * u / ur)] for u in uu]                       # straight from the snout tip (0, 0) to the lip junction
        oc = M.get('corner')
        if isinstance(oc, list) and len(oc) >= 2:
            off = np.array(oc[:2]) - old_seam[-1]; M['corner'] = [r2(ur + off[0]), r2(yr + off[1])] + list(oc[2:])
        M['seam'] = seam; M['rictus'] = r2(ur)
        M['_origin_traced'] = ('MEASURED ends: snout tip and closed-lip junction on the photo; the seam between them is straight '
                               '(ESTIMATE until a mouth-line read); corner keeps its offset from the seam end')
        rep['measured'] += ['mouth.seam (ends)', 'mouth.rictus']
    if 'gill' in L and len(L['gill']) >= 2:
        G = sk['gills']; g = np.array(L['gill'], float)
        mg = resample_poly(g, 9); op = G['opercle']; z = (op.get('z') or [None])[0]
        op['margin'] = [[r2(a), r2(b)] for a, b in mg]
        R['gill']['u'] = r2(g[:, 0].max())        # head length on this photo, so cover, gill and pectoral root share one frame
        R['gill']['_origin_traced'] = 'MEASURED: u = rearmost point of the gill cover edge on the photo; y1 its top'
        R['gill']['y1'] = r2(g[0, 1]); R['gill']['y0'] = r2(min(R['gill'].get('y0', g[-1, 1]), g[-1, 1]))
        # the cover's lower free edge continues the margin forward to the isthmus: keep only subopercle points in front of and
        # below the margin's visible end, so the rear edge runs one way (the drafted points behind it made the zigzag)
        if 'subopercle' in G:
            lo = mg[-1]; keep = [p for p in G['subopercle'] if p[0] <= lo[0] - 0.005 * SL and p[1] < lo[1]]
            dropped = len(G['subopercle']) - len(keep); G['subopercle'] = keep
            if dropped: rep['notes'].append(f'subopercle: {dropped} drafted points behind or above the photo margin end dropped')
        if 'tri' in op:                                                     # opercle triangle: rear corners on the photo margin
            op['tri'][1] = [r2(mg[0][0]), r2(mg[0][1])]; op['tri'][2] = [r2(mg[-1][0]), r2(mg[-1][1])]
        op['_origin_traced'] = 'MEASURED: margin = the gill cover rear edge on the photo (trace gill polyline, top to visible end)'
        rep['measured'] += ['skeleton.gills.opercle.margin', 'gill.y1']
    for k, key in (('preop', 'preopercle'), ('subop', 'subopercle'), ('interop', 'interopercle')):
        G = sk['gills']
        if k in L:
            zs = [p[2] for p in G.get(key, []) if len(p) > 2] or [None]; zz = float(np.mean([z for z in zs if z is not None])) if zs[0] is not None else None
            G[key] = [[r2(a), r2(b)] + ([r2(zz)] if zz is not None else []) for a, b in resample_poly(L[k], 7)]
            rep['measured'].append(f'skeleton.gills.{key}')
        else: rep['estimate'].append(f'skeleton.gills.{key} (draft, re-seated)')
    M = sk['median']
    for k in ('d1', 'd2', 'an', 'd'):
        if k in L and k in M:
            M[k]['u'] = [r2(L[k][0]), r2(L[k][1])]; rep['measured'].append(f'skeleton.median.{k}.u')
    if 'fins' in parts:            # traced free outline of each median fin (maker PR #50 reads skeleton.median.<k>.edge, record units)
        for k in ('d1', 'd2', 'an', 'd', 'caudal'):
            F = (T.get('fins') or {}).get(k)
            if not (F and len(F.get('edge') or []) > 2 and k in M): continue
            e = fr.to_rec(F['edge'])
            if (k == 'caudal' and e[0, 1] < e[-1, 1]) or (k != 'caudal' and e[0, 0] > e[-1, 0]): e = e[::-1]
            M[k]['edge'] = [[r2(a), r2(b)] for a, b in e]
            M[k]['_origin_edge'] = ('MEASURED: free outline traced on the photo (trace fins.' + k + '.edge), '
                                    + ('top to bottom' if k == 'caudal' else 'front to back') + ', record units')
            rep['measured'].append(f'skeleton.median.{k}.edge')
    for k, key in (('pect', 'pectoral'), ('pelvic', 'pelvic')):
        if k in L and key in sk and isinstance(sk[key].get('base'), dict):
            sk[key]['base']['u'], sk[key]['base']['y'] = r2(L[k][0]), r2(L[k][1]); rep['measured'].append(f'skeleton.{key}.base')
    # sanity, reported not hidden
    top_at = lambda u: interp(O['top'], u); bot_at = lambda u: interp(O['bot'], u)
    E = sk['eye']
    if not (bot_at(E['u']) < E['y'] - E['R'] and E['y'] + E['R'] < top_at(E['u'])): rep['notes'].append('FAULT eye circle crosses the outline')
    rear = sk['gills']['opercle']['margin']
    for p in sk['gills'].get('preopercle', []):
        cand = [q for q in rear if abs(q[1] - p[1]) < 0.06 * SL]
        if cand and p[0] > min(q[0] for q in cand): rep['notes'].append(f'FAULT preopercle point {p[:2]} behind the opercle margin'); break
    SZ.apply(D, T, fr, rep)               # adult size in mm and size-scaled swim timing (size.py)
    D['_trace'] = dict(tool=f'species_tracer {VERSION}', trace=trace_name, photo=photo, frame='u along snout tip -> caudal base (= SL), y up, snout (0, 0)',
                       measured=rep['measured'], estimate=rep['estimate'], notes=rep['notes'])
    return D, rep
