"""Overlay picture: record outline, eye, mouth seam and gill cover drawn over the species' own photo.
before = the draft record (red), after = the traced record (green); the photo's body edge pieces in thin white; fin-base points read
on the photo as yellow dots; spans of the traced outline under a fin in cyan (through base points) or orange (ESTIMATE arc)."""
import numpy as np
from PIL import Image, ImageDraw
from . import trace as TR


def _draw_record(dr, R, fr, col, w):
    O = R['outline']; P = lambda pts: [tuple(p) for p in fr.to_px(pts)]
    top = sorted(O['top']); bot = sorted(O['bot'])
    dr.line(P(top), fill=col, width=w); dr.line(P(bot), fill=col, width=w)
    E = R['skeleton']['eye']; c = fr.to_px([[E['u'], E['y']]])[0]; r = E['R'] / fr.k
    dr.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], outline=col, width=w)
    dr.line(P(R['mouth']['seam']), fill=col, width=w)
    G = R['skeleton']['gills']; m = [p[:2] for p in G['opercle']['margin']]
    sub = [p[:2] for p in G.get('subopercle', [])]
    rear = m + [p for p in sub[::-1] if p[1] < m[-1][1]]; rear = sorted(rear, key=lambda p: -p[1])   # as the maker reads it
    if len(rear) > 1: dr.line(P(rear), fill=col, width=w)
    pre = [p[:2] for p in G.get('preopercle', [])]
    if len(pre) > 1: dr.line(P(pre), fill=col, width=max(1, w - 1))


def overlay(photo_path, T, before, after, out_path, width=1400):
    im = Image.open(photo_path).convert('RGB'); s = width / im.width
    im = im.resize((width, int(im.height * s))); dr = ImageDraw.Draw(im)
    T2 = dict(T); T2['px'] = [im.width, im.height]
    SL = float(after['record']['outline']['end']); fr = TR.Frame(T2, SL)
    for side in ('top', 'bot'):
        E, _ = TR.body_edge(T2, fr, side, SL); dr.line([tuple(p) for p in fr.to_px(E)], fill=(255, 255, 255), width=1)
    w = max(2, width // 500)
    if before is not None: _draw_record(dr, before['record'], fr, (235, 60, 60), w)
    _draw_record(dr, after['record'], fr, (60, 230, 90), w)
    O = after['record']['outline']
    for b in O.get('_bridges') or []:
        P = np.array(sorted(O[b['side']]), float); uu = np.linspace(b['u'][0], b['u'][1], 40)
        col = (0, 220, 255) if b['kind'] in ('measured', 'short') else (255, 150, 0)
        dr.line([tuple(p) for p in fr.to_px(np.c_[uu, np.interp(uu, P[:, 0], P[:, 1])])], fill=col, width=w)
    fr0 = TR.Frame(T, SL)
    for side in ('top', 'bot'):
        pts = (T.get('fin_base') or {}).get(side) or []
        if pts:
            for p in fr.to_px(fr0.to_rec(pts)): dr.ellipse([p[0] - w - 1, p[1] - w - 1, p[0] + w + 1, p[1] + w + 1], outline=(255, 230, 0), width=1)
    im.save(out_path, quality=88)
    return out_path
