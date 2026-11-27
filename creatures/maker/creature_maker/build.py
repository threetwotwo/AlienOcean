"""Build one creature from a native Species record: record -> form -> cage -> UV -> maps -> fins -> files.

Writes to OUT:
  cage.npz        V (snapped cage vertices), VN (normals), XT (body chart coords per vertex)
  cage.json       faces, tags, UVs, fins, designed-crease registers, openings, eyes, provenance, stats
  body_*.png/npy  maps (maps.py), fin_*.png (fins.py)
  form_mc.npz     the dense form, the Blender bake source (never shipped)
Then blender/export_glb.py turns OUT into the glTF.
"""
import json, os, time
import numpy as np
from .record import adapt
from .form import Form
from .chart import Chart
from .cage import build_cage
from .cage.eye import shells
from .uv import unwrap
from .maps import bake_body, HAMP
from .fins import build_fins


def build(record_path, out, res=2048, dense_form=True, debug=False, log=print):
    T0 = time.time(); os.makedirs(out, exist_ok=True)
    rec = adapt(record_path)
    form = Form(rec)
    chart = Chart(form)
    B = build_cage(form, chart, rec, debug_dir=out if debug else None)
    uvr = unwrap(B)
    t_b = time.time()
    map_prov = bake_body(B, uvr, res, out)
    t_bake = time.time() - t_b
    fins = build_fins(form, rec, out)
    eyes = shells(B, B.V)
    write(B, uvr, fins, eyes, rec, form, map_prov, out, dict(build_s=round(time.time() - T0, 1), bake_s=round(t_bake, 1), res=res))
    faces = B.mesh.faces; nq = sum(len(f) == 4 for f in faces); nt = sum(len(f) == 3 for f in faces)
    log(f'cage verts {len(B.V)} quads {nq} tris {nt}  -> body tris {2 * nq + nt}; fins {sum(2 * len(v["F"]) for v in fins.values())} tris; '
        f'build {time.time() - T0:.1f}s bake {t_bake:.1f}s')
    if dense_form:
        vv, ff = form.dense_mesh()
        np.savez(os.path.join(out, 'form_mc.npz'), V=vv, F=ff)
        log(f'form mesh {len(ff)} tris')
    return B


def write(B, uvr, fins, eyes, rec, form, map_prov, out, stats):
    M, G, mesh = B.mouth, B.gill, B.mesh
    np.savez(os.path.join(out, 'cage.npz'), V=B.V, VN=B.VN, XT=uvr['XT'])
    openings = dict(jr=M.jr, iK=M.iK, gill=G.info, xk=M.XK.round(5).tolist(), eye_margin_short_cols=sorted(set(M.XK_EYE_SHORT)),
                    mouth_rows=[list(map(int, r)) for r in M.MROWS], eye_rings=B.eye['rings'])
    json.dump(dict(faces=[list(map(int, f)) for f in mesh.faces], ftag=mesh.ftag, uv=[u.tolist() for u in uvr['face_uv']],
                   fins={k: dict(V=v['V'].tolist(), F=v['F'], UV=v['UV'].tolist(), T=v['T']) for k, v in fins.items()},
                   s_uv=float(uvr['s_uv']), rolls=B.rolls(), junctions=B.junctions(), commissures=B.commissures, openings=openings,
                   eyes=[dict(c=e['c'].tolist(), n=e['n'].tolist(), r=e['r'], r_side=e['r_side'], side=e['side']) for e in eyes],
                   eye=form.EY, SL_mm=rec['SL_mm'], xend=form.XEND, bones=rec['bones'], species=rec['species'], hamp=HAMP,
                   input_faults=rec['input_faults'], inputs=rec['provenance'], defaults_used=rec['defaults_used'],
                   parts=dict(eyes=len(B.eye['rims']), fins=sorted(fins.keys())), form_rules=dict(orbit_lift_pctSL=round(form.ORBIT_LIFT * 100, 2)),
                   uv_relax={str(k): v for k, v in uvr['uv_relax'].items()},
                   provenance=form.provenance() + map_prov,
                   stats=stats),
              open(os.path.join(out, 'cage.json'), 'w'))
