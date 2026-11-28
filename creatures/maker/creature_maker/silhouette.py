"""SIL1, silhouette before detail (Gary 27 Nov): the built fish seen from the side must match its traced reference
outline before any finer anatomy counts. Built mask = skin faces + median fin cards (dorsal, anal, caudal) projected to
the side plane; the reference is a polygon traced from the species' photo, in the record's SL units (snout at x 0,
standard-length end at x 1, y as in the record outline). Scored as overlap (IoU) for the whole fish and for the head
alone (in front of the gill cover's rear edge): the face carries the species, so a good body cannot hide a wrong head.

Reference file: silhouettes/<record name>.json beside the record, or in the folder given by CREATURE_SIL_DIR:
  {"source": "<photo path or url>", "traced_by": "...", "side": [[x, y], ...], "side_body": [[x, y], ...] (optional,
   without fins)}
"""
import json, os
import numpy as np
from PIL import Image, ImageDraw

BOX = (-0.05, 1.60, -0.90, 0.90)      # x0, x1, y0, y1 in SL: room for long caudal lobes, filaments and tall fins (batfish, idol)
RES = 1100                            # pixels along x
SIL_MIN, SIL_HEAD_MIN = 0.90, 0.90    # DEFAULTS: pass marks for the whole side view and the head
MEDIAN = ('dorsal', 'anal', 'caudal')


def _canvas():
    x0, x1, y0, y1 = BOX; w = RES; h = int(RES * (y1 - y0) / (x1 - x0))
    to_px = lambda P: [((p[0] - x0) / (x1 - x0) * w, (y1 - p[1]) / (y1 - y0) * h) for p in P]
    return Image.new('L', (w, h), 0), to_px


def built_mask(C, V, fins=True):
    im, to_px = _canvas(); d = ImageDraw.Draw(im)
    for f, t in zip(C['faces'], C['ftag']):
        if t in ('body', 'eye', 'mouth', 'cap'): d.polygon(to_px(V[f][:, :2]), fill=1)
    if fins:
        for k, fn in C.get('fins', {}).items():
            if not k.startswith(MEDIAN): continue
            FV = np.array(fn['V'])
            for f in fn['F']: d.polygon(to_px(FV[f][:, :2]), fill=1)
    ImageDraw.floodfill(im, (0, 0), 2)            # a silhouette has no holes: the eye opening and gill slits fill in
    return np.asarray(im) != 2


def poly_mask(P):
    im, to_px = _canvas(); ImageDraw.Draw(im).polygon(to_px(np.asarray(P, float)), fill=1); return np.asarray(im, bool)


def find_reference(record_path):
    name = os.path.basename(record_path)[:-5]
    for d in (os.environ.get('CREATURE_SIL_DIR'), os.path.join(os.path.dirname(record_path), 'silhouettes'),
              os.path.join(os.path.dirname(os.path.dirname(record_path)), 'silhouettes')):
        if d and os.path.exists(os.path.join(d, name + '.json')): return os.path.join(d, name + '.json')
    return None


def iou(a, b): return float((a & b).sum() / max(1, (a | b).sum()))


def score(C, V, rec, ref):
    """IoU whole and head; the head is everything in front of the cover's rear edge."""
    A, B = built_mask(C, V), poly_mask(ref['side'])
    x0, x1 = BOX[0], BOX[1]; xh = max(p[0] for p in rec['cover']['rear'])
    cut = int((xh - x0) / (x1 - x0) * A.shape[1])
    R = dict(SIL1_iou=round(iou(A, B), 3), SIL1_head_iou=round(iou(A[:, :cut], B[:, :cut]), 3))
    if ref.get('side_body'):
        R['SIL1_body_iou'] = round(iou(built_mask(C, V, fins=False), poly_mask(ref['side_body'])), 3)
    R['SIL1_pass'] = R['SIL1_iou'] >= SIL_MIN and R['SIL1_head_iou'] >= SIL_HEAD_MIN
    return R


def silhouette_check(C, V, rec, record_path):
    p = find_reference(record_path)
    if p is None: return dict(SIL1_pass=False, SIL1_reference=None, SIL1_note='no traced reference silhouette yet',
                              SIL2_pass=False, SIL2_note='no front or top reference yet')
    ref = json.load(open(p)); R = score(C, V, rec, ref); R['SIL1_reference'] = p
    R.update(score2(C, V, ref) or dict(SIL2_pass=False, SIL2_note='no front or top reference yet'))
    return R


def overlay(C, V, ref, out_png):
    """built (red) over reference (blue); purple where both agree."""
    A, B = built_mask(C, V), poly_mask(ref['side'])
    img = np.full(A.shape + (3,), 245, np.uint8)
    img[B & ~A] = (90, 130, 255); img[A & ~B] = (255, 90, 90); img[A & B] = (150, 110, 190)
    Image.fromarray(img).save(out_png)


def outline_of(C, V, fins=True):
    """the built side silhouette as a reference would be traced (used by the planted fault and as a tracing aid)."""
    A = built_mask(C, V, fins); ys, xs = np.nonzero(A); x0, x1, y0, y1 = BOX; h, w = A.shape
    top, bot = [], []
    for c in range(xs.min(), xs.max() + 1):
        col = np.nonzero(A[:, c])[0]
        if len(col) == 0: continue
        X = x0 + (c + 0.5) / w * (x1 - x0)
        top.append([X, y1 - (col.min()) / h * (y1 - y0)]); bot.append([X, y1 - (col.max() + 1) / h * (y1 - y0)])
    return top + bot[::-1]


def planted_sil(C, V, rec):
    """a reference traced from the build itself must pass; the same reference with the head 20 % deeper (the trevally's
    eel face, mirrored) must fail."""
    ref = dict(side=outline_of(C, V)); good = score(C, V, rec, ref)['SIL1_pass']
    xh = max(p[0] for p in rec['cover']['rear'])
    bad = dict(side=[[x, y * 1.2] if x < xh else [x, y] for x, y in ref['side']])
    return {'SIL1 (own outline passes)': bool(good), 'SIL1 (head 20 % deeper)': not score(C, V, rec, bad)['SIL1_pass']}


# ---- SIL2: front and top silhouettes (Gary 28 Nov: "check if front views are correct"). The side view (SIL1) cannot see
# girth, the cross-section's shape (keel, flat flank, where it is widest) or head width. Reference keys in the same
# silhouettes/<name>.json, SL units: "front": [[z, y], ...] the fish seen head-on (body and median fins, no paired fins;
# z to the fish's left, y as the record outline), "top": [[x, z], ...] seen from above (body only, no fins; snout x 0).
# Each is scored by IoU on its own canvas fitted to the reference, pass mark SIL2_MIN.
SIL2_MIN = 0.90       # DEFAULT: same pass mark as the side view
VIEW2 = {'front': lambda Q: np.c_[Q[:, 2], Q[:, 1]], 'top': lambda Q: np.c_[Q[:, 0], Q[:, 2]]}


def _faces2(C, V, view):
    F = [V[f] for f, t in zip(C['faces'], C['ftag']) if t in ('body', 'eye', 'mouth', 'cap')]
    if view == 'front':
        for k, fn in C.get('fins', {}).items():
            if k.startswith(MEDIAN): FV = np.array(fn['V']); F += [FV[f] for f in fn['F']]
    return [VIEW2[view](q) for q in F]


def _box2(P, pad=0.15):
    lo, hi = P.min(0), P.max(0); m = (hi - lo).max() * pad; return lo - m, hi + m


def mask2(polys, box, res=500):
    lo, hi = box; s = res / (hi - lo).max(); w, h = [int(np.ceil(v * s)) + 2 for v in (hi - lo)]
    im = Image.new('L', (w, h), 0); d = ImageDraw.Draw(im)
    for q in polys: d.polygon([((x - lo[0]) * s, (hi[1] - y) * s) for x, y in q], fill=1)
    ImageDraw.floodfill(im, (0, 0), 2); return np.asarray(im) != 2


def score2(C, V, ref):
    R = {}
    for view in ('front', 'top'):
        if not ref.get(view): continue
        P = np.asarray(ref[view], float); box = _box2(np.vstack([P] + _faces2(C, V, view)))
        R[f'SIL2_{view}_iou'] = round(iou(mask2(_faces2(C, V, view), box), mask2([P], box)), 3)
    if R: R['SIL2_pass'] = all(v >= SIL2_MIN for v in R.values())
    return R


def outline2(C, V, view, res=500):
    """the built front or top silhouette as a reference would be traced (planted fault, tracing aid)."""
    polys = _faces2(C, V, view); box = _box2(np.vstack(polys)); A = mask2(polys, box, res); lo, hi = box; s = res / (hi - lo).max()
    from skimage import measure
    c = max(measure.find_contours(A.astype(float), 0.5), key=len)
    return [[lo[0] + p[1] / s, hi[1] - p[0] / s] for p in c[::2]]


def overlay2(C, V, ref, view, out_png):
    P = np.asarray(ref[view], float); box = _box2(np.vstack([P] + _faces2(C, V, view)))
    A, B = mask2(_faces2(C, V, view), box), mask2([P], box)
    img = np.full(A.shape + (3,), 245, np.uint8); img[B & ~A] = (90, 130, 255); img[A & ~B] = (255, 90, 90); img[A & B] = (150, 110, 190)
    Image.fromarray(img).save(out_png)


def planted_sil2(C, V):
    """own front and top outlines pass; the same body 30 % wider (a guessed girth) fails both."""
    ref = {v: outline2(C, V, v) for v in ('front', 'top')}; good = score2(C, V, ref).get('SIL2_pass')
    W = V.copy(); W[:, 2] *= 1.3; bad = score2(C, W, ref)
    return {'SIL2 (own front and top pass)': bool(good), 'SIL2 (girth 30 % wider)': not bad['SIL2_pass']}


def fin_edges(ref, rec, margin_px=2):
    """read each median fin's free outline off a traced reference, in SL units: a reading aid for the tracer, which writes
    the result into the record as skeleton.median.<fin>.edge (the record stays the build's only input; the reference stays
    the test). The free outline is the run of the traced outline lying off the body (outside side_body, or the record
    body), from where the leading edge leaves the body to where the rear margin meets it: dorsal and anal front to back,
    caudal top to bottom. A run that spans two fins (d1 and d2 joined by a notch) is split at its lowest point between them.
    Returns {fin name: [[x, y], ...]} and, under '_faults', where a fin's outline and its record root disagree."""
    side = np.asarray(ref['side'], float); x0, x1, y0, y1 = BOX
    if ref.get('side_body'): body = poly_mask(ref['side_body'])
    else:
        O = rec['outline']; top, bot = np.array(O['top']), np.array(O['bot']); xs = np.linspace(0, 1, 200)
        body = poly_mask(np.r_[np.c_[xs, np.interp(xs, top[:, 0], top[:, 1])], np.c_[xs, np.interp(xs, bot[:, 0], bot[:, 1])][::-1]])
    from scipy.ndimage import binary_dilation
    body = binary_dilation(body, iterations=margin_px); h, w = body.shape
    px = lambda P: (np.clip(((P[:, 0] - x0) / (x1 - x0) * w).astype(int), 0, w - 1), np.clip(((y1 - P[:, 1]) / (y1 - y0) * h).astype(int), 0, h - 1))
    c, r = px(side); off = ~body[r, c]
    n = len(side); runs = []                                   # contiguous off-body runs, wrapping round the closed outline
    if off.all(): return {'_faults': ['whole outline off the body']}
    k0 = int(np.argmin(off)); seq = [(k0 + k) % n for k in range(n)]; cur = []
    for k in seq:
        if off[k]: cur.append(k)
        elif cur: runs.append(cur); cur = []
    if cur: runs.append(cur)
    runs = [[(R[0] - 1) % n] + R + [(R[-1] + 1) % n] for R in runs if len(R) >= 3]     # anchor both ends on the body
    pts = [side[R] for R in runs]
    out, faults, used = {}, [], set()
    cx = rec['fins']['caudal']['x']
    ci = int(np.argmax([P[:, 0].max() for P in pts])) if pts else None
    if ci is not None and pts[ci][:, 0].max() > cx:
        P = pts[ci]; out['caudal'] = (P if P[0, 1] > P[-1, 1] else P[::-1]).tolist(); used.add(ci)
    yc = lambda x: 0.5 * (np.interp(x, np.array(rec['outline']['top'])[:, 0], np.array(rec['outline']['top'])[:, 1]) +
                          np.interp(x, np.array(rec['outline']['bot'])[:, 0], np.array(rec['outline']['bot'])[:, 1]))
    for m in rec['fins']['median']:
        a, b = m['base']; best, bo = None, 0.0
        for k, P in enumerate(pts):
            if k in used: continue
            if (P[:, 1].mean() > yc(P[:, 0].mean())) != m['top']: continue
            ov = min(b, P[:, 0].max()) - max(a, P[:, 0].min())
            if ov > bo: best, bo = k, ov
        if best is None: faults.append(f"{m['name']}: no traced outline over its root"); continue
        P = pts[best]; P = P if P[0, 0] < P[-1, 0] else P[::-1]
        out.setdefault('_runs', {}).setdefault(best, []).append(m['name']); out[m['name']] = P
    for k, names in out.pop('_runs', {}).items():                 # one run over two fins: split at the notch between them
        if len(names) < 2: out[names[0]] = out[names[0]].tolist(); continue
        ms = sorted([m for m in rec['fins']['median'] if m['name'] in names], key=lambda m: m['base'][0]); P = out[ms[0]['name']]
        cuts = [0]
        for m0, m1 in zip(ms, ms[1:]):
            lo, hi = sorted((m0['base'][1], m1['base'][0])); lo, hi = lo - 0.02, hi + 0.02
            sel = np.where((P[:, 0] >= lo) & (P[:, 0] <= hi))[0]
            if not len(sel): sel = np.array([int(np.argmin(np.abs(P[:, 0] - 0.5 * (lo + hi))))])
            hgt = np.abs(P[sel, 1] - yc(P[sel, 0])); cuts.append(int(sel[np.argmin(hgt)]))
        cuts.append(len(P) - 1)
        for m, s_, e_ in zip(ms, cuts, cuts[1:]): out[m['name']] = P[s_:e_ + 1].tolist()
    for m in rec['fins']['median']:
        if m['name'] in out:
            P = np.array(out[m['name']]); d = max(abs(P[0, 0] - m['base'][0]), abs(P[-1, 0] - m['base'][1]))
            if d > 0.03: faults.append(f"{m['name']}: traced outline meets the body {d:.3f} SL from the record root ends")
    out['_faults'] = faults
    return out


def board(outroot, record_dirs, names=()):
    """SIL1 on every record, fast (build at low res, no pose sweeps): per species the scores and an overlay, plus one
    contact sheet (sheet.png, worst first) and silboard.json. Run it whenever traced references or records change."""
    import subprocess, sys
    from concurrent.futures import ThreadPoolExecutor
    from .board import find_records
    from .record import adapt
    recs = find_records(record_dirs)
    if names: recs = [r for r in recs if os.path.basename(r)[:-5] in names]
    cwd = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    def one(rp):
        n = os.path.basename(rp)[:-5]; d = os.path.join(outroot, n)
        p = subprocess.run([sys.executable, '-m', 'creature_maker', 'build', rp, d, '--res', '64', '--no-form'],
                           capture_output=True, text=True, cwd=cwd, timeout=600)
        if p.returncode: return n, dict(error=(p.stderr.strip().splitlines() or ['?'])[-1][:200])
        ref = find_reference(rp)
        if ref is None: return n, dict(SIL1_pass=False, SIL1_note='no traced reference silhouette yet')
        C = json.load(open(os.path.join(d, 'cage.json'))); V = np.load(os.path.join(d, 'cage.npz'))['V']
        rec = adapt(rp, C.get('style')); RF = json.load(open(ref)); R = score(C, V, rec, RF); R.update(score2(C, V, RF))
        overlay(C, V, RF, os.path.join(d, 'silhouette.png')); R['png'] = os.path.join(d, 'silhouette.png')
        for view in ('front', 'top'):
            if RF.get(view): overlay2(C, V, RF, view, os.path.join(d, f'silhouette_{view}.png'))
        return n, R
    with ThreadPoolExecutor(4) as ex: res = dict(ex.map(one, recs))
    json.dump(res, open(os.path.join(outroot, 'silboard.json'), 'w'), indent=1)
    rows = sorted([(v.get('SIL1_iou', 0), n) for n, v in res.items() if 'png' in res[n]])
    if rows:
        from PIL import ImageFont
        tw, th = 300, 245; cols = 4; sh = Image.new('RGB', (cols * tw, ((len(rows) + cols - 1) // cols) * th), (255, 255, 255))
        for i, (_, n) in enumerate(rows):
            im = Image.open(res[n]['png']).convert('RGB'); im.thumbnail((tw, th - 20))
            x, y = (i % cols) * tw, (i // cols) * th; sh.paste(im, (x, y + 20)); v = res[n]
            ImageDraw.Draw(sh).text((x + 6, y + 4), f"{n}  whole {v['SIL1_iou']:.2f}  head {v['SIL1_head_iou']:.2f}" +
                                    ('' if v['SIL1_pass'] else '  FAIL'), fill=(0, 0, 0) if v['SIL1_pass'] else (200, 0, 0))
        sh.save(os.path.join(outroot, 'sheet.png'))
    return res
