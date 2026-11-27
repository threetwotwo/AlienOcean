"""The board: every native record through record -> form -> cage -> UV at low map res, then the cage checks. This is how a
rule is proven universal (several body plans, not one hero). Writes OUTROOT/board.json: per species the error (stage +
message) or the check results.
"""
import glob, json, os, subprocess, sys, traceback
from concurrent.futures import ThreadPoolExecutor

KEEP = ('P2_worst_corner_p1_deg', 'P5_stretch_ok_area', 'P5_uv_folded_faces', 'OP1_pass', 'OP2_pass', 'OP3_folds', 'OP3_folds_by_region',
        'IC1_input_faults', 'IC1_missing')


def find_records(dirs):
    recs = []
    for d in dirs:
        if d.endswith('.json'): recs.append(d); continue
        for sub in ('', 'stress/', 'cave/'):
            recs += [r for r in glob.glob(os.path.join(d, sub + '*.json'))
                     if not r.endswith('_fb.json') and 'stalk' not in r and 'draft' not in os.path.basename(r)]
    return sorted(set(recs))


def one(rp, outroot):
    n = os.path.basename(rp)[:-5]; d = os.path.join(outroot, n); os.makedirs(d, exist_ok=True)
    p = subprocess.run([sys.executable, '-m', 'creature_maker', 'build', rp, d, '--res', '128', '--no-form'], capture_output=True, text=True,
                       timeout=900, cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if p.returncode:
        tb = [l for l in p.stderr.strip().splitlines() if l.strip()]
        where = next((l.strip()[:160] for l in reversed(tb) if 'creature_maker' in l), '')
        return n, dict(error=tb[-1][:300] if tb else 'unknown', where=where)
    try:
        from .checks import check
        R = check(d, rp)
        return n, {k: R[k] for k in KEEP if k in R}
    except Exception:
        return n, dict(error='checks: ' + traceback.format_exc().strip().splitlines()[-1][:200])


def run(outroot, record_dirs, names=()):
    recs = find_records(record_dirs)
    if names: recs = [r for r in recs if os.path.basename(r)[:-5] in names]
    with ThreadPoolExecutor(4) as ex: res = dict(ex.map(lambda r: one(r, outroot), recs))
    path = os.path.join(outroot, 'board.json')
    old = json.load(open(path)) if os.path.exists(path) and names else {}
    old.update(res); json.dump(old, open(path, 'w'), indent=1, default=str)
    return res
