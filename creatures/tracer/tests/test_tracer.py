"""species_tracer tests on the trevally (draft record = snapper template scaled; its FishBase photo's trace, segmentation mask and
fin-base points read by eye). The draft must FAIL SIL2 against its own photo, the traced record must PASS, and both planted faults
(template forehead, bulge under a fin) must be caught."""
import copy, json, os, sys
import numpy as np, cv2
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.dirname(HERE))
from species_tracer import write, check, silhouette, trace as TR

D = json.load(open(os.path.join(HERE, 'data', 'trevally_record.json')))
T0 = json.load(open(os.path.join(HERE, 'data', 'trevally_trace.json')))
FB = json.load(open(os.path.join(HERE, 'data', 'trevally_fin_base.json')))
MASK = cv2.imread(os.path.join(HERE, 'data', 'trevally_mask.png'), cv2.IMREAD_GRAYSCALE)
T = dict(T0, fin_base={'top': FB['top'], 'bot': FB['bot']})
SL = float(D['record']['outline']['end'])


def test_draft_fails_traced_passes():
    assert not check.silhouette_check(D, T, MASK)['pass']
    D2, rep = write.apply(D, T, 'trevally_trace', 'test')
    h = check.silhouette_check(D2, T, MASK, rep['notes']); assert h['pass'], h
    assert 'outline.top' in rep['measured'] and D2['_trace']['tool'].startswith('species_tracer')
    assert not [b for b in D2['record']['outline']['_bridges'] if b['kind'] == 'estimate']   # pelvic root: a short arc


def test_planted_faults_caught():
    D2, _ = write.apply(D, T, 'trevally_trace', 'test'); res = check.planted(D2, T, MASK)
    assert res == {'forehead': True, 'bulge': True}, res


def test_outline_runs_through_base_points():
    fr = TR.Frame(T, SL)
    for side in ('top', 'bot'):
        E, br = TR.body_edge(T, fr, side, SL); B = fr.to_rec(T['fin_base'][side])
        assert np.abs(np.interp(B[:, 0], E[:, 0], E[:, 1]) - B[:, 1]).max() < 0.0005 * SL      # within 0.05 % SL (the edge is sampled every 0.5 % SL)


def test_arc_bridge_without_base_points_is_convex_and_labelled():
    fr = TR.Frame(T0, SL)
    for side, sg in (('top', 1), ('bot', -1)):
        E, br = TR.body_edge(T0, fr, side, SL); assert br
        for u0, u1, kind in br:
            assert kind in ('short', 'estimate') and (kind == 'short') == (u1 - u0 <= TR.BASE_GAP * SL)
            seg = E[(E[:, 0] >= u0) & (E[:, 0] <= u1)]
            chord = seg[0, 1] + (seg[:, 0] - seg[0, 0]) * (seg[-1, 1] - seg[0, 1]) / (seg[-1, 0] - seg[0, 0])
            assert (sg * (seg[:, 1] - chord) >= -1e-6).all(), (side, u0, u1)     # convex: never inside the chord


def test_stations_keep_a_corner():
    u = np.linspace(0, 100, 1001); E = np.c_[u, np.where(u < 33, 0.0, (u - 33) * 0.5)]   # a kink between fixed stations
    st = write.refine(E, [0, 10, 20, 40, 60, 80, 100], 0.15)
    y = np.interp(u, st, np.interp(st, E[:, 0], E[:, 1])); assert np.abs(y - E[:, 1]).max() <= 0.15


def test_median_fin_edges_written_front_to_back():
    D2, _ = write.apply(D, T, 'trevally_trace', 'test'); M = D2['record']['skeleton']['median']
    for k in ('d2', 'an'): e = M[k]['edge']; assert e[0][0] < e[-1][0] and abs(e[0][0] - M[k]['u'][0]) < 0.02 * SL
    c = M['caudal']['edge']; assert c[0][1] > c[-1][1]


def test_eye_held_inside_outline():
    T2 = copy.deepcopy(T); T2['eye'] = list(T2['eye']); T2['eye'][2] = T2['eye'][2] * 3     # an eye far too big for the head
    D2, rep = write.apply(D, T2, 'trevally_trace', 'test'); assert any(n.startswith('eye R') for n in rep['notes'])
    assert not [n for n in rep['notes'] if n.startswith('FAULT eye')]


def test_silhouette_reference_units():
    ref = silhouette.reference(T, SL, 'test', 'test')
    xs = [p[0] for p in ref['side']]; assert min(xs) < 0.02 and max(xs) > 1.05      # snout at 0, caudal fin past SL end


def test_outline_u_strictly_increasing():
    D2, _ = write.apply(D, T, 'trevally_trace', 'test')
    for side in ('top', 'bot'):
        u = [p[0] for p in D2['record']['outline'][side]]; assert all(b > a for a, b in zip(u, u[1:])), side


def test_adult_size_and_swim_timing():
    D2, rep = write.apply(D, T, 'trevally_trace', 'test'); S = D2['record']['size']; M = D2['body']['motion']
    assert S['TL_mm'] == D['body']['L'] and 1.05 < S['TL_over_SL'] < 1.4 and abs(S['SL_mm'] - S['mm_per_unit'] * SL) < 0.5
    assert M['U'] < 1.5 and abs(M['f'] - 0.3 * M['U'] / (2 * M['A'])) < 0.01      # a 60 cm fish cruises at fewer BL/s than the 25 cm reference


def test_views_top_and_apply():
    """a synthetic top view: an ellipse body with a caudal fin swung to one side; the tail rise must be dropped, and apply()
    must write hw in record units and rescale a front section to the top view's width."""
    import numpy as np
    from species_tracer import views
    H, W = 400, 200; yy, xx = np.mgrid[:H, :W]
    m = ((xx - 100) / 30.0) ** 2 + ((yy - 170) / 150.0) ** 2 <= 1          # body: snout y 20, SL 300 px (tail at 320)
    m |= (yy > 300) & (yy < 340) & (xx > 100) & (xx < 100 + (yy - 300) * 1.5)   # caudal fin swung to the right
    r = views.top(None, (100, 20), (100, 20 + 300 * 1.15), 1.15, m=m)
    hw = np.array(r['hw'])[:, 1]; i = int(np.argmax(hw))
    assert abs(hw.max() - 0.1) < 0.01 and (np.diff(hw[i:]) <= 1e-9).all()
    D = {'record': {'outline': {'end': 170.0, 'top': [[0, 0], [85, 30], [170, 2]], 'bot': [[0, 0], [85, -30], [170, -2]],
                                'hw': [[0, 0], [170, 2], [180, 1]]}}}
    front = dict(front=[[0.05, 0.1], [-0.05, -0.1]], w=[[-1, 0], [0, 1], [1, 0]], half_width_max=0.05)
    D, sil = views.apply(D, {}, r, front, {})
    O = D['record']['outline']
    assert abs(max(w for u, w in O['hw']) - 17.0) < 2 and O['hw'][-1][0] == 180
    assert len(O['sections']) == 1 and abs(sil['front'][0][0] - 0.1) < 0.012
