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
