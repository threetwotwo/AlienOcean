"""reseat_head.py: GENERATOR RULE (Species 20 Nov 2026; Creature Sculptor 15:46Z chose option (a): "make it the generator rule,
not a one-off pass, so any later outline change carries the head with it").

The builder reads the head's inner parts (jaw bones, lips, mouth seam and corner, gill cover and throat bones, pectoral girdle,
skull rows, nostrils, muscles) and the fin bases as ABSOLUTE (u, y) record positions; it does not re-fit them when outline.top /
outline.bot change. So whenever any tool changes the outline it must call reseat() with the old outline:

  every absolute position keeps its SECTION FRACTION  f = (y - bot(u)) / (top(u) - bot(u))  on the outline it was placed on and
  takes its y on the new one:  y' = bot'(u) + f (top'(u) - bot'(u)).  u never changes (so gape length in u is kept for the lips and
  seam), z never changes (outline.hw is not touched), and relative numbers (radii, depths, widths, spans, heights, fractions,
  teeth rows, fin heights) are never touched. u outside the outline uses the nearest end section. Eye-anchored muscles move with
  the eye (eye_dy). No species names: one rule for every outline record.

Which numbers are positions follows the Sculptor's own record walk (tools/creature_sculpt/cage/stress/warp.js: 3-number arrays
[u, y, z], ["s", u, y, z] surface points, y / y0 / y1 / endY keys, and the [u, y] pair lists named in Y2), plus three it leaves out:
opercle.margin, gills.opening, jaw.maxPlate, lips.groove, tail.fleshEnd ([u, y] pairs), cavity.endY (at cavity.end) and
skull.braincase rows [u, half width, top, bottom].

    import reseat_head as RH; log = RH.reseat(record, old_top, old_bot, eye_dy=0.0)     (record = R['record'], edited in place)
    log = {'moved': [(path, old_y, new_y)], 'kept': [(path, why)]}  -- 'kept' lists every array it chose NOT to move, for review.
"""
import numpy as np

BLOCKS = ('jaw', 'mouth', 'lips', 'cavity', 'nostrilA', 'nostrilP', 'gill', 'muscles', 'tail')
SKEL = ('skull', 'jawJoint', 'gills', 'pectoral', 'pelvic', 'scutes', 'eye')
SKIP = {'gaze', 'axis', 'r', 'span', 'sweep', 'lean', 'h', 'prof', 'z', 'teeth', 'rootHw', 'thick', 'flare', 'kinds', 'eye'}
Y2 = {'seam', 'floor', 'innerTop', 'tri', 'margin', 'fleshEnd', 'opening', 'maxPlate', 'groove'}
YKEYS = ('y', 'y0', 'y1', 'endY')
num = lambda x: isinstance(x, (int, float)) and not isinstance(x, bool)


def _edge(pts):
    a = np.array(sorted(([float(p[0]), float(p[1])] for p in pts), key=lambda p: p[0]))
    return a[:, 0], a[:, 1]


class SectionMap:
    def __init__(s, old_top, old_bot, new_top, new_bot):
        s.o = (_edge(old_top), _edge(old_bot)); s.n = (_edge(new_top), _edge(new_bot))

    @staticmethod
    def _sec(e, u):
        (tu, ty), (bu, by) = e
        return float(np.interp(u, bu, by)), float(np.interp(u, tu, ty))

    def frac(s, u, y):
        b0, t0 = s._sec(s.o, u); return (y - b0) / (t0 - b0) if t0 - b0 > 1e-6 else 0.5

    def Y(s, u, y):
        b0, t0 = s._sec(s.o, u); b1, t1 = s._sec(s.n, u)
        if t0 - b0 < 1e-6: return y + 0.5 * (b1 + t1 - b0 - t0)
        return b1 + (y - b0) / (t0 - b0) * (t1 - b1)


def _r(v): return round(v, 2)


def reseat(rec, old_top, old_bot, eye_dy=0.0):
    o = rec['outline']; M = SectionMap(old_top, old_bot, o['top'], o['bot']); log = {'moved': [], 'kept': []}

    def mv(path, u, y):
        y2 = _r(M.Y(u, y)); log['moved'].append((path, y, y2)); return y2

    def walk(x, path, key):
        if isinstance(x, dict):
            u_sib = x.get('u', x.get('u0', x.get('end')))
            if isinstance(u_sib, list) and len(u_sib) == 2 and all(num(v) for v in u_sib): u_sib = 0.5 * (u_sib[0] + u_sib[1])
            for k in list(x):
                if k.startswith('_'): continue
                if k in SKIP: continue
                if k in YKEYS and num(x[k]):
                    if num(u_sib): x[k] = mv(path + '.' + k, u_sib, x[k])
                    else: log['kept'].append((path + '.' + k, 'no u beside it'))
                elif k == 'arches' and isinstance(x[k], dict): arches(x[k], path + '.arches')
                elif k == 'braincase' and isinstance(x[k], list):
                    x[k] = [[r[0], r[1], mv(path + '.braincase.top', r[0], r[2]), mv(path + '.braincase.bot', r[0], r[3])] + list(r[4:]) for r in x[k]]
                elif k == 'box' and isinstance(x[k], list) and len(x[k]) == 2: x[k] = box(x[k], path + '.box')
                else: x[k] = walk(x[k], path + '.' + k, k)
            return x
        if isinstance(x, list):
            if len(x) == 3 and all(num(v) for v in x): return [x[0], mv(path, x[0], x[1]), x[2]]
            if len(x) == 4 and x[0] == 's' and all(num(v) for v in x[1:]): return ['s', x[1], mv(path, x[1], x[2]), x[3]]
            if x and all(isinstance(p, list) and len(p) == 2 and all(num(v) for v in p) for p in x):
                if key in Y2: return [[p[0], mv(path, p[0], p[1])] for p in x]
                log['kept'].append((path, '[u, value] pairs, not positions')); return x
            if x and all(num(v) for v in x): log['kept'].append((path, 'plain number list')); return x
            return [walk(v, path, key) for v in x]
        return x

    def arches(a, path):
        n, u0, du = a.get('n', 1), a.get('u0', 0.0), a.get('du', 0.0); uc = u0 + du * (n - 1) / 2.0
        a['pts'] = [[[p[0], _r(M.Y(uc + p[0], p[1])), p[2]] for p in seg] for seg in a.get('pts', [])]
        log['moved'].append((path + '.pts', 'template', 'section at the arches\' middle u %.1f' % uc))

    def box(b, path):
        ua, ub = sorted([b[0][0], b[1][0]]); us = np.linspace(ua, ub, 25); lo, hi = (0, 1) if b[0][1] <= b[1][1] else (1, 0)
        ylo = _r(min(M.Y(u, b[lo][1]) for u in us)); yhi = _r(max(M.Y(u, b[hi][1]) for u in us))
        out = [list(b[0]), list(b[1])]; out[lo][1] = ylo; out[hi][1] = yhi
        log['moved'].append((path, (b[lo][1], b[hi][1]), (ylo, yhi))); return out

    for k in BLOCKS:
        if k not in rec: continue
        if k == 'muscles':
            for g in rec[k]:
                if g == 'eye' and isinstance(rec[k][g], dict):
                    for m, v in rec[k][g].items():
                        if isinstance(v, list) and len(v) == 3 and all(num(q) for q in v):
                            rec[k][g][m] = [v[0], _r(v[1] + eye_dy), v[2]]; log['moved'].append(('muscles.eye.' + m, v[1], rec[k][g][m][1]))
                elif not g.startswith('_'): rec[k][g] = walk(rec[k][g], 'muscles.' + g, g)
        elif k == 'tail': rec[k] = {kk: (walk(vv, 'tail.' + kk, kk) if kk == 'fleshEnd' else vv) for kk, vv in rec[k].items()}
        else: rec[k] = walk(rec[k], k, k)
    sk = rec.get('skeleton', {})
    for k in SKEL:
        if k not in sk: continue
        if k == 'eye':
            e = sk['eye']
            if num(e.get('y')) and num(e.get('u')): e['y'] = mv('skeleton.eye.y', e['u'], e['y'])
            continue
        sk[k] = walk(sk[k], 'skeleton.' + k, k)
    return log
