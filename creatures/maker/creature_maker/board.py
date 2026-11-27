"""The board: every native record through record -> form -> cage -> UV at low map res, then the cage checks. This is how a
rule is proven universal (several body plans, not one hero). Writes OUTROOT/board.json: per species the error (stage +
message) or the check results.
"""
import glob, json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

KEEP = ('GP0_rest_crossings', 'GP1_pass', 'GF1_pass', 'SR1_pass', 'SR1_safe', 'SR1_short', 'P2_worst_corner_p1_deg', 'P5_stretch_ok_area', 'P5_uv_folded_faces', 'OP1_pass', 'OP2_pass', 'OP3_folds', 'OP3_folds_by_region',
        'IC1_input_faults', 'IC1_missing', 'P3_pass', 'EY1_pass',
        'SIL1_pass', 'SIL1_iou', 'SIL1_head_iou', 'SIL1_body_iou', 'SIL1_note')


def find_records(dirs):
    recs = []
    for d in dirs:
        if d.endswith('.json'): recs.append(d); continue
        for sub in ('', 'stress/', 'cave/'):
            recs += [r for r in glob.glob(os.path.join(d, sub + '*.json'))
                     if '_fb' not in os.path.basename(r) and 'stalk' not in r and 'draft' not in os.path.basename(r)
                     and not r.endswith('.sil.json') and os.path.basename(r) != 'run_report.json']
    return sorted(set(recs))


def one(rp, outroot, style='', quick=False, tag=''):
    n = os.path.basename(rp)[:-5]; d = os.path.join(outroot, n + tag); os.makedirs(d, exist_ok=True)
    cwd = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cmd = [sys.executable, '-m', 'creature_maker', 'build', rp, d, '--res', '128', '--no-form'] + (['--style', style] if style else [])
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=900, cwd=cwd)
    if p.returncode:
        tb = [l for l in p.stderr.strip().splitlines() if l.strip()]
        where = next((l.strip()[:160] for l in reversed(tb) if 'creature_maker' in l), '')
        return n, dict(error=tb[-1][:300] if tb else 'unknown', where=where)
    # checks in their own process too: the pose sweeps are numpy-heavy and a thread pool would serialise them
    p = subprocess.run([sys.executable, '-m', 'creature_maker', 'check', d, rp] + (['--quick'] if quick else []), capture_output=True, text=True, timeout=1800, cwd=cwd)
    if p.returncode: return n, dict(error='checks: ' + (p.stderr.strip().splitlines() or ['unknown'])[-1][:200])
    R = json.load(open(os.path.join(d, 'checks.json')))
    return n, {k: R[k] for k in KEEP if k in R}


def run(outroot, record_dirs, names=(), style=''):
    recs = find_records(record_dirs)
    if names: recs = [r for r in recs if os.path.basename(r)[:-5] in names]
    with ThreadPoolExecutor(4) as ex: res = dict(ex.map(lambda r: one(r, outroot, style), recs))
    path = os.path.join(outroot, 'board.json')
    old = json.load(open(path)) if os.path.exists(path) and names else {}
    old.update(res); json.dump(old, open(path, 'w'), indent=1, default=str)
    return res
