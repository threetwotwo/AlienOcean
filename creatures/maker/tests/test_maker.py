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
