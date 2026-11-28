"""Stage 8, CHECKS: measured from the built outputs, written before judging; every check has a planted fault (--planted).

Cage checks (no Blender):
  P2  quads >= 95 %, worst corner (1st percentile) >= 20 deg
  P3  no non-manifold edges; open borders only at the eye openings
  P4  skin within 0.5 % SL (p95) / 2 % SL (max) of the form
  P5  skin UV: area with stretch in [0.8, 1.25] >= 95 %, no folded UV faces, no texel under two skin faces
  IC1 every part the record names exists; input faults and defaults listed
  EY1 eye rim radius within 5 % of the record eye
  EY2 the eyeball is no goggle: the cornea window stands 0.04-0.40 eye radii over its rim and clears the lens
  EA1 the skin round the eye (best plane of the 1.6-2.4 eye radii ring) faces no further up than the scans' line for the eye's height + 8 deg
  EA2 the eye's own aim lies in the range real eye discs keep to (up -6..12, forward 4..26 deg), and the eye sits true in its rim
  OP1 openings are topology: genus 2 (mouth -> throat -> two gill exits), 2 border loops (eyes), consistent winding,
      and the lips reach each gill slit through interior faces only
  OP2 every interior-only vertex lies inside the body (signed distance < -0.1 % SL)
  OP3 no fold (> 60 deg between neighbouring faces) outside the designed creases (rolls, junctions, commissures)
  FM1 the body loft is fair: no crease round a section and no ripple of the flank along the body (what the normal bake
      would write as stripes and bands)
Export checks (after Blender): P1 triangle budget + LODs, P6 the normal map carries the form, faces out, is the same on
both sides and is clean (1st percentile of normal z >= 0.8, at most 2 specks), P7 bones, P8 Khronos
validator, P11 silhouette against the ceiling frame (info), and the export stage's own rows:
  EX1 Blender's skinning at the real gape equals the stress test's gape pose (pose.gape) within 0.01 % SL, and the jaw moves
  EX2 the same for the gill covers at the real flare (pose.flare)
  EX3 every cavity and gill face is on the 'interior' material, and every LOD keeps interior faces (the mouth never turns see-through)
  EX4 clips swim_loop, breathe_loop, gape, flare exist; swim_loop closes (last frame = first within 1e-4 BL)
  EX5 collision: at least 3 hulls (a body that bends), >= 99 % of the form's inside covered, hull volume <= 1.3 x form volume
  EX6 the swim settings ride in the glTF (rig node extras alien_ocean.swim: envelope with phase, envelopes at >= 2 speeds, wavelength, beat law, clips)
  EX8 the eye shells (iris, lens, cornea, both eyes) stay inside their triangle budget: the eye's look is in its maps
  EX7 LOD chain by the Unreal-era intake rule (creature_meter K2 + export round trip X4): each level 2.5-6 x fewer triangles, switch distances stated
"""
import json, os, sys, math, copy, hashlib, subprocess
from collections import Counter, defaultdict, deque
import numpy as np
from PIL import Image
from .mesh import SKIN_TAGS, INNER_TAGS


def angles(V, f):
    P = V[f]; out = []
    for i in range(len(f)):
        a, b, c = P[i - 1], P[i], P[(i + 1) % len(f)]
        u, v = a - b, c - b; out.append(math.degrees(math.acos(np.clip(u @ v / (np.linalg.norm(u) * np.linalg.norm(v) + 1e-12), -1, 1))))
    return out


def face_normal(V, f):
    P = V[f]; n = np.cross(P[2] - P[0], P[-1] - P[1]) if len(f) == 4 else np.cross(P[1] - P[0], P[2] - P[0])
    return n / (np.linalg.norm(n) + 1e-12)


def expected_parts(a):
    fins = ['caudal'] + [m['name'] for m in a['fins']['median']] + [f'{n}_{s}' for n in ('pectoral', 'pelvic') if n in a['fins'] for s in 'LR']
    return dict(eyes=2, fins=sorted(fins))


def topology(C):
    F = C['faces']; E = Counter()
    for f in F:
        for i in range(len(f)): E[frozenset((f[i], f[(i + 1) % len(f)]))] += 1
    used = set(v for f in F for v in f)
    adj = defaultdict(list)
    for e, n in E.items():
        if n == 1: a, b = tuple(e); adj[a].append(b); adj[b].append(a)
    seen, loops = set(), 0
    for v in adj:
        if v in seen: continue
        loops += 1; st = [v]
        while st:
            x = st.pop()
            if x in seen: continue
            seen.add(x); st += adj[x]
    chi = len(used) - len(E) + len(F)
    D = Counter((f[i], f[(i + 1) % len(f)]) for f in F for i in range(len(f)))
    wind = sum(1 for (a, b), n in D.items() if n > 1)
    return dict(border_loops=loops, nonmanifold=sum(1 for n in E.values() if n > 2), genus=(2 - loops - chi) / 2, winding_faults=wind)


def passages(C):
    """for each gill slit: can the lips reach it through interior faces only?"""
    F, T = C['faces'], C['ftag']; inner = [k for k, t in enumerate(T) if t in INNER_TAGS]
    vf = defaultdict(list)
    for k in inner:
        for v in C['faces'][k]: vf[v].append(k)
    lips = set(C['rolls'][0]); start = [k for k in inner if lips & set(F[k])]
    seen = set(start); dq = deque(start)
    while dq:
        k = dq.popleft()
        for v in F[k]:
            for kk in vf[v]:
                if kk not in seen: seen.add(kk); dq.append(kk)
    reach = set(v for k in seen for v in F[k])
    slits = C['rolls'][2:2 + len(C.get('junctions', []))]
    return [bool(set(s) & reach) for s in slits]


def folds(C, V, limit=60):
    F, T = C['faces'], C['ftag']; designed = set()
    for r in C.get('rolls', []) + C.get('junctions', []):
        for a, b in zip(r, r[1:] + r[:1]): designed.add(frozenset((a, b)))
    for ch in C.get('commissures', []):
        for a, b in zip(ch[:-1], ch[1:]): designed.add(frozenset((a, b)))
    E = defaultdict(list)
    for k, f in enumerate(F):
        for i in range(len(f)): E[frozenset((f[i], f[(i + 1) % len(f)]))].append(k)
    by = Counter(); dmax = 0.0
    for e, ks in E.items():
        if len(ks) != 2: continue
        a = math.degrees(math.acos(np.clip(face_normal(V, F[ks[0]]) @ face_normal(V, F[ks[1]]), -1, 1)))
        if e in designed: dmax = max(dmax, a); continue
        if a > limit: by['-'.join(sorted((T[ks[0]], T[ks[1]])))] += 1
    return dict(by), dmax


UV_OVERLAP_RES = 512    # DEFAULT: the raster the overlap count is taken on (the smallest body map the maker ships)
UV_OVERLAP_MAX = 0      # DEFAULT: texels allowed under two skin faces. None: such a texel is baked twice and one face loses


def uv_overlap(C, res=UV_OVERLAP_RES):
    """texels whose centre lies inside more than one skin face (strictly inside: a shared edge is not an overlap). A fold
    shows as flipped faces, but one part of an island laid over another (a chart wrapped on itself, a flap over its lip)
    flips nothing, and only this count sees it."""
    cnt = np.zeros((res, res), np.int32)
    for f, t, uv in zip(C['faces'], C['ftag'], C['uv']):
        if t not in SKIN_TAGS: continue
        uv = np.array(uv) * res; x0, y0 = np.floor(uv.min(0)).astype(int); x1, y1 = np.ceil(uv.max(0)).astype(int)
        xs, ys = np.meshgrid(np.arange(max(x0, 0), min(x1 + 1, res)), np.arange(max(y0, 0), min(y1 + 1, res))); px, py = xs + 0.5, ys + 0.5
        inside = np.zeros(xs.shape, bool)
        for tr in ([(0, 1, 2)] if len(f) == 3 else [(0, 1, 2), (0, 2, 3)]):
            A = uv[list(tr)]; d = (A[1, 1] - A[2, 1]) * (A[0, 0] - A[2, 0]) + (A[2, 0] - A[1, 0]) * (A[0, 1] - A[2, 1])
            if abs(d) < 1e-12: continue
            w0 = ((A[1, 1] - A[2, 1]) * (px - A[2, 0]) + (A[2, 0] - A[1, 0]) * (py - A[2, 1])) / d
            w1 = ((A[2, 1] - A[0, 1]) * (px - A[2, 0]) + (A[0, 0] - A[2, 0]) * (py - A[2, 1])) / d
            inside |= (w0 > 1e-3) & (w1 > 1e-3) & (1 - w0 - w1 > 1e-3)
        cnt[ys[inside], xs[inside]] += 1
    return int((cnt > 1).sum())


# ---- eye aim. Source: the Species thread's 79 CC0 photogrammetry scans, plans/species_system/gapfill/README.md "Eye aim,
# round 1" and eye_aim_r1/skin_targets.json + gaze_report.json (meta).
EA1_LINE = (-57.4, 103.8)    # skin ring degrees above horizontal = a + b x eye height in the local body depth (79 species, r 0.84)
EA1_TOL = 8.0                # leave-one-out error of that line (7.7 over all scans, 8.0 inside the board's eye heights)
EA2_UP = (-6.0, 12.0)        # eye disc, degrees above horizontal: scan median 2, spread 8-10 (regression error 10.7; "noise 10-17 on dead scans")
EA2_FWD = (4.0, 26.0)        # eye disc, degrees toward the snout: scan median 14.3, IQR 10.2-19.6, error 7.8 -> median +- 1.5 errors
EA2_STATED_TOL = 3.0         # DEFAULT: a record that states its own aim (skeleton.eye.aim, or a gaze that is not the stand-in) is held to it within 3 deg
EA2_SEAT_MAX = 6.0           # DEFAULT: the rim's best plane within 6 deg of the aim. At 6 deg the iris shell's edge (1.12 eye radii) stands
                             # 0.12 eye radii off the rim, about what the exporter seats it under the rim (0.4 % SL): more shows as a cocked eye


def eye_aim_checks(C, V, form, rec):
    """EA1 the skin round the eye, EA2 the eye's own aim. Angles as the scans give them: up = degrees above horizontal,
    fwd = degrees toward the snout (x runs snout to tail, y up, z left)."""
    R = {}; E = rec['eye']
    up, fwd, _, h = form.skin_ring()
    tgt = E['skin_up'] if E.get('skin_up') is not None else EA1_LINE[0] + EA1_LINE[1] * h
    R['EA1_skin_up_deg'] = round(up, 1); R['EA1_skin_fwd_deg'] = round(fwd, 1); R['EA1_eye_height'] = round(h, 3)
    R['EA1_target_deg'] = round(float(tgt), 1); R['EA1_target_source'] = 'record skeleton.eye.skin_up' if E.get('skin_up') is not None else 'scan line from eye height'
    R['EA1_dev_deg'] = round(up - float(tgt), 1)
    # the fault is skin that faces further up than real skin at that eye height: the head falls away round the eye. Skin
    # under the band is listed, not failed: the line is no lower limit (same-genus scans sit up to 20 deg under it:
    # Caranx 2.2 at a line value of 14, Diodon 6.9 at 25, Chlorurus 8.7 at 23; a flat-sided head with a high eye is real)
    R['EA1_under_band'] = bool(R['EA1_dev_deg'] < -EA1_TOL)
    R['EA1_pass'] = bool(R['EA1_dev_deg'] <= EA1_TOL)
    ups, fwds, seat = [], [], []
    for e, rings in zip(C['eyes'], C['openings']['eye_rings']):
        n = np.array(e['n'], float); n /= np.linalg.norm(n); sg = e['side']
        ups.append(math.degrees(math.asin(n[1]))); fwds.append(math.degrees(math.atan2(-n[0], sg * n[2])))
        P = V[rings[-2]]; rn = np.linalg.svd(P - P.mean(0))[2][2]                  # the rim ring: the opening the shells sit in
        seat.append(math.degrees(math.acos(min(abs(float(rn @ n)), 1.0))))
    R['EA2_aim_up_deg'] = [round(v, 1) for v in ups]; R['EA2_aim_fwd_deg'] = [round(v, 1) for v in fwds]
    R['EA2_below_skin_deg'] = round(up - float(np.mean(ups)), 1)                   # scans: the disc aims 7.5 deg below the skin ring (median, n 48)
    R['EA2_seat_deg'] = [round(v, 1) for v in seat]
    st = E.get('aim') or {}
    bu = (st['up'] - EA2_STATED_TOL, st['up'] + EA2_STATED_TOL) if st.get('up') is not None else EA2_UP
    bf = (st['fwd'] - EA2_STATED_TOL, st['fwd'] + EA2_STATED_TOL) if st.get('fwd') is not None else EA2_FWD
    R['EA2_band_up'] = list(bu); R['EA2_band_fwd'] = list(bf)
    ok = lambda v, band: band[0] <= round(v, 1) <= band[1]                        # to 0.1 deg: an aim held at the band's edge is inside
    R['EA2_pass'] = bool(all(ok(v, bu) for v in ups) and all(ok(v, bf) for v in fwds) and max(seat) <= EA2_SEAT_MAX)
    return R


def eyeball_checks(C):
    """EY2: the cornea window's height over its rim lies in cage.eye.CORNEA_SAG (flat window .. goggles limit, from the
    old Eyes work) and the lens stays under it."""
    from .cage.eye import CORNEA_SAG
    o = [e.get('optics') for e in C['eyes']]
    if not all(o): return dict(EY2_pass=False, EY2_note='no eye optics in the cage')
    sag = [v['cornea_sag_R'] for v in o]; gap = [v['lens_under_cornea_R'] for v in o]
    return dict(EY2_cornea_sag_R=sag, EY2_lens_under_cornea_R=gap, EY2_pass=bool(all(CORNEA_SAG[0] <= v <= CORNEA_SAG[1] for v in sag) and min(gap) > 0))


EYE_SHELL_TRIS_MAX = 300    # DEFAULT: iris + lens + cornea of both eyes. The ceiling fish (the Nestaeric alfonsino) is about 8.8k
                            # triangles whole with its eyes a separate material; 300 is 3.4 % of that. The shells this replaces took 864

FM1_STEP = 0.00005      # DEFAULT: arc (SL) over which a crease is looked for: a tenth of a texel of the 2048 body map, so the
                        # rounding of a narrow back or keel (radius >= 0.1 % SL: under 3 deg over this arc) is not a crease
FM1_CREASE_MAX = 8.0    # DEFAULT: most the loft's normal may turn over FM1_STEP (deg). The 28 traced records: <= 3.1; straight
                        # lines between the rows of a traced section: 19 to 42 (export r5, stripes along the body, dark rims)
FM1_WINDOW = 0.06       # DEFAULT: a ripple is what is left of the flank normal's fore-aft angle after its mean over this length (SL)
FM1_RIPPLE_MAX = 1.5    # DEFAULT: rms of that ripple (deg). The 28 traced records: <= 1.0; a top view's trace jitter carried into
                        # the half-width: 2.9 (export r5, vertical bands)


def _loft_normal(form, P, e):
    g = np.stack([form.sd_body(P + v) - form.sd_body(P - v) for v in np.eye(3) * e], -1)
    return g / (np.linalg.norm(g, axis=-1, keepdims=True) + 1e-15)


FM1_ORBIT_GATED = False  # the periorbital tissue (PR #109) still leaves a crease where it meets the brow and snout (the boxy roof,
                         # 28-37 deg on the 28 traced fish): listed as FM1_orbit_crease_deg, gated once the head is held to the scan line


def form_fair(form):
    """FM1 on the record loft (the tissue round the eye set aside), with the tissue's own crease listed. See _form_fair."""
    orb = getattr(form, '_orb', None)
    try:
        form._orb = None; R = _form_fair(form)
    finally:
        form._orb = orb
    if orb is not None:
        T = _form_fair(form); R['FM1_orbit_crease_deg'] = T['FM1_crease_deg']; R['FM1_orbit_crease_at_xy'] = T['FM1_crease_at_xy']
        if FM1_ORBIT_GATED: R['FM1_pass'] = R['FM1_pass'] and T['FM1_crease_deg'] <= FM1_CREASE_MAX
    return R


def _form_fair(form):
    """FM1: the body loft (level 0, before plates) is fair. crease = the most its normal turns, in the section plane, over
    FM1_STEP of arc round a section (15 sections along the body); ripple = rms of the flank normal's fore-aft angle along
    the widest line, less its running mean over FM1_WINDOW. Both are zero on a smooth loft and neither needs a bake."""
    X = form.XEND; th = np.linspace(0, np.pi, 20001); crease = 0.0; at = None
    for x in np.linspace(0.08, 0.92, 15) * X:
        P = form.loft_point(np.full(th.shape, x), th); n = _loft_normal(form, P, 5e-6); n[:, 0] = 0
        n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-15
        arc = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
        j = np.clip(np.searchsorted(arc, arc + FM1_STEP), 0, len(th) - 1)
        t = np.degrees(np.arccos(np.clip((n * n[j]).sum(1), -1, 1))); k = int(t.argmax())
        if t[k] > crease: crease = float(t[k]); at = [round(float(x), 3), round(float(P[k, 1]), 3)]
    xs = np.arange(0.05 * X, 0.95 * X, 0.001); k = int(FM1_WINDOW / 0.001) | 1
    ax = np.degrees(np.arcsin(np.clip(_loft_normal(form, form.loft_point(xs, np.full(xs.shape, np.pi / 2)), 1e-4)[:, 0], -1, 1)))
    hp = ax - np.convolve(np.pad(ax, k // 2, mode='edge'), np.ones(k) / k, 'valid'); ripple = float(np.sqrt((hp ** 2).mean()))
    return dict(FM1_crease_deg=round(crease, 1), FM1_crease_at_xy=at, FM1_ripple_deg=round(ripple, 2),
                FM1_pass=crease <= FM1_CREASE_MAX and ripple <= FM1_RIPPLE_MAX)


def cage_checks(C, V, form, rec):
    R = {}; faces, tags = C['faces'], C['ftag']
    skin = [k for k, t in enumerate(tags) if t in SKIN_TAGS]
    q = [f for f in faces if len(f) == 4]; R['P2_quad_share'] = round(len(q) / len(faces), 3)
    Amin = np.array([min(angles(V, f)) for f in q]); R['P2_worst_corner_p1_deg'] = round(float(np.percentile(Amin, 1)), 1)
    edges = Counter()
    for f in faces:
        for i in range(len(f)): edges[tuple(sorted((f[i], f[(i + 1) % len(f)])))] += 1
    val = np.zeros(len(V), int)
    for a, b in edges: val[a] += 1; val[b] += 1
    R['P2_poles'] = int(np.sum((val != 4) & (val > 0))); R['P2_max_pole_valence'] = int(val.max())
    R['P2_pass'] = R['P2_quad_share'] >= 0.95 and R['P2_worst_corner_p1_deg'] >= 20
    border = [e for e, n in edges.items() if n == 1]; nonman = [e for e, n in edges.items() if n > 2]
    eyev = set(v for f, t in zip(faces, tags) if t == 'eye' for v in f)
    R['P3_border_edges'] = len(border); R['P3_nonmanifold_edges'] = len(nonman)
    R['P3_border_outside_eye_openings'] = int(sum(1 for a, b in border if not (a in eyev and b in eyev)))
    R['P3_pass'] = len(nonman) == 0 and R['P3_border_outside_eye_openings'] == 0
    rng = np.random.default_rng(0); pts = []
    for k in skin:
        P = V[faces[k]]
        for w in rng.dirichlet(np.ones(len(faces[k])), 6): pts.append(w @ P)
    d = np.abs(form.sd_full(np.array(pts)))
    R['P4_skin_to_form_p95_pctSL'] = round(float(np.percentile(d, 95)) * 100, 2); R['P4_max_pctSL'] = round(float(d.max()) * 100, 2)
    R['P4_pass'] = R['P4_skin_to_form_p95_pctSL'] <= 0.5 and R['P4_max_pctSL'] <= 2.0
    cr = lambda a, b: a[0] * b[1] - a[1] * b[0]; ratio = []; flips = 0
    for k in skin:
        f, u, t = faces[k], np.array(C['uv'][k]), tags[k]; P = V[f]
        a3 = sum(np.linalg.norm(np.cross(P[i] - P[0], P[i + 1] - P[0])) for i in range(1, len(f) - 1)) / 2
        a2 = sum(abs(cr(u[i] - u[0], u[i + 1] - u[0])) for i in range(1, len(f) - 1)) / 2
        if a3 > 1e-12: ratio.append((a2 / a3, a3, float(t != 'eye')))
        s_ = 1 if V[f, 2].mean() >= 0 else -1
        for tri in ([(0, 1, 2)] + ([(0, 2, 3)] if len(f) == 4 else [])):
            a, b, c_ = u[list(tri)]
            if cr(b - a, c_ - a) * s_ <= 0: flips += 1; break
    r = np.array(ratio); r[:, 0] /= np.median(r[:, 0]); ok = (r[:, 0] > 0.8) & (r[:, 0] < 1.25)
    R['P5_stretch_ok_area'] = round(float((ok * r[:, 1]).sum() / r[:, 1].sum()), 3)
    bm = r[:, 2] > 0.5; R['P5_stretch_ok_area_without_eye_patch'] = round(float((ok * r[:, 1])[bm].sum() / r[:, 1][bm].sum()), 3)
    R['P5_uv_folded_faces'] = flips; R['P5_uv_md5'] = hashlib.md5(json.dumps(C['uv']).encode()).hexdigest()[:10]
    R['P5_uv_overlap_texels'] = uv_overlap(C); R['P5_uv_relaxed'] = all(v.get('relaxed') for v in C.get('uv_relax', {}).values())
    R['P5_pass'] = R['P5_stretch_ok_area'] >= 0.95 and flips == 0 and R['P5_uv_overlap_texels'] <= UV_OVERLAP_MAX
    exp = expected_parts(rec); got = dict(eyes=C['parts']['eyes'], fins=sorted(C['parts']['fins']))
    R['IC1_missing'] = sorted(set(exp['fins']) - set(got['fins'])) + (['eye'] * (exp['eyes'] - got['eyes']))
    R['IC1_input_faults'] = C.get('input_faults', []); R['IC1_defaults_used'] = C.get('defaults_used', [])
    R['IC1_pass'] = not R['IC1_missing'] and not R['IC1_input_faults']
    er = rec['eye']['d'] / 2; built = np.mean([e.get('r_side', e['r']) for e in C['eyes']])
    R['EY1_eye_radius_ratio'] = round(float(built / er), 3); R['EY1_pass'] = abs(built / er - 1) <= 0.05
    R.update(eye_aim_checks(C, V, form, rec)); R.update(eyeball_checks(C))
    tp = topology(C); ps = passages(C)
    R['OP1_topology'] = tp; R['OP1_lips_reach_each_gill'] = ps
    R['OP1_pass'] = tp['genus'] == 2 and tp['border_loops'] == 2 and tp['nonmanifold'] == 0 and tp['winding_faults'] == 0 and len(ps) == 2 and all(ps)
    skinv = set(v for k in skin for v in faces[k])
    deep = sorted(set(v for f, t in zip(faces, tags) if t in INNER_TAGS for v in f) - skinv)
    sd = form.sd_body(V[deep]) if deep else np.array([-1.0])
    R['OP2_interior_sd_max_pctSL'] = round(float(sd.max()) * 100, 3); R['OP2_outside'] = int((sd > -0.001).sum())
    R['OP2_pass'] = R['OP2_outside'] == 0
    by, dmax = folds(C, V)
    R['OP3_folds_by_region'] = by; R['OP3_folds'] = int(sum(by.values())); R['OP3_designed_crease_max_deg'] = round(dmax)
    R['OP3_pass'] = R['OP3_folds'] == 0
    R.update(form_fair(form))
    return R


def pose_checks(C, V, rec, jaw_w=None, sweep=True):
    """GP0 no crossing faces at rest; GP1 gape to the record's real gape and GF1 gill flare 0-20 deg add no crossings or flipped faces and
    leave the eye rims in place, and the lip tips part by the gape (GP1_opening_share); SR1 stylized range: gape, flare, C-bend, S-wave, arch and all at once each stay
    clean up to the species' own target x 1.3 (record gape, muscle strain limit for the body), poses it cannot make skipped (pose.py)."""
    from .pose import stress, range_sweep
    S = stress(C, V, rec, jaw_w=jaw_w)
    R = {'GP0_rest_crossings': S['rest_crossings'], 'GP0_pass': S['GP0_pass'], 'GP1_gape': S['gape'], 'GP1_opening_share': S['opening_share'], 'GP1_pass': S['GP1_pass'],
         'GF1_flare': S['flare'], 'GF1_pass': S['GF1_pass']}
    if sweep:
        R['SR1_range'] = range_sweep(C, V, rec, jaw_w=jaw_w)
        R['SR1_safe'] = {k: v.get('safe') for k, v in R['SR1_range'].items()}
        R['SR1_short'] = sorted(k for k, v in R['SR1_range'].items() if 'skipped' not in v and v['safe'] < v['target'])
        R['SR1_pass'] = not R['SR1_short']
    return R


P6_BACK_MAX = 1e-4      # DEFAULT: share of skin texels that may face into the skin (single rays at the tail pole); a face baked
                        # from the wrong side is hundreds of texels
P6_Z_P1_MIN = 0.8       # DEFAULT: 1st percentile of the tangent normal's z. Below it more than 1 % of the skin is tilted over 37 deg
                        # from the cage's own shading: the map is carrying shape the cage should (dark rims, export r5: 0.60; r3: 0.83)
P6_SPECKS_MAX = 2       # DEFAULT: isolated texels left after the bake's own speck repair (export r3: 1, r5: 13)
P6_SIDE_DEG, P6_SIDE_MAX = 25.0, 0.02   # DEFAULT: twin texels of the two sides may differ by more than 25 deg (the speck
                                        # limit) on at most 2 % of them (edges that fall on different texel rows)


P6_RELIEF_MIN = 0.10    # DEFAULT: a third of the body is expected to show tilt where at least this share of it has fine relief
                        # (scales) in the height map. Smooth naked skin on a fair loft that the cage follows bakes flat, and should:
                        # the pufferfish trunk showed 53 % tilt only while its traced tables were rippled (6 % once faired)


def p6(N, Mk, H=None):
    """the normal map carries the form: every third of the body that has fine relief (all of them when no height map H is
    given) has >= 10 % of texels tilted > 3 deg, at least one third does (a flat map is a failed bake), the map is not
    inverted and not carrying the cage's shape (1st percentile of z >= P6_Z_P1_MIN), at most P6_SPECKS_MAX isolated specks remain
    (> 25 deg from all 8 neighbours), no texel faces into the skin, and the two sides
    carry the same map. The left island lies in the upper half of the texture and the right island at the same place in
    the lower half (uv.py), so a texel and the one half a texture below it are twins on a body that is the same on both
    sides (every body the maker builds so far). A bake fault is never the same on both sides: the interior faces baked
    over the skin maps (0.3.0) made backwards patches on the cheek and throat of one side and the tail root of the other."""
    if Mk.shape != N.shape[:2]: Mk = np.asarray(Image.fromarray(Mk.astype(np.uint8) * 255).resize(N.shape[:2][::-1])) > 127
    Nn = N / (np.linalg.norm(N, axis=-1, keepdims=True) + 1e-9)
    tilt = Nn[..., 2] < np.cos(np.radians(3)); cols = np.where(Mk.any(0))[0]; a, b = cols.min(), cols.max()
    third = lambda A, k: A[:, a + k * (b - a) // 3: a + (k + 1) * (b - a) // 3][Mk[:, a + k * (b - a) // 3: a + (k + 1) * (b - a) // 3]]
    thirds = [float(third(tilt, k).mean()) for k in range(3)]
    if H is not None and H.shape != N.shape[:2]: H = np.asarray(Image.fromarray(H.astype(np.float32)).resize(N.shape[:2][::-1]))
    relief = [True] * 3 if H is None else [bool(float((third(H, k) > 0.05).mean()) >= P6_RELIEF_MIN) for k in range(3)]
    best = np.full(Nn.shape[:2], -1.0)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy or dx: best = np.maximum(best, (Nn * np.roll(np.roll(Nn, dy, 0), dx, 1)).sum(-1))
    specks = int((best < np.cos(np.radians(25)))[Mk].sum())
    zp1 = float(np.percentile(Nn[..., 2][Mk], 1)); back = int((Nn[..., 2][Mk] < 0).sum())
    h = N.shape[0] // 2; both = Mk[:h] & Mk[h:2 * h]; dot = (Nn[:h] * Nn[h:2 * h]).sum(-1)
    side = float((dot[both] < np.cos(np.radians(P6_SIDE_DEG))).mean()) if both.any() else 1.0
    twins = float(both.sum() / max(Mk.sum() / 2, 1))          # share of skin texels that have a twin: the islands are packed as twins
    return dict(P6_tilted_share_head_trunk_tail=[round(t, 3) for t in thirds], P6_specks=specks, P6_normal_z_p1=round(zp1, 3),
                P6_backward_texels=back, P6_sides_differ_share=round(side, 4), P6_twin_texel_share=round(twins, 3), P6_thirds_with_relief=relief,
                P6_pass=min(t for t, r in zip(thirds + [max(thirds)], relief + [True]) if r) >= 0.10 and specks <= P6_SPECKS_MAX and zp1 >= P6_Z_P1_MIN and back <= P6_BACK_MAX * Mk.sum() and side <= P6_SIDE_MAX and twins >= 0.95)


def validator(path):
    js = ("const v=require('gltf-validator');const fs=require('fs');v.validateBytes(new Uint8Array(fs.readFileSync(process.argv[1])))"
          ".then(r=>{console.log(JSON.stringify({errors:r.issues.numErrors,warnings:r.issues.numWarnings,infos:r.issues.numInfos,"
          "msgs:r.issues.messages.filter(m=>m.severity<2).slice(0,6).map(m=>m.code+' '+m.message)}))})")
    root = subprocess.run(['npm', 'root', '-g'], capture_output=True, text=True).stdout.strip()
    p = subprocess.run(['node', '-e', js, path], capture_output=True, text=True, env=dict(os.environ, NODE_PATH=root), timeout=120)
    try: return json.loads(p.stdout.strip().splitlines()[-1])
    except Exception: return dict(errors=-1, msgs=[p.stderr[-300:]])


def export_checks(out, st):
    R = {'P1_tris_total': st['tris_total'], 'P1_pass': st['tris_total'] <= 10000}
    lods = st.get('lods', {}); R['P1_lods'] = {k: v['tris'] for k, v in lods.items()}
    R['P1_lod_pass'] = bool(lods) and lods.get('LOD1', {}).get('tris', 1e9) <= 0.6 * st['tris_total'] and lods.get('LOD2', {}).get('tris', 1e9) <= 1000
    R['P7_bones'] = st['bones']; R['P7_pass'] = st['bones'] <= 24
    npath = os.path.join(out, 'body_normal.png')
    if os.path.exists(npath):
        N = np.asarray(Image.open(npath)).astype(float) / 127.5 - 1
        hp = os.path.join(out, 'body_height.npy')
        R.update(p6(N, np.load(os.path.join(out, 'body_mask.npy'))[::-1], np.load(hp)[::-1] if os.path.exists(hp) else None))
    for name in ('fish.glb', 'fish_LOD1.glb', 'fish_LOD2.glb'):
        if os.path.exists(os.path.join(out, name)): R[f'P8_validator_{name}'] = validator(os.path.join(out, name))
    R['P8_pass'] = all(v.get('errors', 1) == 0 for k, v in R.items() if k.startswith('P8_validator'))
    R.update(ex_checks(out, st))
    return R


def ex_checks(out, st):
    """EX1-EX7 (export stage) from glb_stats.json and the written fish.glb."""
    R = {}
    for k, tag in (('EX1', 'EX1_gape'), ('EX2', 'EX2_flare')):
        e, m = st.get(tag + '_max_err_pctSL'), st.get(tag + '_moved_pctSL', 0)
        R[k + '_err_pctSL'] = e; R[k + '_pass'] = e is not None and e < 0.01 and m > 0.1
    cp = os.path.join(out, 'cage.json'); want = None
    if os.path.exists(cp): want = sum(1 for t in json.load(open(cp))['ftag'] if t in INNER_TAGS)
    lods = st.get('lods', {})
    R['EX3_interior_faces'] = st.get('interior_faces'); R['EX3_lod_interior_tris'] = {k: v.get('interior_tris') for k, v in lods.items()}
    R['EX3_pass'] = bool(st.get('interior_faces')) and (want is None or st['interior_faces'] == want) and all((v.get('interior_tris') or 0) > 0 for v in lods.values())
    clips = st.get('clips', {})
    R['EX4_clips'] = sorted(clips); R['EX4_swim_loop_closure_BL'] = st.get('swim_loop_closure_BL')
    R['EX4_pass'] = {'swim_loop', 'breathe_loop', 'gape', 'flare'} <= set(clips) and (st.get('swim_loop_closure_BL') if st.get('swim_loop_closure_BL') is not None else 1) < 1e-4
    col = st.get('collision', {})
    R['EX5_collision'] = col
    R['EX5_pass'] = col.get('hulls', 0) >= 3 and col.get('coverage', 0) >= 0.99 and col.get('hull_over_form_volume', 9) <= 1.3
    gp = os.path.join(out, 'fish.glb'); sw = None
    if os.path.exists(gp):
        from .glbpatch import read
        js, _ = read(gp)
        sw = next((n['extras']['alien_ocean']['swim'] for n in js.get('nodes', []) if n.get('name') == 'rig' and 'alien_ocean' in n.get('extras', {})), None)
    elif 'swim_extras' in st: sw = st['swim_extras']
    R['EX8_eye_shell_tris'] = st.get('eye_shell_tris'); R['EX8_eye_patch_tris'] = st.get('eye_patch_tris')
    R['EX8_pass'] = st.get('eye_shell_tris') is not None and 0 < st['eye_shell_tris'] <= EYE_SHELL_TRIS_MAX
    need = ('wave', 'beat_law', 'clips')
    R['EX6_pass'] = bool(sw) and all(k in sw for k in need) and bool(sw['wave'].get('amplitude_envelope_BL')) and bool(sw['wave'].get('lam_BL')) \
        and len(sw['wave'].get('envelopes_by_speed') or []) >= 2 and all(len(r) == 3 for r in sw['wave']['amplitude_envelope_BL'])
    # EX7 the LOD chain follows the Unreal-era intake rule (creature_meter K2) and export round trip X4: each level 2.5-6 x fewer
    # triangles than the one before, every level built within 20 % of its count (fin and eye floors), switch distances stated (rising)
    ch = (st.get('lod_chain') or {}).get('levels') or []
    R['EX7_chain'] = [(c['lod'], c.get('tris_built', c['tris']), c['from_m']) for c in ch]
    R['EX7_pass'] = len(ch) >= 2 and all(2.5 <= ch[i - 1].get('tris_built', ch[i - 1]['tris']) / max(ch[i].get('tris_built', ch[i]['tris']), 1) <= 6.0
                                         and ch[i].get('tris_built', 1e9) <= 1.2 * ch[i]['tris'] and ch[i]['from_m'] > ch[i - 1]['from_m'] for i in range(1, len(ch)))
    return R


def planted(C0, V0, VN0, form, rec):
    """each planted fault must be caught by its check."""
    run = lambda c, v: cage_checks(c, v, form, rec); PL = {}
    c = copy.deepcopy(C0); c['parts']['fins'] = c['parts']['fins'][1:]; PL['IC1 (fin removed)'] = not run(c, V0)['IC1_pass']
    c = copy.deepcopy(C0); c['parts']['eyes'] = 1; PL['IC1 (eye removed)'] = not run(c, V0)['IC1_pass']
    sk = next(i for i, t in enumerate(C0['ftag']) if t == 'body'); v_ = C0['faces'][sk][0]
    V = V0.copy(); V[v_] += 0.05 * VN0[v_]; PL['P4 (skin vertex pulled 5 % SL)'] = not run(C0, V)['P4_pass']
    PL['OP3 (same pull folds the skin)'] = not run(C0, V)['OP3_pass']
    c = copy.deepcopy(C0); cap = [i for i, t in enumerate(c['ftag']) if t == 'cap']
    keep = [i for i in range(len(c['faces'])) if i not in set(cap)]
    for key in ('faces', 'ftag', 'uv'): c[key] = [c[key][i] for i in keep]
    PL['P3 (tail cap deleted)'] = not run(c, V0)['P3_pass']
    c = copy.deepcopy(C0); c['eyes'] = [dict(e, r=e['r'] * 0.8, r_side=e.get('r_side', e['r']) * 0.8) for e in c['eyes']]; PL['EY1 (eye 20 % small)'] = not run(c, V0)['EY1_pass']
    # EA2: the eye shells aimed 25 deg further up, as when the aim was the rim's own plane on a head that falls away
    def tip(n, a_=math.radians(25)): n = np.array(n, float); h_ = math.hypot(n[0], n[2]); e_ = math.atan2(n[1], h_) + a_; return [n[0] / h_ * math.cos(e_), math.sin(e_), n[2] / h_ * math.cos(e_)]
    c = copy.deepcopy(C0); c['eyes'] = [dict(e, n=tip(e['n'])) for e in c['eyes']]; PL['EA2 (eyes aimed 25 deg further up)'] = not eye_aim_checks(c, V0, form, rec)['EA2_pass']
    # EA1: the head leaning in round the eye (narrower above it, wider below: no volume round the eye), the skin's slope steeper by tan 40 deg
    class Leaning:
        def __init__(s_, f): s_.f = f
        def __getattr__(s_, k): return getattr(s_.f, k)
        def z_on(s_, x, y): return s_.f.z_on(x, y) - math.tan(math.radians(40)) * (y - s_.f.eyy)
        def skin_ring(s_): return type(s_.f).skin_ring(s_)
    PL['EA1 (head leaning in round the eye)'] = not eye_aim_checks(C0, V0, Leaning(form), rec)['EA1_pass']
    c = copy.deepcopy(C0); c['uv'] = [(np.array(u) * np.array([1, 1.6])).tolist() if i % 3 == 0 else u for i, u in enumerate(c['uv'])]
    PL['P5 (UV stretched 1.6x on 1/3 of faces)'] = not run(c, V0)['P5_pass']
    c = copy.deepcopy(C0); c['uv'][sk] = c['uv'][sk][::-1]; PL['P5 (one UV face folded)'] = run(c, V0)['P5_uv_folded_faces'] > 0
    c = copy.deepcopy(C0); gl = [i for i, t in enumerate(c['ftag']) if t == 'gill']; gl = set(gl[:len(gl) // 2])   # one passage removed
    keep = [i for i in range(len(c['faces'])) if i not in gl]
    for key in ('faces', 'ftag', 'uv'): c[key] = [c[key][i] for i in keep]
    PL['OP1 (one gill passage deleted)'] = not run(c, V0)['OP1_pass']
    deep = sorted(set(v for f, t in zip(C0['faces'], C0['ftag']) if t == 'cavity' for v in f) - set(v for f, t in zip(C0['faces'], C0['ftag']) if t in SKIN_TAGS for v in f))
    V = V0.copy(); V[deep[len(deep) // 2]] += np.array([0, 0, 0.2]); PL['OP2 (cavity vertex pushed out of the body)'] = not run(C0, V)['OP2_pass']
    from .pose import jaw_weights
    from .pose import triangles, self_intersections
    T_ = triangles(C0['faces']); base = self_intersections(V0, T_)[0]
    V = V0.copy(); cav = C0['openings']['cavity_rows'][3]; V[cav[len(cav) // 4]] += np.array([0, 0, 0.15])
    PL['GP0 (cavity vertex pushed through the cheek)'] = self_intersections(V, T_)[0] > base
    w = jaw_weights(C0, V0, rec); up = C0['openings']['mouth_rows'][1]
    for v in up[1:C0['openings']['jr'] - 1:2]: w[v] = 1.0       # upper-lip loop vertices wrongly bound to the jaw
    PL['GP1 (upper lip loop bound to the jaw)'] = not pose_checks(C0, V0, rec, jaw_w=w, sweep=False)['GP1_pass']
    ws = 0.5 + (jaw_weights(C0, V0, rec) - 0.5) * 0.6            # the gape smeared over the snout: lip tips at 0.2 and 0.8
    PL['GP1 (jaw weight that opens the mouth by 60 % of the gape)'] = not pose_checks(C0, V0, rec, jaw_w=ws, sweep=False)['GP1_pass']
    from .pose import range_sweep, gape_target
    PL['SR1 (upper lip loop bound to the jaw)'] = range_sweep(C0, V0, rec, jaw_w=w, only=['gape'])['gape']['safe'] < gape_target(rec)
    c = copy.deepcopy(C0); bodyf = [i for i, t in enumerate(C0['ftag']) if t == 'body']; a_, b_ = (np.array(c['uv'][bodyf[i]]) for i in (0, 40))
    c['uv'][bodyf[0]] = (a_ + b_.mean(0) - a_.mean(0)).tolist()
    PL['P5 (one skin face laid over another in UV)'] = run(c, V0)['P5_uv_overlap_texels'] > 0
    yy, xx = np.mgrid[0:64, 0:64]; g = np.sin(xx / 5.0) * 0.5; nm = np.dstack([g, np.cos(yy % 32 / 4.0) * 0.3, np.ones((64, 64))])   # the same relief on both halves
    PL['P6 planted baseline passes'] = p6(nm, np.ones((64, 64), bool))['P6_pass']
    n2 = nm.copy(); n2[40:52, 10:30] = [0, 0, 1.0]
    PL['P6 (flat panel baked on one side only)'] = p6(n2, np.ones((64, 64), bool))['P6_sides_differ_share'] > P6_SIDE_MAX
    n2 = nm.copy(); n2[8:12, 10:20] = [0.3, 0, -0.95]; n2[40:44, 10:20] = [0.3, 0, -0.95]
    PL['P6 (patch baked from the inside, facing into the skin)'] = p6(n2, np.ones((64, 64), bool))['P6_backward_texels'] > P6_BACK_MAX * 64 * 64
    PL['P6 (flat normal map)'] = not p6(np.dstack([np.zeros((64, 64)), np.zeros((64, 64)), np.ones((64, 64))]), np.ones((64, 64), bool))['P6_pass']
    n2 = nm.copy(); n2[4:28, 0:8] = [1.2, 0, 1.0]; n2[36:60, 0:8] = [1.2, 0, 1.0]
    PL['P6 (a rim tilted 50 deg on both sides: the map carries the cage\'s shape)'] = p6(n2, np.ones((64, 64), bool))['P6_normal_z_p1'] < P6_Z_P1_MIN
    n2 = nm.copy()
    for y_, x_ in ((5, 5), (9, 20), (14, 40)): n2[y_, x_] = n2[y_ + 32, x_] = [0.9, 0.9, 0.3]
    PL['P6 (three specks left on each side)'] = p6(n2, np.ones((64, 64), bool))['P6_specks'] > P6_SPECKS_MAX
    from .form import Form
    PL['FM1 planted baseline passes'] = form_fair(form)['FM1_pass']
    r2 = copy.deepcopy(rec); xk = np.arange(0.0, form.XEND + 1e-9, 0.02); hw0 = np.array(rec['outline']['hw'])
    r2['outline']['hw'] = [[float(x_), float(max(np.interp(x_, hw0[:, 0], hw0[:, 1]) + (0.006 if i % 2 else -0.006) * (0 < i < len(xk) - 1), 0.0))] for i, x_ in enumerate(xk)]
    PL['FM1 (half-width rippled by 0.6 % SL from knot to knot)'] = form_fair(Form(r2))['FM1_ripple_deg'] > FM1_RIPPLE_MAX
    f2 = Form(rec); ph = np.linspace(0, np.pi, 361); c_, s_ = np.abs(np.cos(ph)), np.sin(ph)       # a rhombus: a corner on the flank
    f2.SECT = dict(x=np.array([0.5]), s=np.linspace(-1, 1, 3), w=np.array([[0.0, 1.0, 0.0]]), phi=ph, rho=(1 / (c_ + s_))[None],
                   drho=(-(np.where(ph < np.pi / 2, -s_, s_) + np.cos(ph)) / (c_ + s_) ** 2)[None])
    PL['FM1 (section with a corner on the flank)'] = form_fair(f2)['FM1_crease_deg'] > FM1_CREASE_MAX
    flat = np.dstack([np.zeros((64, 64)), np.zeros((64, 64)), np.ones((64, 64))]); n2 = nm.copy(); n2[:, 22:42] = [0, 0, 1.0]
    Hs = np.ones((64, 64)); Hn = Hs.copy(); Hn[:, 22:42] = 0
    PL['P6 naked trunk (no relief in the height map) may bake flat'] = p6(n2, np.ones((64, 64), bool), Hn)['P6_pass']
    PL['P6 (scaled trunk baked flat)'] = not p6(n2, np.ones((64, 64), bool), Hs)['P6_pass']
    PL['P6 (flat normal map on naked skin all over)'] = not p6(flat, np.ones((64, 64), bool), np.zeros((64, 64)))['P6_pass']
    PL['P1 (40k tris)'] = not export_checks('/nonexistent', dict(tris_total=40000, bones=10))['P1_pass']
    good = dict(EX1_gape_max_err_pctSL=0.001, EX1_gape_moved_pctSL=6.0, EX2_flare_max_err_pctSL=0.001, EX2_flare_moved_pctSL=2.0,
                interior_faces=10, lods=dict(LOD1=dict(tris=1, interior_tris=5), LOD2=dict(tris=1, interior_tris=2)),
                clips=dict(swim_loop={}, breathe_loop={}, gape={}, flare={}), swim_loop_closure_BL=0.0,
                collision=dict(hulls=5, coverage=1.0, hull_over_form_volume=1.2), eye_shell_tris=252,
                lod_chain=dict(levels=[dict(lod=0, tris=8000, from_m=0.0), dict(lod=1, tris=2000, from_m=5.0, tris_built=1950), dict(lod=2, tris=500, from_m=10.0, tris_built=490)]),
                swim_extras=dict(wave=dict(amplitude_envelope_BL=[[0, 0.02, 0.0]], lam_BL=1.0, envelopes_by_speed=[{}, {}]), beat_law={}, clips={}))
    ex = lambda **kw: ex_checks('/nonexistent', {**good, **kw})
    PL['EX planted baseline passes'] = all(ex()[k] for k in ('EX1_pass', 'EX2_pass', 'EX3_pass', 'EX4_pass', 'EX5_pass', 'EX6_pass', 'EX7_pass', 'EX8_pass'))
    PL['EX8 (the old eye shells: two 24 x 5 domes an eye, 864 triangles)'] = not ex(eye_shell_tris=864)['EX8_pass']
    c = copy.deepcopy(C0)
    for e in c['eyes']: e['optics'] = dict(e['optics'], cornea_sag_R=0.7)          # the old builds' dome: 0.66-0.77 eye radii on every species
    PL['EY2 (cornea a dome 0.7 eye radii high: goggles)'] = not eyeball_checks(c)['EY2_pass']
    PL['EX1 (jaw skinned off the stress pose by 0.5 % SL)'] = not ex(EX1_gape_max_err_pctSL=0.5)['EX1_pass']
    PL['EX2 (covers never move)'] = not ex(EX2_flare_moved_pctSL=0.0)['EX2_pass']
    PL['EX3 (LOD2 lost the mouth interior)'] = not ex(lods=dict(LOD1=dict(tris=1, interior_tris=5), LOD2=dict(tris=1, interior_tris=0)))['EX3_pass']
    PL['EX4 (swim loop does not close)'] = not ex(swim_loop_closure_BL=0.01)['EX4_pass']
    PL['EX5 (one rigid hull for a bending body)'] = not ex(collision=dict(hulls=1, coverage=1.0, hull_over_form_volume=1.1))['EX5_pass']
    PL['EX6 (no swim settings in the glTF)'] = not ex(swim_extras=None)['EX6_pass']
    PL['EX7 (LOD1 only 2 x fewer triangles than LOD0)'] = not ex(lod_chain=dict(levels=[dict(lod=0, tris=8000, from_m=0.0), dict(lod=1, tris=2000, from_m=5.0, tris_built=4000)]))['EX7_pass']
    PL['EX6 (one speed only, no envelopes to blend)'] = not ex(swim_extras=dict(wave=dict(amplitude_envelope_BL=[[0, 0.02, 0.0]], lam_BL=1.0, envelopes_by_speed=[{}]), beat_law={}, clips={}))['EX6_pass']
    return PL


def check(out, record_path, with_planted=False, sweep=True):
    from .record import adapt
    from .form import Form
    C = json.load(open(os.path.join(out, 'cage.json'))); Z = np.load(os.path.join(out, 'cage.npz'))
    rec = adapt(record_path, C.get('style')); form = Form(rec)
    R = cage_checks(C, Z['V'], form, rec)
    R.update(pose_checks(C, Z['V'], rec, sweep=sweep))
    stp = os.path.join(out, 'glb_stats.json')
    if os.path.exists(stp): R.update(export_checks(out, json.load(open(stp))))
    R['P9_form_cage_s'] = round(C['stats']['build_s'] - C['stats']['bake_s'], 1); R['P9_pass'] = R['P9_form_cage_s'] < 60
    from .silhouette import silhouette_check
    R.update(silhouette_check(C, Z['V'], rec, record_path))      # SIL1: silhouette before detail
    if with_planted:
        R['PLANTED_caught'] = planted(C, Z['V'], Z['VN'], form, rec)
        from .silhouette import planted_sil
        R['PLANTED_caught'].update(planted_sil(C, Z['V'], rec))
        from .silhouette import planted_sil2
        R['PLANTED_caught'].update(planted_sil2(C, Z['V']))
    J = lambda o: bool(o) if isinstance(o, np.bool_) else (float(o) if isinstance(o, np.generic) else str(o))
    json.dump(R, open(os.path.join(out, 'checks.json'), 'w'), indent=1, default=J)
    return R
