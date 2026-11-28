"""Smoke test: the proof record builds, its openings pass, and every planted fault is caught. Run: pytest creatures/maker/tests"""
import json, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE); sys.path.insert(0, ROOT)
from creature_maker.build import build
from creature_maker.checks import check

REC = os.path.join(ROOT, 'records', 'beryx_splendens.json')


def test_proof_record(tmp_path):
    out = str(tmp_path / 'beryx')
    build(REC, out, res=64, dense_form=False, log=lambda *a: None)
    R = check(out, REC, with_planted=True)
    assert R['OP1_pass'], R['OP1_topology']
    assert R['OP2_pass']
    assert R['P3_pass'] and R['IC1_pass'] and R['EY1_pass']
    assert all(R['PLANTED_caught'].values()), R['PLANTED_caught']
    assert R['SIL1_pass'] is False and R['SIL1_reference'] is None      # no traced outline for the proof record yet
    assert set(R['SR1_range']) == {'gape', 'flare', 'bend', 'wave', 'arch', 'combo'}


def test_style_deviation_reaches_the_form():
    from creature_maker.record import adapt
    a, b = adapt(REC), adapt(REC, dict(eye=1.5, mouth=1.2, girth=0.8))
    assert abs(b['eye']['d'] / a['eye']['d'] - 1.5) < 1e-9 and b['style'] == dict(eye=1.5, mouth=1.2, girth=0.8)
    assert abs(b['outline']['hw'][3][1] / a['outline']['hw'][3][1] - 0.8) < 1e-9


def test_export_rig_is_the_stress_pose(tmp_path):
    """the jaw and gill-cover bones skin the cage into exactly the stress test's poses (rig.skin == pose.gape / pose.flare), and a
    jaw pivot moved by 2 % SL is caught (planted)."""
    from creature_maker.record import adapt
    from creature_maker import rig
    out = str(tmp_path / 'beryx'); build(REC, out, res=64, dense_form=False, log=lambda *a: None)
    C = json.load(open(os.path.join(out, 'cage.json'))); V = np.load(os.path.join(out, 'cage.npz'))['V']; rec = adapt(REC, C.get('style'))
    bl = rig.bones(C, V, rec); W, info = rig.weights(C, V, rec)
    assert np.allclose(sum(W.values()), 1.0)
    g = rec.get('gape_deg', 30.0)
    assert np.abs(rig.skin(V, W, bl, {'jaw': g}) - rig.stress_pose(C, V, rec, 'gape', g)).max() < 1e-9
    assert np.abs(rig.skin(V, W, bl, {'opercleL': 23, 'opercleR': 23}) - rig.stress_pose(C, V, rec, 'flare', 23)).max() < 1e-9
    bad = [dict(b, pivot=[b['pivot'][0] + 0.02, b['pivot'][1], b['pivot'][2]]) if b['name'] == 'jaw' else b for b in bl]
    assert np.abs(rig.skin(V, W, bad, {'jaw': g}) - rig.stress_pose(C, V, rec, 'gape', g)).max() > 1e-3


def test_swim_clip_loops(tmp_path):
    """the swim engine on the cage: one beat at cruise closes on itself, the tail swings wider than the head, and the extras carry
    what the school system reads. The proof record has no gait yet, so this test lends it the trevally record's motion block
    (an ESTIMATE in that record too); a record without one must fail loudly."""
    import shutil, pytest
    if shutil.which('node') is None: pytest.skip('node not installed')
    from creature_maker.record import adapt
    from creature_maker import rig, swim_clip
    out = str(tmp_path / 'beryx'); build(REC, out, res=64, dense_form=False, log=lambda *a: None)
    C = json.load(open(os.path.join(out, 'cage.json'))); V = np.load(os.path.join(out, 'cage.npz'))['V']; rec = adapt(REC, C.get('style'))
    raw = json.load(open(REC)); bl = rig.bones(C, V, rec)
    with pytest.raises(KeyError): swim_clip.model(C, V, dict(raw, body={}), bl)
    raw['body'] = dict(raw.get('body', {}), motion=dict(A=0.1, alpha=3.4, lam=1.0, St=0.3, U=1.5, f=3.0, alphaSlope=0.6, alphaMin=2.8, alphaMax=4.4))
    R = swim_clip.clips(C, V, raw, bl)
    assert R['loop_err'] < 1e-4
    env = R['extras']['wave']['amplitude_envelope_BL']
    assert env[-1][1] > 2 * env[0][1] > 0
    for k in ('wave', 'beat_law', 'clips', 'amp_law'): assert k in R['extras']
    bs = R['extras']['wave']['envelopes_by_speed']          # shader blends between speeds: rising beat, U_rec entry = the main table
    assert len(bs) == 3 and [b['U_BLps'] for b in bs] == sorted(b['U_BLps'] for b in bs)
    assert bs[0]['beat_Hz'] < bs[1]['beat_Hz'] < bs[2]['beat_Hz'] and bs[0]['rows'] == env
    assert all(len(r) == 3 for b in bs for r in b['rows']) and bs[0]['rows'] != bs[2]['rows']
    assert all(b['loop_closure_BL'] < 1e-4 for b in bs)
    bw = R['extras']['beat_law']            # the published law reproduces every measured beat
    for b in bs: assert abs(bw['f_rec_Hz'] * (bw['c_BLps'] + b['U_BLps']) / (bw['c_BLps'] + bw['U_rec_BLps']) - b['beat_Hz']) < 2e-3
    # a cruise below the gait's steady band (the engine swims burst-and-coast there): the loop is taken at the band's floor and closes
    raw['body']['motion'] = dict(raw['body']['motion'], U=0.968, f=1.452)
    R2 = swim_clip.clips(C, V, raw, bl); st = R2['extras']['steady']
    bw = R2['extras']['beat_law']
    for b in R2['extras']['wave']['envelopes_by_speed']: assert abs(bw['f_rec_Hz'] * (bw['c_BLps'] + b['U_BLps']) / (bw['c_BLps'] + bw['U_rec_BLps']) - b['beat_Hz']) < 2e-3
    assert R2['loop_err'] < 1e-4 and st['U_loop_BLps'] == st['U_min_BLps'] > st['U_rec_BLps'] == 0.968


def test_traced_fin_outline_sets_the_silhouette(tmp_path):
    """a fin outline read off a reference goes into the record (skeleton.median.<fin>.edge) and the rebuilt fish matches
    that reference better than the guessed fins (heights and a lean) did: the record is the input, the outline the test."""
    from creature_maker.record import adapt
    from creature_maker import silhouette as S
    out = str(tmp_path / 'a'); build(REC, out, res=64, dense_form=False, log=lambda *a: None)
    C = json.load(open(os.path.join(out, 'cage.json'))); V = np.load(os.path.join(out, 'cage.npz'))['V']; rec = adapt(REC)
    ref = dict(side=S.outline_of(C, V), side_body=S.outline_of(C, V, fins=False))
    for m in rec['fins']['median']:                 # the "photo": every median fin 30 % taller than the record's guess
        a, b = m['base']; sg = 1 if m['top'] else -1
        ref['side'] = [[x, y * 1.3] if a - 0.02 <= x <= b + 0.08 and y * sg > 0 else [x, y] for x, y in ref['side']]
    before = S.score(C, V, rec, ref)['SIL1_iou']
    E = S.fin_edges(ref, rec); E.pop('_faults')
    D = json.load(open(REC)); SL = D['record']['outline']['end']; M = D['record']['skeleton']['median']
    key = {'dorsal1': 'd1', 'dorsal2': 'd2', 'anal': 'an', 'dorsal': 'd', 'caudal': 'caudal'}
    for k, P in E.items(): M[key[k]]['edge'] = [[x * SL, y * SL] for x, y in P]
    rp = str(tmp_path / 'traced.json'); json.dump(D, open(rp, 'w'))
    out2 = str(tmp_path / 'b'); build(rp, out2, res=64, dense_form=False, log=lambda *a: None)
    C2 = json.load(open(os.path.join(out2, 'cage.json'))); V2 = np.load(os.path.join(out2, 'cage.npz'))['V']
    after = S.score(C2, V2, adapt(rp), ref)['SIL1_iou']
    assert after > before and after >= 0.93, (before, after)


def test_skin_uv_islands_are_fold_free_twins(tmp_path):
    """the two halves of the skin flatten without a fold or an overlap, SLIM runs on both, and the right island is the
    left one half a texture lower (the bake's left/right check, P6, reads twin texels)."""
    from scipy.spatial import cKDTree
    out = str(tmp_path / 'beryx'); build(REC, out, res=64, dense_form=False, log=lambda *a: None)
    R = check(out, REC, sweep=False)
    assert R['P5_uv_folded_faces'] == 0 and R['P5_uv_overlap_texels'] == 0 and R['P5_uv_relaxed'] and R['P5_pass'], {k: v for k, v in R.items() if k.startswith('P5')}
    C = json.load(open(os.path.join(out, 'cage.json'))); V = np.load(os.path.join(out, 'cage.npz'))['V']
    side = lambda sg: np.array([uv for f, t, u in zip(C['faces'], C['ftag'], C['uv']) if t in ('body', 'eye', 'mouth', 'cap') and (V[f, 2].mean() >= 0) == (sg > 0) for uv in u])
    L, Rt = side(1), side(-1)
    assert L[:, 1].min() > 0.5 > Rt[:, 1].max()
    assert cKDTree(L - [0, 0.5]).query(Rt)[0].max() < 1.5 / 4096         # twins to within a texel and a half at 4K


def test_bake_keeps_interior_and_linings_off_the_skin_maps(tmp_path):
    """the export bake (Blender) on the proof record: no patch of the normal map faces into the skin and both sides carry the
    same map. Baking the cavity and gill passage faces into the skin's own image (they have their own UV island, laid over
    the skin's) put backwards patches on the cheek and throat of one side: P6 must be clean, and the same fault planted
    back (interior faces left on the skin's bake target) must be caught."""
    import shutil, subprocess, pytest
    pytest.importorskip('bpy')
    if shutil.which('node') is None: pytest.skip('node not installed (swim clips)')
    from creature_maker import checks
    from PIL import Image
    D = json.load(open(REC))          # the proof record has no gait yet: lend it one, as test_swim_clip_loops does
    D['body'] = dict(D.get('body', {}), motion=dict(A=0.1, alpha=3.4, lam=1.0, St=0.3, U=1.5, f=3.0, alphaSlope=0.6, alphaMin=2.8, alphaMax=4.4))
    rp = str(tmp_path / 'rec.json'); json.dump(D, open(rp, 'w'))
    out = str(tmp_path / 'beryx'); build(rp, out, res=256, log=lambda *a: None)

    def bake(env=None):
        p = subprocess.run([sys.executable, '-m', 'creature_maker', 'glb', out, '--record', rp], cwd=ROOT, capture_output=True, text=True, env=dict(os.environ, **(env or {})))
        assert p.returncode == 0, p.stderr[-800:]
        N = np.asarray(Image.open(os.path.join(out, 'body_normal.png'))).astype(float)[..., :3] / 127.5 - 1
        return checks.p6(N, np.load(os.path.join(out, 'body_mask.npy'))[::-1])
    good = bake()
    assert good['P6_pass'], good
    bad = bake(dict(CREATURE_PLANT_BAKE_FAULT='interior_on_skin'))
    assert not bad['P6_pass'] and bad['P6_backward_texels'] > 20 * max(good['P6_backward_texels'], 1), bad


def test_ventral_vs_from_the_record():
    """the lower-jaw V and the gill V are form plates, the slit has a ventral leg, and the hole loop matches the slit loop."""
    from creature_maker.record import adapt
    from creature_maker.form import Form
    from creature_maker.chart import Chart
    from creature_maker.cage import build_cage
    rec = adapt(REC); form = Form(rec)
    assert {'jaw.dentary', 'jaw.mandibleLow'} <= set(rec['defaults_used'])          # the proof record has no jaw bones: listed
    assert [p[0] for p in form.VPLATES] == ['mandible', 'branchiostegal'] and form.vedge['za'] < form.vedge['zc']
    e = form.vedge; xm = 0.5 * (e['xa'] + e['xc']); zm = float(form.vedge_z(xm)); y = float(form.BOT(xm)) + 0.004
    d_in, d_out = (float(form.sd_full(np.array([[xm, y, z]]))[0] - form.sd_body(np.array([[xm, y, z]]))[0]) for z in (zm - 0.004, zm + 0.004))
    assert d_out < d_in - 1e-4                                                      # the membrane stands proud outside the V edge only
    # the proof record's slit is 14 columns long, so the 17-edge cap leaves no leg that reaches the cavity slot; a cover
    # with a lower top (as most records have) gets the leg
    assert build_cage(form, Chart(form), rec).gill.info['ia'] is None
    rec['cover']['rear'] = rec['cover']['rear'][len(rec['cover']['rear']) // 2:]; form = Form(rec)
    B = build_cage(form, Chart(form), rec); g = B.gill.info
    assert g['ia'] is not None and g['ne'] == g['nj'] + g['i'] - g['ia'] <= 17
    for s in B.gill.slits:
        assert len(s['loop']) == len(s['hole']) == 2 * g['ne']
        assert abs(B.V[s['loop'][g['ne']]][2]) < abs(B.V[s['loop'][g['nj']]][2])    # the leg runs in toward the midline


def test_traced_cross_section_reaches_the_form_and_the_front_gate(tmp_path):
    """a traced section (outline.sections: widest above the middle, a thin keel below) is the loft's own shape at its station,
    the skin lies on it (rnorm = 1 on the boundary), and the front gate (SIL2) tells it from the default oval."""
    from creature_maker.record import adapt
    from creature_maker.form import Form
    from creature_maker import silhouette as S
    D = json.load(open(REC)); SL = D['record']['outline']['end']; s = np.linspace(-1, 1, 21)
    w = np.where(s > 0.3, np.sqrt(np.clip(1 - ((s - 0.3) / 0.7) ** 2, 0, 1)), np.clip(1 - np.abs((s - 0.3) / 1.3) ** 1.4, 0, 1) ** 0.9)
    D['record']['outline']['sections'] = [dict(u=0.4 * SL, w=[[float(a), float(b)] for a, b in zip(s, w)])]
    rp = str(tmp_path / 'sec.json'); json.dump(D, open(rp, 'w'))
    F = Form(adapt(rp)); x = np.full(5, 0.4); ss = np.array([-0.8, -0.3, 0.3, 0.6, 0.9])
    assert np.allclose(F.wnorm(x, ss), np.interp(ss, s, w) / w.max(), atol=0.02)
    th = np.linspace(0.1, np.pi - 0.1, 9); P = F.loft_point(np.full(9, 0.4), th); c, a, b = F.sec(0.4)
    assert np.allclose(F.rnorm(np.full(9, 0.4), (P[:, 1] - c) / a, P[:, 2] / b), 1, atol=1e-6)
    o1, o2 = str(tmp_path / 'oval'), str(tmp_path / 'sec')
    build(REC, o1, res=64, dense_form=False, log=lambda *a: None); build(rp, o2, res=64, dense_form=False, log=lambda *a: None)
    load = lambda o: (json.load(open(os.path.join(o, 'cage.json'))), np.load(os.path.join(o, 'cage.npz'))['V'])
    (C1, V1), (C2, V2) = load(o1), load(o2)
    ref = dict(front=S.outline2(C2, V2, 'front'))
    assert S.score2(C2, V2, ref)['SIL2_pass'] and not S.score2(C1, V1, ref)['SIL2_pass']
