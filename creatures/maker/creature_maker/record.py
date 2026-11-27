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
    out = dict(species=D.get('species'), label=get(R, 'name', '', need=False), SL_mm=float(get(R, 'SL', SL, need=False)))
    sc = lambda tab: [[a * f, b * f] for a, b in tab]
    out['outline'] = dict(top=sc(O['top']), bot=sc(O['bot']), hw=sc(O['hw']),
                          nUp=[[a * f, b] for a, b in O['nUp']], nLo=[[a * f, b] for a, b in O['nLo']])
    P('body loft', 'record.outline top/bot/hw/nUp/nLo (/ outline.end)')
    E = R['skeleton']['eye']
    out['eye'] = dict(x=E['u'] * f, y=E['y'] * f, d=2 * E['R'] * f, orbit=dget(E, 'orbitR', E['R'] / 0.8, 'skeleton.eye') * f,
                      iris=get(E, 'iris', [0.92, 0.62, 0.18], need=False, where='skeleton.eye'), pupil=get(E, 'pupil', 0.42, need=False, where='skeleton.eye'))
    P('eye opening', 'record.skeleton.eye.u/y/R (R = visible eye, 0.8 orbitR); orbit ring from orbitR')
    seam = np.array(get(R, 'mouth.seam')) * f
    out['mouth'] = dict(line=seam.tolist(), maxilla_h=float(get(R, 'mouth.maxilla_h', 0.18 * (seam[-1, 0] - seam[0, 0]) + 0.012, need=False)))
    P('mouth cleft + maxilla', 'record.mouth.seam')
    G = R['skeleton']['gills']
    margin = [[a * f, b * f] for a, b in G['opercle']['margin']]
    sub = [[p[0] * f, p[1] * f] for p in dget(G, 'subopercle', [], 'skeleton.gills')]
    rear = margin + [p for p in sub[::-1] if p[1] < margin[-1][1]]       # cover free edge: opercle margin then subopercle
    rear = sorted(rear, key=lambda p: -p[1])
    preop = [[p[0] * f, p[1] * f] for p in G['preopercle']]
    out['cover'] = dict(rear=rear, preop=preop, step=float(get(R, 'skeleton.gills.step', 0.006 * SL, need=False)) * f)
    P('opercle plate', 'record.skeleton.gills.opercle.margin + subopercle'); P('preopercle plate', 'record.skeleton.gills.preopercle')
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
    med = []
    for key, top in (('d1', True), ('d2', True), ('an', False)):
        if key in M:
            m = M[key]; med.append(dict(name={'d1': 'dorsal1', 'd2': 'dorsal2', 'an': 'anal'}[key], base=[m['u'][0] * f, m['u'][1] * f],
                                        h=[v * f for v in m['h']], lean=dget(m, 'lean', [35, 55], 'skeleton.median.<fin>'), top=top,
                                        rays=len(m['h']) + dget(m, 'spines', 0, 'skeleton.median.<fin>')))
            P(f'fin {key}', f'record.skeleton.median.{key} (u, h, lean, spines)')
    if 'd' in M:  # single dorsal fin records
        m = M['d']; med.append(dict(name='dorsal', base=[m['u'][0] * f, m['u'][1] * f], h=[v * f for v in m['h']], lean=dget(m, 'lean', [35, 55], 'skeleton.median.<fin>'), top=True, rays=len(m['h']) + dget(m, 'spines', 0, 'skeleton.median.<fin>')))
    fins['median'] = med
    C = M['caudal']
    fins['caudal'] = dict(x=dget(dget(C, 'proc', {}, 'skeleton.median.caudal'), 'uUp', SL, 'skeleton.median.caudal.proc') * f, len=C['len'] * f, spread=C['spread'], outline=C['outline'] if 'outline' in C else caudal_outline(C['round']), rays=dget(C, 'n', 17, 'skeleton.median.caudal'))
    P('caudal fin', 'record.skeleton.median.caudal (proc.uUp, len, spread deg, outline; else outline from caudal.round)')
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
    ll = get(S, 'lateral_line.pored_scales', None, need=False) or get(S, 'grow.lateral_line.pored_scales.value', None, need=False)
    rows = float(np.mean(ll)) if ll else float(dget(S, 'rows', 60, 'scales'))
    naked = 'naked' in str(get(S, 'grow.type_body.value', '', need=False))
    if naked: rows = 0.0                     # naked skin (blennies): no scale relief
    elif rows <= 0:                          # record: 0 = "none or too small to count" on a scaled body -> minute scales
        rows = 150.0; DEFAULTS.append(dict(input='scales.rows', source='DEFAULT', value=150, note='scaled body with rows 0: minute scales'))
    out['scales'] = dict(lateral_line=rows, ll_frac=float(get(S, 'll_frac', 0.27, need=False, where='scales')),
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
    k = float(style.get('girth', 1.0)); out['outline']['hw'] = [[a, b * k] for a, b in out['outline']['hw']]
    out['style'] = {k_: float(v) for k_, v in style.items()}
    P('style deviation', 'command line --style ' + ','.join(f'{k_}={v}' for k_, v in sorted(style.items())))


def parse_style(s):
    """'eye=1.4,mouth=1.2' -> {'eye': 1.4, 'mouth': 1.2}"""
    return {a.strip(): float(b) for a, b in (kv.split('=') for kv in s.split(',') if kv.strip())} if s else {}

if __name__ == '__main__':
    import sys; a = adapt(sys.argv[1]); print(json.dumps({k: (v if k in ('eye', 'cover', 'paint', 'input_faults', 'bones') else '...') for k, v in a.items()}, indent=1)[:3000])
