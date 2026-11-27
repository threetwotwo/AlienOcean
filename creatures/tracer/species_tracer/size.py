"""Adult size and size-scaled swim timing, at the record level (coordinator 27 Nov: the maker's trevally came out 17 cm because
record.SL is the outline's length in record units, not millimetres).

size  record.size = {TL_mm, SL_mm, mm_per_unit}: TL_mm = body.L (the adult total length from the species' references, written by
      the record generators: make_stress.py "Lref 200 = total length", spec mm), SL_mm = TL_mm x SL / TL measured on the species'
      own photo (snout to caudal base over snout to the caudal fin's rearmost tip, trace frame). record.SL is left as it is
      (record units = outline.end) because other readers use it so.
swim  body.motion.U (cruise, BL/s) and f (tail beats per s) for this fish's size, in place of the snapper reference's numbers:
      U = U_REF x (L_REF / TL_mm)^0.5: absolute cruise speed grows as the square root of length (optimal cruising speed scaling,
      Weihs 1973 / Ware 1978), anchored at the snapper hero record's own 1.5 BL/s at 250 mm (itself an ESTIMATE);
      f = St x U / (2 A): the Strouhal number of efficient cruising, St 0.3 (Triantafyllou et al. 1993; Taylor et al. 2003),
      over the tail's peak-to-peak excursion 2 A (body.motion.A, BL). Both ESTIMATE until this species is timed on footage;
      the gait style (body wave, median- or pectoral-fin swimming) is not changed here.
"""
import numpy as np

U_REF, L_REF, ST = 1.5, 250.0, 0.3


def tl_over_sl(T, fr, SL):
    F = (T.get('fins') or {}).get('caudal') or {}
    if len(F.get('edge') or []) < 3: return None
    return float(fr.to_rec(F['edge'])[:, 0].max()) / SL


def apply(D, T, fr, rep):
    R = D['record']; SL = float(R['outline']['end']); TL_mm = (D.get('body') or {}).get('L')
    if not TL_mm: rep['notes'].append('size: no body.L (adult length) in the record; real size unknown'); return
    k = tl_over_sl(T, fr, SL)
    if k is None or not (1.02 < k < 1.6):
        rep['notes'].append(f'size: caudal tip not traced (TL/SL {k}); SL_mm left unset'); return
    SL_mm = TL_mm / k
    R['size'] = dict(TL_mm=round(float(TL_mm), 1), SL_mm=round(SL_mm, 1), mm_per_unit=round(SL_mm / SL, 5), TL_over_SL=round(k, 4),
                     _origin=f'TL_mm = body.L (adult total length from the species references); TL/SL {k:.3f} MEASURED on the photo '
                             f'trace (caudal fin rearmost tip over caudal base); SL_mm = TL_mm / (TL/SL); mm_per_unit = SL_mm / outline.end')
    rep['measured'].append('record.size.TL_over_SL'); rep['estimate'].append('record.size.TL_mm (references, not this photo)')
    M = (D.get('body') or {}).get('motion')
    if isinstance(M, dict) and M.get('A'):
        U = U_REF * (L_REF / TL_mm) ** 0.5; f = ST * U / (2 * float(M['A']))
        old = dict(U=M.get('U'), f=M.get('f'))
        M['U'], M['f'], M['St'] = round(U, 3), round(f, 3), ST
        M['src'] = (f'ESTIMATE scaled to this fish: U = {U_REF} BL/s x (250 mm / {TL_mm:g} mm)^0.5 (cruise speed grows as the square root of '
                    f'length, Weihs 1973 / Ware 1978; anchored at the snapper hero record), f = St {ST} x U / (2 A) (efficient cruising '
                    f'Strouhal number, Triantafyllou 1993, Taylor 2003). Was U {old["U"]}, f {old["f"]} (the snapper reference). '
                    'Gait style unchanged; time this species on footage to replace.')
        rep['estimate'].append('body.motion.U, f (size-scaled)')
