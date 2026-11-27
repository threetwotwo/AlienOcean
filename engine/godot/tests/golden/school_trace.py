"""Golden trace for M31 (core/m31_school/school_sim.gd): the Nov 1 schooling paper's numpy prototype
(research/schooling/school.py, model "ao", step() copied line for line) with three changes so that the GDScript port
can be compared step for step:
  - y is up (school.py has z up): the depth band, pitch levelling, home tether and noise flattening use index 1;
  - random numbers come from the shared PCG hash stream (core/m31_school/school_rng.gd), drawn in school.py's order;
  - D1: the startle onset window is centred on the latency (LESSONS, schools v1), as the Unreal lab and the port do.
Usage: python3 tests/golden/school_trace.py tests/golden/school_v1.json
"""
import json, sys
import numpy as np

DT = 1.0 / 30.0
LAT_S = 2.0 / 30.0


class Rng:
    def __init__(self, seed):
        self.h = (seed * 2654435761 + 12345) & 0xFFFFFFFF

    def u32(self):
        self.h = (self.h * 747796405 + 2891336453) & 0xFFFFFFFF
        h = self.h
        w = (((h >> ((h >> 28) + 4)) ^ h) * 277803737) & 0xFFFFFFFF
        return (w >> 22) ^ w

    def uniform(self):
        return (self.u32() >> 8) * 5.9604644775390625e-8

    def integer(self, n):
        return min(int(self.uniform() * n), n - 1)

    def normal(self):
        u1 = self.uniform(); u2 = self.uniform()
        return np.sqrt(-2.0 * np.log(1.0 - u1)) * np.cos(2 * np.pi * u2)


def unit(v):
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(n, 1e-9)


OPEN = dict(v0=2.0, d0=1.1, la=5.0, lal=3.0, g_att=1.2, g_ali=2.6, eps=0.5, k=7, tau_v=0.8, k_speed=1.0, k_turn=2.2,
            wmax=np.radians(220), noise=0.25, vmin=0.15, fov=np.radians(300), depth=(3.0, 40.0), g_far=0.5, n_far=4,
            alert_T=15.0, alert_far=1.0, alert_ali=0.0, breathe=0.0)


class School:
    def __init__(self, p, N, seed):
        self.p = p; self.N = N; self.rng = Rng(seed)
        init = np.random.default_rng(seed)
        self.x = np.array([0.0, 15.0, 0.0]) + init.normal(0, 7.0 / 2.5, (N, 3)) * np.array([1, 0.4, 1])
        self.e = unit(np.array([1.0, 0.0, 0.2]) + init.normal(0, 0.5, (N, 3)) * np.array([1, 0.1, 1]))
        self.L = np.clip(init.normal(1.0, 0.05, N), 0.85, 1.15)
        self.v0i = p["v0"] * np.clip(init.normal(1.0, 0.04, N), 0.7, 1.3)
        self.v = self.v0i.copy()
        self.phase = init.uniform(0, 2 * np.pi, N)
        self.s = np.zeros(N); self.t_on = np.full(N, -99.0); self.t = 0.0
        self.cascade_dir = np.zeros((N, 3)); self.light = 1.0

    def poke(self, i):
        self.t_on[i] = self.t; self.s[i] = 1.0; self.cascade_dir[i] = self.e[i]

    def step(self, dt=DT):
        p, N, rng = self.p, self.N, self.rng
        k, nf = p["k"], p["n_far"]
        # random numbers in school.py's order (no breathing here): far integers, cascade uniforms, noise normals
        fj = np.array([rng.integer(N) for _ in range(N * nf)]).reshape(N, nf)
        cu = np.array([rng.uniform() for _ in range(N * k)]).reshape(N, k)
        nz0 = np.array([rng.normal() for _ in range(N * 3)]).reshape(N, 3)
        r = self.x[None, :, :] - self.x[:, None, :]
        d = np.linalg.norm(r, axis=-1); np.fill_diagonal(d, np.inf)
        rh = r / np.maximum(d[..., None], 1e-9)
        cosv = np.einsum("ik,ijk->ij", self.e, rh)
        blind = cosv < np.cos(p["fov"] / 2.0)
        vis = d.copy(); vis[blind] = np.inf
        light = self.light
        dv = np.zeros(N); S = np.zeros((N, 3))
        d0 = p["d0"]
        aT = p["alert_T"]
        al = np.clip(1.0 - (self.t - self.t_on) / aT, 0.0, 1.0)
        idx = np.argpartition(vis, k, axis=1)[:, :k]
        dk = np.take_along_axis(vis, idx, 1); ok = np.isfinite(dk); dk = np.where(ok, dk, 50.0)
        rhk = np.take_along_axis(rh, idx[..., None], 1); cvk = np.take_along_axis(cosv, idx, 1)
        ej = self.e[idx]; Lj = self.L[idx]
        w = np.where(ok, (Lj / np.maximum(dk, 0.3)) ** 2, 0.0); w = w / np.maximum(w.sum(1, keepdims=True), 1e-9)
        fa = p["g_att"] * (dk - d0) / (1.0 + (dk / p["la"]) ** 2) * (1.0 + p["eps"] * cvk)
        fa = np.where(dk < d0, fa * 3.0, fa)
        fl = p["g_ali"] * (1.0 + p["alert_ali"] * al)[:, None] * (dk + 0.3) * np.exp(-(dk / p["lal"]) ** 2) * 0.5 * (1.0 + cvk)
        ali = ej - np.einsum("ijk,ik->ij", ej, self.e)[..., None] * self.e[:, None, :]
        g = np.where(dk < 1.0, 1.0, light)[..., None]
        Sv = (w[..., None] * g * (fa[..., None] * rhk + fl[..., None] * ali)).sum(1)
        fr = self.x[fj] - self.x[:, None, :]
        fd = np.linalg.norm(fr, axis=-1)
        fe = np.einsum("ik,ijk->ij", self.e, fr / np.maximum(fd[..., None], 1e-9))
        fvis = (fe >= np.cos(p["fov"] / 2.0)) & (fd > 3.0)
        fw = np.where(fvis, 1.0 - np.exp(-(fd - 3.0) / 5.0), 0.0)
        gf = p["g_far"] * (1.0 + p["alert_far"] * al)
        Sv = Sv + (gf * light)[:, None] * (fw[..., None] * fr / np.maximum(fd[..., None], 1e-9)).sum(1) / nf
        par = np.einsum("ik,ik->i", Sv, self.e)
        dv += p["k_speed"] * par
        S += Sv - par[:, None] * self.e
        age = self.t - self.t_on[idx]
        fresh = ok & (age >= LAT_S - dt / 2) & (age < LAT_S + dt / 2)          # D1
        rank = np.argsort(np.argsort(-w, 1, kind="stable"), 1) + 1
        pr = 1.0 / (1.0 + np.exp(-0.302 + 1.421 * np.log(np.maximum(dk, 0.3)) + 0.126 * rank)) * light
        hit = fresh & (cu < pr)
        refr = (self.t - self.t_on) > 3.0
        trig = hit.any(1) & refr
        awayv = -(hit[..., None] * rhk).sum(1)
        self.cascade_dir = np.where(trig[:, None], unit(awayv), self.cascade_dir)
        # environment (y up)
        z = self.x[:, 1]
        zlo, zhi = p["depth"]
        up = np.clip((zlo + 2.0 - z) / 2.0, 0, None) - np.clip((z - (zhi - 2.0)) / 2.0, 0, None)
        S[:, 1] += 1.5 * up - 0.8 * self.e[:, 1]
        self.t_on = np.where(trig, self.t, self.t_on)
        self.s = np.maximum(self.s * np.exp(-dt / 0.25), trig.astype(float))
        cd = self.cascade_dir * (self.s > 0.5)[:, None] * 6.0
        S += cd - np.einsum("ik,ik->i", cd, self.e)[:, None] * self.e
        burst = self.s > 0.5
        S -= np.einsum("ik,ik->i", S, self.e)[:, None] * self.e
        wr = np.minimum(np.linalg.norm(S, axis=1) * p["k_turn"], np.where(burst, np.radians(900), p["wmax"]))
        ax = unit(S); ang = wr * dt
        self.e = unit(self.e * np.cos(ang)[:, None] + ax * np.sin(ang)[:, None])
        nz = nz0 * np.array([1, 0.35, 1]) * p["noise"] * (1.0 + 1.5 * (1.0 - self.light)) * np.sqrt(dt)
        nz -= np.einsum("ik,ik->i", nz, self.e)[:, None] * self.e
        self.e = unit(self.e + nz)
        v0 = np.where(burst, 8.0, self.v0i)
        dv += (v0 - self.v) / np.where(burst, 0.12, p["tau_v"])
        self.v = np.clip(self.v + dv * dt, p["vmin"] * p["v0"], 10.0)
        self.x += (self.v[:, None] * self.e) * dt
        dd = np.where(np.isfinite(d), d, 1e9)
        j = dd.argmin(1); dm = dd[np.arange(N), j]
        bad = dm < 0.3
        if bad.any():
            push = unit(self.x[bad] - self.x[j[bad]]) * ((0.3 - dm[bad]) * 0.5)[:, None]
            self.x[bad] += push
        f = (4.0 * self.v / self.L + 4.0) / 3.0
        self.phase = (self.phase + 2 * np.pi * f * dt) % (2 * np.pi)
        self.t += dt
        return int(trig.sum())


def main(out):
    N, seed, steps, poke_at = 60, 3, 90, 20
    S = School(OPEN, N, seed)
    init = dict(x=S.x.tolist(), e=S.e.tolist(), v=S.v.tolist(), L=S.L.tolist(), v0=S.v0i.tolist(), phase=S.phase.tolist())
    frames = []
    poke_i = 0
    for i in range(steps):
        if i == poke_at:
            poke_i = int(np.argmin(np.linalg.norm(S.x - S.x.mean(0), axis=1)))      # the fish nearest the middle
            S.poke(poke_i)
        ntrig = S.step()
        if i % 10 == 9 or i in (21, 22, 23, 24):
            frames.append(dict(step=i + 1, x=S.x.tolist(), e=S.e.tolist(), v=S.v.tolist(), trig=ntrig,
                               burst=int((S.s > 0.5).sum())))
    json.dump(dict(N=N, seed=seed, steps=steps, poke_at=poke_at, poke_i=poke_i, params=dict(OPEN, wmax=float(OPEN["wmax"]),
              fov=float(OPEN["fov"])), init=init, frames=frames), open(out, "w"))
    print("wrote", out, "bursting at end:", frames[-1]["burst"])


if __name__ == "__main__":
    main(sys.argv[1])
