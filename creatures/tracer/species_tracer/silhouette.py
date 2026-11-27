"""Traced reference silhouette for the creature maker's SIL1 gate (creature_maker/silhouette.py).

side      = the photo's whole side outline with the median fins the maker builds as cards (dorsal, anal, caudal), no
            pectoral or pelvic fins: body edge (trace.body_edge) united with each median fin's traced edge polygon.
side_body = the body alone (top edge, then bottom edge back), fins bridged as in the record outline.
Units: the record's SL (snout tip x 0, SL end x 1), y up, as the record outline divided by SL.
"""
import numpy as np
from PIL import Image, ImageDraw
from . import trace as TR

MEDIAN = ('d1', 'd2', 'd', 'an', 'caudal')


def reference(T, SL, source, traced_by):
    fr = TR.Frame(T, SL)
    top, _ = TR.body_edge(T, fr, 'top', SL); bot, _ = TR.body_edge(T, fr, 'bot', SL)
    body = np.vstack([top, bot[::-1]]) / SL
    polys = [body]
    for k in MEDIAN:
        F = T.get('fins', {}).get(k)
        if not (F and 'edge' in F and len(F['edge']) > 2): continue
        e = fr.to_rec(F['edge'])
        if k != 'caudal':        # close the fin down the body edge between its two ends, not by a chord (a fin whose ends sit
            B = top if k in ('d1', 'd2', 'd') else bot     # off the body would float: damsel dorsal, maker note 27 Nov)
            if e[0, 0] > e[-1, 0]: e = e[::-1]
            uu = np.linspace(e[-1, 0], e[0, 0], 30); e = np.vstack([e, np.c_[uu, np.interp(uu, B[:, 0], B[:, 1])]])
        polys.append(e / SL)
    # union on a raster, then the outer contour back to a polygon
    x0, x1 = min(p[:, 0].min() for p in polys) - 0.02, max(p[:, 0].max() for p in polys) + 0.02
    y0, y1 = min(p[:, 1].min() for p in polys) - 0.02, max(p[:, 1].max() for p in polys) + 0.02
    W = 2000; H = int(W * (y1 - y0) / (x1 - x0)) + 1
    px = lambda P: [((p[0] - x0) / (x1 - x0) * W, (y1 - p[1]) / (y1 - y0) * H) for p in P]
    im = Image.new('L', (W, H), 0); d = ImageDraw.Draw(im)
    for P in polys: d.polygon(px(P), fill=1)
    from skimage import measure
    cs = measure.find_contours(np.pad(np.asarray(im, float), 1), 0.5)
    c = max(cs, key=len) - 1
    side = np.c_[x0 + c[:, 1] / W * (x1 - x0), y1 - c[:, 0] / H * (y1 - y0)]
    side = side[::max(1, len(side) // 600)]
    r4 = lambda A: [[round(float(a), 4), round(float(b), 4)] for a, b in A]
    return dict(source=source, traced_by=traced_by, side=r4(side), side_body=r4(body[::max(1, len(body) // 300)]),
                note='median fins (dorsal, anal, caudal) from the photo trace; pectoral and pelvic fins left out; SL units')
