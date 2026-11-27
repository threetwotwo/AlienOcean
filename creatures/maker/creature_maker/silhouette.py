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

BOX = (-0.05, 1.30, -0.55, 0.55)      # x0, x1, y0, y1 in SL: room for the caudal fin past x 1 and tall fins
RES = 900                             # pixels along x
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
    if p is None: return dict(SIL1_pass=False, SIL1_reference=None, SIL1_note='no traced reference silhouette yet')
    R = score(C, V, rec, json.load(open(p))); R['SIL1_reference'] = p
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
