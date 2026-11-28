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


def chain_names(NB):
    """swim.js wants its chain as root, head, spine_* (sorted); our bones are spine_00..spine_NB-1 plus the tail tip."""
    return ['root', 'head'] + [f'spine_{i:02d}' for i in range(2, NB + 1)]


def model(C, V, raw_record, bone_list):
    """the engine's motion model (alien-swim-model-1), swim frame: snout +X, up +Y, z lateral, metres."""
    m = C['SL_mm'] / 1000.0; L = C['xend'] * m
    NB, xs = rig.spine_stations(C); names = chain_names(NB)
    # record (x tail-ward, y up, z left) -> engine (snout +X, up +Y, left -Z: swim.js yawRate + turns toward -Z): a half turn
    # about y, a proper rotation (a reflection here would turn every turn clip the wrong way)
    to = lambda p: [-p[0] * m, p[1] * m, -p[2] * m]
    joints = [dict(name=names[i], parent=names[i - 1] if i else None, rest=to([xs[i], 0, 0])) for i in range(NB + 1)]
    ours = {f'spine_{i:02d}': names[i] for i in range(NB)}
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


def clips(C, V, raw_record, bone_list, checks=None):
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
    # one breath at rest
    Rb0 = run_engine(M, 0.0, 0.2, 30, 0.0, breath=True); br = float(Rb0['breathRate'])
    Tb = 1.0 / br; fpsb = max(24, math.ceil(KEY_HZ * Tb)) / Tb
    Rb = run_engine(M, 0.0, Tb, fpsb, 6.0 * Tb, breath=True)
    breathe = body_frames(Rb, M)
    names, rest, W, Q = swim; NB, _ = rig.spine_stations(C); L = M['L']
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
    if checks:
        ext['pose_limits'] = dict(SR1_safe=checks.get('SR1_safe'), real=dict(gape_deg=checks.get('real_gape_deg'), flare_deg=checks.get('real_flare_deg')),
                                  source='creature_maker check (SR1 stylized range: largest amplitude with no crossing, fold or crush), measured on the cage with pose.py deformers, NOT on the exported 10-bone skin: treat body limits as upper bounds')
    ext['jitter'] = dict(swim_loop=jitter(swim[2], fps), breathe_loop=jitter(breathe[2], fpsb), rule=f'JT1: peak joint acceleration played by straight lines between keys over the smooth curve, at {list(JT_RATES)} Hz, <= {JT_MAX}')
    ext['jitter']['JT1_pass'] = bool(ext['jitter']['swim_loop']['pass'] and ext['jitter']['breathe_loop']['pass'])
    return dict(model=M, swim=swim, breathe=breathe, swim_fps=fps, breathe_fps=fpsb, extras=ext, loop_err=loop_err_all)


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
