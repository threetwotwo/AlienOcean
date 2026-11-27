"""Stage 6, FINS: single-sheet cards from the record fin fields, root rows welded under the skin, and one fin atlas
(rays and segments as normal relief, membrane outline cut by alpha). Output: fin meshes + fin_base.png, fin_normal.png.
"""
import os
import numpy as np
from PIL import Image


def build_fins(form, rec, out):
    F = rec['fins']; fins = {}; TOP, BOT, sec = form.TOP, form.BOT, form.sec

    def card(base, dirs, lens, rows, name, nrays):
        """base: (M,3) points along the fin root, dirs: (M,3) unit ray directions, lens: (M,) ray lengths."""
        Mb = len(base); vs = []; uv = []
        for r in range(rows + 1):
            t = r / rows
            for i in range(Mb):
                vs.append(base[i] + dirs[i] * lens[i] * t); uv.append((i / (Mb - 1), t))
        fs = [[r * Mb + i, r * Mb + i + 1, (r + 1) * Mb + i + 1, (r + 1) * Mb + i] for r in range(rows) for i in range(Mb - 1)]
        fins[name] = dict(V=np.array(vs), F=fs, UV=np.array(uv), rays=nrays, lens=lens, T=[t for _, t in uv])

    def median(m):
        x0, x1 = m['base']; Mb = int(np.clip(len(m['h']) + 2, 9, 17)); xs = np.linspace(x0, x1, Mb)
        top = m['top']; edge = TOP(xs) if top else BOT(xs); sgn = 1 if top else -1
        base = np.stack([xs, edge - sgn * 0.006, 0 * xs], -1)       # root row sits under the skin (own root ring)
        hs = np.interp(np.linspace(0, 1, Mb), np.linspace(0, 1, len(m['h'])), m['h'])
        lean = np.radians(np.interp(np.linspace(0, 1, Mb), [0, 1], m['lean']))   # ray lean back from the vertical (record)
        dirs = np.stack([np.sin(lean), sgn * np.cos(lean), 0 * xs], -1)
        hs = np.maximum(hs, 0.004)
        card(base, dirs, hs + 0.006, 5, m['name'], m['rays'])
    for m in F['median']: median(m)
    c = F['caudal']; Mb = 17; cx = c['x']; cc = float(sec(cx)[0]); ch = float(sec(cx)[1])
    ty = np.linspace(-1, 1, Mb); base = np.stack([np.full(Mb, cx - 0.012), cc + ty * ch * 0.92, 0 * ty], -1)
    ang = np.radians(ty * c['spread'] / 2)
    dirs = np.stack([np.cos(ang), np.sin(ang), 0 * ty], -1)
    ol = np.array(c['outline']); lens = c['len'] * np.interp(ty, ol[:, 0], ol[:, 1]) + 0.012
    card(base, dirs, lens, 6, 'caudal', c['rays'])
    for name in ('pectoral', 'pelvic'):
        if name not in F: continue          # fins the record does not have are not made
        f = F[name]
        for sg in (1, -1):
            Mb = 9; tt = np.linspace(0, 1, Mb)
            prof = np.interp(tt, np.array(f['prof'])[:, 0], np.array(f['prof'])[:, 1])
            out_ = np.radians(f['out']); a = np.radians(np.interp(tt, [0, 1], f['sweep']))
            if name == 'pectoral':
                ys = f['y'] + f['span'][0] + (f['span'][1] - f['span'][0]) * tt
                zz = np.array([float(form.loft_point(np.array(f['x']), np.array(form.theta_of(f['x'], y, sg)))[2]) for y in ys])
                base = np.stack([np.full(Mb, f['x']) - 0.003 * (tt - 0.5), ys, zz - sg * 0.004], -1)
                dirs = np.stack([np.cos(a) * np.cos(out_), np.sin(a), sg * np.sin(out_) * np.ones(Mb)], -1)
            else:
                yb = max(float(BOT(f['x'])) + 0.006, f['y'])
                base = np.stack([np.full(Mb, f['x']) + 0.02 * (tt - 0.5), np.full(Mb, yb), np.full(Mb, sg * 0.006) + sg * 0.008 * tt], -1)
                dirs = np.stack([np.cos(a) * np.cos(out_), -np.sin(a) * np.cos(out_) - 0.2, sg * np.sin(out_) * np.ones(Mb)], -1)
            dirs = dirs / np.linalg.norm(dirs, axis=1, keepdims=True)
            card(base, dirs, f['len'] * prof, 4, f'{name}_{"L" if sg > 0 else "R"}', f['rays'])
    # fin atlas: one rectangle per fin, shared between left/right paired fins
    keys = ['caudal'] + [m['name'] for m in F['median']] + [n for n in ('pectoral', 'pelvic') if n in F]
    RECTS = {}
    for i, k in enumerate(keys):                             # simple shelf grid, 3 columns
        cu, rv = i % 3, i // 3; nrows = (len(keys) + 2) // 3
        RECTS[k] = (0.02 + cu / 3, 0.02 + rv / nrows, (cu + 1) / 3 - 0.02, (rv + 1) / nrows - 0.02)
    FR = 1024; fb = np.zeros((FR, FR, 4)); fn = np.zeros((FR, FR, 3)); fn[..., 2] = 1
    yy, xx = np.mgrid[0:FR, 0:FR] + 0.5; U, Vv = xx / FR, yy / FR
    for key, (u0, v0, u1, v1) in RECTS.items():
        fname = key if key in fins else key + '_L'; nr = fins[fname]['rays']
        m = (U >= u0) & (U < u1) & (Vv >= v0) & (Vv < v1)
        su = (U - u0) / (u1 - u0); tv = (Vv - v0) / (v1 - v0)
        ph = su * (nr - 1); fr = ph - np.floor(ph)
        ray = np.exp(-((fr - 0.5) / 0.13) ** 2)                      # ray ridges (record ray count)
        seg = 0.5 + 0.5 * np.cos(2 * np.pi * tv * 9)                  # ray segments
        edge = 1 - 0.09 * (1 - ray) - 0.02 * (1 - seg)               # membrane free edge recedes between ray tips
        alpha = (tv < edge).astype(float)
        hgt = ray * (1 - 0.25 * seg * tv)
        col = np.array(rec['paint']['fin']) * (0.7 + 0.3 * ray[..., None]) * (1 - 0.25 * tv[..., None]) + 0.12 * (1 - tv[..., None]) * np.array([0.3, 0.2, 0.2])
        fb[m, :3] = col[m]; fb[m, 3] = alpha[m]
        gu = np.gradient(hgt, axis=1) * nr * 0.6; gv = np.gradient(hgt, axis=0) * 3
        n3 = np.stack([-gu, -gv, np.ones_like(gu)], -1); n3 /= np.linalg.norm(n3, axis=-1, keepdims=True)
        fn[m] = n3[m]
        for nm in [k for k in fins if k == key or k.startswith(key + '_')]:
            fins[nm]['UV'] = np.stack([u0 + fins[nm]['UV'][:, 0] * (u1 - u0), v0 + fins[nm]['UV'][:, 1] * (v1 - v0)], -1)
    fb_s = fb.copy(); fb_s[..., :3] = np.where(fb[..., :3] <= 0.0031308, 12.92 * fb[..., :3], 1.055 * np.clip(fb[..., :3], 0, 1) ** (1 / 2.4) - 0.055)
    Image.fromarray((np.clip(fb_s[::-1], 0, 1) * 255).astype(np.uint8), 'RGBA').save(os.path.join(out, 'fin_base.png'))
    Image.fromarray(((fn[::-1] * 0.5 + 0.5) * 255).astype(np.uint8)).save(os.path.join(out, 'fin_normal.png'))
    return fins
