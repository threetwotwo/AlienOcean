"""The board: every native record through record -> form -> cage -> UV at low map res, then the cage checks. This is how a
rule is proven universal (several body plans, not one hero). Writes OUTROOT/board.json: per species the error (stage +
message) or the check results.
"""
import glob, json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

KEEP = ('GP0_rest_crossings', 'GP1_pass', 'GP1_opening_share', 'GF1_pass', 'SR1_pass', 'SR1_safe', 'SR1_short', 'P2_worst_corner_p1_deg', 'P5_pass', 'P5_stretch_ok_area', 'P5_uv_folded_faces', 'P5_uv_overlap_texels', 'OP1_pass', 'OP2_pass', 'OP3_folds', 'OP3_folds_by_region',
        'FM1_pass', 'FM1_crease_deg', 'FM1_orbit_crease_deg', 'FM1_ripple_deg', 'FM2_pass', 'FM2_plate_slope_max', 'FM3_pass', 'FM3_front_height_pctSL', 'FM3_nose_radius_pctSL', 'FM3_nose_radius_wanted_pctSL', 'FM3_jaw_end_share',
        'IC1_input_faults', 'IC1_missing', 'P3_pass', 'EY1_pass',
        'EY2_pass', 'EY2_cornea_sag_R', 'EA1_pass', 'EA1_skin_up_deg', 'EA1_target_deg', 'EA1_dev_deg', 'EA1_under_band', 'EA1_bare_skin_up_deg', 'EA1_flat_by_record', 'EA1_filled_by_builder', 'EA2_pass', 'EA2_aim_up_deg', 'EA2_aim_fwd_deg', 'EA2_seat_deg', 'EA2_below_skin_deg',
        'PF1_pass', 'PF1_own_side_min_pctSL', 'PF2_pass', 'PF2_reach_over_trace', 'PF3_pass', 'PF3_turned_area_share', 'PF3_blade_bend_deg', 'PF4_pass', 'PF4_root_to_skin_deg',
        'FN1_pass', 'FN1_folded_area_share', 'FN1_worst_fin',
        'SIL1_pass', 'SIL1_iou', 'SIL1_head_iou', 'SIL1_body_iou', 'SIL1_note',
        'SIL2_pass', 'SIL2_front_iou', 'SIL2_top_iou', 'SIL2_note',
        'RG_pass', 'RG1_pass', 'RG1_head_end_SL', 'RG1_head_bend_pctBL', 'RG2_pass', 'RG2_paired', 'RG3_pass', 'RG3_caudal', 'RG_bones', 'RG_note')


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
