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
