"""Stage 8, CHECKS: measured from the built outputs, written before judging; every check has a planted fault (--planted).

Cage checks (no Blender):
  P2  quads >= 95 %, worst corner (1st percentile) >= 20 deg
  P3  no non-manifold edges; open borders only at the eye openings
  P4  skin within 0.5 % SL (p95) / 2 % SL (max) of the form
  P5  skin UV: area with stretch in [0.8, 1.25] >= 95 %, no folded UV faces, no texel under two skin faces
  IC1 every part the record names exists; input faults and defaults listed
  EY1 eye rim radius within 5 % of the record eye
  EY2 the eyeball is no goggle: the cornea window stands 0.04-0.40 eye radii over its rim and clears the lens
  EA1 the skin round the eye (best plane of the 1.6-2.4 eye radii ring) faces no further up than the scans' line for the eye's height + 8 deg,
      and the builder has not filled the head to more than 8 deg under it
  EA2 the eye's own aim lies in the range real eye discs keep to (up -6..12, forward 4..26 deg), and the eye sits true in its rim
  OP1 openings are topology: genus 2 (mouth -> throat -> two gill exits), 2 border loops (eyes), consistent winding,
      and the lips reach each gill slit through interior faces only
  OP2 every interior-only vertex lies inside the body (signed distance < -0.1 % SL)
  OP3 no fold (> 60 deg between neighbouring faces) outside the designed creases (rolls, junctions, commissures)
  FM1 the body loft is fair: no crease round a section and no ripple of the flank along the body (what the normal bake
      would write as stripes and bands)
  FM2 bone plates shape the skin as one surface: no wall anywhere on a plate (what the dense form would turn into a
      staircase and the bake into saw-toothed plate edges)
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
  FM3 (cage stage) the snout closes round (no flat front, no knife edge seen from above) and the lower jaw's ridge runs on under the gill cover
  EX9 a lining carries the skin's colour where it meets the skin (lips, gill slits): no pink or black line at a closed opening
  RG1 the head is rigid in the swim clip: no vertex ahead of the head's end (rig.head_end: the gill cover's rear line) moves against
      the head bone (linear blend skinning through every key); the bend starts behind the gill covers
  RG2 every paired fin has a chain of 2+ bones along its blade that carries its edge, and the tip trails its rigid place in the swim clip
  RG3 the caudal fin has a root bone and two lobe bones that carry its edge, and the lobes trail the peduncle
      (RG rows are measured here from the cage, numpy, when the record has a gait and node is installed; the exports write the same rows)
  EX11 the mouth's lining is lit with the mouth open: occlusion falls off into the throat, no flat floor, no dither
  EX10 the wall of the mouth is mucosa: gill red stays in the gill passages (no red streak on the floor of an open mouth)
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
EA1_FILL_TOL = 1.0          # DEFAULT (deg): under the band, the built skin ring may lie this far below the bare loft's (the swelling's run-out
                             # just reaches the ring's inner edge on some heads: 0.0-0.6 on the 28 traced fish)
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
    # two faults. Over the band: skin that faces further up than real skin at that eye height, the head falls away round
    # the eye. Under the band: a head fuller than the scans', if the builder made it so (the swelling round the eye, or the
    # head's turn, took the ring more than EA1_FILL_TOL below the record's own loft: PR #109 did that to 12 of the 28 traced fish).
    # A head the record's own sections draw under the band is listed (EA1_flat_by_record), not failed: the line is no lower
    # limit for a record (same-genus scans sit up to 20 deg under it: Caranx 2.2 at a line value of 14, Diodon 6.9 at 25,
    # Chlorurus 8.7 at 23; a flat-sided head with a high eye is real)
    bare = form.bare_skin_ring()[0]; R['EA1_bare_skin_up_deg'] = round(bare, 1)
    R['EA1_under_band'] = bool(R['EA1_dev_deg'] < -EA1_TOL)
    R['EA1_filled_by_builder'] = bool(R['EA1_under_band'] and up < bare - EA1_FILL_TOL)
    R['EA1_flat_by_record'] = bool(R['EA1_under_band'] and not R['EA1_filled_by_builder'])
    R['EA1_pass'] = bool(R['EA1_dev_deg'] <= EA1_TOL and not R['EA1_filled_by_builder'])
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


FM1_ORBIT_GATED = True   # the swelling round the eye is held to FM1 too. (PR #109's tissue left a crease where it met the brow and snout, the
                         # boxy roof: 28-37 deg on the 28 traced fish; the swelling that replaced it: <= 5.3 on the body's sections and
                         # on FM1_ORBIT_SECTIONS sections through the swelling itself)
FM1_ORBIT_SECTIONS = 13  # DEFAULT: sections through the swelling round the eye, evenly from its front end to its rear end


def form_fair(form):
    """FM1 on the record loft (the tissue round the eye set aside), with the tissue's own crease listed. See _form_fair."""
    orb = getattr(form, '_orb', None)
    try:
        form._orb = None; R = _form_fair(form)
    finally:
        form._orb = orb
    if orb is not None:
        T = _form_fair(form); cr, at = max((T['FM1_crease_deg'], T['FM1_crease_at_xy']), _orbit_crease(form, True))
        R['FM1_orbit_crease_deg'] = cr; R['FM1_orbit_crease_at_xy'] = at
        if FM1_ORBIT_GATED: R['FM1_pass'] = bool(R['FM1_pass'] and cr <= FM1_CREASE_MAX)
    return R


def _section_crease(form, xs):
    """the most the loft's normal turns, in the section plane, over FM1_STEP of arc round the sections at xs: (deg, [x, y])."""
    th = np.linspace(0, np.pi, 20001); crease = 0.0; at = None
    for x in xs:
        P = form.loft_point(np.full(th.shape, x), th); n = _loft_normal(form, P, 5e-6); n[:, 0] = 0
        n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-15
        arc = np.r_[0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
        j = np.clip(np.searchsorted(arc, arc + FM1_STEP), 0, len(th) - 1)
        t = np.degrees(np.arccos(np.clip((n * n[j]).sum(1), -1, 1))); k = int(t.argmax())
        if t[k] > crease: crease = float(t[k]); at = [round(float(x), 3), round(float(P[k, 1]), 3)]
    return round(crease, 1), at


def _orbit_crease(form, where=False):
    """FM1's crease on sections through the swelling round the eye (the body's 15 sections can all miss a small eye)."""
    w = form._orb['far'] * form.er; xs = np.clip(form.ex + np.linspace(-0.98, 0.98, FM1_ORBIT_SECTIONS) * w, 0.02 * form.XEND, 0.98 * form.XEND)
    c = _section_crease(form, np.unique(xs)); return c if where else c[0]


def _form_fair(form):
    """FM1: the body loft (level 0, before plates) is fair. crease = the most its normal turns, in the section plane, over
    FM1_STEP of arc round a section (15 sections along the body); ripple = rms of the flank normal's fore-aft angle along
    the widest line, less its running mean over FM1_WINDOW. Both are zero on a smooth loft and neither needs a bake."""
    X = form.XEND; crease, at = _section_crease(form, np.linspace(0.08, 0.92, 15) * X)
    xs = np.arange(0.05 * X, 0.95 * X, 0.001); k = int(FM1_WINDOW / 0.001) | 1
    ax = np.degrees(np.arcsin(np.clip(_loft_normal(form, form.loft_point(xs, np.full(xs.shape, np.pi / 2)), 1e-4)[:, 0], -1, 1)))
    hp = ax - np.convolve(np.pad(ax, k // 2, mode='edge'), np.ones(k) / k, 'valid'); ripple = float(np.sqrt((hp ** 2).mean()))
    return dict(FM1_crease_deg=crease, FM1_crease_at_xy=at, FM1_ripple_deg=round(ripple, 2),
                FM1_pass=crease <= FM1_CREASE_MAX and ripple <= FM1_RIPPLE_MAX)


FM2_STEP = 0.001        # DEFAULT: the skin is sampled half a cell of the dense form apart (SL)
FM2_SLOPE_MAX = 1.25    # DEFAULT: steepest rise of bone over the bare body, rise over run: form.PLATE_SLOPE (45 deg) and a quarter. A plate
                        # cut off square at its outline measures its whole step over one sample (6 for a 0.6 % SL step)


def plate_fair(form):
    """FM2: bone plates shape the skin as one surface. Thickness of bone over the bare body, sampled on the skin every
    FM2_STEP along the body and round the section across every plate: nowhere may it rise faster than FM2_SLOPE_MAX. A
    wall (a plate cut off square, an outline edge left out of its fade) is sharper than the dense form's 0.2 % SL cells
    carry: marching cubes makes a staircase of it and the bake writes saw teeth along the plate (export r6)."""
    if not getattr(form, 'PLATES', None): return dict(FM2_plate_slope_max=0.0, FM2_pass=True)
    x0 = max(min(p['poly'][:, 0].min() for p in form.PLATES) - 0.01, FM2_STEP); x1 = min(max(p['poly'][:, 0].max() for p in form.PLATES) + 0.01, form.XEND)
    xs = np.arange(x0, x1, FM2_STEP); X, TH = np.meshgrid(xs, np.linspace(0.01, np.pi - 0.01, 400), indexing='ij')
    S = form.loft_point(X.ravel(), TH.ravel()); T = form.plates(S)[0].reshape(X.shape); S = S.reshape(X.shape + (3,)); worst = 0.0; at = None
    for ax in (0, 1):
        q = np.abs(np.diff(T, axis=ax)) / np.maximum(np.linalg.norm(np.diff(S, axis=ax), axis=-1), 0.25 * FM2_STEP)
        if q.max() > worst: i, j = np.unravel_index(int(np.argmax(q)), q.shape); worst = float(q.max()); at = [round(float(X[i, j]), 4), round(float(np.degrees(TH[i, j])), 1)]
    return dict(FM2_plate_slope_max=round(worst, 2), FM2_plate_slope_at_x_theta=at, FM2_plate_step_max_pctSL=round(float(T.max()) * 100, 3),
                FM2_pass=worst <= FM2_SLOPE_MAX)


FM3_FRONT_MAX = 0.012    # DEFAULT: tallest flat front the snout may end in at x = 0 (SL): the two jaws' least thickness and their
                         # round (form.JAW_MIN + JAW_K each) and a fifth. The trevally's traced front, cut off square, was 4.8 % SL
FM3_NOSE_SHARE = 0.5     # DEFAULT: least radius of the snout's tip seen from above, as a share of the traced front's half-height (or of
                         # the widest round the top view's knots leave room for)
FM3_NOSE_X = 0.002       # DEFAULT: where that radius is read (SL): one cell of the dense form behind the tip
FM3_JAW_END_MIN = 0.5    # DEFAULT: least share of the lower jaw ridge still standing at the jaw joint, of its height half a ridge-width in front


def snout_fair(form):
    """FM3: the snout closes and the lower jaw's ridge runs on under the cover. (a) The loft's front at x = 0 is no taller
    than FM3_FRONT_MAX: a traced blunt snout cut off square there is a flat front with a corner over and under the lips.
    (b) Seen from above the tip is round: the circle through the tip and the half-width FM3_NOSE_X behind it has at least
    FM3_NOSE_SHARE of the radius the record asks for (half the traced front's height, or what the top view's knots leave
    room for); a wedge there is a knife edge down the front of the head. (c) At the jaw joint the mandible ridge still
    stands at FM3_JAW_END_MIN of its height half a ridge-width in front of it: ended on the joint it leaves a pit between
    jaw and gill cover."""
    from .form import pch, HW_MIN
    O = form.O; h0 = 0.5 * float(pch(O['top'])(0.0) - pch(O['bot'])(0.0)); k = np.array(O['hw'], float); k = k[k[:, 0] > 1e-6]
    want = max(min(h0, float(np.min((k[:, 1] ** 2 + k[:, 0] ** 2) / (2 * k[:, 0])))), 0.0)
    front = float(form.TOP(0.0) - form.BOT(0.0)); w = float(form.HW(FM3_NOSE_X)); rad = (w * w + FM3_NOSE_X ** 2) / (2 * FM3_NOSE_X)
    R = dict(FM3_front_height_pctSL=round(100 * front, 3), FM3_nose_radius_pctSL=round(100 * rad, 3), FM3_nose_radius_wanted_pctSL=round(100 * want, 3))
    ok = front <= FM3_FRONT_MAX and (want <= 2 * HW_MIN or rad >= FM3_NOSE_SHARE * want)
    md = [p for p in getattr(form, 'PLATES', []) if p['name'] == 'mandible']
    if md:
        # the ridge half a ridge-width in front of the joint against the ridge at the joint, each at its highest round the
        # underside (a jaw whose two lines close on each other toward the joint has little ridge at either place)
        xj = float(form.rec['jaw_joint'][0]); th = np.linspace(np.pi / 2, np.pi - 0.01, 240); k_ = 1 + [p['name'] for p in form.PLATES].index('mandible')
        def top(x):
            T, ids, _ = form.plates(form.loft_point(np.full(len(th), x), th)); m = ids == k_
            return (float(T[m].max()), float(th[m][np.argmax(T[m])])) if m.any() else (0.0, None)
        before, th0 = top(max(xj - 0.5 * md[0]['ridge'], md[0]['poly'][:, 0].min()))
        if th0 is not None and before > 1e-5:
            end = float(form.plates(form.loft_point(np.full(len(th), xj), th))[0][np.abs(th - th0) < 0.15].max())
            R['FM3_jaw_end_share'] = round(end / before, 2); ok = ok and end >= FM3_JAW_END_MIN * before
    R['FM3_pass'] = bool(ok); return R


EX9_DIFF_MAX = 0.06     # DEFAULT: most a lining's texel at a rim may differ from the skin's texel at the same vertex (linear RGB, 95th percentile)


def rim_colour(C, body_lin, int_lin, margin=0.02):
    """EX9: where a lining meets the skin (lips, gill slits) it carries the skin's colour. For every vertex shared by a skin
    face and an interior face: the interior map at that vertex's place in the interior island (remapped as blender/interior.py
    lays it out) against the skin map at its place in the skin island. Images: linear RGB, row 0 at the top."""
    inner = [t in INNER_TAGS for t in C['ftag']]
    rim = set(v for f, i in zip(C['faces'], inner) if i for v in f) & set(v for f, i in zip(C['faces'], inner) if not i for v in f)
    U = np.array([uv for f, i, u in zip(C['faces'], inner, C['uv']) if i for uv in u]); lo, hi = U.min(0), U.max(0)
    px = lambda img, u, v: img[int(np.clip((1 - v) * img.shape[0], 0, img.shape[0] - 1)), int(np.clip(u * img.shape[1], 0, img.shape[1] - 1)), :3]
    skin, own = {}, {}
    for f, uv, i in zip(C['faces'], C['uv'], inner):
        for v, (u_, v_) in zip(f, uv):
            if v not in rim: continue
            if i: own.setdefault(v, []).append(px(int_lin, margin + (1 - 2 * margin) * (u_ - lo[0]) / (hi[0] - lo[0]), margin + (1 - 2 * margin) * (v_ - lo[1]) / (hi[1] - lo[1])))
            else: skin.setdefault(v, []).append(px(body_lin, u_, v_))
    d = np.array([np.abs(np.mean(own[v], 0) - np.mean(skin[v], 0)).max() for v in rim if v in own and v in skin])
    if not len(d): return dict(EX9_rim_vertices=0, EX9_pass=False)
    return dict(EX9_rim_vertices=len(d), EX9_rim_colour_diff_p95=round(float(np.percentile(d, 95)), 3), EX9_rim_colour_diff_max=round(float(d.max()), 3),
                EX9_pass=float(np.percentile(d, 95)) <= EX9_DIFF_MAX)


EX10_RG_MAX = 1.7      # DEFAULT: most a cavity wall texel's red may stand over its green (linear). The stand-in mucosa reads 1.48
                       # (blender/interior.py MUCOSA), skin near 1.1, gill-filament red 8.4: a wall texel one part in ten gill red reads 1.75


def cavity_wall_colour(C, int_lin, margin=0.02):
    """EX10: the wall of the mouth is mucosa; gill red stays in the gill passages. The interior map is read inside every
    cavity face (its centre and each corner drawn a third of the way in), at its place in the interior island as
    blender/interior.py lays it out. Image: linear RGB, row 0 at the top."""
    inner = [t in INNER_TAGS for t in C['ftag']]
    U = np.array([uv for f, i, u in zip(C['faces'], inner, C['uv']) if i for uv in u])
    if not len(U): return dict(EX10_pass=False)
    lo, hi = U.min(0), U.max(0); H, W = int_lin.shape[:2]; rg = []
    for t, uv in zip(C['ftag'], C['uv']):
        if t != 'cavity': continue
        q = np.array(uv, float); c = q.mean(0)
        for p in [c] + [c + (k - c) * (2 / 3) for k in q]:
            u_, v_ = margin + (1 - 2 * margin) * (p - lo) / (hi - lo)
            px = int_lin[int(np.clip((1 - v_) * H, 0, H - 1)), int(np.clip(u_ * W, 0, W - 1)), :3]; rg.append(px[0] / max(px[1], 1e-3))
    if not rg: return dict(EX10_pass=False)
    rg = np.array(rg)
    return dict(EX10_cavity_red_over_green_max=round(float(rg.max()), 3), EX10_cavity_red_texels=int((rg > EX10_RG_MAX).sum()), EX10_pass=float(rg.max()) <= EX10_RG_MAX)


EX11_FLOOR = 0.2            # DEFAULT: an occlusion texel under this is at the floor (blender/interior.py clips at 0.15)
EX11_LIT_MIN = 0.12         # DEFAULT: least share of the mouth's wall behind the lip faces that the open mouth lights above the floor. Baked
                            # with the lips shut that wall is all floor but its first row
EX11_SPECK_MAX = 0.008      # DEFAULT: most of the interior island that may stand 0.25 or more off the median of its 5 x 5 texels: the dither of
                            # a bake where one ray in many gets out


def lining_light(C, int_ao, margin=0.02):
    """EX11: the mouth's lining is lit as it is seen, with the mouth open: its occlusion falls off into the throat, it is not
    one flat floor value, and it has no dither. int_ao: R of interior_orm.png (row 0 at the top), 0..1."""
    from scipy.ndimage import median_filter
    inner = [t in INNER_TAGS for t in C['ftag']]
    U = np.array([uv for f, i, u in zip(C['faces'], inner, C['uv']) if i for uv in u])
    if not len(U): return dict(EX11_pass=False)
    lo, hi = U.min(0), U.max(0); H, W = int_ao.shape[:2]; v = []
    rim = set(v_ for f, i in zip(C['faces'], inner) if i for v_ in f) & set(v_ for f, i in zip(C['faces'], inner) if not i for v_ in f)
    for t, uv, f in zip(C['ftag'], C['uv'], C['faces']):
        if t != 'cavity' or rim & set(f): continue        # behind the lip's own faces: those are lit as the skin they are
        q = np.array(uv, float); c = q.mean(0)
        for p in [c] + [c + (k - c) * (2 / 3) for k in q]:
            u_, v_ = margin + (1 - 2 * margin) * (p - lo) / (hi - lo); v.append(int_ao[int(np.clip((1 - v_) * H, 0, H - 1)), int(np.clip(u_ * W, 0, W - 1))])
    if not v: return dict(EX11_pass=False)
    lit = float((np.array(v) > EX11_FLOOR).mean()); speck = float((np.abs(int_ao - median_filter(int_ao, 5)) >= 0.25).mean())
    return dict(EX11_cavity_lit_share=round(lit, 3), EX11_speck_share=round(speck, 4), EX11_pass=lit >= EX11_LIT_MIN and speck <= EX11_SPECK_MAX)


def _lin(path):
    a = np.asarray(Image.open(path).convert('RGB'), float) / 255; return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)


PF_SIZE_TOL = 0.05      # DEFAULT: a traced paired fin's reach (first root to its farthest point) is the trace's within 5 %. Pushed
                        # out of the photo's plane by tan(out), the rule before, it was 15 % long at out 30
PF_FLAT_MAX = 25.0      # DEFAULT (deg): past its base a paired fin's blade is flat: no cell's normal more than this off the blade's
                        # mean (a fin laid round a flank turns a few deg; the cupped pelvic fins of export r6 turned 60-90)
PF_TURNED_MAX = 0.002   # DEFAULT: share of a paired fin's area that may be turned over (a sliver in a corner of the outline)
PF_ROOT_MAX = 20.0      # DEFAULT (deg): over the body a paired fin leaves the skin at no more than this (a sheet standing on the
                        # flank at its out angle is a slab with an open wedge behind it)


FN_TURNED_MAX = 0.015   # DEFAULT: share of a median fin's or the tail's side-view area that may be folded over. Rows relaxed to the
                        # mean of their neighbours folded 15 % of the trevally's second dorsal behind its lobe (the notch) and 1-29 %
                        # on 16 of 28 records; what is left with the Winslow grid is slivers where a traced outline dips under its
                        # own root row (trevally 1.1 %)


def fin_fold_check(C):
    """FN1: no median fin or caudal card is folded over in the side view (cells whose turn is against the card's)."""
    worst, at = 0.0, None
    for k, f in C['fins'].items():
        if k.startswith(('pectoral', 'pelvic')): continue
        P = np.asarray(f['V'], float)[:, :2]; Q = P[np.asarray(f['F'])]
        a = 0.5 * ((Q[:, 2, 0] - Q[:, 0, 0]) * (Q[:, 3, 1] - Q[:, 1, 1]) - (Q[:, 3, 0] - Q[:, 1, 0]) * (Q[:, 2, 1] - Q[:, 0, 1]))
        sh = float(np.abs(a[a * np.sign(a.sum()) < 0]).sum() / (np.abs(a).sum() + 1e-15))
        if sh > worst: worst, at = sh, k
    return dict(FN1_folded_area_share=round(worst, 4), FN1_worst_fin=at, FN1_pass=worst <= FN_TURNED_MAX)


def paired_sheets(C, rec):
    """the traced paired fins as built, {fin name: (rows + 1, columns, 3)}; the builder's fin record goes with each."""
    from .fins import EDGE_RAYS
    out = {}
    for n in ('pectoral', 'pelvic'):
        f = rec['fins'].get(n)
        if not f or not (f.get('edge') and f.get('base_line')): continue
        for s_ in 'LR':
            if f'{n}_{s_}' in C['fins']: out[f'{n}_{s_}'] = (np.array(C['fins'][f'{n}_{s_}']['V'], float).reshape(-1, EDGE_RAYS, 3), f)
    return out


def paired_fin_checks(sheets, form):
    """PF1 each paired fin stays on its own side of the midline (the pair never meets or crosses). PF2 its reach is the
    traced outline's (true size, not the side view stretched by its out angle). PF3 the sheet is not turned over (at most PF_TURNED_MAX
    of its area, a corner sliver) and its blade is flat (no cup). PF4 where it lies over the body it leaves the skin along the skin (no slab, no wedge)."""
    from .fins import PAIR_BASE
    R = {}; side, size, flat, turned, root = [], [], [], 0.0, []
    for name, (V, f) in sheets.items():
        sg = 1 if name.endswith('_L') else -1; side.append(float((sg * V[..., 2]).min()))
        E, B = np.asarray(f['edge'], float), np.asarray(f['base_line'], float)
        c2 = V[0, -1, :2] - V[0, 0, :2]; c2 /= np.linalg.norm(c2); sr = (V[0, :, :2] - V[0, 0, :2]) @ c2; o_ = np.argsort(sr)
        Q = V.copy(); Q[..., 2] -= np.interp((V[..., :2] - V[0, 0, :2]) @ c2, sr[o_], V[0, o_, 2])    # measured off the root line's own distance out (the flank's curve is not fin)
        size.append(float(np.linalg.norm(Q - Q[0, 0], axis=-1).max() / np.linalg.norm(E - B[0], axis=1).max()))
        n = np.cross(V[1:, 1:] - V[:-1, :-1], V[1:, :-1] - V[:-1, 1:]); a = np.linalg.norm(n, axis=-1); n = n / (a[..., None] + 1e-15)
        m = (n * a[..., None]).sum((0, 1)); m /= np.linalg.norm(m) + 1e-15; turned = max(turned, float(a[(n @ m) <= 0].sum() / a.sum()))
        # the blade: cells further from the root line (first root to last root) than the base is deep, with some room
        ax = V[0, -1] - V[0, 0]; ax /= np.linalg.norm(ax); W = V - V[0, 0]; dist = np.linalg.norm(W - (W @ ax)[..., None] * ax, axis=-1)
        dc = np.minimum(np.minimum(dist[1:, 1:], dist[:-1, :-1]), np.minimum(dist[1:, :-1], dist[:-1, 1:]))
        blade = (dc >= 1.25 * f.get('base_w', PAIR_BASE) * dist.max()) & (a > 1e-9); nb, ab = n[blade], a[blade]
        mb = (nb * ab[..., None]).sum(0); mb /= np.linalg.norm(mb) + 1e-15
        flat.append(float(np.degrees(np.arccos(np.clip(nb @ mb, -1, 1))).max()) if blade.any() else 0.0)
        # the second row of cells (the first dives under the skin to the root row) against the skin under it
        P = 0.5 * (V[1] + V[2]); P = 0.5 * (P[1:] + P[:-1]); x, y = np.clip(P[:, 0], 1e-4, form.XEND - 1e-4), P[:, 1]; e_ = 1e-4
        on = (y > form.BOT(x) + 2 * e_) & (y < form.TOP(x) - 2 * e_) & (np.abs(form.z_on(x, y)) > 0.01)
        if on.any():       # where the skin faces sideways more than down (under the belly a fin hangs from the skin, it does not lie on it)
            gx = (np.abs(form.z_on(x + e_, y)) - np.abs(form.z_on(x - e_, y))) / (2 * e_); gy = (np.abs(form.z_on(x, y + e_)) - np.abs(form.z_on(x, y - e_))) / (2 * e_)
            ns = np.stack([-gx, -gy, np.ones_like(gx)], -1); ns /= np.linalg.norm(ns, axis=1, keepdims=True); n1 = n[1] * np.array([1, 1, sg]); on &= a[1] > 1e-9
            ang = np.degrees(np.arccos(np.clip(np.abs((n1 * ns).sum(1)), 0, 1))); on &= np.abs(gy) < 1
            if on.any(): root.append(float(ang[on].max()))
    if not sheets: return R
    R['PF1_own_side_min_pctSL'] = round(min(side) * 100, 3); R['PF1_pass'] = min(side) > 0
    R['PF2_reach_over_trace'] = [round(min(size), 3), round(max(size), 3)]; R['PF2_pass'] = all(abs(v - 1) <= PF_SIZE_TOL for v in size)
    R['PF3_turned_area_share'] = round(turned, 4); R['PF3_blade_bend_deg'] = round(max(flat), 1); R['PF3_pass'] = turned <= PF_TURNED_MAX and max(flat) <= PF_FLAT_MAX
    R['PF4_root_to_skin_deg'] = round(max(root), 1) if root else None; R['PF4_pass'] = not root or max(root) <= PF_ROOT_MAX
    return R


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
    R.update(form_fair(form)); R.update(plate_fair(form)); R.update(snout_fair(form)); R.update(paired_fin_checks(paired_sheets(C, rec), form)); R.update(fin_fold_check(C))
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


P6_RIM_Z_MED_MIN = 0.985    # DEFAULT: the middle texel of the skin faces at a rim tilts at most 10 deg. Baked right: 4.4-6.8 deg (trevally, grouper,
                            # pufferfish, blenny, needlefish at 1024-2048 px, the proof record at 256); lips shaded with the lining: 15.2 deg


def rim_lean(C, V, VN, N):
    """P6, at the rims: the median tangent-normal z over the texels of skin faces that share a vertex with a lining (lips,
    gill slit lips; not the orbit linings, which are flat by design). Lip vertices shaded with the lining lean into the
    opening and the bake writes the opposite lean over all of every such face. The map-wide 1st percentile caught that
    only while plate walls used up most of its 1 %: with the walls gone the planted fault sat at 0.801 against the 0.8
    gate on the proof record. N: the normal map as saved (row 0 at the top)."""
    from .maps import raster
    sk = [k for k, t in enumerate(C['ftag']) if t in SKIN_TAGS]; iv = set(v for f, t in zip(C['faces'], C['ftag']) if t in INNER_TAGS for v in f)
    tuck = set(v for rings in C['openings'].get('eye_rings', []) for v in rings[-1])
    F = raster([C['faces'][k] for k in sk], [np.array(C['uv'][k]) for k in sk], V, VN, N.shape[0])[3][::-1]
    rim = np.isin(F, [i for i, k in enumerate(sk) if iv & set(C['faces'][k]) and not (C['ftag'][k] == 'eye' and tuck & set(C['faces'][k]))])
    if not rim.any(): return dict(P6_rim_texels=0, P6_rim_z_median=None, P6_rim_pass=False)
    z = N[..., 2][rim] / (np.linalg.norm(N[rim][:, :3], axis=1) + 1e-9); med = float(np.median(z))
    return dict(P6_rim_texels=int(rim.sum()), P6_rim_z_median=round(med, 3), P6_rim_pass=med >= P6_RIM_Z_MED_MIN)


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
        cj, cz = os.path.join(out, 'cage.json'), os.path.join(out, 'cage.npz')
        if os.path.exists(cj) and os.path.exists(cz):
            Zc = np.load(cz); R.update(rim_lean(json.load(open(cj)), Zc['V'], Zc['VN'], N[..., :3])); R['P6_pass'] = R['P6_pass'] and R['P6_rim_pass']
    for name in ('fish.glb', 'fish_LOD1.glb', 'fish_LOD2.glb'):
        if os.path.exists(os.path.join(out, name)): R[f'P8_validator_{name}'] = validator(os.path.join(out, name))
    R['P8_pass'] = all(v.get('errors', 1) == 0 for k, v in R.items() if k.startswith('P8_validator'))
    R.update(ex_checks(out, st))
    bp, ip, cp = (os.path.join(out, n) for n in ('body_base.png', 'interior_base.png', 'cage.json'))
    if all(os.path.exists(p_) for p_ in (bp, ip, cp)): R.update(rim_colour(json.load(open(cp)), _lin(bp), _lin(ip)))
    if all(os.path.exists(p_) for p_ in (ip, cp)): R.update(cavity_wall_colour(json.load(open(cp)), _lin(ip)))
    op = os.path.join(out, 'interior_orm.png')
    if all(os.path.exists(p_) for p_ in (op, cp)): R.update(lining_light(json.load(open(cp)), np.asarray(Image.open(op).convert('RGB'), float)[..., 0] / 255))
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


def planted_fins(C0, form, rec):
    """the fin cards' planted faults (FN1, PF1-PF4); C0 needs only its fins."""
    PL = {}
    fk = next(k for k in C0['fins'] if not k.startswith(('pectoral', 'pelvic'))); f_ = C0['fins'][fk]; fv = np.array(f_['V'], float); nc = f_['F'][0][3] - f_['F'][0][0]
    rows_ = fv.reshape(-1, nc, 3).copy(); rows_[[1, 2]] = rows_[[2, 1]]        # two rows of a median fin laid over each other
    PL['FN1 (two rows of a fin card swapped: the card folded over itself)'] = not fin_fold_check(dict(fins={fk: dict(f_, V=rows_.reshape(-1, 3))}))['FN1_pass']
    sh = paired_sheets(C0, rec)
    if sh:
        from .fins import paired_sheet
        fault = lambda kind, only=None: {n: (paired_sheet(form, f, 1 if n.endswith('_L') else -1, kind) if only is None or n.startswith(only) else v, f) for n, (v, f) in sh.items()}
        PL['PF planted baseline passes'] = all(v for k, v in paired_fin_checks(sh, form).items() if k.endswith('_pass'))
        old = paired_fin_checks(fault('project'), form)
        PL['PF2 (side-view outline pushed out by tan(out): the fin too long)'] = not old['PF2_pass']
        PL['PF3 (rows relaxed between root and outline, lifted by distance from the root: turned or cupped)'] = not old['PF3_pass']
        n0 = next(iter(sh)); v0, f0 = sh[n0]; v1 = v0.copy(); v1[..., 2] -= (1 if n0.endswith('_L') else -1) * (np.abs(v0[..., 2]).min() + 0.01)
        PL['PF1 (one fin moved 1 % SL across the midline)'] = not paired_fin_checks({**sh, n0: (v1, f0)}, form)['PF1_pass']
        if paired_fin_checks(sh, form)['PF4_root_to_skin_deg'] is not None and max(f['out'] for _, f in sh.values()) >= PF_ROOT_MAX + 10:
            PL['PF4 (the whole turn on the root line: a slab on the flank)'] = not paired_fin_checks(fault('hard'), form)['PF4_pass']
    return PL


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
    # EA1, the other side: tissue that fills the head round the eye (wider above it, narrower below), the skin's slope less by tan 40 deg
    class Filled(Leaning):
        def z_on(s_, x, y): return s_.f.z_on(x, y) + math.tan(math.radians(40)) * (y - s_.f.eyy)
    r_ = eye_aim_checks(C0, V0, Filled(form), rec); PL['EA1 (head filled out round the eye by the builder)'] = r_['EA1_filled_by_builder'] and not r_['EA1_pass']
    # FM1 on the swelling round the eye: its run-out cut off square a third of the way (a step round the eye)
    f3 = copy.copy(form); t3 = form._tissue
    def cut(x, u, cab=None):
        x, u = np.broadcast_arrays(np.asarray(x, float), np.clip(np.asarray(u, float), -1, 1)); c_, a_, _ = form.sec(x)
        return np.where(np.hypot(x - form.ex, c_ + a_ * u - form.eyy) < 1.2 * form.er, t3(x, u), 1.0)
    f3._tissue = cut
    PL['FM1 (the swelling round the eye cut off square)'] = _orbit_crease(f3) > FM1_CREASE_MAX
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
    flat_ = np.dstack([np.zeros((256, 256)), np.zeros((256, 256)), np.ones((256, 256))]); a_ = math.radians(15.2)
    PL['P6 rim planted baseline passes'] = rim_lean(C0, V0, VN0, flat_)['P6_rim_pass']
    PL['P6 (rim faces leaning 15 deg: lips shaded with the lining)'] = not rim_lean(C0, V0, VN0, flat_ * 0 + [math.sin(a_), 0, math.cos(a_)])['P6_rim_pass']
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
    PL['FM2 planted baseline passes'] = plate_fair(form)['FM2_pass']
    f3 = Form(rec)
    for p_ in f3.PLATES: p_['bevel'] = 0.0006                     # the old plates' edge: a wall rounded over 0.06 % SL
    PL['FM2 (plates cut off square at their free margins)'] = plate_fair(f3)['FM2_plate_slope_max'] > FM2_SLOPE_MAX
    f3 = Form(rec)
    for p_ in f3.PLATES: p_['buried'] = [l[:max(2, len(l) // 2)] for l in p_['buried']]      # half of each buried outline has no fade: a wall there
    PL['FM2 (a stretch of outline left out of the fade)'] = plate_fair(f3)['FM2_plate_slope_max'] > FM2_SLOPE_MAX
    # FM3: the same record with a blunt traced front (2 % SL over and under the mouth tip at x = 0, the top view starting at a point), with and without the rules
    from . import form as _fm
    rb = copy.deepcopy(rec); tip_ = min(rb['mouth']['line'], key=lambda q: q[0])[1]
    rb['outline']['top'][0][1] = max(rb['outline']['top'][0][1], tip_ + 0.02); rb['outline']['bot'][0][1] = min(rb['outline']['bot'][0][1], tip_ - 0.02); rb['outline']['hw'][0][1] = 0.0
    PL['FM3 planted baseline passes'] = snout_fair(Form(rb))['FM3_pass'] and snout_fair(form)['FM3_pass']
    _cap, _rnd = _fm.NOSE_CAP, _fm.NOSE_ROUND
    try:
        _fm.NOSE_CAP = 0.0; PL['FM3 (blunt snout cut off square at x = 0)'] = snout_fair(Form(rb))['FM3_front_height_pctSL'] > 100 * FM3_FRONT_MAX
        _fm.NOSE_CAP, _fm.NOSE_ROUND = _cap, 0.0; PL['FM3 (snout a wedge seen from above: a knife edge down the front)'] = not snout_fair(Form(rb))['FM3_pass']
    finally: _fm.NOSE_CAP, _fm.NOSE_ROUND = _cap, _rnd
    class _EndsOnJoint(Form): _jaw_ends_on_joint = True
    PL['FM3 (lower jaw ridge ended on the joint: a pit before the gill cover)'] = snout_fair(_EndsOnJoint(rec)).get('FM3_jaw_end_share', 0.0) < FM3_JAW_END_MIN
    sk_ = np.zeros((64, 64, 3)) + [0.45, 0.42, 0.30]
    PL['EX9 planted baseline passes'] = rim_colour(C0, sk_, sk_.copy())['EX9_pass']
    PL['EX9 (lining mucosa pink right from the rim)'] = not rim_colour(C0, sk_, np.zeros((64, 64, 3)) + [0.62, 0.42, 0.40])['EX9_pass']
    PL['EX10 planted baseline passes'] = cavity_wall_colour(C0, np.zeros((64, 64, 3)) + [0.62, 0.42, 0.40])['EX10_pass']
    PL['EX10 (gill red on the wall of the mouth)'] = not cavity_wall_colour(C0, np.zeros((64, 64, 3)) + [0.52, 0.235, 0.225])['EX10_pass']
    _ao = np.tile(np.linspace(1.0, 0.15, 64), (64, 1)); _rs = np.random.RandomState(3)
    PL['EX11 planted baseline passes'] = lining_light(C0, _ao)['EX11_pass']
    PL['EX11 (lining lit with the mouth shut: all floor)'] = not lining_light(C0, np.full((64, 64), 0.15))['EX11_pass']
    PL['EX11 (dither in the lining occlusion)'] = not lining_light(C0, np.where(_rs.rand(64, 64) < 0.05, 0.15, _ao))['EX11_pass']
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
    PL.update(planted_fins(C0, form, rec))
    return PL


def rig_check(C, V, rec, record_path, planted=False):
    """RG1-RG3 from the cage: the rig's bones and weights (rig.py) through the swim clip (swim_clip.py). planted: also the faults."""
    import shutil
    from . import rig, swim_clip
    raw = json.load(open(record_path))
    if shutil.which('node') is None or not raw.get('body', {}).get('motion'):
        return dict(RG_note='not measured: ' + ('node is not installed' if shutil.which('node') is None else 'the record has no gait (body.motion)'))
    def run(c=C, fin_fault=None, clip_fault=None):
        bl = rig.bones(c, V, rec) + rig.fin_bones(c); W, _ = rig.weights(c, V, rec)
        return swim_clip.rig_checks(C, V, W, bl, swim_clip.clips(c, V, raw, bl, fin_fault=clip_fault), fin_fault=fin_fault)
    try: R = run()
    except KeyError as e: return dict(RG_note=f'not measured: the record has no full gait (body.motion lacks {e})')
    R['RG_bones'] = len(rig.bones(C, V, rec) + rig.fin_bones(C))
    if planted:
        R['RG_planted'] = {'RG planted baseline passes': R['RG_pass'],
                           'RG1 (bones evenly from the snout, weights blended across the skull)': not run(dict(C, rig_fault='even'))['RG1_pass'],
                           'RG2 (a paired fin all on its root bone)': not run(fin_fault='rigid')['RG2_pass'],
                           'RG3 (the caudal fin all on its root bone)': not run(fin_fault='rigid')['RG3_pass'],
                           'RG2, RG3 (fin chains that do not trail: boards)': not (lambda r: r['RG2_pass'] or r['RG3_pass'])(run(clip_fault='board'))}
    return R


def check(out, record_path, with_planted=False, sweep=True):
    from .record import adapt
    from .form import Form
    C = json.load(open(os.path.join(out, 'cage.json'))); Z = np.load(os.path.join(out, 'cage.npz'))
    rec = adapt(record_path, C.get('style')); form = Form(rec)
    R = cage_checks(C, Z['V'], form, rec)
    R.update(pose_checks(C, Z['V'], rec, sweep=sweep))
    stp = os.path.join(out, 'glb_stats.json')
    if os.path.exists(stp): R.update(export_checks(out, json.load(open(stp))))
    rg = rig_check(C, Z['V'], rec, record_path, with_planted); rg_pl = rg.pop('RG_planted', {}); R.update(rg)
    R['P9_form_cage_s'] = round(C['stats']['build_s'] - C['stats']['bake_s'], 1); R['P9_pass'] = R['P9_form_cage_s'] < 60
    from .silhouette import silhouette_check
    R.update(silhouette_check(C, Z['V'], rec, record_path))      # SIL1: silhouette before detail
    if with_planted:
        R['PLANTED_caught'] = planted(C, Z['V'], Z['VN'], form, rec)
        R['PLANTED_caught'].update(rg_pl)
        from .silhouette import planted_sil
        R['PLANTED_caught'].update(planted_sil(C, Z['V'], rec))
        from .silhouette import planted_sil2
        R['PLANTED_caught'].update(planted_sil2(C, Z['V']))
    J = lambda o: bool(o) if isinstance(o, np.bool_) else (float(o) if isinstance(o, np.generic) else str(o))
    json.dump(R, open(os.path.join(out, 'checks.json'), 'w'), indent=1, default=J)
    return R
