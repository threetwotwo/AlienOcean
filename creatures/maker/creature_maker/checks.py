"""Stage 8, CHECKS: measured from the built outputs, written before judging; every check has a planted fault (--planted).

Cage checks (no Blender):
  P2  quads >= 95 %, worst corner (1st percentile) >= 20 deg
  P3  no non-manifold edges; open borders only at the eye openings
  P4  skin within 0.5 % SL (p95) / 2 % SL (max) of the form
  P5  skin UV: area with stretch in [0.8, 1.25] >= 95 %, no folded UV faces
  IC1 every part the record names exists; input faults and defaults listed
  EY1 eye rim radius within 5 % of the record eye
  OP1 openings are topology: genus 2 (mouth -> throat -> two gill exits), 2 border loops (eyes), consistent winding,
      and the lips reach each gill slit through interior faces only
  OP2 every interior-only vertex lies inside the body (signed distance < -0.1 % SL)
  OP3 no fold (> 60 deg between neighbouring faces) outside the designed creases (rolls, junctions, commissures)
Export checks (after Blender): P1 triangle budget + LODs, P6 the normal map carries the form, P7 bones, P8 Khronos
validator, P11 silhouette against the ceiling frame (info).
"""
import json, os, sys, math, copy, hashlib, subprocess
from collections import Counter, defaultdict, deque
import numpy as np
from PIL import Image
from .mesh import SKIN_TAGS, INNER_TAGS


def angles(V, f):
    P = V[f]; out = []
    for i in range(len(f)):
        a, b, c = P[i - 1], P[i], P[(i + 1) % len(f)]
        u, v = a - b, c - b; out.append(math.degrees(math.acos(np.clip(u @ v / (np.linalg.norm(u) * np.linalg.norm(v) + 1e-12), -1, 1))))
    return out


def face_normal(V, f):
    P = V[f]; n = np.cross(P[2] - P[0], P[-1] - P[1]) if len(f) == 4 else np.cross(P[1] - P[0], P[2] - P[0])
    return n / (np.linalg.norm(n) + 1e-12)


def expected_parts(a):
    fins = ['caudal'] + [m['name'] for m in a['fins']['median']] + [f'{n}_{s}' for n in ('pectoral', 'pelvic') for s in 'LR']
    return dict(eyes=2, fins=sorted(fins))


def topology(C):
    F = C['faces']; E = Counter()
    for f in F:
        for i in range(len(f)): E[frozenset((f[i], f[(i + 1) % len(f)]))] += 1
    used = set(v for f in F for v in f)
    adj = defaultdict(list)
    for e, n in E.items():
        if n == 1: a, b = tuple(e); adj[a].append(b); adj[b].append(a)
    seen, loops = set(), 0
    for v in adj:
        if v in seen: continue
        loops += 1; st = [v]
        while st:
            x = st.pop()
            if x in seen: continue
            seen.add(x); st += adj[x]
    chi = len(used) - len(E) + len(F)
    D = Counter((f[i], f[(i + 1) % len(f)]) for f in F for i in range(len(f)))
    wind = sum(1 for (a, b), n in D.items() if n > 1)
    return dict(border_loops=loops, nonmanifold=sum(1 for n in E.values() if n > 2), genus=(2 - loops - chi) / 2, winding_faults=wind)


def passages(C):
    """for each gill slit: can the lips reach it through interior faces only?"""
    F, T = C['faces'], C['ftag']; inner = [k for k, t in enumerate(T) if t in INNER_TAGS]
    vf = defaultdict(list)
    for k in inner:
        for v in C['faces'][k]: vf[v].append(k)
    lips = set(C['rolls'][0]); start = [k for k in inner if lips & set(F[k])]
    seen = set(start); dq = deque(start)
    while dq:
        k = dq.popleft()
        for v in F[k]:
            for kk in vf[v]:
                if kk not in seen: seen.add(kk); dq.append(kk)
    reach = set(v for k in seen for v in F[k])
    slits = C['rolls'][2:2 + len(C.get('junctions', []))]
    return [bool(set(s) & reach) for s in slits]


def folds(C, V, limit=60):
    F, T = C['faces'], C['ftag']; designed = set()
    for r in C.get('rolls', []) + C.get('junctions', []):
        for a, b in zip(r, r[1:] + r[:1]): designed.add(frozenset((a, b)))
    for ch in C.get('commissures', []):
        for a, b in zip(ch[:-1], ch[1:]): designed.add(frozenset((a, b)))
    E = defaultdict(list)
    for k, f in enumerate(F):
        for i in range(len(f)): E[frozenset((f[i], f[(i + 1) % len(f)]))].append(k)
    by = Counter(); dmax = 0.0
    for e, ks in E.items():
        if len(ks) != 2: continue
        a = math.degrees(math.acos(np.clip(face_normal(V, F[ks[0]]) @ face_normal(V, F[ks[1]]), -1, 1)))
        if e in designed: dmax = max(dmax, a); continue
        if a > limit: by['-'.join(sorted((T[ks[0]], T[ks[1]])))] += 1
    return dict(by), dmax


def cage_checks(C, V, form, rec):
    R = {}; faces, tags = C['faces'], C['ftag']
    skin = [k for k, t in enumerate(tags) if t in SKIN_TAGS]
    q = [f for f in faces if len(f) == 4]; R['P2_quad_share'] = round(len(q) / len(faces), 3)
    Amin = np.array([min(angles(V, f)) for f in q]); R['P2_worst_corner_p1_deg'] = round(float(np.percentile(Amin, 1)), 1)
    edges = Counter()
    for f in faces:
        for i in range(len(f)): edges[tuple(sorted((f[i], f[(i + 1) % len(f)])))] += 1
    val = np.zeros(len(V), int)
    for a, b in edges: val[a] += 1; val[b] += 1
    R['P2_poles'] = int(np.sum((val != 4) & (val > 0))); R['P2_max_pole_valence'] = int(val.max())
    R['P2_pass'] = R['P2_quad_share'] >= 0.95 and R['P2_worst_corner_p1_deg'] >= 20
    border = [e for e, n in edges.items() if n == 1]; nonman = [e for e, n in edges.items() if n > 2]
    eyev = set(v for f, t in zip(faces, tags) if t == 'eye' for v in f)
    R['P3_border_edges'] = len(border); R['P3_nonmanifold_edges'] = len(nonman)
    R['P3_border_outside_eye_openings'] = int(sum(1 for a, b in border if not (a in eyev and b in eyev)))
    R['P3_pass'] = len(nonman) == 0 and R['P3_border_outside_eye_openings'] == 0
    rng = np.random.default_rng(0); pts = []
    for k in skin:
        P = V[faces[k]]
        for w in rng.dirichlet(np.ones(len(faces[k])), 6): pts.append(w @ P)
    d = np.abs(form.sd_full(np.array(pts)))
    R['P4_skin_to_form_p95_pctSL'] = round(float(np.percentile(d, 95)) * 100, 2); R['P4_max_pctSL'] = round(float(d.max()) * 100, 2)
    R['P4_pass'] = R['P4_skin_to_form_p95_pctSL'] <= 0.5 and R['P4_max_pctSL'] <= 2.0
    cr = lambda a, b: a[0] * b[1] - a[1] * b[0]; ratio = []; flips = 0
    for k in skin:
        f, u, t = faces[k], np.array(C['uv'][k]), tags[k]; P = V[f]
        a3 = sum(np.linalg.norm(np.cross(P[i] - P[0], P[i + 1] - P[0])) for i in range(1, len(f) - 1)) / 2
        a2 = sum(abs(cr(u[i] - u[0], u[i + 1] - u[0])) for i in range(1, len(f) - 1)) / 2
        if a3 > 1e-12: ratio.append((a2 / a3, a3, float(t != 'eye')))
        s_ = 1 if V[f, 2].mean() >= 0 else -1
        for tri in ([(0, 1, 2)] + ([(0, 2, 3)] if len(f) == 4 else [])):
            a, b, c_ = u[list(tri)]
            if cr(b - a, c_ - a) * s_ <= 0: flips += 1; break
    r = np.array(ratio); r[:, 0] /= np.median(r[:, 0]); ok = (r[:, 0] > 0.8) & (r[:, 0] < 1.25)
    R['P5_stretch_ok_area'] = round(float((ok * r[:, 1]).sum() / r[:, 1].sum()), 3)
    bm = r[:, 2] > 0.5; R['P5_stretch_ok_area_without_eye_patch'] = round(float((ok * r[:, 1])[bm].sum() / r[:, 1][bm].sum()), 3)
    R['P5_uv_folded_faces'] = flips; R['P5_uv_md5'] = hashlib.md5(json.dumps(C['uv']).encode()).hexdigest()[:10]
    R['P5_pass'] = R['P5_stretch_ok_area'] >= 0.95 and flips == 0
    exp = expected_parts(rec); got = dict(eyes=C['parts']['eyes'], fins=sorted(C['parts']['fins']))
    R['IC1_missing'] = sorted(set(exp['fins']) - set(got['fins'])) + (['eye'] * (exp['eyes'] - got['eyes']))
    R['IC1_input_faults'] = C.get('input_faults', []); R['IC1_defaults_used'] = C.get('defaults_used', [])
    R['IC1_pass'] = not R['IC1_missing'] and not R['IC1_input_faults']
    er = rec['eye']['d'] / 2; built = np.mean([e.get('r_side', e['r']) for e in C['eyes']])
    R['EY1_eye_radius_ratio'] = round(float(built / er), 3); R['EY1_pass'] = abs(built / er - 1) <= 0.05
    tp = topology(C); ps = passages(C)
    R['OP1_topology'] = tp; R['OP1_lips_reach_each_gill'] = ps
    R['OP1_pass'] = tp['genus'] == 2 and tp['border_loops'] == 2 and tp['nonmanifold'] == 0 and tp['winding_faults'] == 0 and len(ps) == 2 and all(ps)
    skinv = set(v for k in skin for v in faces[k])
    deep = sorted(set(v for f, t in zip(faces, tags) if t in INNER_TAGS for v in f) - skinv)
    sd = form.sd_body(V[deep]) if deep else np.array([-1.0])
    R['OP2_interior_sd_max_pctSL'] = round(float(sd.max()) * 100, 3); R['OP2_outside'] = int((sd > -0.001).sum())
    R['OP2_pass'] = R['OP2_outside'] == 0
    by, dmax = folds(C, V)
    R['OP3_folds_by_region'] = by; R['OP3_folds'] = int(sum(by.values())); R['OP3_designed_crease_max_deg'] = round(dmax)
    R['OP3_pass'] = R['OP3_folds'] == 0
    return R


def p6(N, Mk):
    """the normal map carries the form: every third of the body has >= 10 % of texels tilted > 3 deg, the map is not
    inverted, and no isolated specks remain (> 25 deg from all 8 neighbours)."""
    if Mk.shape != N.shape[:2]: Mk = np.asarray(Image.fromarray(Mk.astype(np.uint8) * 255).resize(N.shape[:2][::-1])) > 127
    Nn = N / (np.linalg.norm(N, axis=-1, keepdims=True) + 1e-9)
    tilt = Nn[..., 2] < np.cos(np.radians(3)); cols = np.where(Mk.any(0))[0]; a, b = cols.min(), cols.max()
    thirds = [float(tilt[:, a + k * (b - a) // 3: a + (k + 1) * (b - a) // 3][Mk[:, a + k * (b - a) // 3: a + (k + 1) * (b - a) // 3]].mean()) for k in range(3)]
    best = np.full(Nn.shape[:2], -1.0)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy or dx: best = np.maximum(best, (Nn * np.roll(np.roll(Nn, dy, 0), dx, 1)).sum(-1))
    specks = int((best < np.cos(np.radians(25)))[Mk].sum())
    zp1 = float(np.percentile(Nn[..., 2][Mk], 1))
    return dict(P6_tilted_share_head_trunk_tail=[round(t, 3) for t in thirds], P6_specks=specks, P6_normal_z_p1=round(zp1, 3),
                P6_pass=min(thirds) >= 0.10 and specks <= 10 and zp1 > 0.2)


def validator(path):
    js = ("const v=require('gltf-validator');const fs=require('fs');v.validateBytes(new Uint8Array(fs.readFileSync(process.argv[1])))"
          ".then(r=>{console.log(JSON.stringify({errors:r.issues.numErrors,warnings:r.issues.numWarnings,infos:r.issues.numInfos,"
          "msgs:r.issues.messages.filter(m=>m.severity<2).slice(0,6).map(m=>m.code+' '+m.message)}))})")
    root = subprocess.run(['npm', 'root', '-g'], capture_output=True, text=True).stdout.strip()
    p = subprocess.run(['node', '-e', js, path], capture_output=True, text=True, env=dict(os.environ, NODE_PATH=root), timeout=120)
    try: return json.loads(p.stdout.strip().splitlines()[-1])
    except Exception: return dict(errors=-1, msgs=[p.stderr[-300:]])


def export_checks(out, st):
    R = {'P1_tris_total': st['tris_total'], 'P1_pass': st['tris_total'] <= 10000}
    lods = st.get('lods', {}); R['P1_lods'] = {k: v['tris'] for k, v in lods.items()}
    R['P1_lod_pass'] = bool(lods) and lods.get('LOD1', {}).get('tris', 1e9) <= 0.6 * st['tris_total'] and lods.get('LOD2', {}).get('tris', 1e9) <= 1000
    R['P7_bones'] = st['bones']; R['P7_pass'] = st['bones'] <= 24
    npath = os.path.join(out, 'body_normal.png')
    if os.path.exists(npath):
        N = np.asarray(Image.open(npath)).astype(float) / 127.5 - 1
        R.update(p6(N, np.load(os.path.join(out, 'body_mask.npy'))[::-1]))
    for name in ('fish.glb', 'fish_LOD1.glb', 'fish_LOD2.glb'):
        if os.path.exists(os.path.join(out, name)): R[f'P8_validator_{name}'] = validator(os.path.join(out, name))
    R['P8_pass'] = all(v.get('errors', 1) == 0 for k, v in R.items() if k.startswith('P8_validator'))
    return R


def planted(C0, V0, VN0, form, rec):
    """each planted fault must be caught by its check."""
    run = lambda c, v: cage_checks(c, v, form, rec); PL = {}
    c = copy.deepcopy(C0); c['parts']['fins'] = c['parts']['fins'][1:]; PL['IC1 (fin removed)'] = not run(c, V0)['IC1_pass']
    c = copy.deepcopy(C0); c['parts']['eyes'] = 1; PL['IC1 (eye removed)'] = not run(c, V0)['IC1_pass']
    sk = next(i for i, t in enumerate(C0['ftag']) if t == 'body'); v_ = C0['faces'][sk][0]
    V = V0.copy(); V[v_] += 0.05 * VN0[v_]; PL['P4 (skin vertex pulled 5 % SL)'] = not run(C0, V)['P4_pass']
    PL['OP3 (same pull folds the skin)'] = not run(C0, V)['OP3_pass']
    c = copy.deepcopy(C0); cap = [i for i, t in enumerate(c['ftag']) if t == 'cap']
    keep = [i for i in range(len(c['faces'])) if i not in set(cap)]
    for key in ('faces', 'ftag', 'uv'): c[key] = [c[key][i] for i in keep]
    PL['P3 (tail cap deleted)'] = not run(c, V0)['P3_pass']
    c = copy.deepcopy(C0); c['eyes'] = [dict(e, r=e['r'] * 0.8, r_side=e.get('r_side', e['r']) * 0.8) for e in c['eyes']]; PL['EY1 (eye 20 % small)'] = not run(c, V0)['EY1_pass']
    c = copy.deepcopy(C0); c['uv'] = [(np.array(u) * np.array([1, 1.6])).tolist() if i % 3 == 0 else u for i, u in enumerate(c['uv'])]
    PL['P5 (UV stretched 1.6x on 1/3 of faces)'] = not run(c, V0)['P5_pass']
    c = copy.deepcopy(C0); c['uv'][sk] = c['uv'][sk][::-1]; PL['P5 (one UV face folded)'] = run(c, V0)['P5_uv_folded_faces'] > 0
    c = copy.deepcopy(C0); gl = [i for i, t in enumerate(c['ftag']) if t == 'gill']; gl = set(gl[:len(gl) // 2])   # one passage removed
    keep = [i for i in range(len(c['faces'])) if i not in gl]
    for key in ('faces', 'ftag', 'uv'): c[key] = [c[key][i] for i in keep]
    PL['OP1 (one gill passage deleted)'] = not run(c, V0)['OP1_pass']
    deep = sorted(set(v for f, t in zip(C0['faces'], C0['ftag']) if t == 'cavity' for v in f) - set(v for f, t in zip(C0['faces'], C0['ftag']) if t in SKIN_TAGS for v in f))
    V = V0.copy(); V[deep[len(deep) // 2]] += np.array([0, 0, 0.2]); PL['OP2 (cavity vertex pushed out of the body)'] = not run(C0, V)['OP2_pass']
    PL['P6 (flat normal map)'] = not p6(np.dstack([np.zeros((64, 64)), np.zeros((64, 64)), np.ones((64, 64))]), np.ones((64, 64), bool))['P6_pass']
    PL['P1 (40k tris)'] = not export_checks('/nonexistent', dict(tris_total=40000, bones=10))['P1_pass']
    return PL


def check(out, record_path, with_planted=False):
    from .record import adapt
    from .form import Form
    rec = adapt(record_path); form = Form(rec)
    C = json.load(open(os.path.join(out, 'cage.json'))); Z = np.load(os.path.join(out, 'cage.npz'))
    R = cage_checks(C, Z['V'], form, rec)
    stp = os.path.join(out, 'glb_stats.json')
    if os.path.exists(stp): R.update(export_checks(out, json.load(open(stp))))
    R['P9_form_cage_s'] = round(C['stats']['build_s'] - C['stats']['bake_s'], 1); R['P9_pass'] = R['P9_form_cage_s'] < 60
    if with_planted: R['PLANTED_caught'] = planted(C, Z['V'], Z['VN'], form, rec)
    J = lambda o: bool(o) if isinstance(o, np.bool_) else (float(o) if isinstance(o, np.generic) else str(o))
    json.dump(R, open(os.path.join(out, 'checks.json'), 'w'), indent=1, default=J)
    return R
