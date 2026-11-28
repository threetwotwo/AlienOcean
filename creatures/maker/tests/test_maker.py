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


def test_export_rig_is_the_stress_pose(tmp_path):
    """the jaw and gill-cover bones skin the cage into exactly the stress test's poses (rig.skin == pose.gape / pose.flare), and a
    jaw pivot moved by 2 % SL is caught (planted)."""
    from creature_maker.record import adapt
    from creature_maker import rig
    out = str(tmp_path / 'beryx'); build(REC, out, res=64, dense_form=False, log=lambda *a: None)
    C = json.load(open(os.path.join(out, 'cage.json'))); V = np.load(os.path.join(out, 'cage.npz'))['V']; rec = adapt(REC, C.get('style'))
    bl = rig.bones(C, V, rec); W, info = rig.weights(C, V, rec)
    assert np.allclose(sum(W.values()), 1.0)
    g = rec.get('gape_deg', 30.0)
    assert np.abs(rig.skin(V, W, bl, {'jaw': g}) - rig.stress_pose(C, V, rec, 'gape', g)).max() < 1e-9
    assert np.abs(rig.skin(V, W, bl, {'opercleL': 23, 'opercleR': 23}) - rig.stress_pose(C, V, rec, 'flare', 23)).max() < 1e-9
    bad = [dict(b, pivot=[b['pivot'][0] + 0.02, b['pivot'][1], b['pivot'][2]]) if b['name'] == 'jaw' else b for b in bl]
    assert np.abs(rig.skin(V, W, bad, {'jaw': g}) - rig.stress_pose(C, V, rec, 'gape', g)).max() > 1e-3


def test_swim_clip_loops(tmp_path):
    """the swim engine on the cage: one beat at cruise closes on itself, the tail swings wider than the head, and the extras carry
    what the school system reads. The proof record has no gait yet, so this test lends it the trevally record's motion block
    (an ESTIMATE in that record too); a record without one must fail loudly."""
    import shutil, pytest
    if shutil.which('node') is None: pytest.skip('node not installed')
    from creature_maker.record import adapt
    from creature_maker import rig, swim_clip
    out = str(tmp_path / 'beryx'); build(REC, out, res=64, dense_form=False, log=lambda *a: None)
    C = json.load(open(os.path.join(out, 'cage.json'))); V = np.load(os.path.join(out, 'cage.npz'))['V']; rec = adapt(REC, C.get('style'))
    raw = json.load(open(REC)); bl = rig.bones(C, V, rec)
    with pytest.raises(KeyError): swim_clip.model(C, V, dict(raw, body={}), bl)
    raw['body'] = dict(raw.get('body', {}), motion=dict(A=0.1, alpha=3.4, lam=1.0, St=0.3, U=1.5, f=3.0, alphaSlope=0.6, alphaMin=2.8, alphaMax=4.4))
    R = swim_clip.clips(C, V, raw, bl)
    assert R['loop_err'] < 1e-4
    env = R['extras']['wave']['amplitude_envelope_BL']
    assert env[-1][1] > 2 * env[0][1] > 0
    for k in ('wave', 'beat_law', 'clips', 'amp_law'): assert k in R['extras']
    bs = R['extras']['wave']['envelopes_by_speed']          # shader blends between speeds: rising beat, U_rec entry = the main table
    assert len(bs) == 3 and [b['U_BLps'] for b in bs] == sorted(b['U_BLps'] for b in bs)
    assert bs[0]['beat_Hz'] < bs[1]['beat_Hz'] < bs[2]['beat_Hz'] and bs[0]['rows'] == env
    assert all(len(r) == 3 for b in bs for r in b['rows']) and bs[0]['rows'] != bs[2]['rows']
    assert all(b['loop_closure_BL'] < 1e-4 for b in bs)
    bw = R['extras']['beat_law']            # the published law reproduces every measured beat
    for b in bs: assert abs(bw['f_rec_Hz'] * (bw['c_BLps'] + b['U_BLps']) / (bw['c_BLps'] + bw['U_rec_BLps']) - b['beat_Hz']) < 2e-3
    # a cruise below the gait's steady band (the engine swims burst-and-coast there): the loop is taken at the band's floor and closes
    raw['body']['motion'] = dict(raw['body']['motion'], U=0.968, f=1.452)
    R2 = swim_clip.clips(C, V, raw, bl); st = R2['extras']['steady']
    bw = R2['extras']['beat_law']
    for b in R2['extras']['wave']['envelopes_by_speed']: assert abs(bw['f_rec_Hz'] * (bw['c_BLps'] + b['U_BLps']) / (bw['c_BLps'] + bw['U_rec_BLps']) - b['beat_Hz']) < 2e-3
    assert R2['loop_err'] < 1e-4 and st['U_loop_BLps'] == st['U_min_BLps'] > st['U_rec_BLps'] == 0.968


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


def test_skin_uv_islands_are_fold_free_twins(tmp_path):
    """the two halves of the skin flatten without a fold or an overlap, SLIM runs on both, and the right island is the
    left one half a texture lower (the bake's left/right check, P6, reads twin texels)."""
    from scipy.spatial import cKDTree
    out = str(tmp_path / 'beryx'); build(REC, out, res=64, dense_form=False, log=lambda *a: None)
    R = check(out, REC, sweep=False)
    assert R['P5_uv_folded_faces'] == 0 and R['P5_uv_overlap_texels'] == 0 and R['P5_uv_relaxed'] and R['P5_pass'], {k: v for k, v in R.items() if k.startswith('P5')}
    C = json.load(open(os.path.join(out, 'cage.json'))); V = np.load(os.path.join(out, 'cage.npz'))['V']
    side = lambda sg: np.array([uv for f, t, u in zip(C['faces'], C['ftag'], C['uv']) if t in ('body', 'eye', 'mouth', 'cap') and (V[f, 2].mean() >= 0) == (sg > 0) for uv in u])
    L, Rt = side(1), side(-1)
    assert L[:, 1].min() > 0.5 > Rt[:, 1].max()
    assert cKDTree(L - [0, 0.5]).query(Rt)[0].max() < 1.5 / 4096         # twins to within a texel and a half at 4K


def test_bake_keeps_interior_and_linings_off_the_skin_maps(tmp_path):
    """the export bake (Blender) on the proof record: no patch of the normal map faces into the skin and both sides carry the
    same map. Baking the cavity and gill passage faces into the skin's own image (they have their own UV island, laid over
    the skin's) put backwards patches on the cheek and throat of one side: P6 must be clean, and the same fault planted
    back (interior faces left on the skin's bake target) must be caught."""
    import shutil, subprocess, pytest
    pytest.importorskip('bpy')
    if shutil.which('node') is None: pytest.skip('node not installed (swim clips)')
    from creature_maker import checks
    from PIL import Image
    D = json.load(open(REC))          # the proof record has no gait yet: lend it one, as test_swim_clip_loops does
    D['body'] = dict(D.get('body', {}), motion=dict(A=0.1, alpha=3.4, lam=1.0, St=0.3, U=1.5, f=3.0, alphaSlope=0.6, alphaMin=2.8, alphaMax=4.4))
    rp = str(tmp_path / 'rec.json'); json.dump(D, open(rp, 'w'))
    out = str(tmp_path / 'beryx'); build(rp, out, res=256, log=lambda *a: None)

    def bake(env=None):
        p = subprocess.run([sys.executable, '-m', 'creature_maker', 'glb', out, '--record', rp], cwd=ROOT, capture_output=True, text=True, env=dict(os.environ, **(env or {})))
        assert p.returncode == 0, p.stderr[-800:]
        N = np.asarray(Image.open(os.path.join(out, 'body_normal.png'))).astype(float)[..., :3] / 127.5 - 1
        return checks.p6(N, np.load(os.path.join(out, 'body_mask.npy'))[::-1])
    good = bake()
    assert good['P6_pass'], good
    bad = bake(dict(CREATURE_PLANT_BAKE_FAULT='interior_on_skin'))
    assert not bad['P6_pass'] and bad['P6_backward_texels'] > 20 * max(good['P6_backward_texels'], 1), bad
    # the skin's shading stops at the lips: with the lip normals averaged into the lining again (the edges between skin and
    # interior faces left smooth) the map must lean the other way over every skin face at a lip, and P6 sees it
    lean = bake(dict(CREATURE_PLANT_BAKE_FAULT='lips_shaded_with_lining'))
    assert lean['P6_normal_z_p1'] < good['P6_normal_z_p1'] - 0.03 and lean['P6_normal_z_p1'] < checks.P6_Z_P1_MIN, (good, lean)


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
    d_in, d_out = (float(form.sd_full(np.array([[xm, y, z]]))[0] - form.sd_body(np.array([[xm, y, z]]))[0]) for z in (zm - 0.004, zm + 0.008))     # outside: past the edge's chamfer (form.PLATE_CHAMFER)
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


def test_traced_cross_section_reaches_the_form_and_the_front_gate(tmp_path):
    """a traced section (outline.sections: widest above the middle, a thin keel below) is the loft's own shape at its station,
    the skin lies on it (rnorm = 1 on the boundary), and the front gate (SIL2) tells it from the default oval."""
    from creature_maker.record import adapt
    from creature_maker.form import Form
    from creature_maker import silhouette as S
    D = json.load(open(REC)); SL = D['record']['outline']['end']; s = np.linspace(-1, 1, 21)
    w = np.where(s > 0.3, np.sqrt(np.clip(1 - ((s - 0.3) / 0.7) ** 2, 0, 1)), np.clip(1 - np.abs((s - 0.3) / 1.3) ** 1.4, 0, 1) ** 0.9)
    D['record']['outline']['sections'] = [dict(u=0.4 * SL, w=[[float(a), float(b)] for a, b in zip(s, w)])]
    rp = str(tmp_path / 'sec.json'); json.dump(D, open(rp, 'w'))
    F = Form(adapt(rp)); x = np.full(5, 0.4); ss = np.array([-0.8, -0.3, 0.3, 0.6, 0.9])
    # the rows are faired by at most SECT_FAIR_TOL (2 %) of the section's half-size, measured from its centre: a little more in w where the side is steep
    assert np.allclose(F.wnorm(x, ss), np.interp(ss, s, w) / w.max(), atol=0.035) and F.SECT_FAIRED <= 0.02 + 1e-9
    th = np.linspace(0.1, np.pi - 0.1, 9); P = F.loft_point(np.full(9, 0.4), th); c, a, b = F.sec(0.4)
    assert np.allclose(F.rnorm(np.full(9, 0.4), (P[:, 1] - c) / a, P[:, 2] / b), 1, atol=1e-6)
    o1, o2 = str(tmp_path / 'oval'), str(tmp_path / 'sec')
    build(REC, o1, res=64, dense_form=False, log=lambda *a: None); build(rp, o2, res=64, dense_form=False, log=lambda *a: None)
    load = lambda o: (json.load(open(os.path.join(o, 'cage.json'))), np.load(os.path.join(o, 'cage.npz'))['V'])
    (C1, V1), (C2, V2) = load(o1), load(o2)
    ref = dict(front=S.outline2(C2, V2, 'front'))
    assert S.score2(C2, V2, ref)['SIL2_pass'] and not S.score2(C1, V1, ref)['SIL2_pass']


def _cage(rec_dict, tmp_path, name):
    """build the cage only (no maps) from a record dict; returns (cage dict as pose.py reads it, V, adapted record, form, builder)."""
    from creature_maker.record import adapt
    from creature_maker.form import Form
    from creature_maker.chart import Chart
    from creature_maker.cage import build_cage
    p = str(tmp_path / f'{name}.json'); json.dump(rec_dict, open(p, 'w'))
    rec = adapt(p); form = Form(rec); B = build_cage(form, Chart(form), rec); M, G = B.mouth, B.gill
    C = dict(faces=[list(map(int, f)) for f in B.mesh.faces], ftag=B.mesh.ftag, rolls=B.rolls(), junctions=B.junctions(), commissures=B.commissures,
             xend=form.XEND, openings=dict(jr=M.jr, mouth_rows=[list(map(int, r)) for r in M.MROWS], mouth_lining_rows=M.NF,
                                           cavity_rows=[list(map(int, r)) for r in M.CROWS + M.DOME] + [[int(M.gut)]],
                                           gill_flaps=[list(map(int, s['A'])) for s in G.slits], gill_rows=[[list(map(int, r)) for r in s['rows']] for s in G.slits],
                                           jaw_joint=rec['jaw_joint'], opercle_hinge=rec['opercle_hinge'],
                                           gill_v=dict(edge=[[float(x), float(form.vedge_z(x))] for x in np.linspace(form.vedge['xa'], form.vedge['xc'], 16)], under=form.vunder, apex=G.apex) if G.apex else None))
    return C, B.V, rec, form, B


def test_jaws_enclose_the_mouth_line(tmp_path):
    """planted: an outline traced round an overhanging upper lip, its lower edge above the mouth line for the first 3 % SL
    (triggerfish, blenny, porcupinefish records). The form carries the outline round the seam, so the lips keep their width;
    without the rule they fell on the midline (z = 0) and the lip roll crossed the first loops."""
    from creature_maker.form import JAW_MIN
    raw = json.load(open(REC)); O = raw['record']['outline']
    O['bot'] = [[0.0, -0.2], [3.0, -0.2], [9.0, -0.2]] + [p for p in O['bot'] if p[0] > 9.5]      # the seam at x 9 is at y -6.2
    C, V, rec, form, B = _cage(raw, tmp_path, 'overhang')
    ml = np.array(rec['mouth']['line']); xs = np.linspace(0.002, ml[:, 0].max(), 20); ys = np.interp(xs, ml[:, 0], ml[:, 1])
    assert form.JAW_LIFT > 0.01 and (ys - form.BOT(xs)).min() > 0.8 * JAW_MIN and (form.TOP(xs) - ys).min() > 0.8 * JAW_MIN
    lips = np.array(B.mouth.LIP3); NT = len(lips)
    assert np.abs(lips[1:NT // 2, 2]).min() > 1e-3, np.abs(lips[1:NT // 2, 2]).round(4)      # every lip vertex off the midline
    C0, V0, rec0, form0, B0 = _cage(json.load(open(REC)), tmp_path, 'plain')
    assert form0.JAW_LIFT < 1e-6                                                             # a mouth inside its outline moves nothing


def test_lower_lip_tip_is_charted_under_the_mouth(tmp_path):
    """the snout chart's angle of a front-disc point: straight below the mouth tip is pi, not 2 pi (the lookup answered
    2 pi for every angle, and the loops under the chin started above the lips)."""
    C, V, rec, form, B = _cage(json.load(open(REC)), tmp_path, 'plain'); S = B.mouth.snout
    assert abs(float(S.disc_theta(np.array(S.y_m0 - 0.001), np.array(0.0))) - np.pi) < 1e-6
    assert 0.2 < float(S.disc_theta(np.array(S.y_m0), np.array(0.001))) < np.pi - 0.2
    assert abs(B.mouth.LIPT[len(B.mouth.LIPT) // 2] - np.pi) < 1e-6 and B.mouth.LIPT[0] < 1e-6


def test_jaw_field_holds_when_the_joint_sits_on_the_rictus(tmp_path):
    """planted: the jaw joint 0.5 % SL above the rictus (sweetlips, blenny records). The field's frame is the jaw's own
    line (mouth tip to joint), so the jaw is still the part under the mouth in front of the joint: the lip tips part by
    the whole gape, the upper head stays, and the throat far behind the joint stays. Framed on the line from rictus to
    joint the field turned a quarter turn: half weight on the throat floor far behind the joint, a fold at gape 10."""
    from creature_maker.pose import jaw_weights, OPEN_MIN
    raw = json.load(open(REC)); R = raw['record']; xr, yr = R['mouth']['seam'][-1]
    R['skeleton']['jawJoint'] = [xr + 0.3, yr + 1.5]
    C, V, rec, form, B = _cage(raw, tmp_path, 'joint_on_rictus'); w = jaw_weights(C, V, rec); J = np.array(rec['jaw_joint'])
    lips = C['openings']['mouth_rows'][0]
    assert w[lips[len(lips) // 2]] - w[lips[0]] >= OPEN_MIN
    ml = np.array(rec['mouth']['line']); ml = ml[np.argsort(ml[:, 0])]
    skin = np.zeros(len(V), bool); skin[[v for f, t in zip(C['faces'], C['ftag']) if t in ('mouth', 'body') for v in f]] = True
    behind = V[:, 0] > J[0] + 0.08; above = skin & (V[:, 0] < ml[-1, 0] - 0.01) & (V[:, 1] > np.interp(V[:, 0], ml[:, 0], ml[:, 1]) + 0.01)
    assert w[behind].max() < 0.05 and above.sum() > 10 and w[above].max() < 0.05, (w[behind].max(), above.sum(), w[above].max())
    chin = skin & (V[:, 0] < 0.6 * ml[0, 0] + 0.4 * ml[-1, 0]) & (V[:, 1] < np.interp(V[:, 0], ml[:, 0], ml[:, 1]) - 0.01)
    assert chin.sum() > 5 and w[chin].min() > 0.95, (chin.sum(), w[chin].min())


def test_corner_blend_stops_short_of_the_lip_tips(tmp_path):
    """planted: the jaw joint as far behind the rictus as the mouth is long (trevally, damsel, hawkfish records). The
    corner's blend is capped at half the mouth, so the lip tips still part by the whole gape (GP1's opening share);
    uncapped they stood at 0.2 and 0.8 and the snout drooped with the jaw."""
    from creature_maker.pose import jaw_weights, OPEN_MIN
    raw = json.load(open(REC)); R = raw['record']; xr, yr = R['mouth']['seam'][-1]
    R['skeleton']['jawJoint'] = [xr + 22.0, yr - 6.0]
    C, V, rec, form, B = _cage(raw, tmp_path, 'joint_far_behind'); w = jaw_weights(C, V, rec); lips = C['openings']['mouth_rows'][0]
    assert w[lips[len(lips) // 2]] - w[lips[0]] >= OPEN_MIN
    assert abs(w[lips[C['openings']['jr']]] - 0.5) < 1e-6                              # the corner itself still sits half way


def test_gill_slit_opens_as_a_lens(tmp_path):
    """the first passage row is designed all along each slit (flap lining under the flap, lip lining straight in), the
    slit's ends go with the skin round them and every lining vertex follows its own slit vertex: no crossing at rest
    between passage and skin, none in the real flare, and the flap's middle goes with the cover."""
    from creature_maker.pose import cover_weights, stress, self_intersections, triangles
    C, V, rec, form, B = _cage(json.load(open(REC)), tmp_path, 'plain')
    T = triangles(C['faces']); tt = [t for f, t in zip(C['faces'], C['ftag']) for _ in range(len(f) - 2)]
    _, pairs = self_intersections(V, T)
    assert not [p for p in pairs if 'gill' in (tt[p[0]], tt[p[1]])]
    w = cover_weights(C, V, rec)
    for s, rows in zip(C['openings']['gill_flaps'], C['openings']['gill_rows']):
        assert w[s].max() > 0.5 and w[s[0]] < w[s].max()                               # open in the middle, closing toward the ends
        for r, row in enumerate(rows[1:-1], 1):
            assert np.allclose(w[row], w[rows[0]] * (1 - r / (len(rows) - 1)))         # lining follows its slit vertex
    assert stress(C, V, rec)['GF1_pass']
    from creature_maker.pose import jaw_weights
    assert (w + jaw_weights(C, V, rec)).max() <= 1 + 1e-9                              # the cover takes what the jaw leaves: the rig never scales


def test_lower_jaw_plate_has_no_ledge():
    """the plates drawn from below (lower-jaw rami, branchiostegal membrane) end in chamfers. Cut off square in the side
    view, the mandible's upper limit was a ledge along the lower jaw whose face leaned over the skin: a flat shelf with a
    jagged edge in the engine, backward texels in the bake. Nowhere on the lower jaw may the form's normal face away from
    the bare body's."""
    from creature_maker.record import adapt
    from creature_maker.form import Form
    form = Form(adapt(REC)); k = [p[0] for p in form.VPLATES].index('mandible'); poly = np.array(form.VPLATES[k][1]); n = 140
    X, T = np.meshgrid(np.linspace(poly[:, 0].min(), poly[:, 0].max(), n), np.linspace(np.pi * 0.5, np.pi, n)); X, T = X.ravel(), T.ravel()
    top, bot = form.TOP(X), form.BOT(X); D = np.stack([np.zeros_like(X), np.cos(T), np.sin(T)], 1); O = np.stack([X, (top + bot) / 2, np.zeros_like(X)], 1)
    lo, hi = np.zeros(len(X)), 1.5 * np.maximum(form.HW(X), (top - bot) / 2) + 0.02; f = lambda P: form.sd_full(P, cleft=False)
    for _ in range(30):                                                                # the form's surface along each ray from the axis
        m = (lo + hi) / 2; ins = f(O + D * m[:, None]) < 0; lo = np.where(ins, m, lo); hi = np.where(ins, hi, m)
    P = O + D * hi[:, None]; e = 2e-4
    g = lambda fn: np.stack([fn(P + e * np.eye(3)[i]) - fn(P - e * np.eye(3)[i]) for i in range(3)], 1)
    a, b = g(f), g(form.sd_body); c = (a * b).sum(1) / (np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1) + 1e-15)
    ids = form.sd_full(P - b / np.linalg.norm(b, axis=1)[:, None] * 5e-4, parts=True)[1]
    jaw = np.asarray(ids) == len(form.PLATES) + k + 1
    assert jaw.sum() > 50 and c[jaw].min() > 0, (int(jaw.sum()), float(c[jaw].min()))


def test_top_view_closing_to_a_point_at_the_snout_builds(tmp_path):
    """a traced top view may close to zero width at the snout while the side view still has height there; the form keeps
    a least half-width (form.HW_MIN) instead of dividing by zero."""
    from creature_maker.form import Form, HW_MIN
    from creature_maker.record import adapt
    D = json.load(open(REC)); D['record']['outline']['hw'][0][1] = 0.0
    p = str(tmp_path / 'pointy.json'); json.dump(D, open(p, 'w'))
    F = Form(adapt(p)); assert abs(float(F.HW(np.array(0.0))) - HW_MIN) < 1e-12
    P = F.loft_point(np.array([0.0, 0.0]), np.array([0.3, 1.5]))
    assert np.isfinite(P).all()


def test_front_reference_marked_body_only_is_gated_without_fins():
    from creature_maker.silhouette import front_has_fins
    assert front_has_fins({}) and front_has_fins({'front_fins': True})
    assert not front_has_fins({'front_fins': False}) and not front_has_fins({'front_fins': 'body only: spine folded'})


def test_scale_relief_covers_the_trunk(tmp_path):
    """the head mask in maps comes from form part labels; a part that labels the bare flank (a plate whose chamfer ran out
    still blending with the body: export r5) wiped the scale relief off the trunk. A scaled fish keeps relief on most of it."""
    out = str(tmp_path / 'beryx'); build(REC, out, res=256, dense_form=False, log=lambda *a: None)
    h = np.load(os.path.join(out, 'body_height.npy')); m = np.load(os.path.join(out, 'body_mask.npy')).astype(bool)
    assert (np.abs(h - np.median(h)) > 1e-4)[m].mean() > 0.4


def test_lateral_line_height_falls_back_when_the_record_holds_none(tmp_path):
    from creature_maker.record import adapt, LL_FRAC
    D = json.load(open(REC)); D['record'].setdefault('scales', {}).setdefault('grow', {})['lateral_line'] = {'ll_frac': None}
    p = str(tmp_path / 'r.json'); json.dump(D, open(p, 'w'))
    assert adapt(p)['scales']['ll_frac'] == LL_FRAC


def test_front_reference_marked_as_a_section_is_scored_against_a_slice():
    from creature_maker.silhouette import section_u
    assert section_u({}) is None and section_u({'front_kind': 'projection'}) is None
    assert section_u({'front_kind': 'section', 'front_u': 0.57}) == 0.57


def test_eye_aims_down_its_own_axis_and_the_head_has_volume_round_it(tmp_path):
    """planted: a record whose eye sits high on a round head (the proof record with its eye moved up to 0.15 eye radii under
    the dorsal outline). On the bare loft the rim's own plane leans far up there (the old aim); the eye's aim stays in the
    scan range, the rim is plane and square to it, the tissue only widens the head and stays inside the top view."""
    from creature_maker.record import adapt
    from creature_maker.form import Form, AIM_UP, AIM_FWD
    from creature_maker.cage.eye import rim3
    D = json.load(open(REC)); R = D['record']; E = R['skeleton']['eye']; top = np.array(R['outline']['top'])
    E['y'] = float(np.interp(E['u'], top[:, 0], top[:, 1])) - 1.15 * E['R']
    p = str(tmp_path / 'high_eye.json'); json.dump(D, open(p, 'w'))
    rec = adapt(p); F = Form(rec); O = F.ORBIT
    ph = np.linspace(0, 2 * np.pi, 360, endpoint=False); rim = rim3(F, 1, ph)
    keep = F._orb; F._orb = None; bare = rim3(F, 1, ph); F._orb = keep
    up_of = lambda P: (lambda n: float(np.degrees(np.arcsin(abs(n[1])))))(np.linalg.svd(P - P.mean(0))[2][2])
    assert up_of(bare) > O['aim_up_deg'] + 5                               # the fault: the bare rim plane looks further up than the eye
    assert AIM_UP[0] <= O['aim_up_deg'] <= AIM_UP[1] and AIM_FWD[0] <= O['aim_fwd_deg'] <= AIM_FWD[1]
    from creature_maker.checks import EA2_SEAT_MAX
    n = F.eye_axis(1); rn = np.linalg.svd(rim - rim.mean(0))[2][2]
    assert np.degrees(np.arccos(min(abs(float(rn @ n)), 1.0))) < EA2_SEAT_MAX      # the rim's plane is square to the aim: the eye sits true
    assert (rim[:, 2] >= bare[:, 2] - rec['eye']['groove'] * F.er - 1e-9).all()      # tissue is added; the furrow is the only way in
    assert (rim[:, 2] <= F.HW(rim[:, 0]) + rec['eye']['bulge'] * F.er + 1e-9).all()  # and stays inside the top view + the bulge
    assert np.allclose(F.eye_axis(-1), n * [1, 1, -1])
    assert O['skin_up_deg'] < O['bare_skin_up_deg']                        # the skin round the eye faces less up than before
    out = str(tmp_path / 'b'); build(p, out, res=64, dense_form=False, log=lambda *a: None)
    Rk = check(out, p, sweep=False)
    assert Rk['EA2_pass'] and Rk['EY1_pass'] and Rk['EY2_pass'] and Rk['OP1_pass'], {k: Rk[k] for k in Rk if k.startswith(('EA', 'EY'))}


def test_a_stated_aim_wins_and_the_eyeball_is_a_flat_window():
    from creature_maker.record import adapt
    from creature_maker.form import Form
    from creature_maker.cage.eye import optics, CORNEA_SAG
    D = json.load(open(REC)); D['record']['skeleton']['eye']['aim'] = dict(up=8.0, fwd=10.0)
    import tempfile
    with tempfile.TemporaryDirectory() as t:
        p = os.path.join(t, 'r.json'); json.dump(D, open(p, 'w')); rec = adapt(p); F = Form(rec)
    assert F.ORBIT['aim_source'] == 'record skeleton.eye.aim' and abs(F.ORBIT['aim_up_deg'] - 8) < 1.5
    assert any(r['input'] == 'eye aim' for r in rec['provenance'])
    o = optics(rec['eye'], rec['eye']['d'] / 2)
    assert CORNEA_SAG[0] <= o['cornea_sag_R'] <= CORNEA_SAG[1] and o['lens_under_cornea_R'] > 0
    assert o['lens_r'] < o['pupil_r'] < rec['eye']['d'] / 2                 # the lens stands in a pupil wider than itself (aphakic gap)

def test_traced_tables_are_faired_and_the_loft_has_no_crease_or_ripple(tmp_path):
    """a traced top view and a traced section carry the trace's jitter (export r5: vertical bands, stripes along the body,
    dark rims). The form fairs each table by no more than its named tolerance, the section's boundary and its blend along
    the body are smooth (C1), and FM1 passes; jitter larger than the tolerance, or a section with a corner, is caught."""
    from creature_maker.record import adapt
    from creature_maker.form import Form, HW_FAIR_TOL, SECT_FAIR_TOL
    from creature_maker.checks import form_fair, FM1_RIPPLE_MAX, FM1_CREASE_MAX, _loft_normal
    D = json.load(open(REC)); O = D['record']['outline']; SL = O['end']; hw = np.array(O['hw']); rng = np.random.default_rng(3)
    s = np.linspace(-1, 1, 21); w = np.sqrt(np.clip(1 - s ** 2, 0, 1)) ** 0.8; w2 = np.clip(1 - np.abs(s) ** 3, 0, 1)

    def rec(name, jit_hw, jit_w, sections=True):
        E = json.loads(json.dumps(D)); xk = np.linspace(0, hw[-1, 0], 51); sg = np.where(np.arange(51) % 2, 1, -1) * (np.arange(51) % 50 > 0)
        E['record']['outline']['hw'] = [[float(a), float(max(b, 0))] for a, b in zip(xk, np.interp(xk, hw[:, 0], hw[:, 1]) + sg * jit_hw * SL)]
        if sections:
            E['record']['outline']['sections'] = [dict(u=u * SL, w=[[float(a), float(np.clip(b + jit_w * rng.uniform(-1, 1) * (0 < i < 20), 0, 1))] for i, (a, b) in enumerate(zip(s, w_))])
                                                  for u, w_ in ((0.35, w), (0.7, w2))]
        p = str(tmp_path / f'{name}.json'); json.dump(E, open(p, 'w')); return adapt(p)
    F = Form(rec('jit', 0.9 * HW_FAIR_TOL, 0.5 * SECT_FAIR_TOL)); R = form_fair(F)
    assert F.HW_FAIRED <= HW_FAIR_TOL + 1e-9 and F.SECT_FAIRED <= SECT_FAIR_TOL + 1e-9
    assert R['FM1_pass'], R
    # theta and the loft are inverses in the head (plain angle) and in the trunk (angle round the section's own shape)
    x = np.array([0.05, 0.2, 0.45, 0.6, 0.9]) * F.XEND; th = np.array([0.2, 1.0, 1.7, 2.6, 3.0]); P = F.loft_point(x, th)
    assert np.allclose(F.theta_of(P[:, 0], P[:, 1], P[:, 2]), th, atol=1e-9) and np.abs(F.sd_body(P)).max() < 1e-9
    # C1 along the body at a station: the normal just in front of the station is the normal just behind it
    for th_ in (0.4, 1.2, 2.5):
        n = _loft_normal(F, F.loft_point(np.array([0.35 - 2e-4, 0.35 + 2e-4]), np.full(2, th_)), 2e-5)
        assert np.degrees(np.arccos(np.clip(n[0] @ n[1], -1, 1))) < 0.5
    # the two sides meet on the midline without a crease: the normal a hair off the dorsal and ventral edge is the edge's own
    for x_ in (0.35, 0.55, 0.7):
        n = _loft_normal(F, F.loft_point(np.full(2, x_), np.array([1e-4, np.pi - 1e-4])), 2e-6)
        assert abs(n[0, 2]) < 0.05 and abs(n[1, 2]) < 0.05, n
    assert form_fair(Form(rec('ripple', 4 * HW_FAIR_TOL, 0.0, sections=False)))['FM1_ripple_deg'] > FM1_RIPPLE_MAX
    G = Form(rec('corner', 0.0, 0.0)); ph = G.SECT['phi']; c_, s_ = np.abs(np.cos(ph)), np.sin(ph)     # a rhombus, drawn row to row
    G.SECT['rho'][:] = 1 / (c_ + s_); G.SECT['drho'][:] = -(np.where(ph < np.pi / 2, -s_, s_) + np.cos(ph)) / (c_ + s_) ** 2
    assert form_fair(G)['FM1_crease_deg'] > FM1_CREASE_MAX
