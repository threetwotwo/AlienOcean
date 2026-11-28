"""SIL2 silhouette check: is the record's side outline the fish on its own photo?

Independent of the bridge rule that wrote the record: the reference is the photo's segmentation mask (the shared tracer's model,
plans/text_species/tools/silhouette.py, body + all fins) and the fin-base points read by eye on the same photo (fin_bases/<sp>.json),
not trace.body_edge. (The first check, HS1, compared the record with body_edge, which the writer had just copied: circular, Fable
critique 27 Nov.)

Along the record outline, sampled every 0.5 % SL from 1 % SL to the last traced station:
 OUT   no point lies outside the mask (closed with the tracer's envelope disc) by more than SIL2_OUT: a bulge past the fish (under
       a fin the fin covers it, see BASE)
 FREE  (any run longer than SIL2_RUN) where the body edge is free (no fin over it: not inside a bridged span, not where a traced pectoral or pelvic fin hangs past
       the edge, not over an appendage span read by eye such as chin barbels), the outline is within SIL2_FREE of the mask edge
 BASE  under a fin, the outline is within SIL2_BASE of every fin-base point read on the photo (perpendicular to u)
 EYE   the record eye centre is within SIL2_EYE of the eye centre found on the image (circle transform near the landmark);
       when none is found the eye is reported unverified
 FAULT the writer's own sanity notes (eye circle crossing the outline, cover bone order) fail the record
Spans bridged with no base point (kind 'estimate') cannot be checked from the photo; they are listed, never passed silently.
A record with no photo trace fails as NO_TRACE.
"""
import os, sys
import numpy as np
from . import trace as TR

SIL2_OUT = 0.005    # share of SL; the mask edge's own blur is about 0.3 % SL on these photos
SIL2_FREE = 0.01
SIL2_RUN = 0.03     # share of SL: the shortest run off the free edge that FREE fails (a template forehead runs ~25 % SL)
SIL2_CLOSE = 0.012  # OUT is read against the mask closed with this disc (share of SL; autotrace CLOSE_SL): the see-through sliver
                    # between a fin root and the body is narrow, so it is not background the outline may not cross
SIL2_BASE = 0.01    # by-eye base points: about 0.5 % SL repeat error on zoomed crops
SIL2_EYE = 0.015
PAIRED = ('pect', 'pelvic')
TOOLS = os.environ.get('SIL_TOOLS', '/mnt/project-files/plans/text_species/tools')


def photo_mask(photo, box=None):
    """the segmentation model's fish mask (uint8 0/255) for the whole photo, same model and cache as the shared tracer."""
    if TOOLS not in sys.path: sys.path.insert(0, TOOLS)
    from silhouette import model_mask
    from PIL import Image
    img = np.asarray(Image.open(photo).convert('RGB'))[:, :, ::-1].copy()   # BGR as cv2 reads it; PIL also opens FishBase GIFs
    H, W = img.shape[:2]; x0, y0, x1, y1 = [int(v / 100 * (W if i % 2 == 0 else H)) for i, v in enumerate(box or (1, 1, 99, 99))]
    m = np.zeros((H, W), np.uint8); m[y0:y1, x0:x1] = model_mask(img[y0:y1, x0:x1])
    return m


def photo_rgb(photo):
    from PIL import Image
    return np.asarray(Image.open(photo).convert('RGB'))


def eye_fit(img, T):
    """the eye's centre found on the image itself (circle transform on a crop around the eye landmark), photo px, or None.
    Only the centre is used: the transform finds the eyeball or the orbit ring, so its radius is not a measurement."""
    import cv2
    H, W = img.shape[:2]; ex, ey, er = T['eye'][0] * W / 100, T['eye'][1] * H / 100, T['eye'][2] * W / 100
    R = int(er * 3) + 2; x0, y0 = int(max(0, ex - R)), int(max(0, ey - R)); crop = img[y0:int(ey + R), x0:int(ex + R)]
    if crop.size == 0: return None
    s = max(1, int(round(120 / crop.shape[1]))); g = cv2.cvtColor(np.ascontiguousarray(crop), cv2.COLOR_RGB2GRAY)
    g = cv2.GaussianBlur(cv2.resize(g, None, fx=s, fy=s, interpolation=cv2.INTER_CUBIC), (5, 5), 1.5)
    cs = cv2.HoughCircles(g, cv2.HOUGH_GRADIENT, dp=1, minDist=3, param1=80, param2=12, minRadius=max(2, int(er * 0.4 * s)),
                          maxRadius=int(er * 1.6 * s) + 1)
    if cs is None: return None
    c = min(cs[0][:15], key=lambda c: np.hypot(c[0] / s + x0 - ex, c[1] / s + y0 - ey))
    cx, cy = c[0] / s + x0, c[1] / s + y0
    return (float(cx), float(cy)) if np.hypot(cx - ex, cy - ey) < er else None


def signed_dist(mask):
    """per pixel: distance to the mask edge, + outside, - inside (pixels)."""
    import cv2
    m = (mask > 0).astype(np.uint8)
    return cv2.distanceTransform(1 - m, cv2.DIST_L2, 5) - cv2.distanceTransform(m, cv2.DIST_L2, 5)


def silhouette_check(D, T, mask, notes=(), img=None):
    R = D['record']; O = R['outline']; SL = float(O['end'])
    T2 = dict(T); T2['px'] = [mask.shape[1], mask.shape[0]]; fr = TR.Frame(T2, SL); fr0 = TR.Frame(T, SL); sd = signed_dist(mask)
    br = O.get('_bridges')
    if br is None:                     # a draft has no bridge list: the spans hidden under fins are where the photo edge is hidden
        br = [dict(side=sd_, u=[u0, u1], kind=k) for sd_ in ('top', 'bot') for u0, u1, k in TR.body_edge(T2, fr, sd_, SL)[1]]
    import cv2
    k = 2 * int(round(SIL2_CLOSE * SL / fr.k)) + 1                     # the tracer's ray-tip envelope disc (autotrace CLOSE_SL)
    env = cv2.morphologyEx(cv2.copyMakeBorder(mask, k, k, k, k, cv2.BORDER_CONSTANT, value=0), cv2.MORPH_CLOSE,
                           cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))[k:-k, k:-k]; sd_env = signed_dist(env)
    out = dict(species=D.get('species'), fails=[], estimate_spans=[[b['side'], b['u']] for b in br if b['kind'] == 'estimate'])
    worst = dict(out=0.0, free=0.0, base=0.0)
    for side in ('top', 'bot'):
        P = np.array(sorted(O[side]), float); spans = [b['u'] for b in br if b['side'] == side]
        uu = np.arange(0.01 * SL, min(P[-1, 0], 0.97 * SL), 0.005 * SL); yy = np.interp(uu, P[:, 0], P[:, 1])
        px = fr.to_px(np.c_[uu, yy]); ix = np.clip(np.round(px).astype(int), 0, [mask.shape[1] - 1, mask.shape[0] - 1])
        d = sd[ix[:, 1], ix[:, 0]] * fr.k / SL                              # share of SL, + outside the fish (raw mask)
        d_env = sd_env[ix[:, 1], ix[:, 0]] * fr.k / SL                      # same against the envelope
        under = np.zeros(len(uu), bool)
        for u0, u1 in spans: under |= (uu >= u0 - 0.005 * SL) & (uu <= u1 + 0.005 * SL)
        for A in T.get('appendages') or []:   # read by eye on the photo (fin_bases/<sp>.json "appendages"): barbels, a dewlap
            if A['side'] == side: under |= (uu >= A['u'][0] * SL) & (uu <= A['u'][1] * SL)
        for k in PAIRED:                   # a paired fin hanging past the body edge: there the mask edge is the fin, not the body
            F = (T.get('fins') or {}).get(k) or {}
            if F.get('silhouette'):
                Q = fr0.to_rec(F['silhouette']); e_side = np.interp(Q[:, 0], P[:, 0], P[:, 1])
                past = (Q[:, 1] > e_side) if side == 'top' else (Q[:, 1] < e_side)
                if past.any(): under |= (uu >= Q[past, 0].min() - 0.01 * SL) & (uu <= Q[past, 0].max() + 0.01 * SL)
        i = int(np.argmax(d_env)); worst['out'] = max(worst['out'], float(d_env[i]))
        if d_env[i] > SIL2_OUT: out['fails'].append(f'OUT {side} at u {uu[i] / SL:.3f} SL: {d_env[i]:.1%} SL outside the fish')
        if (~under).any():
            # a run of outline off the free edge longer than SIL2_RUN fails; a shorter one is an appendage root the trace does not
            # name (barbels at the chin, a spine), where the mask edge leaves the body for a moment
            f = np.where(under, 0, np.abs(d)); off = f > SIL2_FREE; run = 0; best = (0, 0)
            for j in range(len(uu)):
                run = run + 1 if off[j] else 0
                if run > best[0]: best = (run, j)
            j = int(np.argmax(f)); worst['free'] = max(worst['free'], float(f[j]))
            if best[0] * 0.005 >= SIL2_RUN:
                j = best[1] - best[0] // 2
                out['fails'].append(f'FREE {side} at u {uu[j] / SL:.3f} SL: {f[j]:.1%} SL off the photo edge over {best[0] * 0.005:.1%} SL')
        fb = (T.get('fin_base') or {}).get(side) or []
        if fb:
            B = fr.to_rec(fb); e = np.abs(np.interp(B[:, 0], P[:, 0], P[:, 1]) - B[:, 1]) / SL
            j = int(np.argmax(e)); worst['base'] = max(worst['base'], float(e[j]))
            if e[j] > SIL2_BASE: out['fails'].append(f'BASE {side} at u {B[j, 0] / SL:.3f} SL: {e[j]:.1%} SL off the fin-base point')
    e = R['skeleton']['eye']; fit = eye_fit(img, T) if img is not None and 'eye' in T else None
    if fit is not None:                # against the eye found on the image, not the landmark the writer copied
        Ti = dict(T); Ti['px'] = [img.shape[1], img.shape[0]]; c = TR.Frame(Ti, SL).to_rec([[fit[0] / img.shape[1] * 100, fit[1] / img.shape[0] * 100]])[0]
        out['eye_off'] = round(float(np.hypot(e['u'] - c[0], e['y'] - c[1])) / SL, 4)
        if out['eye_off'] > SIL2_EYE: out['fails'].append(f'EYE centre {out["eye_off"]:.1%} SL off the eye found on the photo')
    else: out['eye_unverified'] = True
    out['fails'] += [n for n in notes if n.startswith('FAULT')]
    out.update({k: round(v, 4) for k, v in worst.items()}); out['pass'] = not out['fails']
    return out


def planted(D, T, mask):
    """planted faults the check must catch: (1) the template forehead (top edge dropped 6 % SL over the head), (2) a bulge of 4 % SL
    under the first fin span that has base points. Returns {name: caught}."""
    import copy
    R0 = D['record']; SL = float(R0['outline']['end']); hl = float(R0['gill']['u']); res = {}
    D1 = copy.deepcopy(D); O = D1['record']['outline']
    O['top'] = [[u, y - 0.06 * SL * max(0.0, 1 - abs(u - 0.5 * hl) / (0.5 * hl))] for u, y in O['top']]
    res['forehead'] = not silhouette_check(D1, T, mask)['pass']
    span = next((b for b in (R0['outline'].get('_bridges') or []) if b['kind'] == 'measured'), None)
    if span:
        D2 = copy.deepcopy(D); O = D2['record']['outline']; (u0, u1), sg = span['u'], (1 if span['side'] == 'top' else -1)
        O[span['side']] = [[u, y + sg * 0.04 * SL * max(0.0, 1 - abs(2 * u - u0 - u1) / (u1 - u0))] for u, y in O[span['side']]]
        res['bulge'] = not silhouette_check(D2, T, mask)['pass']
    return res
