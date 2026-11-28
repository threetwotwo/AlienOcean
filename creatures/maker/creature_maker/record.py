"""Stage 1, RECORD: read a NATIVE Species record (alien-ocean/sculptor-record/1) and return the form inputs in SL units.
One code path for every species; every value names the record field it came from (provenance), and a missing required field fails
loudly, and every optional field that falls back to a default is listed as a DEFAULT provenance row (lesson 48: never swallow a missing input into a silent default).
"""
import json, math
import numpy as np

class MissingField(KeyError): pass

DEFAULTS = []   # every fallback used is listed as a DEFAULT provenance row (critique 0.2.0 cond. 2): nothing is silently filled
def get(d, path, default=None, need=True, where=''):
    cur = d
    for k in path.split('.'):
        if isinstance(cur, dict) and k in cur: cur = cur[k]
        else:
            if need and default is None: raise MissingField(path)
            if default is not None: DEFAULTS.append(dict(input=(where + '.' if where else '') + path, source='DEFAULT', value=default if not isinstance(default, np.ndarray) else default.tolist()))
            return default
    return cur
LL_FRAC = 0.27       # DEFAULT: lateral line height as a share of depth when the record has none
SPINE_NOTCH = 0.22   # DEFAULT: membrane dip between spine tips, share of the spine length (seabream/snapper-like; deep-notched fins say so in the record)

def eye_iris(R, E):
    """iris colour: record paint.eye.iris (hex, read from photos) where present, else skeleton.eye.iris, else the DEFAULT gold."""
    h = get(R, 'paint.eye.iris', None, need=False)
    if isinstance(h, str) and h.startswith('#'): return hex_rgb(h)
    return get(E, 'iris', [0.92, 0.62, 0.18], need=False, where='skeleton.eye')

def dget(d, key, default, where):
    """dict.get that records the default it fell back to."""
    if isinstance(d, dict) and key in d: return d[key]       # a record may hold a bare number where a block is expected (0 = none)
    DEFAULTS.append(dict(input=f'{where}.{key}', source='DEFAULT', value=default)); return default

def hex_rgb(h):
    h = h.lstrip('#'); return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]

def srgb_to_lin(c): c = np.asarray(c, float); return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)

def lstar_to_Y(L): return ((L + 16) / 116) ** 3 if L > 8 else L / 903.3

def cells_rgb(c, L=None):
    """STAND-IN pigment mix from the record's chromatophore cells (M melanin, X xanthophore, E erythrophore) to linear RGB,
    scaled to the record's measured L* when given. Root: the old paint LUT (parts/paint.js) is not ported yet."""
    rgb = np.ones(3)
    rgb *= 1 - 0.8 * c.get('M', 0)
    rgb[2] *= 1 - 0.75 * c.get('X', 0); rgb[1] *= 1 - 0.15 * c.get('X', 0)
    rgb[1] *= 1 - 0.85 * c.get('E', 0); rgb[2] *= 1 - 0.9 * c.get('E', 0)
    if L is not None:
        Y = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]; rgb *= lstar_to_Y(L) / max(Y, 1e-6)
    return np.clip(rgb, 0, 1).tolist()

def caudal_outline(rnd):
    """caudal ray-length profile (tip -1..1 -> length share) from record caudal.round when no outline is given:
    round < 0 forks (centre 1 + 0.8 round: trevally -0.9 -> 0.28, its drawn outline), round > 0 rounds (lobes shorter)."""
    ty = np.linspace(-1, 1, 9)
    f = 1 + 0.8 * rnd * (1 - np.abs(ty)) ** 0.8 if rnd < 0 else 1 - 0.6 * rnd * ty ** 2
    return [[float(a), float(b)] for a, b in zip(ty, f)]


def adapt(path, style=None):
    D = json.load(open(path)); R = D['record']; prov = []; DEFAULTS.clear()
    SL = float(get(R, 'outline.end')); f = 1.0 / SL
    def P(name, src): prov.append(dict(input=name, source=src))
    O = R['outline']
    # real size: record.size.SL_mm (measured standard length of an adult); record.SL is the outline length in record
    # units on older records, so it is only the fallback, listed as a DEFAULT row when used
    sl_mm = get(R, 'size.SL_mm', None, need=False)
    if sl_mm is None: sl_mm = get(R, 'SL', SL, need=False); DEFAULTS.append(dict(input='size.SL_mm', source='DEFAULT', value=f'record.SL ({sl_mm}), outline units, not mm'))
    out = dict(species=D.get('species'), label=get(R, 'name', '', need=False), SL_mm=float(sl_mm))
    sc = lambda tab: [[a * f, b * f] for a, b in tab]
    out['outline'] = dict(top=sc(O['top']), bot=sc(O['bot']), hw=sc(O['hw']),
                          nUp=[[a * f, b] for a, b in O['nUp']], nLo=[[a * f, b] for a, b in O['nLo']])
    if O.get('sections'):     # traced cross-sections: x in record units, w as [s, half-width share] (form.Form._sections)
        out['outline']['sections'] = [dict(x=q['u'] * f, w=q['w']) for q in O['sections']]
        P('body cross-section', 'record.outline.sections (traced: u, w = [s -1 ventral .. +1 dorsal, half-width 0..1])')
    else: DEFAULTS.append(dict(input='outline.sections', source='DEFAULT', value='two half superellipses from nUp/nLo, widest at mid-height'))
    P('body loft', 'record.outline top/bot/hw/nUp/nLo (/ outline.end)')
    E = R['skeleton']['eye']
    out['eye'] = dict(x=E['u'] * f, y=E['y'] * f, d=2 * E['R'] * f, orbit=dget(E, 'orbitR', E['R'] / 0.8, 'skeleton.eye') * f,
                      iris=eye_iris(R, E), pupil=get(E, 'pupil', 0.42, need=False, where='skeleton.eye'))
    P('eye opening', 'record.skeleton.eye.u/y/R (R = visible eye, 0.8 orbitR); orbit ring from orbitR')
    seam = np.array(get(R, 'mouth.seam')) * f
    out['mouth'] = dict(line=seam.tolist(), maxilla_h=float(get(R, 'mouth.maxilla_h', 0.18 * (seam[-1, 0] - seam[0, 0]) + 0.012, need=False)))
    P('mouth cleft + maxilla', 'record.mouth.seam')
    G = R['skeleton']['gills']
    margin = [[a * f, b * f] for a, b in G['opercle']['margin']]
    sub = [[p[0] * f, p[1] * f] for p in dget(G, 'subopercle', [], 'skeleton.gills')]
    if sub and math.dist(sub[0], margin[-1]) < math.dist(sub[-1], margin[-1]): sub = sub[::-1]   # either order: walk away from the margin
    sub = sub[::-1]
    # cover free edge, side part: opercle margin, then the subopercle down to the cover's lower corner, where it turns to run
    # more forward than down. The forward part is the ventral margin (it scrambled a y-sorted rear edge; and on a deep belly
    # the subopercle's lowest point is its front end, not the corner)
    k = next((m for m in range(1, len(sub) - 1) if sub[m + 1][0] - sub[m][0] < -abs(sub[m + 1][1] - sub[m][1])), len(sub) - 1)
    rear = sorted(margin + [p for p in sub[:k + 1] if p[1] < margin[-1][1]], key=lambda p: -p[1])
    preop = [[p[0] * f, p[1] * f] for p in G['preopercle']]
    out['cover'] = dict(rear=rear, preop=preop, step=float(get(R, 'skeleton.gills.step', 0.006 * SL, need=False)) * f)
    # the slit's ring is taken from the whole free edge, ventral margin too: from the side part alone it fell one ring
    # further back on deep bodies, where the flap crossed the body skin
    out['cover']['edge_all'] = sorted(margin + [p for p in sub if p[1] < margin[-1][1]], key=lambda p: -p[1])
    P('opercle plate', 'record.skeleton.gills.opercle.margin + subopercle (to the lower corner)'); P('preopercle plate', 'record.skeleton.gills.preopercle')
    # under the head the free edge runs on forward (subopercle, interopercle, branchiostegal membrane) and ends on the
    # isthmus at the interopercle's front end: the apex of the gill V
    io = [p[0] * f for p in dget(G, 'interopercle', [], 'skeleton.gills')]
    out['cover']['apex_x'] = min(io) if io else None
    if io: P('gill V: apex', 'record.skeleton.gills.interopercle (front end)')
    # branchiostegal fan {n, th0, dth}: ray k ends at angle th0 + k dth round the section (degrees, 0 = flank, -90 = ventral
    # midline; the section scaled to its half-width). The first ray is the membrane's inner end: 90 + th0 is the isthmus
    # half-angle. The last ray is where the membrane starts under the cover. (t0, dt, u1, du lie inside the head: not used.)
    BS = dget(G, 'branchiostegals', {}, 'skeleton.gills')
    th0, dth, nbs = (float(dget(BS, k_, v_, 'skeleton.gills.branchiostegals')) for k_, v_ in (('th0', -70), ('dth', 9), ('n', 6)))
    out['cover']['isthmus_deg'] = float(np.clip(90 + th0, 5, 45)); out['cover']['membrane_top_deg'] = float(min(-th0 - (nbs - 1) * dth, 80))
    P('gill V: isthmus and membrane angles', 'record.skeleton.gills.branchiostegals th0, dth, n')
    # lower jaw from below: the ramus runs between the dentary line (outer) and the mandible's lower edge (inner), [x, y, z]
    J = R.get('jaw') or {}; dn, lo = J.get('dentary'), J.get('mandibleLow')
    out['jaw'] = dict(dentary=[[v * f for v in p] for p in dn] if dn else None, low=[[v * f for v in p] for p in lo] if lo else None)
    if not dn: DEFAULTS.append(dict(input='jaw.dentary', source='DEFAULT', value='mouth tip to jaw joint, on the skin'))
    if not lo: DEFAULTS.append(dict(input='jaw.mandibleLow', source='DEFAULT', value='half the dentary width, meeting at the chin'))
    if not io: DEFAULTS.append(dict(input='skeleton.gills.interopercle (apex of the gill V)', source='DEFAULT', value='jaw joint x'))
    if dn: P('lower-jaw V (rami)', 'record.jaw.dentary + jaw.mandibleLow')
    out['gill_u'] = float(get(R, 'gill.u')) * f
    # jaw joint (quadrate-articular) and opercle hinge: the pivots for the gape and gill-flare poses
    xr, yr = seam[-1]; ml_ = seam[-1, 0] - seam[0, 0]
    jj = get(R, 'skeleton.jawJoint', None, need=False)
    if jj is not None: out['jaw_joint'] = [jj[0] * f, jj[1] * f]; P('jaw joint', 'record.skeleton.jawJoint')
    else:
        out['jaw_joint'] = [float(xr + 0.3 * ml_), float(yr - 0.15 * ml_)]
        DEFAULTS.append(dict(input='skeleton.jawJoint', source='DEFAULT', value='behind and below the rictus (0.3, -0.15 mouth lengths)'))
    hg = get(G, 'opercle.hinge', None, need=False)
    if hg is not None: out['opercle_hinge'] = [hg[0] * f, hg[1] * f]; P('opercle hinge', 'record.skeleton.gills.opercle.hinge')
    else:
        top_ = max(preop, key=lambda p: p[1]); out['opercle_hinge'] = [float(top_[0]), float(top_[1])]
        DEFAULTS.append(dict(input='skeleton.gills.opercle.hinge', source='DEFAULT', value='top of the preopercle margin'))
    gp = get(R, 'jaw.linkage.gape', None, need=False)
    if gp is not None: out['gape_deg'] = float(gp); P('real gape (deg)', 'record.jaw.linkage.gape')
    else:
        out['gape_deg'] = 30.0; DEFAULTS.append(dict(input='jaw.linkage.gape', source='DEFAULT', value=30))
    M = R['skeleton']['median']; fins = {}
    # a traced fin carries its free edge (ray tips, first ray to last, record units): the card's rays end on it, so the
    # fin's side silhouette is the photo's, not one guessed from heights and a lean (SIL1, Gary 27 Nov)
    fin_edge = lambda m: sc(m['edge']) if isinstance(m, dict) and m.get('edge') else None
    def fin_elements(m):
        # h lists every element of the fin, front to back, spines first (record h counts the spines: d1 h == spines), so the
        # ray count is len(h) and the first `spines` of them are spines. The membrane dips between spine tips by `notch`, a
        # share of the spine length (record skeleton.median.<fin>.notch when traced; SPINE_NOTCH otherwise)
        sp = int(dget(m, 'spines', 0, 'skeleton.median.<fin>'))
        return dict(rays=len(m['h']), spines=sp, notch=float(dget(m, 'notch', SPINE_NOTCH, 'skeleton.median.<fin>')) if sp else 0.0)
    med = []
    for key, top in (('d1', True), ('d2', True), ('an', False)):
        if key in M:
            m = M[key]; med.append(dict(name={'d1': 'dorsal1', 'd2': 'dorsal2', 'an': 'anal'}[key], base=[m['u'][0] * f, m['u'][1] * f],
                                        h=[v * f for v in m['h']], lean=dget(m, 'lean', [35, 55], 'skeleton.median.<fin>'), top=top,
                                        edge=fin_edge(m), **fin_elements(m)))
            P(f'fin {key}', f'record.skeleton.median.{key} ' + ('(u, edge traced: ray tips on the free edge, spines)' if 'edge' in m else '(u, h, lean, spines)'))
    if 'd' in M:  # single dorsal fin records
        m = M['d']; med.append(dict(name='dorsal', base=[m['u'][0] * f, m['u'][1] * f], h=[v * f for v in m['h']], lean=dget(m, 'lean', [35, 55], 'skeleton.median.<fin>'), top=True, edge=fin_edge(m), **fin_elements(m)))
    fins['median'] = med
    C = M['caudal']
    fins['caudal'] = dict(x=dget(dget(C, 'proc', {}, 'skeleton.median.caudal'), 'uUp', SL, 'skeleton.median.caudal.proc') * f, len=C['len'] * f, spread=C['spread'], outline=C['outline'] if 'outline' in C else caudal_outline(C['round']), rays=dget(C, 'n', 17, 'skeleton.median.caudal'), edge=fin_edge(C))
    P('caudal fin', 'record.skeleton.median.caudal ' + ('(proc.uUp, edge traced: ray tips upper lobe to lower lobe)' if C.get('edge') else '(proc.uUp, len, spread deg, outline; else outline from caudal.round)'))
    PE = R['skeleton']['pectoral']
    fins['pectoral'] = dict(x=PE['base']['u'] * f, y=PE['base']['y'] * f, len=PE['length'], span=[s * f for s in dget(PE, 'span', [3, -3], 'skeleton.pectoral')],
                            sweep=dget(PE, 'sweep', [20, -30], 'skeleton.pectoral'), out=dget(PE, 'out', 30, 'skeleton.pectoral'), prof=dget(PE, 'prof', [[0, 1], [1, 0.4]], 'skeleton.pectoral'), rays=dget(PE, 'rays', 14, 'skeleton.pectoral'))
    P('pectoral fin', 'record.skeleton.pectoral (base, length (SL), span, sweep, out, prof)')
    if 'pelvic' in R['skeleton']:            # puffers, porcupinefish, filefish have no pelvic fins (anatomy, not a gap)
        PV = R['skeleton']['pelvic']
        fins['pelvic'] = dict(x=PV['base']['u'] * f, y=PV['base']['y'] * f, len=PV['length'], sweep=dget(PV, 'sweep', [40, -10], 'skeleton.pelvic'), out=dget(PV, 'out', 30, 'skeleton.pelvic'),
                              prof=dget(PV, 'prof', [[0, 1], [1, 0.6]], 'skeleton.pelvic'), rays=dget(PV, 'rays', 6, 'skeleton.pelvic') + dget(PV, 'spines', 0, 'skeleton.pelvic'))
        P('pelvic fin', 'record.skeleton.pelvic (base, length (SL), sweep, out, prof)')
    else: P('pelvic fin', 'absent in record.skeleton (no pelvic fins)')
    out['fins'] = fins
    S = R.get('scales', {})
    # pored scales: older records hold them at scales.lateral_line, grown ones at scales.grow.lateral_line, as a [lo, hi]
    # list or a {value: ...} block (the list form was missed: trevally fell back to the rows ESTIMATE, scales 25 % small)
    pv = lambda v: v.get('value') if isinstance(v, dict) else v
    ll = pv(get(S, 'lateral_line.pored_scales', None, need=False)) or pv(get(S, 'grow.lateral_line.pored_scales', None, need=False))
    rows = float(np.mean(ll)) if ll else float(dget(S, 'rows', 60, 'scales'))
    naked = 'naked' in str(get(S, 'grow.type_body.value', '', need=False))
    if naked: rows = 0.0                     # naked skin (blennies): no scale relief
    elif rows <= 0:                          # record: 0 = "none or too small to count" on a scaled body -> minute scales
        rows = 150.0; DEFAULTS.append(dict(input='scales.rows', source='DEFAULT', value=150, note='scaled body with rows 0: minute scales'))
    if not (get(S, 'll_frac', None, need=False) or get(S, 'grow.lateral_line.ll_frac', None, need=False)):
        DEFAULTS.append(dict(input='scales.grow.lateral_line.ll_frac', source='DEFAULT', value=LL_FRAC))
    out['scales'] = dict(lateral_line=rows, ll_frac=float(get(S, 'll_frac', None, need=False) or get(S, 'grow.lateral_line.ll_frac', None, need=False) or LL_FRAC),
                         type=get(S, 'grow.type_body.value', get(S, 'type', 'ctenoid', need=False), need=False))
    P('scale height (UV)', 'record.scales lateral_line pored_scales (else scales.rows)')
    G0 = R['paint']['ground']; sh = dget(G0, 'shade', {}, 'paint.ground')
    back = cells_rgb(G0['back'], dget(sh, 'back_L', None, 'paint.ground.shade')); belly = cells_rgb(G0['belly'], dget(sh, 'belly_L', None, 'paint.ground.shade'))
    flank = (np.array(back) * 0.45 + np.array(belly) * 0.55).tolist()
    fin_ic = get(R, 'paint.fins.all.cells.ic', None, need=False)
    fin = srgb_to_lin(hex_rgb(fin_ic)).tolist() if fin_ic else back
    metal = dict(back=0.25 + 0.5 * dget(G0['back'], 'I', 0.2, 'paint.ground.back'), flank=0.35 + 0.5 * (dget(G0['back'], 'I', 0.2, 'paint.ground.back') + dget(G0['belly'], 'I', 0.5, 'paint.ground.belly')) / 2,
                 belly=0.35 + 0.5 * dget(G0['belly'], 'I', 0.5, 'paint.ground.belly'))
    out['paint'] = dict(back=back, flank=flank, belly=belly, fin=fin, metal=metal, rough=0.32,
                        line=float(dget(G0, 'line', -0.3, 'paint.ground')), fin_alpha=float(get(R, 'paint.fins.all.alpha', 0.85, need=False)))
    P('coat (STAND-IN)', 'record.paint.ground back/belly cells + shade L*; fins.all.cells.ic; grown layer not yet ported')
    out['bones'] = int(min(get(D, 'body.motion.bones', 8, need=False), 10)) if get(D, 'body.motion.bones', None, need=False) else 8
    if style: stylize(out, style, P)
    _u = {}
    for d in DEFAULTS: _u.setdefault(d['input'], d)
    out['provenance'] = prov + list(_u.values())
    out['defaults_used'] = list(_u)
    # input checks (lesson 18, 44): fail loudly
    chk = []
    if fins['pectoral']['x'] <= out['gill_u']: chk.append('pectoral base in front of gill.u')
    if not (0.02 < out['eye']['d'] < 0.25): chk.append('eye size out of range')
    out['input_faults'] = chk
    return out


STYLE_KNOBS = ('eye', 'mouth', 'girth')


def stylize(out, style, P):
    """art-direction deviations from the record, as plain multipliers (1 = the record): eye = eye and orbit diameter,
    mouth = mouth line, maxilla and jaw joint scaled about the mouth tip (a longer gape), girth = half-width of the whole
    body. They act on the adapted record, so every later stage and check sees one consistent fish."""
    bad = set(style) - set(STYLE_KNOBS)
    if bad: raise ValueError(f'unknown style knob(s) {sorted(bad)}; known: {STYLE_KNOBS}')
    k = float(style.get('eye', 1.0)); out['eye']['d'] *= k; out['eye']['orbit'] *= k
    k = float(style.get('mouth', 1.0))
    ml = np.array(out['mouth']['line']); tip = ml[np.argmin(ml[:, 0])]
    out['mouth']['line'] = (tip + k * (ml - tip)).tolist(); out['mouth']['maxilla_h'] *= k
    out['jaw_joint'] = (tip + k * (np.array(out['jaw_joint']) - tip)).tolist()
    for key in ('dentary', 'low'):                        # the rami follow the mouth
        if out['jaw'][key]: out['jaw'][key] = [list(tip + k * (np.array(p[:2]) - tip)) + [p[2]] for p in out['jaw'][key]]
    if out['cover']['apex_x'] is not None: out['cover']['apex_x'] = max(out['cover']['apex_x'], out['jaw_joint'][0])
    k = float(style.get('girth', 1.0)); out['outline']['hw'] = [[a, b * k] for a, b in out['outline']['hw']]
    for key in ('dentary', 'low'):
        if out['jaw'][key]: out['jaw'][key] = [[p[0], p[1], p[2] * k] for p in out['jaw'][key]]
    out['style'] = {k_: float(v) for k_, v in style.items()}
    P('style deviation', 'command line --style ' + ','.join(f'{k_}={v}' for k_, v in sorted(style.items())))


def parse_style(s):
    """'eye=1.4,mouth=1.2' -> {'eye': 1.4, 'mouth': 1.2}"""
    return {a.strip(): float(b) for a, b in (kv.split('=') for kv in s.split(',') if kv.strip())} if s else {}

if __name__ == '__main__':
    import sys; a = adapt(sys.argv[1]); print(json.dumps({k: (v if k in ('eye', 'cover', 'paint', 'input_faults', 'bones') else '...') for k, v in a.items()}, indent=1)[:3000])
