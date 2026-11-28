"""Stage 6, FINS: single-sheet cards from the record fin fields, root rows welded under the skin, and one fin atlas
(rays and segments as normal relief, membrane outline cut by alpha). Output: fin meshes + fin_base.png, fin_normal.png.
"""
import os
import numpy as np
from PIL import Image
from .form import fair


EDGE_RAYS = 25      # DEFAULT: most columns on a traced median fin card (a falcate lobe needs more than 17 to keep its tip)
EDGE_ROWS, RELAX_IT = 6, 60     # DEFAULTS: rows on a traced card and relaxation passes between root and outline
SOFT_FRAY = 0.015   # DEFAULT: a soft-ray fin's edge recedes this share of the ray length between ray tips (a whole edge, faintly frayed)
SPINE_W = 0.12      # DEFAULT: half-width of a spine's free tip, share of the spacing between spines
RAY_RELIEF = 0.10   # DEFAULT: ray ridge relief in the fin normal map (rays read in the texture, not as a pleated card). 0.06
                    # (fins step 1) left the paired fins reading as flat boards (export r5 pixel check, item 9)
SHEATH = 0.12       # DEFAULT: body skin colour carries onto the base of the median fins and caudal over this share of the ray length


def resample(P, n):
    """n points spaced evenly by length along the polyline P."""
    s = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]; t = np.linspace(0, s[-1], n)
    return np.stack([np.interp(t, s, P[:, k]) for k in range(P.shape[1])], -1)

PAIR_BASE = 0.12    # DEFAULT: share of a paired fin's reach taken by its fleshy base, where it leaves the skin (record
                    # skeleton.<fin>.baseBand.w when read off a photo; the snapper's read is 0.12 pectoral, 0.10 pelvic)
PAIR_CLEAR = 0.002  # DEFAULT (SL): past its base a paired fin stands at least this far off the skin under it (a fin laid on the flank)
EDGE_FAIR_TOL, EDGE_FAIR_LEN = 0.004, 0.05   # DEFAULTS (SL): a paired fin's traced outline is faired by at most 0.4 % SL (a silhouette read off
                    # a photo mask steps from pixel to pixel: the trevally's pelvic rear edge zigzags by 0.7 % SL from knot to knot), over 5 % SL
GRID_ROWS, GRID_IT, GRID_RELAX = 12, 400, 0.7   # DEFAULTS: rows of the working grid of a paired fin, Winslow passes, share of each pass taken
PAIR_EMERGE = (0.3, 0.8)  # DEFAULT: share of the base depth at which a paired fin's rays, and the membrane midway between them, come out of the skin
EDGE_CORNER = 20.0  # DEFAULT (deg): a turn of a traced outline sharper than this is a corner the card keeps
PAIR_LIFT = 0.001   # DEFAULT (SL): over its base the fin lies on the skin, this far off it (one skin thickness: no gap to see under, no shimmer)
PAIR_OUT_MAX = 85.0 # DEFAULT (deg): the furthest a paired fin swings out to clear the body
PAIR_GAP = 0.006    # DEFAULT (SL): a fin rooted on the belly line sits this far to its own side of the midline (the untraced card's rule)
ROOT_SINK = 0.004   # DEFAULT (SL): a fin's root row sits this far under the skin
PAIR_BASE_ROWS, PAIR_ROWS = 3, 5    # DEFAULTS: rows across a paired fin's base (the bend off the skin needs three) and beyond it


def resample_corners(P, n):
    """n points along the polyline P, evenly by length, except that the sample nearest each corner of P (a turn over
    EDGE_CORNER deg, sharpest first) sits on the corner: a card's outline keeps the tip of a lobe and the foot of a concave
    trailing edge instead of cutting across them (blockout BK3: the trevally's second dorsal covered 0.79 of its outline)."""
    P = np.asarray(P, float); s = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]; t = np.linspace(0, s[-1], n)
    d = np.diff(P, axis=0); d = d / (np.linalg.norm(d, axis=1, keepdims=True) + 1e-15)
    turn = np.degrees(np.arccos(np.clip((d[1:] * d[:-1]).sum(1), -1, 1))); taken = {0, n - 1}
    for j in np.argsort(-turn):
        if turn[j] < EDGE_CORNER: break
        i = int(np.abs(np.linspace(0, s[-1], n) - s[j + 1]).argmin())
        if i not in taken: t[i] = s[j + 1]; taken.add(i)
    t = np.sort(t); return np.stack([np.interp(t, s, P[:, k]) for k in range(P.shape[1])], -1)


def relaxed_grid(base, top, rows):
    """rows between a root row and a free outline (same column count), each inner point the mean of its neighbours."""
    t = np.linspace(0, 1, rows + 1)[:, None, None]; G = (1 - t) * base[None] + t * top[None]
    for _ in range(RELAX_IT):
        G[1:-1, 1:-1] = 0.25 * (G[:-2, 1:-1] + G[2:, 1:-1] + G[1:-1, :-2] + G[1:-1, 2:])
        G[1:-1, 0] = G[0, 0] + (G[-1, 0] - G[0, 0]) * t[1:-1, 0]; G[1:-1, -1] = G[0, -1] + (G[-1, -1] - G[0, -1]) * t[1:-1, 0]
    return G


def pair_rows(bw):
    """row heights (share of the ray, 0 root to 1 tip) of a paired fin: PAIR_BASE_ROWS rows across its base, where the
    sheet bends away from the skin, then PAIR_ROWS even rows to the margin."""
    return np.r_[np.linspace(0, bw, PAIR_BASE_ROWS + 1)[:-1], np.linspace(bw, 1, PAIR_ROWS + 1)]


def winslow(G):
    """a grid made fold-free inside its border: Winslow's equations (the grid lines are level lines of two harmonic
    functions on the region), the standard cure where a patch or a relaxed grid (each point the mean of its neighbours)
    folds: behind a swept lobe, in a re-entrant corner. The border stays; G: (rows + 1, columns, 2 or 3), changed in place."""
    for _ in range(GRID_IT):
        xu, xt = 0.5 * (G[1:-1, 2:] - G[1:-1, :-2]), 0.5 * (G[2:, 1:-1] - G[:-2, 1:-1])
        g11, g22, g12 = (xu * xu).sum(-1, keepdims=True), (xt * xt).sum(-1, keepdims=True), (xu * xt).sum(-1, keepdims=True)
        xut = 0.25 * (G[2:, 2:] - G[2:, :-2] - G[:-2, 2:] + G[:-2, :-2])
        new = (g22 * (G[1:-1, 2:] + G[1:-1, :-2]) + g11 * (G[2:, 1:-1] + G[:-2, 1:-1]) - 2 * g12 * xut) / (2 * (g11 + g22) + 1e-18)
        G[1:-1, 1:-1] += GRID_RELAX * (new - G[1:-1, 1:-1])
    return G


def ray_grid(base, outline, t):
    """a fin sheet whose columns run as its rays do: the first column is the leading edge itself (the outline from the
    first root to its farthest point from that root, the tip of the first ray), the top row is the margin from there
    back toward the last root, the last column the short last ray. Between them the grid is the one grid makers use for
    a region of any outline: a Coons patch of the four sides to start, then Winslow's equations (the columns and rows are
    level lines of two harmonic functions on the fin), which cannot fold where a patch or a relaxed grid can: behind a
    swept lobe, in the corner of a fin laid back along the belly. A last stretch of outline that runs along the root line
    (within EDGE_FAIR_TOL of it) is not free edge: the root row ends where the outline leaves it.
    base: (M, 2) root row; outline: (K, 2) first root round the tip to the last root; t: row heights (share of each column's length)."""
    M = len(base); O = resample(np.asarray(outline, float), 400); p0 = base[0]; c = base[-1] - p0; cl = np.linalg.norm(c); c = c / cl
    D = np.abs((O - p0) @ np.array([-c[1], c[0]])); free = D > EDGE_FAIR_TOL       # the tip is free edge, not where the outline runs into the root line
    ja = int(np.clip((np.linalg.norm(O - p0, axis=1) * free).argmax() if free.any() else D.argmax(), 2, len(O) - 3)); far = np.nonzero(D[ja:] > EDGE_FAIR_TOL)[0]
    jb = ja + int(far[-1]) if len(far) else ja                                   # where the outline comes back to the root line
    jb = min(jb, ja + int(round((len(O) - 1 - ja) * (1 - 1 / M)))); s1 = float(np.clip((O[jb] - p0) @ c, 0.3 * cl, cl))
    sb = (base - p0) @ c; base = resample(np.vstack([base[sb < s1 - 1e-9], p0 + s1 * c]), M) if s1 < cl - 1e-9 else base
    arc = lambda P, tt: (lambda s: np.stack([np.interp(tt * s[-1], s, P[:, k]) for k in range(2)], -1))(np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
    tw = np.linspace(0, 1, GRID_ROWS + 1); L = arc(np.vstack([base[:1], O[1:ja + 1]]), tw); R = arc(np.vstack([base[-1:], O[jb:jb + 1]]), tw); T = arc(O[ja:jb + 1], np.linspace(0, 1, M))
    u = np.linspace(0, 1, M)[None, :, None]; tt = tw[:, None, None]
    G = ((1 - u) * L[:, None] + u * R[:, None] + (1 - tt) * base[None] + tt * T[None]
         - ((1 - u) * (1 - tt) * base[0] + u * (1 - tt) * base[-1] + (1 - u) * tt * T[0] + u * tt * T[-1]))
    G = winslow(G)
    return np.stack([arc(G[:, i], np.asarray(t, float)) for i in range(M)], 1)        # rows at their heights along each column


def fan_angle(edge, base_line):
    """the angle (deg) a traced fin's fan is open: from its base (first root to last root) to its leading ray (first root to
    the outline's farthest point from it)."""
    E, B = np.asarray(edge, float), np.asarray(base_line, float); c = B[-1] - B[0]; t = E[np.linalg.norm(E - B[0], axis=1).argmax()] - B[0]
    return float(np.degrees(np.arccos(np.clip(c @ t / (np.linalg.norm(c) * np.linalg.norm(t) + 1e-12), -1, 1))))


def paired_sheet(form, f, sg, fault=None, info=None):
    """a traced paired fin as a sheet, (rows + 1, columns, 3). The record's side-view outline (edge, first root round the tip
    to the last root) is the fin's own shape, flat in the photo's plane (measured: trace reach over record length is 1.01
    in the median of the 31 traced paired fins; a fin standing 30 deg out of the photo would read 0.87). Three steps, each
    keeps every length on the fin:
      1 fold: the fan closes about the first root, its base held, until the leading ray stands no further from the base
        than the record's rest angle (f['fan']: a specimen photo shows the pelvic fin erect; at rest it is laid back);
      2 hinge: the sheet turns about its base line by the record's out angle, to its own side. The turn is spread over the
        fin's fleshy base (PAIR_BASE of its reach), so the sheet leaves the skin along the skin and bends away: no slab
        standing on the flank, no open wedge behind the root;
      3 seat: the root row lies on the body where the base line is drawn, ROOT_SINK under the skin; a base drawn on the
        underside sits PAIR_GAP to its own side, so the pair never meets or crosses; over its base the fin lies on the skin
        (PAIR_LIFT off it), past it at least PAIR_CLEAR off the skin under it.
    fault: a planted fault for the checks ('project' = the outline kept as the side view and pushed out by tan(out), the
    rule before; 'hard' = no base, the whole turn on the root line; 'nofold' = step 1 left out)."""
    E, BL = np.asarray(f['edge'], float), np.asarray(f['base_line'], float); p0 = BL[0]; c = BL[-1] - p0; c = c / np.linalg.norm(c)
    if fault != 'project':                  # the outline without the trace's jitter; its ends and its tip stay
        sa = np.r_[0, np.cumsum(np.linalg.norm(np.diff(E, axis=0), axis=1))]; hold = (0, len(E) - 1, int(np.linalg.norm(E - p0, axis=1).argmax()))
        E = np.stack([fair(sa, E[:, k], EDGE_FAIR_TOL, EDGE_FAIR_LEN, hold) for k in (0, 1)], -1)
    tip = E[np.linalg.norm(E - p0, axis=1).argmax()]; e = np.array([-c[1], c[0]]); e = e if (tip - p0) @ e > 0 else -e
    k = 1.0 if fault == 'nofold' else min(1.0, f['fan'] / max(fan_angle(E, BL), 1e-6))
    def fold(P):
        v = P - p0; rho = np.linalg.norm(v, axis=1); phi = np.arctan2(v @ e, v @ c) * k
        return p0 + rho[:, None] * (np.cos(phi)[:, None] * c + np.sin(phi)[:, None] * e)
    Mb = EDGE_RAYS; base = resample(fold(BL), Mb); bw = 1e-6 if fault == 'hard' else f.get('base_w', PAIR_BASE)
    G = ray_grid(base, fold(E), pair_rows(bw)) if fault != 'project' else relaxed_grid(base, resample(E, Mb), len(pair_rows(bw)) - 1)
    if info is not None:                    # the sheet in its own plane, as traced (before the fold and the hinge): what a size check compares with the trace
        info['flat'] = G[..., :2] if k >= 1.0 or fault == 'project' else ray_grid(resample(BL, Mb), E, pair_rows(bw))
    S, D = (G - p0) @ c, (G - p0) @ e; reach = float(D.max()); Dp = np.maximum(D, 0)
    Lf = max(bw * reach, 1e-6)
    step = lambda d: (lambda u: u * u * (3 - 2 * u))(np.clip(d / Lf, 0, 1))
    # the seat of the root row: on the skin at the base line. A base drawn on the underside (the skin there faces down more
    # than sideways, or has no width at all: the belly line) cannot be placed across the body from a side view; it sits
    # PAIR_GAP to its own side of the midline, on the skin
    bx, by = base[:, 0], base[:, 1]; cen = form.sec(bx)[0]; zs = np.abs(form.z_on(bx, by)); h_ = 1e-4
    gy = (np.abs(form.z_on(bx, by + h_)) - np.abs(form.z_on(bx, by - h_))) / (2 * h_)
    under = np.median(np.where(zs < PAIR_GAP, 9.0, np.abs(gy))) > 1.0
    lo, hi = np.where(by < cen, form.BOT(bx), form.TOP(bx)), cen
    for _ in range(40):
        mid = 0.5 * (lo + hi); inn = np.abs(form.z_on(bx, mid)) < PAIR_GAP; lo, hi = np.where(inn, mid, lo), np.where(inn, hi, mid)
    sy = np.where(under, hi, by); sz = np.where(under, PAIR_GAP, zs)
    sb = (base - p0) @ c; o = np.argsort(sb); zb = np.interp(S, sb[o], sz[o]); dd = np.linspace(0, max(reach, 1e-6), 400)

    def place(out_):
        a = out_ * step(dd)
        run = np.r_[0, np.cumsum(0.5 * (np.cos(a[1:]) + np.cos(a[:-1])) * np.diff(dd))]; rise = np.r_[0, np.cumsum(0.5 * (np.sin(a[1:]) + np.sin(a[:-1])) * np.diff(dd))]
        if fault == 'project': run, rise = dd, np.tan(out_) * dd
        XY = p0 + S[..., None] * c + (np.minimum(D, 0) + np.interp(Dp, dd, run))[..., None] * e
        if under:                           # the whole fin moves as one piece, its root line onto the seat's two ends: no stretch
            q0, q1 = np.array([bx[0], sy[0]]), np.array([bx[-1], sy[-1]]); c2 = (q1 - q0) / np.linalg.norm(q1 - q0); e2 = np.array([-c2[1], c2[0]]) * np.sign(c[0] * e[1] - c[1] * e[0])
            XY = q0 + ((XY - p0) @ c)[..., None] * c2 + ((XY - p0) @ e)[..., None] * e2
            sag = sy - (q0[1] + (sb / max(sb[-1], 1e-9)) * (q1[1] - q0[1]))     # the belly's own curve between the two ends: the root line follows it
            XY[..., 1] += np.interp(S, sb[o], sag[o])
        X, Y = XY[..., 0], XY[..., 1]; Z = zb + np.interp(Dp, dd, rise)
        on = (X > 0) & (X < form.XEND) & (Y > form.BOT(np.clip(X, 0, form.XEND))) & (Y < form.TOP(np.clip(X, 0, form.XEND)))
        skin = np.where(on, np.abs(form.z_on(np.clip(X, 1e-6, form.XEND), Y)), 0.0)
        return X, Y, Z, skin + PAIR_LIFT + (PAIR_CLEAR - PAIR_LIFT) * step(Dp)
    # the blade is stiff: where the record's out angle would put it through the body it swings further out, a degree at a
    # time, until it is clear (a fin laid back beside a deep belly; a fin held close on a flank that still widens)
    out_ = float(f['out'])
    while fault != 'project' and out_ < PAIR_OUT_MAX:
        X, Y, Z, floor = place(np.radians(out_))
        if not (form.sd_body(np.stack([X, Y, Z], -1)[Dp > Lf]) < PAIR_LIFT).any(): break
        out_ += 1.0
    X, Y, Z, floor = place(np.radians(out_))
    if fault != 'project' and not under: Z = np.maximum(Z, floor)       # over its base a fin on the flank lies on the skin
    if info is not None: info.update(out_used=out_, fold=round(k, 3), under=bool(under))
    V = np.stack([X, Y, sg * Z], -1)
    if under: V[0, :, 1] += ROOT_SINK * np.sign(cen - V[0, :, 1])       # the root row goes under the skin: up into the belly,
    else: V[0, :, 2] -= sg * ROOT_SINK                                   # or in from the flank
    return V


def build_fins(form, rec, out):
    F = rec['fins']; fins = {}; TOP, BOT, sec = form.TOP, form.BOT, form.sec; PAIRED = {}

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
        the rows between are a Winslow grid (fins.winslow), so rays curve with a swept lobe or a filament instead of cutting
        straight across the gap beside it, and no cell folds over behind the lobe (rows relaxed to the mean of their
        neighbours did: the notch behind the trevally's dorsal lobe, the skirt at the tail root)."""
        Mb = len(base); top = (resample if F.get('fault') == 'relaxed' else resample_corners)(np.asarray(edge_sl, float), Mb); top = np.c_[top, np.zeros(Mb) if top_z is None else top_z(top)]
        if F.get('fault') == 'relaxed': G = relaxed_grid(base, top, rows)
        else:               # Winslow on a finer working grid gives the columns (its rows crowd toward a short root: on a forked tail 23 of
            # 24 lie in the first seventh), then the rows at even shares of each column's length
            G = winslow((lambda t: (1 - t) * base[None] + t * top[None])(np.linspace(0, 1, GRID_ROWS + 1)[:, None, None]))
            G = np.stack([resample(G[:, i], rows + 1) for i in range(Mb)], 1)
        # each point's height in the texture is its own share of its ray's length, wherever the rows fall
        cl = np.r_[np.zeros((1, Mb)), np.cumsum(np.linalg.norm(np.diff(G, axis=0), axis=-1), axis=0)]
        tv = np.where(cl[-1] > 1e-9, cl / np.maximum(cl[-1], 1e-9), np.linspace(0, 1, rows + 1)[:, None]); tv[0], tv[-1] = 0.0, 1.0
        vs = G.reshape(-1, 3); uv = [(i / (Mb - 1), float(tv[r, i])) for r in range(rows + 1) for i in range(Mb)]
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
            for sg in (1, -1):
                info = {}; V = paired_sheet(form, f, sg, f.get('fault'), info); flat = info.pop('flat').reshape(-1, 2)
                PAIRED[name] = dict(info, out_record=f['out'], fan_record=f['fan'], fan_traced=round(fan_angle(f['edge'], f['base_line']), 1))
                t = pair_rows(f.get('base_w', PAIR_BASE)); nr, Mb = V.shape[:2]; uv = [(i / (Mb - 1), float(t[r])) for r in range(nr) for i in range(Mb)]
                fs = [[r * Mb + i, r * Mb + i + 1, (r + 1) * Mb + i + 1, (r + 1) * Mb + i] for r in range(nr - 1) for i in range(Mb - 1)]
                fins[f'{name}_{"L" if sg > 0 else "R"}'] = dict(flat=flat, V=V.reshape(-1, 3), F=fs, UV=np.array(uv), rays=f['rays'], lens=np.linalg.norm(V[-1] - V[0], axis=1), T=[q for _, q in uv])
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
        # F3: scaled skin sheath over the base of median fins and caudal; a paired fin's fleshy base carries the body's skin too
        sheath = F[key].get('base_w', PAIR_BASE) if key in ('pectoral', 'pelvic') else SHEATH
        sh = np.clip(1 - tv / sheath, 0, 1)[..., None] ** 1.5; col = col * (1 - sh) + body_c * sh
        if key in PAIRED:       # a traced paired fin lies on the skin over its base: there the rays come out of the skin first and
            alpha = alpha * (tv >= sheath * (PAIR_EMERGE[0] + (PAIR_EMERGE[1] - PAIR_EMERGE[0]) * d ** 2))    # the membrane between them later, so the root is no straight cut edge
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
    form.PAIRED = PAIRED            # how each traced paired fin was placed (cage.json form_rules.paired_fins)
    return fins
