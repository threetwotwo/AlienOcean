"""Stage 8b, SWIM (numpy + node): the swim and breathing clips and the swim settings the engine reads, from the record's own gait.

Nothing here invents a gait. The motion is the project's swim engine (motion/swim.js v18, ported verbatim from project files
motion/swim/v18, md5 ff051ba7; gaits.json md5 5b229329): the record's body wave z = A L e^(alpha (s - 1)) sin(2 pi (s / lam - phase))
behind the rigid front, Lighthill recoil, the chain keeping its bone lengths, Bainbridge's offset beat law, the opercles breathing.
This module only builds the engine's motion model from the cage (as motion/swim/v18/make_model.js does from a glb: 64 stations,
body mass from the skin's width x depth, added mass from the full depth with fins) and samples it:

  swim_loop     one tail beat at the record's cruise speed (body.motion.U), steady command, tempo off, personality 1, breathing
                held (its period is not the beat's), so the last frame is the first: the clip loops
  breathe_loop  one breath at rest (U = 0): the opercles flare a quarter cycle after the throat (swim.js v12)

and writes the settings the school system asked for (amplitude envelope along the body, wavelength, beat frequency per BL/s, safe
pose limits) as glTF extras under "alien_ocean.swim".
"""
import json, math, os, subprocess, tempfile
import numpy as np
from .mesh import SKIN_TAGS
from . import rig

HERE = os.path.dirname(os.path.abspath(__file__)); MOTION = os.path.join(HERE, 'motion')
NS = 64            # stations along the body (make_model.js)
KEYS_PER_BEAT = 24  # DEFAULT: keys per tail beat (24 resolves a sine with no visible facets at 1 BL/s)
KEY_HZ = 120        # DEFAULT: and never fewer keys than this per second. Gary 28 Nov: no jitter anywhere. An engine plays a clip by
                    # straight lines between keys; at 24 keys a beat (43 Hz at 1.8 beats/s) every key is a kink in velocity, an
                    # acceleration spike a 120 Hz tick shows as a shudder (check JT1). Keys at the highest tick rate leave no kink between ticks
JT_RATES = (30, 60, 120, 144)   # DEFAULT: tick rates the clips are checked at (the girl's stress test runs 30/60/120; 144 Hz displays)
JT_MAX = 1.25       # DEFAULT: peak acceleration of a joint played by straight lines between keys, over the same clip's smooth (periodic
                    # cubic) curve, at every tick rate: a smooth clip is 1.0; 24 keys a beat at 120 Hz measured 3-4


# ---- fin chains trail the body (secondary motion). Observed on the reference rigs (Gary 28 Nov, viewer captures of commercial bony-fish
# rigs): caudal lobes lag and flex past the peduncle bend, pectorals flex along the blade. The rule is the same for every chain: a
# bone points at where its own tip was a little earlier, so it trails whatever its spine bone does (a beat, a turn, a start).
PAIRED_LAG_DEG = 55.0   # DEFAULT (deg of a beat): the delay of a paired fin's tip when the gait style carries no pecLag (gaits.json pecLag:
                        # the engine's own lag of a pectoral's second joint, 40-60 deg by style)
CAUDAL_LAG = 0.25       # DEFAULT (beats): the caudal tip's delay when the gait data carry no finLife.tailLag (gaits.json: 0.25, the engine's idle tail scull)
CAUDAL_FLEX = 0.25      # DEFAULT, ESTIMATE: share of the delayed tip's offset the caudal chain's last bones take up (1 = the tip stays where
                        # it was a delay ago: a rag; 0 = a board). 0.25 at the engine's 0.25-beat tail lag turns the trevally's lobes 19 deg
                        # and the fin's root 13 deg past the peduncle at cruise: "pronounced" on the captures, not measured from them
PAIRED_FLEX = 1.0       # DEFAULT, ESTIMATE: the same for paired fins (their base hardly sways at cruise: 2-9 deg at full share)
FLEX_MAX_DEG = 30.0     # DEFAULT: no chain bone turns further than this from its rest line (smooth limit, tanh)
RG1_MAX_PCT = 0.001     # DEFAULT (% BL): the most a head vertex may move against the head bone in the swim clip (0.001 % of 0.5 m is 5 um)
RG_LAG_MIN = 0.01       # DEFAULT (beats): a fin tip trails its rigid place by at least this
RG2_FLEX_MIN, RG3_FLEX_MIN = 0.3, 5.0   # DEFAULTS (deg): least peak flex of a paired fin's tip bone / a caudal lobe in the swim clip
RG_TIP_W_MIN = 0.5      # DEFAULT: the fin's edge vertices carry at least this weight on the chain's last bones (the bones move the card)


def chain_names(NB):
    """swim.js wants its chain as root, head, spine_* (sorted) and keeps root -> head -> the next joint on one straight line (its
    rigid front, sRigid). Our head bone is that whole front: root at the snout station, 'head' half way along the head bone, then one
    joint per station from the head's end to the tail tip (NB + 2 joints for NB bones), so the body wave starts at the head's end."""
    return ['root', 'head'] + [f'spine_{i:02d}' for i in range(2, NB + 2)]


def bone_joints(NB):
    """our spine bone -> the engine joint whose transform it takes (the head bone takes the root's: the rigid front turns as one)."""
    ch = chain_names(NB); return {f'spine_{i:02d}': ch[0 if i == 0 else i + 1] for i in range(NB)}


def model(C, V, raw_record, bone_list):
    """the engine's motion model (alien-swim-model-1), swim frame: snout +X, up +Y, z lateral, metres."""
    m = C['SL_mm'] / 1000.0; L = C['xend'] * m
    NB, xs = rig.spine_stations(C); names = chain_names(NB); xj = np.r_[xs[0], (xs[0] + xs[1]) / 2, xs[1:]]
    # record (x tail-ward, y up, z left) -> engine (snout +X, up +Y, left -Z: swim.js yawRate + turns toward -Z): a half turn
    # about y, a proper rotation (a reflection here would turn every turn clip the wrong way)
    to = lambda p: [-p[0] * m, p[1] * m, -p[2] * m]
    joints = [dict(name=names[i], parent=names[i - 1] if i else None, rest=to([xj[i], 0, 0])) for i in range(NB + 2)]
    ours = bone_joints(NB)
    for b in bone_list:
        if b['name'].startswith('opercle'): joints.append(dict(name=b['name'], parent=ours[b['parent']], rest=to(b['head'])))
    # stations (make_model.js): s along L; skin depth d and width w, full depth D with fins, all in L units
    skin = sorted(set(v for f, t in zip(C['faces'], C['ftag']) if t in SKIN_TAGS for v in f)); P = V[skin] * m
    allP = [P] + [np.array(f['V']) * m for f in C['fins'].values()]; A = np.vstack(allP)
    def slab(Q):
        k = np.clip((Q[:, 0] / L * NS).astype(int), 0, NS - 1); return k
    ks, ka = slab(P), slab(A); st = []
    for k in range(NS):
        q = P[ks == k]; a = A[ka == k]
        d = (q[:, 1].max() - q[:, 1].min()) / L if len(q) else 0.0; w = (q[:, 2].max() - q[:, 2].min()) / L if len(q) else 0.0
        D = (a[:, 1].max() - a[:, 1].min()) / L if len(a) else 0.0
        st.append(dict(s=(k + 0.5) / NS, body=math.pi / 4 * d * w, added=math.pi / 4 * D * D, D=D, d=d, w=w))
    body = raw_record.get('body', {}); motion = dict(body.get('motion', {}))
    if not motion: raise KeyError('body.motion: the record has no gait (swim engine needs A, alpha, lam, U, f)')
    rr = raw_record.get('record', {})
    sw = rr.get('swim') or raw_record.get('swim')
    if sw and isinstance(sw.get('skill'), (int, float)): motion['skill'] = sw['skill']
    return dict(format='alien-swim-model-1', plan=raw_record.get('plan'), label=body.get('label'), L=L, motion=motion, joints=joints,
                stations=st, breathing=rr.get('breathing'), finsRig={}, soft=[], src=dict(cage=C.get('species'), from_='creature_maker swim_clip'))


def fin_lag(clip, C, bone_list, lag, flex, loop=True, flex_max=FLEX_MAX_DEG):
    """the fin chains' frames, added to a body clip. clip = (names, rest, W, Q) of body_frames; bone_list holds rig.fin_bones (those
    with a 'fin' key); lag {fin: the tip's delay, in turns of the clip when it loops (one beat), else in keys}, flex {fin: share}.
    Rule, per chain bone b with tip point p (carried rigidly by the chain's spine bone) and u the unit line from the chain's root to
    p at rest: d = where p was (lag x (level + 1) / levels) of the clip ago, minus where it is, in the spine bone's frame; the bone's
    turn from rest is the rotation vector flex x (level + 1) / levels x (u x d) / |root -> p| (it moves the tip by that share of d
    across the line; the share grows along the chain, a fin is stiffest at its base, so the chain curls), limited smoothly to flex_max. Delays are whole keys, so the chain is as smooth as the body and a loop stays a loop; a clip that does not
    loop starts from rest (the delay reads the first key).
    Returns (clip with the fin bones as joints and '<bone>_end' joints at their tips, measures per bone: peak flex deg, the tip's lag
    in turns of the clip behind its rigid place, tip excursion in BL)."""
    from scipy.spatial.transform import Rotation as Rt
    names, rest, W, Q = clip; names = list(names); W = np.asarray(W, float); Q = np.asarray(Q, float); rest = np.asarray(rest, float)
    m = C['SL_mm'] / 1000.0; L = C['xend'] * m; to = lambda p: np.array([-p[0] * m, p[1] * m, -p[2] * m])
    NB, _ = rig.spine_stations(C); bj = bone_joints(NB); fb = [b for b in bone_list if b.get('fin')]; by = {b['name']: b for b in fb}
    nF = len(W); n = nF - 1 if loop else nF; back = lambda k: (np.arange(nF) - k) % n if loop else np.maximum(np.arange(nF) - k, 0)
    cap = math.radians(flex_max); st = {}; addN, addR, addW, addQ = [], [], [], []; meas = {}
    for b in sorted(fb, key=lambda b: b['level']):
        root = b
        while root['parent'] in by: root = by[root['parent']]
        ps = names.index(bj[root['parent']]); Rs = Rt.from_quat(Q[:, ps]); h0 = to(root['head']); hb, tb = to(b['head']), to(b['tail'])
        ln = float(np.linalg.norm(tb - h0)); u = (tb - h0) / ln
        carried = W[:, ps] + Rs.apply(tb - rest[ps])                                  # the tip, were the fin a board
        k = int(round(lag[b['fin']] * (b['level'] + 1) / b['levels'] * n)) if loop else int(round(lag[b['fin']] * (b['level'] + 1) / b['levels']))
        d = Rs.inv().apply(carried[back(k)] - carried)
        om = flex[b['fin']] * (b['level'] + 1) / b['levels'] * np.cross(u, d) / ln; a = np.linalg.norm(om, axis=1, keepdims=True)
        om = om * np.where(a > 1e-12, cap * np.tanh(a / cap) / np.maximum(a, 1e-12), 1.0); Rb = Rt.from_rotvec(om)
        if b['parent'] in by: pl, pR, ph = st[b['parent']]; hl = pl + pR.apply(hb - ph)       # its head rides the bone before it
        else: hl = np.broadcast_to(h0, (nF, 3))
        st[b['name']] = (hl, Rb, hb)
        end = W[:, ps] + Rs.apply(hl + Rb.apply(tb - hb) - rest[ps])
        addN += [b['name'], b['name'] + '_end']; addR += [hb, tb]; addW += [W[:, ps] + Rs.apply(hl - rest[ps]), end]; addQ += [(Rs * Rb).as_quat()] * 2
        meas[b['name']] = dict(flex_peak_deg=round(float(np.degrees(np.linalg.norm(Rb.as_rotvec(), axis=1).max())), 3),
                               tip_lag_turns=round(_lag(carried, end, loop), 4) if loop else None,
                               tip_swing_BL=round(float(np.ptp(end, 0).max() / 2 / L), 5), fin=b['fin'], level=b['level'])
    if not fb: return (names, rest, W, Q), meas
    return (names + addN, np.vstack([rest, np.array(addR)]), np.concatenate([W, np.stack(addW, 1)], 1), np.concatenate([Q, np.stack(addQ, 1)], 1)), meas


def _lag(ref, act, loop=True):
    """turns of the clip by which act trails ref (first harmonic, along the line ref swings most on); 0 when either stands still."""
    r = ref[:-1] - ref[:-1].mean(0); a = act[:-1] - act[:-1].mean(0)
    if np.abs(r).max() < 1e-12 or np.abs(a).max() < 1e-12: return 0.0
    ax = np.linalg.svd(r, full_matrices=False)[2][0]; n = len(r); k = np.exp(-2j * np.pi * np.arange(n) / n)
    hr, ha = np.sum((r @ ax) * k), np.sum((a @ ax) * k)
    if abs(ha) < 1e-12 * max(abs(hr), 1e-300): return 0.0
    return float(((np.angle(hr) - np.angle(ha)) / (2 * np.pi) + 0.5) % 1.0 - 0.5)


def joint_mats(clip):
    """{joint name: (frames, 4, 4)} the transform that carries a rest point (engine frame, metres) to its posed place."""
    from scipy.spatial.transform import Rotation as Rt
    names, rest, W, Q = clip; out = {}
    for i, nm in enumerate(names):
        R = Rt.from_quat(np.asarray(Q)[:, i]).as_matrix(); M = np.zeros((len(R), 4, 4)); M[:, :3, :3] = R; M[:, 3, 3] = 1
        M[:, :3, 3] = np.asarray(W)[:, i] - R @ np.asarray(rest[i]); out[nm] = M
    return out


def rig_checks(C, V, Wt, bone_list, SW, fin_fault=None, head=None):
    """RG1-RG3 on the swim clip (numpy, the skinning an engine does):
    RG1  the head is rigid: no vertex ahead of the head's end moves against the head bone (linear blend skinning of the body weights
         Wt through every key; the jaw and cover bones ride the head bone in this clip)
    RG2  every paired fin has a chain of 2+ bones, its edge vertices are carried by the chain's later bones, and the tip trails
    RG3  the caudal fin has a root bone and two lobe bones, they carry the fin's edge, and the lobes trail the peduncle
    SW: swim_clip.clips() output (its swim clip with the fin joints, and the fin measures). head: the head's vertices when they are
    not the ones ahead of the head's end (a blockout's rigid blocks overlap across the joint: its head is the head bone's blocks)."""
    R = {}; m = C['SL_mm'] / 1000.0; L = C['xend'] * m; NB, xs = rig.spine_stations(C); bj = bone_joints(NB); M = joint_mats(SW['swim'])
    P = np.c_[-V[:, 0] * m, V[:, 1] * m, -V[:, 2] * m, np.ones(len(V))]; hd = V[:, 0] <= float(C['head_end']) if head is None else np.asarray(head, bool)
    par = {b['name']: b['parent'] for b in bone_list}; Wh = {}
    for nm, w in Wt.items():                                          # head bones that do not move in this clip ride their spine bone
        while nm not in bj: nm = par[nm]
        Wh[nm] = Wh.get(nm, 0) + np.asarray(w)[hd]
    Ph = P[hd]; sk = sum(w[None, :, None] * np.einsum('fij,vj->fvi', M[bj[nm]], Ph) for nm, w in Wh.items() if np.any(w))
    rigid = np.einsum('fij,vj->fvi', M[bj['spine_00']], Ph)
    R['RG1_head_end_SL'] = round(float(C.get('head_end', xs[1])), 4); R['RG1_head_verts'] = int(hd.sum())
    R['RG1_head_bend_pctBL'] = round(float(np.linalg.norm(sk - rigid, axis=-1).max() / L * 100), 5) if hd.any() else None
    R['RG1_limit_pctBL'] = RG1_MAX_PCT; R['RG1_pass'] = bool(hd.any() and R['RG1_head_bend_pctBL'] <= RG1_MAX_PCT)
    fm = SW.get('fin_measures', {}); fb = [b for b in bone_list if b.get('fin')]; rows2, rows3 = {}, {}
    for k in C['fins']:
        ch = [b for b in fb if b['fin'] == k]; paired = k.startswith(rig.PAIRED)
        if not paired and k != 'caudal': continue
        g = rig.fin_groups(C, k, fin_fault); T = np.asarray(C['fins'][k]['T'], float); edge = T >= T.max() - 1e-6
        last = [b['name'] for b in ch if b['level'] == max(c['level'] for c in ch)] if ch else []
        tw = float(sum(g.get(nm, np.zeros(len(T))) for nm in last)[edge].min()) if last else 0.0
        ms = [fm.get(nm, {}) for nm in last]; flex = min((q.get('flex_peak_deg', 0.0) for q in ms), default=0.0); lagt = min((q.get('tip_lag_turns') or 0.0 for q in ms), default=0.0)
        row = dict(bones=[b['name'] for b in ch], edge_weight_min=round(tw, 3), flex_peak_deg=flex, tip_lag_turns=lagt)
        fmin = RG2_FLEX_MIN if paired else RG3_FLEX_MIN
        row['pass'] = bool(len(ch) >= (2 if paired else 3) and tw >= RG_TIP_W_MIN and flex >= fmin and lagt >= RG_LAG_MIN and flex <= FLEX_MAX_DEG + 1e-6)
        (rows2 if paired else rows3)[k] = row
    R['RG2_paired'] = rows2; R['RG2_pass'] = all(r['pass'] for r in rows2.values())                 # a fish with no paired fins has none to flex
    R['RG3_caudal'] = rows3; R['RG3_pass'] = bool(rows3) and all(r['pass'] for r in rows3.values())
    R['RG_pass'] = bool(R['RG1_pass'] and R['RG2_pass'] and R['RG3_pass'])
    return R


def run_engine(M, U, seconds, fps, warm, breath=True, seed=1):
    M = dict(M)
    if not breath: M['breathing'] = dict(M.get('breathing') or {}, amp=0.0)
    with tempfile.TemporaryDirectory() as td:
        mp, op = os.path.join(td, 'm.json'), os.path.join(td, 'o.json')
        json.dump(M, open(mp, 'w')); json.dump(dict(U=U, seconds=seconds, fps=fps, warm=warm, seed=seed), open(op, 'w'))
        p = subprocess.run(['node', os.path.join(MOTION, 'clip_driver.js'), mp, op], capture_output=True, text=True, timeout=300)
        if p.returncode: raise RuntimeError('swim engine failed: ' + p.stderr[-800:])
        return json.loads(p.stdout)


def body_frames(R, M):
    """world joint transforms with the travel taken out: positions relative to the swim line's mass centre, then shifted so the
    root's mean over the clip sits on its rest point (the fish swims in place, its head sways about where it rests)."""
    fr = R['frames']; names = [j['name'] for j in M['joints']]; rest = np.array([j['rest'] for j in M['joints']])
    W = np.array([f['W'] for f in fr]); Q = np.array([f['Q'] for f in fr]); pos = np.array([f['pos'] for f in fr])
    W = W - pos[:, None, :] * np.array([1, 0, 1])
    shift = rest[0] - W[:, 0].mean(0); shift[1] = 0; W = W + shift
    return names, rest, W, Q


ENVELOPE_SPEEDS = (1.0, 1.5, 2.0)   # multiples of the loop speed (steady band), capped at the gait's Umax


def gait_style(M):
    """the gait style the engine itself resolves for this model (resolveGait in swim.js), so the bands read here are its own"""
    return run_engine(M, float(M['motion']['U']), 0.0, 30, 0.0, breath=False)['gait']


def envelope(W, rest, chain, L):
    """per chain joint: [s, half the sideways excursion over the beat in BL (recoil included), phase lag in turns behind the snout
    (first harmonic; recoil shifts it off the pure travelling wave, so a shader needs it per station, not only lam)]"""
    Z = W[:-1, :, 2]; n = len(Z); k = np.exp(-2j * np.pi * np.arange(n) / n)
    ph = np.unwrap(np.array([float(np.angle(np.sum(Z[:, i] * k))) for i in chain])); ph = (ph[0] - ph) / (2 * np.pi)
    return [[round(-rest[i][0] / L, 4), round(float((W[:, i, 2].max() - W[:, i, 2].min()) / 2 / L), 5), round(float(q), 4)]
            for i, q in zip(chain, ph)]


def clips(C, V, raw_record, bone_list, checks=None, fin_fault=None):
    M = model(C, V, raw_record, bone_list); mo = M['motion']
    U_rec = float(mo['U'])
    G = json.load(open(os.path.join(MOTION, 'gaits.json')))
    gs = gait_style(M); g = dict(G['styles'][gs]); g = {**G['styles'].get(g.get('base', ''), {}), **g}
    # the engine swims a steady, beat-periodic body wave only once the gait's body-wave band is fully on (Ulab + UlabBand); below it
    # it swims burst-and-coast phrases (v16, Videler & Weihs 1982), which no single-beat loop can hold. The loop and the envelopes
    # are taken in the steady band: at the record cruise when that is in it, else at the band's floor.
    U_steady = round(float(g.get('Ulab', 0.0)) + float(g.get('UlabBand', 0.0)), 4)
    U = max(U_rec, U_steady)
    # one beat at cruise: the engine's own f(U) after the warm-up
    probe = run_engine(M, U, 0.5, 60, 4.0, breath=False)
    f = float(probe['frames'][-1]['f']); T = 1.0 / f; fps = max(KEYS_PER_BEAT, math.ceil(KEY_HZ / f)) * f
    R = run_engine(M, U, T, fps, 4.0, breath=False)
    swim = body_frames(R, M)
    # the fin chains trail the body: delays in beats from the engine's own gait data, where it carries them
    fl = G.get('finLife', {}); lag_p = float(g.get('pecLag', PAIRED_LAG_DEG)) / 360.0; lag_c = float((g.get('finLife') or fl).get('tailLag', CAUDAL_LAG))
    lag = {b['fin']: (lag_p if b['fin'].startswith(rig.PAIRED) else lag_c) for b in bone_list if b.get('fin')}
    flex = {k: (PAIRED_FLEX if k.startswith(rig.PAIRED) else CAUDAL_FLEX) * (0.0 if fin_fault == 'board' else 1.0) for k in lag}
    body_swim = swim; swim, fin_meas = fin_lag(swim, C, bone_list, lag, flex)
    # one breath at rest
    Rb0 = run_engine(M, 0.0, 0.2, 30, 0.0, breath=True); br = float(Rb0['breathRate'])
    Tb = 1.0 / br; fpsb = max(24, math.ceil(KEY_HZ * Tb)) / Tb
    Rb = run_engine(M, 0.0, Tb, fpsb, 6.0 * Tb, breath=True)
    breathe = body_frames(Rb, M)
    names, rest, W, Q = body_swim; NB, _ = rig.spine_stations(C); L = M['L']
    chain = [names.index(n) for n in chain_names(NB)]
    env = envelope(W, rest, chain, L)
    loop_err = float(np.abs(W[-1] - W[0]).max() / L)
    loop_err_all = loop_err
    # the same measurement at other speeds, so a shader can blend shapes (alpha_law and the low-speed amp_law change the shape,
    # not only its scale): one beat each, same warm-up
    by_speed = []
    for Uk in sorted({round(min(U * k, float(g.get('Umax', 9e9))), 4) for k in ENVELOPE_SPEEDS}):
        if abs(Uk - U) < 1e-9:
            by_speed.append(dict(U_BLps=U, beat_Hz=round(f, 4), rows=env, loop_closure_BL=round(loop_err, 6))); continue
        fk = float(run_engine(M, Uk, 0.5, 60, 4.0, breath=False)['frames'][-1]['f'])
        Rk = run_engine(M, Uk, 1.0 / fk, max(KEYS_PER_BEAT, math.ceil(KEY_HZ / fk)) * fk, 4.0, breath=False)
        _, rk, Wk, _ = body_frames(Rk, M)
        ek = float(np.abs(Wk[-1] - Wk[0]).max() / L); loop_err_all = max(loop_err_all, ek)
        by_speed.append(dict(U_BLps=Uk, beat_Hz=round(fk, 4), rows=envelope(Wk, rk, chain, L), loop_closure_BL=round(ek, 6)))
    assert R['gait'] == gs, (R['gait'], gs)
    ext = dict(
        version=1, units=dict(length='BL (body length, snout to tail end)', speed='BL/s', angle='deg'),
        body_length_m=round(L, 5), engine='motion/swim.js v18 (project swim engine, ported verbatim)', gait=R['gait'],
        record_motion=mo, record_motion_source=mo.get('src', 'record body.motion'),
        steady=dict(U_min_BLps=U_steady, U_rec_BLps=U_rec, U_loop_BLps=U,
                    rule='at or above U_min the engine swims a steady body wave (swim_loop, envelopes_by_speed); below it it swims burst-and-coast phrases (beats then a glide, motion/swim.js v16), so a loop or a steady shader wave is not the engine there'),
        clips=dict(swim_loop=dict(U_BLps=U, beat_Hz=round(f, 4), beats=1, seconds=round(T, 5), loop=True, loop_closure_BL=round(loop_err, 6)),
                   breathe_loop=dict(U_BLps=0.0, breath_Hz=round(br, 4), seconds=round(Tb, 5), loop=True),
                   gape=dict(seconds=1.0, peak_deg=None), flare=dict(seconds=1.0, peak_deg=None)),
        wave=dict(formula='z(s) = A_U * exp(alpha_U * (s - 1)) * sin(2 pi (s / lam - phase)), s = 0 snout .. 1 tail, behind s_rigid; Lighthill recoil removes sideways momentum and moment',
                  A_BL=mo.get('A'), alpha=mo.get('alpha'), lam_BL=mo.get('lam'), s_rigid=round(float(R['sRigid']), 4),
                  amplitude_envelope_BL=env, envelope_columns=['s', 'half sideways swing BL (recoil included)', 'phase lag turns behind the snout'],
                  envelopes_by_speed=by_speed,
                  envelopes_by_speed_rule='rows as amplitude_envelope_BL, measured from the engine at each U (alpha_law, amp_law and recoil included); blend linearly in U between the two nearest, hold the end rows outside the range; amplitude_envelope_BL is the steady.U_loop entry (the first)'),
        frame=dict(forward_axis_gltf=[-1, 0, 0], up_axis_gltf=[0, 1, 0], left_axis_gltf=[0, 0, 1], snout_at_origin=True,
                   s_of_vertex='s = position.x / body_length_m (glTF metres, snout 0 -> tail 1)'),
        beat_law=dict(formula='f(U) = f_rec * (c + U) / (c + U_rec)  (Bainbridge offset law, lessons swim v3)', f_rec_Hz=mo.get('f'), U_rec_BLps=U_rec,
                      c_BLps=R['fc'], stride_BL_per_beat=round(R['stride'], 4)),
        amp_law=dict(formula='A_U = A * clamp(ampMin + (1 - ampMin) * U / ampU1, 0, 1)', ampMin=g.get('ampMin'), ampU1=g.get('ampU1')),
        alpha_law=dict(formula='alpha_U = clamp(alpha - alphaSlope * (U - U_rec), alphaMin, alphaMax)', alphaSlope=mo.get('alphaSlope'),
                       alphaMin=mo.get('alphaMin'), alphaMax=mo.get('alphaMax')),
        playback=dict(rule='U >= steady.U_min: skinned, play swim_loop at rate f(U) / f(U_loop); shader, blend wave.envelopes_by_speed in U and take the beat from beat_law. Below steady.U_min the engine swims phrases (see steady.rule)'),
        Strouhal=mo.get('St'), slip=mo.get('slip'),
    )
    ext['rig'] = dict(head_end_SL=round(float(C['head_end']), 4) if 'head_end' in C else None, head_bone='spine_00',
                      rule='spine_00 is the rigid head (snout to head_end: the gill cover rear line, no further back than the pectoral base); the wave starts at its end. Fin chains (fin_<fin>_root.._tip, fin_caudal_root/_upper/_lower) trail the body in swim_loop: each bone points at where its tip was lag x (level + 1) / levels of a beat earlier, taking up flex of the offset, at most flex_max_deg',
                      fin_lag_beats={k: round(v, 4) for k, v in lag.items()}, fin_flex=flex, flex_max_deg=FLEX_MAX_DEG, fin_measures=fin_meas)
    if checks:
        ext['pose_limits'] = dict(SR1_safe=checks.get('SR1_safe'), real=dict(gape_deg=checks.get('real_gape_deg'), flare_deg=checks.get('real_flare_deg')),
                                  source='creature_maker check (SR1 stylized range: largest amplitude with no crossing, fold or crush), measured on the cage with pose.py deformers, NOT on the exported 10-bone skin: treat body limits as upper bounds')
    ext['jitter'] = dict(swim_loop=jitter(swim[2], fps), breathe_loop=jitter(breathe[2], fpsb), rule=f'JT1: peak joint acceleration played by straight lines between keys over the smooth curve, at {list(JT_RATES)} Hz, <= {JT_MAX}')
    ext['jitter']['JT1_pass'] = bool(ext['jitter']['swim_loop']['pass'] and ext['jitter']['breathe_loop']['pass'])
    return dict(model=M, swim=swim, breathe=breathe, fin_measures=fin_meas, swim_fps=fps, breathe_fps=fpsb, extras=ext, loop_err=loop_err_all)


def jitter(W, fps, rates=JT_RATES):
    """JT1 for one looping clip W (frames, joints, 3) keyed at fps: per tick rate, the peak joint acceleration when the clip is played
    by straight lines between keys (as engines play it), over the peak of the smooth periodic curve through the same keys."""
    from scipy.interpolate import CubicSpline
    W = np.asarray(W, float); n = len(W); T = (n - 1) / fps; tk = np.arange(n) / fps
    W = W.copy(); W[-1] = W[0]                                    # the loop's seam (closure error is reported apart)
    sp = CubicSpline(tk, W, bc_type='periodic', axis=0); out = {}
    for r in rates:
        t = np.arange(0, 2 * T, 1.0 / r)                          # two loops, so the seam is crossed
        lin = np.stack([np.stack([np.interp(t % T, tk, W[:, j, k]) for k in range(3)], -1) for j in range(W.shape[1])], 1)
        smo = sp(t % T)
        acc = lambda P: np.linalg.norm(np.diff(P, 2, axis=0), axis=-1) * r * r
        a_l, a_s = acc(lin), acc(smo); ratio = float((a_l.max(0) / np.maximum(a_s.max(0), 1e-12)).max())
        out[f'{r}Hz'] = round(ratio, 3)
    out['pass'] = max(v for k, v in out.items()) <= JT_MAX
    return out
