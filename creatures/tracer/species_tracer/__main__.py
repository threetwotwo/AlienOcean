"""species_tracer CLI.

  python -m species_tracer run MANIFEST [--write] [--only sp,sp] [--out DIR]
      For each manifest row: photo trace + fin-base points -> record (outline, eye, mouth, gill cover, fin roots), SIL2 check
      (check.py) before and after with planted faults, overlay picture (draft red, traced green, photo edge white) and the SIL1
      reference silhouette. Without --write the traced records go to OUT only; with --write a record that passes SIL2 (and
      catches its planted faults) replaces the record file (the old one is kept beside it in before_trace_<date>/) and its
      silhouette goes to <records root>/silhouettes/<record name>.json. A failing record is never written.
  python -m species_tracer check MANIFEST        SIL2 on the records as they stand (exit 1 if any fails or has no trace)

MANIFEST (JSON): {"records_root": DIR, "fin_bases": DIR, "rows": [{"species", "record", "trace", "photo", "box"?}]}, paths
absolute or relative to the manifest's folder. fin_bases/<species>.json = {"top": [[x %, y %]..], "bot": [..], "wait"?: reason},
points on the body edge under the fins read on the same photo. A row without "trace" is NO_TRACE; a fin-base file with "wait"
(the photo cannot give the outline: open mouth, fins folded over the body, a drawing) is WAIT and is not written.
"""
import argparse, datetime, json, os, shutil, sys
from . import write, check, overlay, silhouette


def load(path):
    M = json.load(open(path)); base = os.path.dirname(os.path.abspath(path))
    ab = lambda p: p if (p is None or os.path.isabs(p)) else os.path.join(base, p)
    for r in M['rows']:
        for k in ('record', 'trace', 'photo'): r[k] = ab(r.get(k))
    M['records_root'] = ab(M.get('records_root', base)); M['fin_bases'] = ab(M.get('fin_bases', 'fin_bases')); return M


def fin_base(M, sp):
    f = os.path.join(M['fin_bases'], sp + '.json')
    return json.load(open(f)) if os.path.exists(f) else {}


def main(argv=None):
    ap = argparse.ArgumentParser(prog='species_tracer'); ap.add_argument('cmd', choices=('run', 'check'))
    ap.add_argument('manifest'); ap.add_argument('--write', action='store_true'); ap.add_argument('--only', default='')
    ap.add_argument('--out', default='trace_out'); a = ap.parse_args(argv)
    M = load(a.manifest); only = set(filter(None, a.only.split(','))); os.makedirs(a.out, exist_ok=True)
    stamp = datetime.date.today().strftime('%d%b').lower(); rows = []; bad = 0
    for r in M['rows']:
        sp = r['species']
        if only and sp not in only: continue
        D = json.load(open(r['record']))
        if not r.get('trace') or not os.path.exists(r['trace']):
            rows.append(dict(species=sp, status='NO_TRACE')); bad += 1; print(sp, 'NO_TRACE'); continue
        T = json.load(open(r['trace'])); FB = fin_base(M, sp); T['fin_base'] = {k: FB[k] for k in ('top', 'bot') if FB.get(k)}
        T['appendages'] = FB.get('appendages') or []
        if not r.get('photo') or not os.path.exists(r['photo']):
            rows.append(dict(species=sp, status='NO_PHOTO')); bad += 1; print(sp, 'NO_PHOTO'); continue
        mask = check.photo_mask(r['photo'], r.get('box'))
        if a.cmd == 'check':
            h = check.silhouette_check(D, T, mask); rows.append(dict(species=sp, **h)); bad += not h['pass']; print(sp, h); continue
        before = check.silhouette_check(D, T, mask)
        D2, rep = write.apply(D, T, os.path.basename(r['trace'])[:-5], r.get('photo') or T.get('photo'))
        after = check.silhouette_check(D2, T, mask, rep['notes']); planted = check.planted(D2, T, mask)
        ok = after['pass'] and all(planted.values()) and not FB.get('wait')
        ref = silhouette.reference(T, float(D2['record']['outline']['end']), r.get('photo') or T.get('photo'), f'species_tracer {write.VERSION}')
        name = os.path.basename(r['record'])[:-5]
        json.dump(D2, open(os.path.join(a.out, name + '.json'), 'w'), indent=1)
        json.dump(ref, open(os.path.join(a.out, name + '.sil.json'), 'w'))
        if r.get('photo') and os.path.exists(r['photo']):
            overlay.overlay(r['photo'], T, D, D2, os.path.join(a.out, name + '_overlay.jpg'))
        if a.write and ok:
            keep = os.path.join(os.path.dirname(r['record']), f'before_trace_{stamp}'); os.makedirs(keep, exist_ok=True)
            if not os.path.exists(os.path.join(keep, name + '.json')): shutil.copy2(r['record'], keep)
            json.dump(D2, open(r['record'], 'w'), indent=1)
            sd = os.path.join(M['records_root'], 'silhouettes'); os.makedirs(sd, exist_ok=True)
            json.dump(ref, open(os.path.join(sd, name + '.json'), 'w'))
        row = dict(species=sp, record=name, status='WAIT' if FB.get('wait') else ('PASS' if ok else 'FAIL'), wait=FB.get('wait'),
                   written=bool(a.write and ok), before=before, after=after, planted_caught=planted, notes=rep['notes'],
                   measured=rep['measured'], estimate=rep['estimate'])
        rows.append(row); bad += not ok
        print(sp, row['status'], 'before', len(before['fails']), 'fails ->', after['fails'] or 'pass', 'planted', planted, flush=True)
    json.dump(rows, open(os.path.join(a.out, f'{a.cmd}_report.json'), 'w'), indent=1)
    return 1 if bad else 0


if __name__ == '__main__': sys.exit(main())
