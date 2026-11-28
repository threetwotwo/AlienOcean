#!/usr/bin/env python3
"""scan_views.py: body width from above and head-on cross-section shape from a 3D photogrammetry scan of a (dead) fish.

Universal: no species in the code. Output dicts are the ones creatures/tracer/species_tracer/views.apply() accepts:
  top_r   = {hw: [[s, half-width / SL]] for s = u / SL in 0..1 (body only, fins removed), top: symmetric polygon, side_used, roots: []}
  front_r = {front: [[z, y]] (SL units), w: [[s, w]] 21 values (s -1 belly edge .. +1 back edge, w = half-width / greatest half-width),
             half_width_max (SL units)}  at the station of greatest body depth; sections_extra holds the same at 0.25 and 0.75 SL.

usage: scan_views.py <scan_dir> --out <stem> [--head 0|1] [--sl-end x] [--label text] [--meta json]
       (scan_dir holds scene.gltf; --head: which end of the long axis the head is, as eyeaim.head_end; default automatic)

Steps
 1 load + first frame: eyeaim.frame (long axis = principal axis, up = scan +y squared to it, length 10); head end from --head or eyeaim.head_end.
 2 sections: at each station the points in a thin slab are drawn on a (z, y) grid and the enclosed area filled (so a pocket between
   a fin and the flank stays open and the fin stays a thin sheet). Where the scan has a hole and the fill leaks (area under FILL_OK of
   the looser rule "surface met to the left, right, above and below"), the looser rule is used and the station counted (holes_filled).
 3 fins off, the rule: a fin is a THIN SHEET, the body is a thick lump. Each section is opened with a disc of radius
   r = clip(0.4 x the section's inscribed radius, RMIN, OPEN) x SL; anything thinner than 2 r goes (median fins, pelvic and pectoral fins
   standing off the body, spines, barbels). Only the piece holding the thickest point is kept. The opening also blunts the body's own
   dorsal / ventral wedge, so cells of the filled section within r of the core AND over the core's middle half are given back
   (that restores the wedge tip; it can leave a fin stub of at most r in height, never in width). A fin lying flat on the flank
   stays (it adds its own thickness, about 0.2-0.5 % SL).
 4 caudal base (end of SL): section thickness T(x) = 2 x inscribed radius. In the caudal fin T sits on a plateau t (the fin sheet);
   walking forward from the tail the caudal base is the first station with T > CB_K x t.
 5 final frame: x from the snout tip to the centre of the section at the caudal base (SL = 1); roll set so that the row
   mid-points of the trunk sections have no slope against height (a mirror symmetric body upright); two rounds.
 5b along the body: a fin spread ACROSS the body lies in the section plane and looks thick there, so a core cell stays only if the
   core KX ahead or behind (grown by DX) holds it too; every section is first set upright by its own lean (dead bodies twist);
   flank bumps shorter than BUMP along the body (fleshy pectoral roots) are cut by a 1D opening of the left and right edge.
 6 widths: midline z0(s) = middle of the section's dorsal and ventral edge rows (the median plane), smoothed along the body.
   left = zmax - z0, right = z0 - zmin; hw = half the total width (a dead body bends, the total width does not care).
   asymmetry = median over 0.25..0.75 SL of (left - right) / (left + right). Past ASYM the scan is marked 'deformed' and the
   section shape w(s) is read on the wider side only (the side the fish lay on is the flattened, narrower one).
"""
import sys, os, json, argparse
import numpy as np
from scipy import ndimage as ndi

EYEDIR = os.environ.get('EYEAIM_DIR', '/mnt/project-files/plans/species_system/gapfill/eyedir')
CELL = 0.004      # grid cell, SL
SLAB = 0.006      # half thickness of a station slab, SL
OPEN = 0.012      # greatest opening radius, SL (a sheet under 2.4 % SL thick is a fin)
RMIN = 0.004      # smallest opening radius, SL
KX = 0.03         # along-body check distance, SL
BUMP = 0.07       # flank bumps shorter than this along the body are fin roots, SL
DIP = 0.04        # flank dips shorter than this along the body are holes in the scan, SL
DX = 0.02         # how far the body surface may move over KX, SL
CB_K = 2.0        # caudal base: thickness over CB_K x the caudal-fin sheet thickness
FILL_OK = 0.8     # a section whose enclosed area is under this share of the 4-direction fill has a hole in the scan
LEAKS = []
ASYM = 0.12       # left/right asymmetry past which the scan is marked deformed


def load(d):
    sys.path.insert(0, EYEDIR)
    import eyeaim as e
    V, C = e.se.load(d)
    return e, V, C


def section(P, cell, grid=None):
    """P: (z, y) points of a slab -> filled boolean grid, z0, y0 (grid origin). Rows = y, columns = z.
    grid = (z0, y0, nz, ny) fixes the grid (so that stations can be compared cell by cell)."""
    if len(P) < 8: return None
    if grid is None:
        z0, y0 = P[:, 0].min() - 3 * cell, P[:, 1].min() - 3 * cell
        nz = int((np.ptp(P[:, 0])) / cell) + 7; ny = int((np.ptp(P[:, 1])) / cell) + 7
    else:
        z0, y0, nz, ny = grid
    iz = ((P[:, 0] - z0) / cell).astype(int); iy = ((P[:, 1] - y0) / cell).astype(int); ok = (iz >= 1) & (iz < nz - 1) & (iy >= 1) & (iy < ny - 1)
    A = np.zeros((ny, nz), bool); A[iy[ok], iz[ok]] = True
    A = ndi.binary_dilation(A, iterations=1)
    acc = np.logical_or.accumulate
    F4 = acc(A, 1) & acc(A[:, ::-1], 1)[:, ::-1] & acc(A, 0) & acc(A[::-1], 0)[::-1]   # surface met left, right, above and below
    F = ndi.binary_fill_holes(A)                                                        # truly enclosed: a pocket between a fin and the flank stays open
    if F.sum() < FILL_OK * F4.sum(): F = F4; LEAKS.append(1)                            # the scan has a hole here: fall back
    else: LEAKS.append(0)
    F = ndi.binary_erosion(F, iterations=1)
    return F, z0, y0


def opened(F, rmin, rmax):
    """thin sheets off: the section opened with a disc of r = clip(0.4 x inscribed radius, rmin, rmax) cells; the piece
    holding the thickest point only. -> core, r, inscribed radius (cells)"""
    D = ndi.distance_transform_edt(F); Rin = float(D.max())
    if Rin < 1.0: return None, 0.0, Rin
    r = float(np.clip(0.4 * Rin, rmin, rmax)); E = D > r
    if not E.any(): return None, r, Rin
    lab, n = ndi.label(E)
    if n > 1: E = lab == lab[np.unravel_index(np.argmax(D), D.shape)]
    return (ndi.distance_transform_edt(~E) <= r) & F, r, Rin


def restored(F, K, r):
    """give the body's dorsal / ventral wedge tips back: filled cells within r of the core and over the core's middle half."""
    if K is None or not K.any(): return None
    cols = np.nonzero(K.any(0))[0]; zc = 0.5 * (cols[0] + cols[-1]); h = 0.5 * (cols[-1] - cols[0])
    mid = np.zeros_like(F); mid[:, int(np.ceil(zc - 0.5 * h)):int(zc + 0.5 * h) + 1] = True
    Rs = K | (F & (ndi.distance_transform_edt(~K) <= r) & mid)
    lab, n = ndi.label(Rs)
    if n > 1: Rs = lab == (1 + int(np.argmax(ndi.sum(Rs, lab, range(1, n + 1)))))
    return Rs


def edges(Rs, K, z0, y0, cell):
    rows = np.nonzero(Rs.any(1))[0]; zl = np.array([np.nonzero(Rs[i])[0][0] for i in rows]); zr = np.array([np.nonzero(Rs[i])[0][-1] + 1 for i in rows])
    # a surface point sits anywhere in its cell: edges are read at cell centres (no half-cell overshoot on either side)
    kc = np.nonzero(K.any(0))[0]; zl = z0 + (zl + 0.5) * cell; zr = z0 + (zr - 0.5) * cell
    out = dict(ys=y0 + (rows + 0.5) * cell, zl=zl, zr=zr, ybot=y0 + (rows[0] + 0.5) * cell, ytop=y0 + (rows[-1] + 0.5) * cell,
               zmin=z0 + (kc[0] + 0.5) * cell, zmax=z0 + (kc[-1] + 0.5) * cell)
    n = max(2, int(0.06 * len(rows)))                                   # median plane: the dorsal and ventral edge rows
    out['zmid'] = 0.5 * (np.mean(0.5 * (zl[:n] + zr[:n])) + np.mean(0.5 * (zl[-n:] + zr[-n:])))
    m = 0.5 * (zl + zr); wd = zr - zl; yy = out['ys'] - np.average(out['ys'], weights=wd); zz = m - np.average(m, weights=wd)
    out['lean'] = float(np.arctan(np.sum(wd * yy * zz) / max(np.sum(wd * yy * yy), 1e-12)))   # lean of the row mid-points against height
    return out


class Scan:
    def __init__(self, W):
        o = np.argsort(W[:, 0]); self.W = W[o]

    def slab(self, x, h, ang=0.0):
        i0, i1 = np.searchsorted(self.W[:, 0], [x - h, x + h]); P = self.W[i0:i1]
        return rot(P, ang, 1, 2) if ang else P

    def filled(self, x, SL, ang=0.0, grid=None):
        P = self.slab(x, SLAB * SL, ang); cell = CELL * SL
        return section(P[:, [2, 1]], cell, grid) if len(P) else None

    def station(self, x, SL, ang=0.0):
        """-> dict of the fin-free section at x (frame units; no check along the body), or None"""
        s = self.filled(x, SL, ang)
        if s is None: return None
        F, z0, y0 = s; cell = CELL * SL; K, r, Rin = opened(F, RMIN / CELL, OPEN / CELL)
        out = dict(x=x, T=2 * Rin * cell, K=K)
        if K is not None: out.update(edges(restored(F, K, r), K, z0, y0, cell))
        return out


def caudal_base(S, L):
    """S: scan in a frame with the snout near x 0 and total length L. -> x of the caudal base, sheet thickness"""
    xs = np.arange(0.5 * L, 0.995 * L, 0.005 * L); T = np.array([(S.station(x, 0.85 * L) or dict(T=0))['T'] for x in xs])
    fin = (xs > 0.90 * L) & (xs < 0.975 * L); t = float(np.median(T[fin]))
    thr = max(CB_K * t, 2 * RMIN * 0.85 * L)
    i = len(xs) - 1
    while i > 0 and T[i] <= thr: i -= 1
    # the body must stay thick ahead of it (a thick fin ray clump is not the body): 3 stations in a row
    while i > 3 and not (T[i - 3:i + 1] > thr).all(): i -= 1
    return float(xs[i]), t


def rot(W, a, i, j):
    c, s = np.cos(a), np.sin(a); X = W.copy(); X[:, i] = c * W[:, i] - s * W[:, j]; X[:, j] = s * W[:, i] + c * W[:, j]; return X


def align_idx(e, V, head, sl_end, log):
    """-> points [x, y, z, original row] in the final frame (SL = 1), info"""
    base = Scan
    W = e.frame(V); h = e.head_end(W) if head is None else head
    if h == 1: W[:, 0] = 10 - W[:, 0]; W[:, 2] *= -1
    W = np.c_[W, np.arange(len(W))]
    info = dict(head_end=int(h), roll_deg=0.0); SL = 8.5
    for it in range(3):
        W = W[np.argsort(W[:, 0])]; W[:, 0] -= W[0, 0]; L = float(W[-1, 0]); S = base(W[:, :3])
        if sl_end is not None: xc = sl_end * L if it == 0 else SL
        else: xc, t = caudal_base(S, L); info['fin_sheet_T_over_L'] = t / L
        st = S.station(xc, xc)
        sn = W[W[:, 0] < 0.004 * L, :3]; sn = sn.mean(0) if len(sn) else W[0, :3]; sn[0] = 0
        cb = np.array([xc, sn[1], sn[2]]) if (st is None or st['K'] is None) else np.array([xc, 0.5 * (st['ybot'] + st['ytop']), 0.5 * (st['zmin'] + st['zmax'])])
        d = cb - sn; X = W[:, :3] - sn
        X = rot(X, -np.arctan2(d[1], d[0]), 0, 1); X = rot(X, -np.arctan2(d[2], np.hypot(d[0], d[1])), 0, 2); SL = float(np.linalg.norm(d))
        o = np.argsort(X[:, 0]); X = X[o]; W = W[o]; S = base(X); yy, zz, ww = [], [], []
        for f in np.arange(0.25, 0.751, 0.05):
            st = S.station(f * SL, SL)
            if st is None or st['K'] is None: continue
            m = 0.5 * (st['zl'] + st['zr']); wd = st['zr'] - st['zl']
            yy += list(st['ys'] - st['ys'].mean()); zz += list(m - np.average(m, weights=wd)); ww += list(wd)
        if len(yy) > 20:
            yy, zz, ww = map(np.array, (yy, zz, ww)); k = np.sum(ww * yy * zz) / np.sum(ww * yy * yy); a = float(np.clip(-np.arctan(k), -0.45, 0.45))
            X = rot(X, a, 1, 2); info['roll_deg'] += float(np.degrees(a))
        W = np.c_[X, W[:, 3]]
        if log: log(f'round {it}: SL {SL:.3f} of length {L:.3f}, roll so far {info["roll_deg"]:.1f} deg')
    info['SL_over_TL'] = SL / float(W[:, 0].max() - W[:, 0].min()); W[:, :3] /= SL
    return W, info


def smooth(a, k=5):
    a = np.asarray(a, float); ok = ~np.isnan(a)
    if ok.sum() < 3: return a
    b = np.interp(np.arange(len(a)), np.nonzero(ok)[0], a[ok]); b = ndi.median_filter(b, size=k, mode='nearest')
    return ndi.uniform_filter1d(b, size=3, mode='nearest')


def w_of_s(st, z0, side='half_total', n=21):
    """section shape: half-width at normalised height s over the greatest half-width. -> s, w (normalised), greatest half-width, polygon"""
    S = np.linspace(-1, 1, n); yq = st['ybot'] + (S + 1) / 2 * (st['ytop'] - st['ybot'])
    L = np.clip(st['zr'] - z0, 0, None); R = np.clip(z0 - st['zl'], 0, None)
    hwr = dict(half_total=0.5 * (st['zr'] - st['zl']), left=L, right=R)[side]
    hwr = ndi.uniform_filter1d(hwr, size=3, mode='nearest')
    w = np.interp(yq, st['ys'], hwr); w[0] = min(w[0], hwr[0]); w[-1] = min(w[-1], hwr[-1]); mx = float(hwr.max())
    return S, w / mx, mx, yq


def measure(W, step=0.01, log=None):
    """W: aligned points (SL = 1, snout x 0, y up, z to the fish's left). -> result dict + per-station data for the pictures"""
    S = Scan(W); xs = np.round(np.arange(0, 1 + 1e-9, step), 4); n = len(xs)
    # pass 1: the lean of each section (a dead body is twisted along its length), smoothed along the body
    lean = np.array([(lambda s: s['lean'] if (s and s['K'] is not None) else np.nan)(S.station(x, 1.0)) for x in xs])
    ok = ~np.isnan(lean); lean = np.interp(np.arange(n), np.nonzero(ok)[0], lean[ok]); lean = np.clip(ndi.uniform_filter1d(ndi.median_filter(lean, 9, mode='nearest'), 5, mode='nearest'), -0.5, 0.5)
    # pass 2: every section set upright, on one grid
    B = W[(W[:, 0] > -0.02) & (W[:, 0] < 1.02)]; M = 1.15 * float(np.abs(B[:, 1:]).max()) + 4 * CELL; N = int(2 * M / CELL) + 1; grid = (-M, -M, N, N)
    Fs, Ks, rs, Ts = [], [], [], []
    for x, a in zip(xs, lean):
        f = S.filled(x, 1.0, -a, grid); F = np.zeros((N, N), bool) if f is None else f[0]
        K, r, Rin = opened(F, RMIN / CELL, OPEN / CELL); Fs.append(F); Ks.append(K if K is not None else np.zeros((N, N), bool)); rs.append(r); Ts.append(2 * Rin * CELL)
    # along the body: a fin spread ACROSS the body lies in the section plane and looks thick there, but it is thin along x.
    # A core cell stays only if the core KX ahead or KX behind (grown by DX) also holds it.
    kx = max(1, int(round(KX / step))); near = [ndi.distance_transform_edt(~K) <= DX / CELL if K.any() else K for K in Ks]; st = []
    for i in range(n):
        K = Ks[i] & ((near[i - kx] if i - kx >= 0 else False) | (near[i + kx] if i + kx < n else False))
        if K.any():
            lab, m = ndi.label(K)
            if m > 1: K = lab == (1 + int(np.argmax(ndi.sum(K, lab, range(1, m + 1)))))
        if not K.any(): st.append(None); continue
        d = dict(x=xs[i], T=Ts[i], K=K, lean_deg=float(np.degrees(lean[i]))); d.update(edges(restored(Fs[i], K, rs[i]), K, -M, -M, CELL)); st.append(d)
    del Fs, Ks, near
    leaks = int(sum(LEAKS[-n:]))
    g = lambda k: np.array([np.nan if (s is None or s['K'] is None) else s[k] for s in st])
    zmin, zmax, zmid, ybot, ytop = g('zmin'), g('zmax'), g('zmid'), g('ybot'), g('ytop')
    z0 = smooth(zmid, 9); L = zmax - z0; R = z0 - zmin
    # a fleshy fin root (pectoral base) is a short bump on one flank: 1D opening along the body, window BUMP
    def debump(a):
        b = a.copy(); ok = ~np.isnan(a)
        if ok.sum() > 8:
            c = ndi.grey_closing(a[ok], size=2 * int(round(DIP / 2 / step)) + 1, mode='nearest')      # a short dip is a hole in the scan
            b[ok] = np.minimum(c, ndi.grey_opening(c, size=2 * int(round(BUMP / 2 / step)) + 1, mode='nearest'))
        return b
    L, R = debump(L), debump(R); ht = 0.5 * (L + R)
    hw = smooth(ht, 3); hw[np.isnan(ht) & (xs < 0.03)] = 0; hw[0] = 0.0; hw = np.nan_to_num(hw)
    Ls, Rs = smooth(L, 3), smooth(R, 3)
    trunk = (xs >= 0.25) & (xs <= 0.75) & ~np.isnan(L)
    asym = float(np.nanmedian((L[trunk] - R[trunk]) / (L[trunk] + R[trunk])))
    deformed = abs(asym) > ASYM; wide = 'left' if asym > 0 else 'right'
    ytop, ybot = debump(ytop), -debump(-ybot)          # the same along the back and belly: short humps are fin roots (pelvic base, dorsal spine base)
    depth = smooth(ytop - ybot, 3); body = (xs > 0.1) & (xs < 0.9); i_deep = int(np.nanargmax(np.where(body, depth, np.nan)))
    def sec(i):
        s = dict(st[i]); side = wide if deformed else 'half_total'
        s['zr'] = np.minimum(s['zr'], z0[i] + L[i]); s['zl'] = np.maximum(s['zl'], z0[i] - R[i])   # fin roots cut along the body are cut here too
        k = (s['ys'] <= ytop[i] + 1e-9) & (s['ys'] >= ybot[i] - 1e-9)
        if k.sum() > 4: s['ys'], s['zl'], s['zr'] = s['ys'][k], s['zl'][k], s['zr'][k]; s['ytop'], s['ybot'] = float(s['ys'][-1]), float(s['ys'][0])
        Sx, w, mx, yq = w_of_s(s, z0[i], side); _, wl, ml, _ = w_of_s(s, z0[i], 'left'); _, wr, mr, _ = w_of_s(s, z0[i], 'right')
        _, wt, mt, _ = w_of_s(s, z0[i], 'half_total')
        d = float(s['ytop'] - s['ybot']); ymid = 0.5 * (s['ytop'] + s['ybot'])
        # outline of the fin-free section, z to the fish's left, y from the snout-caudal axis (SL units)
        zl = s['zl'] - z0[i]; zr = s['zr'] - z0[i]
        if deformed: zl, zr = ((-zr, zr) if wide == 'left' else (zl, -zl))
        poly = [[float(a), float(b)] for a, b in zip(zr, s['ys'])] + [[float(a), float(b)] for a, b in zip(zl[::-1], s['ys'][::-1])]
        k = max(1, len(poly) // 200); poly = poly[::k]
        return dict(u_frac=float(xs[i]), front=[[round(a, 4), round(b, 4)] for a, b in poly], w=[[round(float(a), 3), round(float(b), 3)] for a, b in zip(Sx, w)],
                    half_width_max=round(mx, 4), depth=round(d, 4), y_top=round(float(s['ytop']), 4), y_bot=round(float(s['ybot']), 4),
                    width_over_depth=round(2 * mt / d, 3), widest_at_s=round(float(Sx[int(np.argmax(wt))]), 2),
                    w_left=[round(float(v * ml / max(ml, mr)), 3) for v in wl], w_right=[round(float(v * mr / max(ml, mr)), 3) for v in wr],
                    lr_rms=round(float(np.sqrt(np.mean((wl * ml - wr * mr) ** 2)) / mt), 3), w_from=side,
                    fullness=round(float(np.trapezoid(wt, Sx) / 2), 3))
    ia, ib = int(round(0.25 / step)), int(round(0.75 / step))
    front_r = sec(i_deep); extra = [sec(i) for i in (ia, ib) if st[i] is not None and st[i]['K'] is not None]
    poly = [[float(s), float(w)] for s, w in zip(xs, hw)] + [[float(s), -float(w)] for s, w in zip(xs[::-1], hw[::-1])]
    nn = lambda a: [None if np.isnan(v) else round(float(v), 4) for v in a]
    top_r = dict(hw=[[round(float(s), 3), round(float(w), 4)] for s, w in zip(xs, hw)], top=[[round(a, 4), round(b, 4)] for a, b in poly],
                 left=nn(Ls), right=nn(Rs), side_used='half_total', roots=[])
    i_w = int(np.argmax(hw))
    res = dict(top_r=top_r, front_r=front_r, sections_extra=extra,
               summary=dict(max_hw_over_SL=round(float(hw.max()), 4), max_hw_at_s=float(xs[i_w]), deepest_at_s=float(xs[i_deep]),
                            depth_max_over_SL=front_r['depth'], width_over_depth_at_deepest=front_r['width_over_depth'],
                            asymmetry_LR=round(asym, 3), deformed=bool(deformed), wider_side=wide,
                            midline_bend_over_SL=round(float(np.nanmax(z0) - np.nanmin(z0)), 4), holes_filled_stations=leaks,
                            twist_deg=round(float(np.degrees(lean[75] - lean[25])), 1)))
    return res, dict(xs=xs, st=st, z0=z0, L=L, R=R, hw=hw, ybot=ybot, ytop=ytop, i_deep=i_deep, ia=ia, ib=ib)


def place_front(front_r, rec_top_y, rec_bot_y):
    """views.apply() wants the front polygon's y in the record's own frame: map the scan section's back/belly edges onto the record's
    top/bottom y at its deepest station (SL units). Widths are left alone (apply() rescales them to the top view)."""
    k = (rec_top_y - rec_bot_y) / (front_r['y_top'] - front_r['y_bot']); f = dict(front_r)
    f['front'] = [[z, round(rec_bot_y + (y - front_r['y_bot']) * k, 4)] for z, y in front_r['front']]; return f


def pictures(W, C, res, aux, stem, label=''):
    import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
    xs, st, z0 = aux['xs'], aux['st'], aux['z0']; sm = res['summary']
    n = len(W); k = max(1, n // 150000); P = W[::k]; Q = C[::k] / 255.0
    fig, ax = plt.subplots(2, 1, figsize=(13, 8.5), gridspec_kw=dict(height_ratios=[1.25, 1]))
    o = np.argsort(P[:, 2]); ax[0].scatter(P[o, 0], P[o, 1], c=Q[o], s=1.2, lw=0)
    ax[0].plot(xs, aux['ytop'], 'r-', lw=1); ax[0].plot(xs, aux['ybot'], 'r-', lw=1)
    for i, c in ((aux['i_deep'], 'm'), (aux['ia'], 'c'), (aux['ib'], 'c')): ax[0].axvline(xs[i], color=c, lw=0.8)
    ax[0].axvline(0, color='k', lw=0.6); ax[0].axvline(1, color='k', lw=0.6); ax[0].set_aspect('equal')
    ax[0].set_title(f'{label}  side (fish left side); red = fin-free body edge; black lines = snout and caudal base (SL)', fontsize=9)
    ax[1].scatter(P[:, 0], P[:, 2], c='0.75', s=1, lw=0)
    ax[1].plot(xs, z0 + aux['L'], 'b-', lw=1, label='left edge (fin-free)'); ax[1].plot(xs, z0 - aux['R'], 'g-', lw=1, label='right edge')
    ax[1].plot(xs, z0, 'k:', lw=0.8, label='median plane'); ax[1].plot(xs, z0 + aux['hw'], 'r--', lw=0.8, label='hw (half total)'); ax[1].plot(xs, z0 - aux['hw'], 'r--', lw=0.8)
    ax[1].set_aspect('equal'); ax[1].legend(fontsize=7, loc='upper right')
    ax[1].set_title(f'from above: max hw {sm["max_hw_over_SL"]:.3f} SL at s {sm["max_hw_at_s"]:.2f}; asymmetry (L-R)/(L+R) {sm["asymmetry_LR"]:+.3f}'
                    f'{" DEFORMED" if sm["deformed"] else ""}; bend {sm["midline_bend_over_SL"]:.3f} SL', fontsize=9)
    fig.tight_layout(); fig.savefig(stem + '_top.png', dpi=80); plt.close(fig)
    secs = [(aux['ia'], res['sections_extra'][0] if res['sections_extra'] else None), (aux['i_deep'], res['front_r']),
            (aux['ib'], res['sections_extra'][-1] if len(res['sections_extra']) > 1 else None)]
    fig, ax = plt.subplots(1, 4, figsize=(15, 5.2))
    for a, (i, r) in zip(ax, secs):
        s = st[i]
        if s is None or s['K'] is None or r is None: a.set_title('no section'); continue
        Pz = Scan(W).slab(xs[i], SLAB, -np.radians(s['lean_deg']))
        a.scatter(Pz[:, 2] - z0[i], Pz[:, 1], c='0.6', s=2, lw=0)
        F = np.array(r['front']); a.plot(np.r_[F[:, 0], F[0, 0]], np.r_[F[:, 1], F[0, 1]], 'r-', lw=1.2)
        a.plot(s['zr'] - z0[i], s['ys'], 'b-', lw=0.6); a.plot(s['zl'] - z0[i], s['ys'], 'g-', lw=0.6); a.axvline(0, color='k', ls=':', lw=0.6)
        a.set_aspect('equal'); a.set_title(f's {xs[i]:.2f}{" (deepest)" if i == aux["i_deep"] else ""}: w/d {r["width_over_depth"]:.2f}, hw {r["half_width_max"]:.3f},\n'
                                           f'widest at s {r["widest_at_s"]:+.1f}, fullness {r["fullness"]:.2f}, L/R rms {r["lr_rms"]:.2f}', fontsize=8)
    r = res['front_r']; Sx = [p[0] for p in r['w']]
    ax[3].plot([p[1] for p in r['w']], Sx, 'r-o', ms=3, label='w(s) used (' + r['w_from'] + ')'); ax[3].plot(r['w_left'], Sx, 'b-', lw=0.7, label='left'); ax[3].plot(r['w_right'], Sx, 'g-', lw=0.7, label='right')
    for e2, c in zip(res['sections_extra'], ('c', 'y')): ax[3].plot([p[1] for p in e2['w']], Sx, c + '--', lw=0.8, label=f's {e2["u_frac"]:.2f}')
    th = np.linspace(-np.pi / 2, np.pi / 2, 50); ax[3].plot(np.cos(th), np.sin(th), 'k:', lw=0.6, label='ellipse')
    ax[3].legend(fontsize=7); ax[3].set_xlabel('w / greatest'); ax[3].set_ylabel('s (-1 belly, +1 back)'); ax[3].set_title('section shape at the deepest station', fontsize=8)
    fig.suptitle(f'{label}  sections head-on (grey = scan points in the slab, red = fin-free outline used, z to the fish left)', fontsize=9)
    fig.tight_layout(); fig.savefig(stem + '_sections.png', dpi=80); plt.close(fig)


def run(d, out, head=None, sl_end=None, label='', meta=None, log=print):
    e, V, C = load(d)
    Wn, info = align_idx(e, V, head, sl_end, log); del V
    W = Wn[:, :3]; C = C[Wn[:, 3].astype(int)]; del Wn
    res, aux = measure(W, log=log)
    res['frame'] = info; res['n_points'] = int(len(W))
    res['units'] = 'SL = 1, snout tip x 0, caudal base x 1; y up from the snout-caudal axis, z to the fish left; fins removed (see scan_views.py header)'
    res.update(meta or {})
    pictures(W, C, res, aux, out, label)
    res['png'] = [out + '_top.png', out + '_sections.png']
    json.dump(res, open(out + '.json', 'w'), indent=0)
    return res


if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('scan_dir'); ap.add_argument('--out', required=True); ap.add_argument('--head', type=int, default=None)
    ap.add_argument('--sl-end', type=float, default=None, help='caudal base as a fraction of total length (overrides the automatic rule)')
    ap.add_argument('--label', default=''); ap.add_argument('--meta', default='{}')
    a = ap.parse_args(); r = run(a.scan_dir, a.out, a.head, a.sl_end, a.label, json.loads(a.meta))
    print(json.dumps(dict(r['summary'], frame=r['frame'], out=a.out + '.json')))
