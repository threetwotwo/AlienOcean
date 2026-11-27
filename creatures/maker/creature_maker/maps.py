"""Stage 5, MAPS: body textures from the cage, its UVs and the form (numpy). The normal and AO bakes happen in Blender
(blender/export_glb.py) in Blender's own tangent frame; this stage writes what Blender does not compute:
  body_base.png      record ground colours by body-height band (countershading) + scale-pocket pigment
  body_orm_pre.png   R = 1 (AO filled in by Blender), G = roughness, B = metalness
  body_height.npy    fine relief (scales by row rule, lateral line) as UV-space height, never in the SDF
  body_mask.npy      texels covered by the skin
Light (AO, sheen) is never painted into the base colour.
"""
import os
import numpy as np
from PIL import Image
from .mesh import SKIN_TAGS

HAMP = 0.0011    # relief height in SL at H = 1 (scales ~1/10 of their length)


def raster(faces, fuv, V, VN, res):
    """rasterise cage triangles in UV space -> per-texel position, normal, tangent frame, face id."""
    Pm = np.full((res, res, 3), np.nan); Nm = np.zeros((res, res, 3)); Tm = np.zeros((res, res, 3)); Fm = -np.ones((res, res), int)
    for fi, (f, uv) in enumerate(zip(faces, fuv)):
        tris = [(0, 1, 2)] if len(f) == 3 else [(0, 1, 2), (0, 2, 3)]
        for t in tris:
            A = uv[list(t)] * res; P = V[[f[k] for k in t]]; N = VN[[f[k] for k in t]]
            x0, y0 = np.floor(A.min(0)).astype(int); x1, y1 = np.ceil(A.max(0)).astype(int)
            xs, ys = np.meshgrid(np.arange(max(x0, 0), min(x1 + 1, res)), np.arange(max(y0, 0), min(y1 + 1, res)))
            px, py = xs + 0.5, ys + 0.5
            d = (A[1, 1] - A[2, 1]) * (A[0, 0] - A[2, 0]) + (A[2, 0] - A[1, 0]) * (A[0, 1] - A[2, 1])
            if abs(d) < 1e-12: continue
            w0 = ((A[1, 1] - A[2, 1]) * (px - A[2, 0]) + (A[2, 0] - A[1, 0]) * (py - A[2, 1])) / d
            w1 = ((A[2, 1] - A[0, 1]) * (px - A[2, 0]) + (A[0, 0] - A[2, 0]) * (py - A[2, 1])) / d
            w2 = 1 - w0 - w1; m = (w0 >= -1e-4) & (w1 >= -1e-4) & (w2 >= -1e-4)
            if not m.any(): continue
            W = np.stack([w0[m], w1[m], w2[m]], -1)
            yy, xx = ys[m], xs[m]
            Pm[yy, xx] = W @ P; n = W @ N; Nm[yy, xx] = n / np.linalg.norm(n, axis=1, keepdims=True)
            e1, e2 = P[1] - P[0], P[2] - P[0]; du1, du2 = A[1] - A[0], A[2] - A[0]       # tangent = dP/du
            r = du1[0] * du2[1] - du2[0] * du1[1]
            Tm[yy, xx] = (e1 * du2[1] - e2 * du1[1]) / (r if abs(r) > 1e-12 else 1)
            Fm[yy, xx] = fi
    return Pm, Nm, Tm, Fm


def dilate(A, M, n=12):
    A = A.copy(); M = M.copy()
    for _ in range(n):
        acc = np.zeros_like(A); cnt = np.zeros(M.shape)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            sh = np.roll(np.roll(M, dy, 0), dx, 1); acc += np.roll(np.roll(A * M[..., None], dy, 0), dx, 1); cnt += sh
        new = (~M) & (cnt > 0); A[new] = acc[new] / cnt[new][:, None]; M = M | new
    return A


def save_png(a, path, srgb=True):
    a = np.clip(a, 0, 1)
    if srgb: a = np.where(a <= 0.0031308, 12.92 * a, 1.055 * a ** (1 / 2.4) - 0.055)
    Image.fromarray((a[::-1] * 255 + 0.5).astype(np.uint8)).save(path)


def bake_body(B, uvr, res, out):
    form, chart, rec, mesh = B.form, B.chart, B.rec, B.mesh; V, VN = B.V, B.VN; XEND = form.XEND
    sk = [k for k, t in enumerate(mesh.ftag) if t in SKIN_TAGS]          # skin faces only (the interior has its own texture)
    Pm, Nm, Tm, Fm = raster([mesh.faces[k] for k in sk], [uvr['face_uv'][k] for k in sk], V, VN, res)
    M = ~np.isnan(Pm[..., 0])
    P = Pm[M]
    _, PID = form.sd_full(P, parts=True)
    # fine relief = UV-space height (scales by row rule from the record count, lateral line); never in the SDF
    x = P[:, 0]; th = form.theta_of(P[:, 0], P[:, 1], P[:, 2]); arc = chart.arc_of(x, th)
    SC = rec['scales']; sp0 = 1.0 / SC['lateral_line']
    cap = chart.arc_of(x, np.full(x.shape, np.pi))
    fh = arc / np.maximum(cap, 1e-6)                       # 0 dorsal .. 1 ventral
    area = 1 - 0.22 * np.exp(-((fh - 0.9) / 0.12) ** 2) - 0.2 * np.clip((x - 0.8) / 0.15, 0, 1) - 0.18 * np.exp(-((fh - 0.02) / 0.06) ** 2)
    sp = sp0 * area                                         # body-area pass: smaller scales on belly, tail root, back ridge
    a_ = x / sp; b_ = arc / (sp * 0.82)
    best = np.full(x.shape, 1e9); h = np.zeros(x.shape)
    for dk in (-1, 0, 1):
        k = np.floor(b_) + dk; off = 0.5 * (np.mod(k, 2))
        for dj in (-1, 0, 1):
            jx = np.floor(a_ - off) + dj + off
            du = a_ - jx; dv = (b_ - (k + 0.5)) * 0.82
            rr = np.sqrt(du ** 2 + dv ** 2); cov = rr < 0.78
            take = cov & (jx < best)                       # the most anterior covering scale lies on top
            best = np.where(take, jx, best); h = np.where(take, np.clip((du + 0.78) / 1.56, 0, 1) ** 1.6, h)
    on_head = (PID > 0) | (x < rec['gill_u'])   # head = in front of the record's gill opening
    h = h * (~on_head) * np.clip((x - rec['gill_u']) / 0.03, 0, 1) * np.clip((0.985 - x / XEND) / 0.03, 0, 1)
    ll = np.exp(-((fh - SC['ll_frac'] * (1 + 0.6 * np.clip((x - 0.55) / 0.4, 0, 1))) / 0.006) ** 2) * (x > 0.3)
    H = np.zeros((res, res)); H[M] = h * 0.55 + ll * 0.5
    np.save(os.path.join(out, 'body_height.npy'), H.astype(np.float32))
    # coat: record ground colours by body-height band (countershading); PLAIN record coat (grown layer not yet ported)
    PA = rec['paint']; c_back, c_fl, c_bel = (np.array(PA[k]) for k in ('back', 'flank', 'belly'))
    wb = np.clip(1 - fh / 0.45, 0, 1) ** 1.3; wv = np.clip((fh - 0.55) / 0.4, 0, 1) ** 1.2
    col = c_back * wb[:, None] + c_fl * (1 - wb - wv)[:, None] + c_bel * wv[:, None]
    col = col * (0.86 + 0.14 * h[:, None])                  # scale-pocket pigment only
    mt = PA['metal']; metal = mt['back'] * wb + mt['flank'] * (1 - wb - wv) + mt['belly'] * wv
    metal = metal * (0.75 + 0.25 * h) * np.where(PID > 0, 0.8, 1)
    rough = PA['rough'] + 0.18 * (1 - h) * (h > 0) + 0.1 * (PID > 0)

    def img(a, fill):
        o = np.zeros((res, res) + a.shape[1:]) + fill; o[M] = a; return o
    BASE = img(col, 0); ORM = np.stack([img(np.ones(len(P)), 1), img(rough, 0.5), img(metal, 0)], -1)
    np.save(os.path.join(out, 'body_mask.npy'), M)
    BASE = dilate(BASE, M); ORM = dilate(ORM, M)
    save_png(BASE, os.path.join(out, 'body_base.png')); save_png(ORM, os.path.join(out, 'body_orm_pre.png'), False)
    return [dict(region='scales (height, UV)', source='row rule: record scales.lateral_line, body-area size pass'),
            dict(region='lateral line (height, UV)', source='record scales.ll_frac')]
