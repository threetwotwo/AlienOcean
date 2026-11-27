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
