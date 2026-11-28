"""Stage 6, FINS: single-sheet cards from the record fin fields, root rows welded under the skin, and one fin atlas
(rays and segments as normal relief, membrane outline cut by alpha). Output: fin meshes + fin_base.png, fin_normal.png.
"""
import os
import numpy as np
from PIL import Image


EDGE_RAYS = 25      # DEFAULT: most columns on a traced median fin card (a falcate lobe needs more than 17 to keep its tip)
EDGE_ROWS, RELAX_IT = 6, 60     # DEFAULTS: rows on a traced card and relaxation passes between root and outline
SOFT_FRAY = 0.015   # DEFAULT: a soft-ray fin's edge recedes this share of the ray length between ray tips (a whole edge, faintly frayed)
SPINE_W = 0.12      # DEFAULT: half-width of a spine's free tip, share of the spacing between spines
RAY_RELIEF = 0.06   # DEFAULT: ray ridge relief in the fin normal map (tilt of the ray flanks stays under ~20 deg: rays read in the
                    # texture, not as a pleated card)
SHEATH = 0.12       # DEFAULT: body skin colour carries onto the base of the median fins and caudal over this share of the ray length


def resample(P, n):
    """n points spaced evenly by length along the polyline P."""
    s = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]; t = np.linspace(0, s[-1], n)
    return np.stack([np.interp(t, s, P[:, k]) for k in range(P.shape[1])], -1)


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

    def edge_card(base, edge_sl, rows, name, nrays, top_z=None):
        """a traced fin: the card spans its root row and its free outline (the photo's outline from where the leading edge
        leaves the body to where the rear margin meets it). Root and outline are resampled to one column count by length;
        the rows between are relaxed (each point the mean of its neighbours, root and outline held), so rays curve with a
        swept lobe or a filament instead of cutting straight across the gap beside it."""
        Mb = len(base); top = resample(np.asarray(edge_sl, float), Mb); top = np.c_[top, np.zeros(Mb) if top_z is None else top_z(top)]
        t = np.linspace(0, 1, rows + 1)[:, None, None]; G = (1 - t) * base[None] + t * top[None]
        for _ in range(RELAX_IT):
            G[1:-1, 1:-1] = 0.25 * (G[:-2, 1:-1] + G[2:, 1:-1] + G[1:-1, :-2] + G[1:-1, 2:])
            G[1:-1, 0] = G[0, 0] + (G[-1, 0] - G[0, 0]) * t[1:-1, 0]; G[1:-1, -1] = G[0, -1] + (G[-1, -1] - G[0, -1]) * t[1:-1, 0]
        vs = G.reshape(-1, 3); uv = [(i / (Mb - 1), r / rows) for r in range(rows + 1) for i in range(Mb)]
        fs = [[r * Mb + i, r * Mb + i + 1, (r + 1) * Mb + i + 1, (r + 1) * Mb + i] for r in range(rows) for i in range(Mb - 1)]
        lens = np.linalg.norm(top - base, axis=1)
        fins[name] = dict(V=vs, F=fs, UV=np.array(uv), rays=nrays, lens=lens, T=[q for _, q in uv])

    def median(m):
        x0, x1 = m['base']; Mb = int(np.clip(len(m['h']) + 2, 9, EDGE_RAYS if m.get('edge') else 17)); xs = np.linspace(x0, x1, Mb)
        top = m['top']; edge = TOP(xs) if top else BOT(xs); sgn = 1 if top else -1
        base = np.stack([xs, edge - sgn * 0.006, 0 * xs], -1)       # root row sits under the skin (own root ring)
        if m.get('edge'): edge_card(base, m['edge'], EDGE_ROWS, m['name'], m['rays']); return
        hs = np.interp(np.linspace(0, 1, Mb), np.linspace(0, 1, len(m['h'])), m['h'])
        lean = np.radians(np.interp(np.linspace(0, 1, Mb), [0, 1], m['lean']))   # ray lean back from the vertical (record)
        dirs = np.stack([np.sin(lean), sgn * np.cos(lean), 0 * xs], -1)
        hs = np.maximum(hs, 0.004)
        card(base, dirs, hs + 0.006, 5, m['name'], m['rays'])
    for m in F['median']:
        median(m); fins[m['name']].update(spines=m.get('spines', 0), notch=m.get('notch', 0.0))
    c = F['caudal']; Mb = EDGE_RAYS if c.get('edge') else 17; cx = c['x']; cc = float(sec(cx)[0]); ch = float(sec(cx)[1])
    ty = np.linspace(-1, 1, Mb); base = np.stack([np.full(Mb, cx - 0.012), cc + ty * ch * 0.92, 0 * ty], -1)
    if c.get('edge'): edge_card(base, c['edge'][::-1], EDGE_ROWS, 'caudal', c['rays'])   # traced outline runs top to bottom; ty runs up
    else:
        ang = np.radians(ty * c['spread'] / 2)
        dirs = np.stack([np.cos(ang), np.sin(ang), 0 * ty], -1)
        ol = np.array(c['outline']); lens = c['len'] * np.interp(ty, ol[:, 0], ol[:, 1]) + 0.012
        card(base, dirs, lens, 6, 'caudal', c['rays'])
    for name in ('pectoral', 'pelvic'):
        if name not in F: continue          # fins the record does not have are not made
        f = F[name]
        if f.get('edge') and f.get('base_line'):
            # traced paired fin: its side-view outline (the photo pose, root round the tip to the other root) is the free
            # edge, its base line on the body is the root row; the fin stands off the flank by its out angle, so each edge
            # point rises from the body by its distance from the root times tan(out)
            BL = np.asarray(f['base_line'], float); Mb = EDGE_RAYS; out_ = np.tan(np.radians(f['out']))
            for sg in (1, -1):
                bxy = resample(BL, Mb); bz = sg * (np.abs(form.z_on(bxy[:, 0], bxy[:, 1])) - 0.004)
                base = np.c_[bxy, bz]
                def top_z(T, base=base, sg=sg):
                    r = np.linalg.norm(T[:, None, :2] - base[None, :, :2], axis=-1); j = r.argmin(1)
                    return base[j, 2] + sg * out_ * r[np.arange(len(T)), j]
                edge_card(base, f['edge'], EDGE_ROWS, f'{name}_{"L" if sg > 0 else "R"}', f['rays'], top_z)
            continue
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
        ph = su * (nr - 1); fr = ph - np.floor(ph); d = np.abs(fr - 0.5) * 2          # d: 0 on a ray, 1 midway between rays
        ray = np.exp(-((fr - 0.5) / 0.13) ** 2)                      # ray ridges (record ray count)
        seg = 0.5 + 0.5 * np.cos(2 * np.pi * tv * 9)                  # ray segments
        # free edge (F1, ceiling study 28 Nov): a soft-ray membrane runs whole to the ray tips; over the spines it dips between
        # tips by the record notch, rising to each spine, whose own tip stands a little clear of the membrane
        sp, notch = fins[fname].get('spines', 0), fins[fname].get('notch', 0.0)
        spine = (np.floor(ph) < sp) & (notch > 0)
        membrane = 1 - notch * (1 - (1 - d) ** 2)
        tip = 1 - 0.5 * notch * np.clip(d / SPINE_W, 0, 1) ** 0.7
        edge = np.where(spine, np.maximum(membrane, tip), 1 - SOFT_FRAY * d ** 2)
        alpha = (tv < edge).astype(float)
        hgt = ray * (1 - 0.25 * seg * tv)
        fin_c = np.array(rec['paint']['fin']); body_c = np.array(rec['paint'].get('flank', rec['paint']['fin']))
        col = fin_c * (0.85 + 0.15 * ray[..., None]) * (1 - 0.2 * tv[..., None])
        if key not in ('pectoral', 'pelvic'):                        # F3: scaled skin sheath over the base of median fins and caudal
            sh = np.clip(1 - tv / SHEATH, 0, 1)[..., None] ** 1.5; col = col * (1 - sh) + body_c * sh
        fb[m, :3] = col[m]; fb[m, 3] = alpha[m]
        px = FR * (u1 - u0) / max(nr - 1, 1)                          # pixels per ray spacing: relief is per ray, whatever the fin size
        gu = np.gradient(hgt, axis=1) * px * RAY_RELIEF; gv = np.gradient(hgt, axis=0) * 3
        n3 = np.stack([-gu, -gv, np.ones_like(gu)], -1); n3 /= np.linalg.norm(n3, axis=-1, keepdims=True)
        fn[m] = n3[m]
        for nm in [k for k in fins if k == key or k.startswith(key + '_')]:
            fins[nm]['UV'] = np.stack([u0 + fins[nm]['UV'][:, 0] * (u1 - u0), v0 + fins[nm]['UV'][:, 1] * (v1 - v0)], -1)
    fb_s = fb.copy(); fb_s[..., :3] = np.where(fb[..., :3] <= 0.0031308, 12.92 * fb[..., :3], 1.055 * np.clip(fb[..., :3], 0, 1) ** (1 / 2.4) - 0.055)
    Image.fromarray((np.clip(fb_s[::-1], 0, 1) * 255).astype(np.uint8), 'RGBA').save(os.path.join(out, 'fin_base.png'))
    Image.fromarray(((fn[::-1] * 0.5 + 0.5) * 255).astype(np.uint8)).save(os.path.join(out, 'fin_normal.png'))
    return fins
