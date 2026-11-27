"""The unrolled chart of the loft: (LEN, ARC) = 3D length along the body at constant theta, and arc length round the section.

Patches (eye, mouth loops) are laid out on this chart, which is near-isometric to the skin, then lifted to the loft. That is
why they do not fold where a side-view projection would be degenerate (lesson: x is not arc length at snout and tail).
"""
import numpy as np
from scipy.interpolate import LinearNDInterpolator


class Chart:
    def __init__(self, form):
        self.form = form; XEND = form.XEND; lp = form.loft_point
        self.ARCX = ARCX = np.linspace(0, XEND, 240); self.ARTH = ARTH = np.linspace(0, np.pi, 257)
        ARC = np.zeros((len(ARCX), len(ARTH)))
        for k, x in enumerate(ARCX):
            p = lp(np.full(ARTH.shape, x), ARTH); seg = np.linalg.norm(np.diff(p, axis=0), axis=1)
            ARC[k, 1:] = np.cumsum(seg)
        LEN = np.zeros_like(ARC)
        PG = np.stack([lp(np.full(ARTH.shape, x), ARTH) for x in ARCX])          # (x, theta, 3)
        TT = np.gradient(PG, axis=1); TT /= np.linalg.norm(TT, axis=-1, keepdims=True) + 1e-12
        DX = np.diff(PG, axis=0); Tm = 0.5 * (TT[1:] + TT[:-1])
        DX = DX - (DX * Tm).sum(-1, keepdims=True) * Tm                             # step along x, measured across the rings
        LEN[1:] = np.cumsum(np.linalg.norm(DX, axis=-1), axis=0)
        self.ARC, self.LEN = ARC, LEN
        XX, TT2 = np.meshgrid(ARCX, ARTH, indexing='ij')
        self._INV = LinearNDInterpolator(np.stack([LEN.ravel(), ARC.ravel()], -1), np.stack([XX.ravel(), TT2.ravel()], -1))

    def _lut(self, T, x, th):
        ARCX, ARTH, XEND = self.ARCX, self.ARTH, self.form.XEND
        th = np.where(th > np.pi, 2 * np.pi - th, th)
        fx = np.clip(x / XEND * (len(ARCX) - 1), 0, len(ARCX) - 1.001); fi = fx.astype(int); fa = fx - fi
        ft = np.clip(th / np.pi * (len(ARTH) - 1), 0, len(ARTH) - 1.001); ti = ft.astype(int); ta = ft - ti
        return ((1 - fa) * ((1 - ta) * T[fi, ti] + ta * T[fi, ti + 1]) + fa * ((1 - ta) * T[fi + 1, ti] + ta * T[fi + 1, ti + 1]))

    def arc_of(self, x, th): return self._lut(self.ARC, x, th)
    def len_of(self, x, th): return self._lut(self.LEN, x, th)
    def chart(self, x, th): return np.stack([self.len_of(x, th), self.arc_of(x, th)], -1)

    def unchart(self, ab, sg):
        """(len, arc) -> (x, theta) on the side sg (+1 left, -1 right)."""
        xt = self._INV(ab); th = xt[:, 1] if sg > 0 else 2 * np.pi - xt[:, 1]; return xt[:, 0], th
