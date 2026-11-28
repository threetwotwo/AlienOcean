"""Top and front views: the body's width from a photo taken from above, and its cross-section shape from a photo taken head-on.

Sources are live-animal photos (iNaturalist research-grade, FishBase), chosen by eye for the view; a view's off-axis angle is
estimated by eye and written beside the result. The fish mask comes from the shared tracer's segmentation model, as for the
side view. Units follow the maker's silhouette file (creature_maker/silhouette.py): SL, snout x 0, y as the record outline.

top    snout and caudal-fin tip marked by eye on the photo; SL = that length / (TL/SL from the side trace). Paired fins are
       removed by opening the mask with a disc of OPEN_SL x SL, and spans the user marks as fin roots (by eye) are bridged by a
       monotone cubic. A slightly rolled fish shows one flank on one side, so the half-width is read on the NEAR side (the
       narrower one over the trunk), not the average; a level fish with a bent body uses half the total width instead
       (mode 'half_total'), since the axis line then wanders off the midline. Behind the widest station the width is held non-increasing (a rise is the caudal fin
       swung sideways). Writes "top" (symmetric polygon) and outline.hw (record units).
front  the body's top and bottom on the photo (excluding median fins) marked by eye; the photo is scaled so that body height =
       the record's greatest depth, and placed at that station's top and bottom. Writes "front" (mask polygon, median fins
       kept, paired fins removed by the same opening) and one outline.sections entry at that station: w(s) = half-width at
       normalised height s (-1 belly, +1 back) over the section's greatest half-width.
"""
import json, sys, os
import numpy as np

OPEN_SL = 0.03
TOOLS = os.environ.get('SIL_TOOLS', '/mnt/project-files/plans/text_species/tools')


def mask_of(path):
    if TOOLS not in sys.path: sys.path.insert(0, TOOLS)
    from silhouette import model_mask
    from PIL import Image
    img = np.asarray(Image.open(path).convert('RGB'))[:, :, ::-1].copy()
    return model_mask(img) > 0


def opened(m, r):
    import cv2
    k = 2 * max(1, int(r)) + 1
    return cv2.morphologyEx(m.astype(np.uint8), cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))) > 0


def top(path, snout_px, tail_px, tl_over_sl, roots=(), step=0.02, m=None, mode='near'):
    """-> dict(hw=[[s, half-width]] in SL units for s = x / SL, near side, roots bridged; polygon; both sides raw; notes)"""
    from scipy.interpolate import PchipInterpolator
    m = mask_of(path) if m is None else m
    a, b = np.asarray(snout_px, float), np.asarray(tail_px, float)
    ex = (b - a) / np.linalg.norm(b - a); ey = np.array([-ex[1], ex[0]]); SLpx = np.linalg.norm(b - a) / tl_over_sl
    mo = opened(m, OPEN_SL * SLpx)
    ys, xs = np.nonzero(mo); P = np.c_[xs, ys] - a; u = P @ ex / SLpx; v = P @ ey / SLpx
    S = np.arange(0, 1.0 + 1e-9, step); L, R = [], []
    for s in S:
        sel = np.abs(u - s) < 0.006
        L.append(v[sel].max() if sel.sum() > 2 else np.nan); R.append(-v[sel].min() if sel.sum() > 2 else np.nan)
    L, R = np.array(L), np.array(R); trunk = (S > 0.3) & (S < 0.8)
    near = L if np.nanmedian(L[trunk]) <= np.nanmedian(R[trunk]) else R
    if mode == 'half_total': near = 0.5 * (L + R)       # level fish, bent body: the axis wanders, the total width does not
    keep = ~np.isnan(near)
    for r0, r1 in roots: keep &= ~((S > r0) & (S < r1))
    hw = PchipInterpolator(S[keep], near[keep])(S)
    hw[0] = 0.0 if S[0] == 0 else hw[0]
    i = int(np.argmax(hw)); hw[i:] = np.minimum.accumulate(hw[i:])   # from above the body only narrows behind its widest point:
                                                                     # a rise there is the caudal fin swung to one side
    poly = [[float(s), float(w)] for s, w in zip(S, hw)] + [[float(s), -float(w)] for s, w in zip(S[::-1], hw[::-1])]
    return dict(hw=[[round(float(s), 3), round(float(w), 4)] for s, w in zip(S, hw)], top=[[round(x, 4), round(z, 4)] for x, z in poly],
                left=[None if np.isnan(x) else round(float(x), 4) for x in L], right=[None if np.isnan(x) else round(float(x), 4) for x in R],
                side_used=mode if mode == 'half_total' else ('left' if near is L else 'right'), roots=[list(r) for r in roots])


def front(path, body_top_px, body_bot_px, rec_top_y, rec_bot_y, m=None, n=21):
    """body_top_px / body_bot_px: (x, y) of the body's highest and lowest point on the photo (by eye, fins excluded);
    rec_top_y / rec_bot_y: the record outline's top and bottom (SL units) at the station of greatest depth."""
    import cv2
    m = mask_of(path) if m is None else m
    t, bt = np.asarray(body_top_px, float), np.asarray(body_bot_px, float)
    ang = np.degrees(np.arctan2(bt[0] - t[0], bt[1] - t[1]))                  # a tilted fish: turn the photo so top-bottom is upright
    if abs(ang) > 1:
        c0 = 0.5 * (t + bt); Rm = cv2.getRotationMatrix2D((float(c0[0]), float(c0[1])), -ang, 1.0)
        m = cv2.warpAffine(m.astype(np.uint8), Rm, (m.shape[1], m.shape[0]), flags=cv2.INTER_NEAREST) > 0
        t, bt = (Rm @ np.r_[t, 1]), (Rm @ np.r_[bt, 1])
    k = (rec_top_y - rec_bot_y) / np.linalg.norm(t - bt)                       # SL units per pixel
    mo = opened(m, OPEN_SL / max(k, 1e-9))
    cs, _ = cv2.findContours(mo.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    c = max(cs, key=cv2.contourArea)[:, 0, :].astype(float)
    ys, xs = np.nonzero(mo); xmid = 0.5 * (t[0] + bt[0])
    to = lambda P: np.c_[-(P[:, 0] - xmid) * k, rec_top_y - (P[:, 1] - t[1]) * k]   # z to the fish's left = image right for a fish facing the camera
    F = to(c[:: max(1, len(c) // 400)])
    S = np.linspace(-1, 1, n); w = []
    for s in S:
        yp = t[1] + (1 - (s + 1) / 2) * (bt[1] - t[1]); row = xs[np.abs(ys - yp) < 1.0]
        w.append(0.5 * (row.max() - row.min()) * k if len(row) else 0.0)
    w = np.array(w); wn = w / w.max() if w.max() > 0 else w
    return dict(front=[[round(float(z), 4), round(float(y), 4)] for z, y in F], w=[[round(float(s), 3), round(float(x), 3)] for s, x in zip(S, wn)],
                half_width_max=round(float(w.max()), 4))


def deepest(O):
    """the record station of greatest depth: (u, top y, bottom y), record units."""
    T, B = np.array(sorted(O['top']), float), np.array(sorted(O['bot']), float)
    u = np.linspace(max(T[0, 0], B[0, 0]), min(T[-1, 0], B[-1, 0]), 400)
    yt, yb = np.interp(u, T[:, 0], T[:, 1]), np.interp(u, B[:, 0], B[:, 1]); i = int(np.argmax(yt - yb))
    return float(u[i]), float(yt[i]), float(yb[i])


def apply(D, sil, top_r=None, front_r=None, src=None):
    """write a top and/or front trace into a record (outline.hw, outline.sections) and its silhouette file (top, front).
    top_r: views.top(...) result; front_r: views.front(...) result taken at the record's deepest station (see deepest()).
    When both exist the front's widths are rescaled so its greatest half-width equals the top view's half-width at that
    station: a head-on photo is rarely level, and a raised camera stretches the section's apparent width, while the
    top view reads width directly. The front keeps its shape w(s); the scale used is written to the provenance."""
    O = D['record']['outline']; SL = float(O['end']); src = dict(src or {}); notes = []
    if top_r:
        hw = [[round(s * SL, 2), round(w * SL, 3)] for s, w in top_r['hw']]
        tail = [p for p in O.get('hw', []) if p[0] > SL + 1e-6]           # past SL the record's hw is the caudal fin: keep, never wider
        last = hw[-1][1]; hw += [[p[0], round(min(p[1], last), 3)] for p in tail]
        O['hw'] = hw; O['_origin_hw'] = dict(src.get('top', {}), method='species_tracer.views.top', side_used=top_r['side_used'],
                                             roots=top_r['roots'], label='MEASURED (off-axis angle ESTIMATE, see angle_deg)')
        sil['top'] = top_r['top']
    if front_r:
        u, yt, yb = deepest(O); F = np.array(front_r['front'], float); scale = 1.0
        if top_r:
            S, W = np.array(top_r['hw'], float).T; want = float(np.interp(u / SL, S, W))
            scale = want / max(front_r['half_width_max'], 1e-9); F[:, 0] *= scale
            notes.append(f'front widths x{scale:.2f} to the top view half-width {want:.4f} SL at u {u / SL:.3f} SL')
        sil['front'] = [[round(float(z), 4), round(float(y), 4)] for z, y in F]
        secs = [s for s in O.get('sections', []) if abs(s['u'] - u) > 0.01 * SL]
        O['sections'] = sorted(secs + [dict(u=round(u, 2), w=front_r['w'])], key=lambda s: s['u'])
        O['_origin_sections'] = dict(src.get('front', {}), method='species_tracer.views.front', width_scale=round(scale, 3),
                                     label='MEASURED shape (off-axis angle ESTIMATE, see angle_deg)', notes=notes)
    sil['views_note'] = 'top: body only, fins removed, SL units, snout x 0; front: head-on, body + median fins, paired fins removed, z to the fish left, y as the record outline (SL units)'
    return D, sil
