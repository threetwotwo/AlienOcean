"""Proportion deviations for stylized art direction: every record rebuilt with bigger or smaller eyes, a longer or
shorter mouth, a fatter or thinner body (record.stylize), through the whole maker. Per species and knob it reports the
widest contiguous range around the record (1.0) that still builds and keeps real openings (OP1), the interior inside
(OP2), a manifold skin (P3), the eye on its record circle (EY1) and no more rest crossings than the record build (GP0).
The ladders are DEFAULTS of the test. Writes OUTROOT/deviate.json.
"""
import json, os
from concurrent.futures import ThreadPoolExecutor
from .board import find_records, one

LADDER = dict(eye=(0.6, 0.8, 1.25, 1.5, 1.75, 2.0), mouth=(0.7, 0.85, 1.2, 1.4, 1.6), girth=(0.6, 0.8, 1.25, 1.5))


def ok(r, base):
    return 'error' not in r and all(r.get(k) for k in ('OP1_pass', 'OP2_pass', 'P3_pass', 'EY1_pass')) \
        and r.get('GP0_rest_crossings', 1e9) <= base.get('GP0_rest_crossings', 0)


def why(r, base):
    if 'error' in r: return 'build: ' + r['error'][:120]
    bad = [k[:-5] for k in ('OP1_pass', 'OP2_pass', 'P3_pass', 'EY1_pass') if not r.get(k)]
    if r.get('GP0_rest_crossings', 0) > base.get('GP0_rest_crossings', 0):
        bad.append(f"GP0 {base.get('GP0_rest_crossings')}->{r['GP0_rest_crossings']}")
    return ', '.join(bad)


def run(outroot, record_dirs, names=()):
    recs = find_records(record_dirs)
    if names: recs = [r for r in recs if os.path.basename(r)[:-5] in names]
    jobs = [(rp, '', '') for rp in recs] + [(rp, f'{k}={v}', f'_{k}{v}') for rp in recs for k, L in LADDER.items() for v in L]
    with ThreadPoolExecutor(4) as ex:
        got = list(ex.map(lambda j: (j, one(j[0], outroot, j[1], quick=True, tag=j[2])[1]), jobs))
    R = {}
    for (rp, style, _), r in got: R.setdefault(os.path.basename(rp)[:-5], {})[style or 'record'] = r
    out = {}
    for n, rows in R.items():
        base = rows['record']; out[n] = dict(record_GP0=base.get('GP0_rest_crossings'), record_error=base.get('error'))
        for k, L in LADDER.items():
            lo = [v for v in L if v < 1][::-1]; hi = [v for v in L if v > 1]; rng = [1.0, 1.0]; fails = {}
            for side, seq in ((0, lo), (1, hi)):
                for v in seq:
                    r = rows[f'{k}={v}']
                    if ok(r, base): rng[side] = v
                    else: fails[str(v)] = why(r, base); break
            out[n][k] = dict(range=rng, first_fail=fails)
    json.dump(out, open(os.path.join(outroot, 'deviate.json'), 'w'), indent=1)
    return out
