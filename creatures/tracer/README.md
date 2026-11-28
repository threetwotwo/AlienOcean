# Species tracer

Version: 0.1.0

Writes a fish's side silhouette from its own photo into its native Species record (alien-ocean/sculptor-record/1), in place
of the drafted values (the snapper template scaled), and checks the result against the photo. Silhouettes come before any
detail work (Gary, 27 Nov): a record that fails here is not built on.

It reuses the shared photo tracer (plans/text_species/tools/autotrace.py: BiRefNet segmentation + potrace + landmarks read
by eye); this package only turns that trace into record fields, checks them and draws the pictures. One rule for every
species, no species names in the code.

## Run

```
pip install -r requirements.txt
cd creatures/tracer
python -m species_tracer run MANIFEST --out DIR            # traced records, overlays, SIL1 silhouettes, run_report.json
python -m species_tracer run MANIFEST --write              # also replace each PASSING record (old copy kept) + silhouette
python -m species_tracer check MANIFEST                    # SIL2 on the records as they stand
python -m pytest -q tests
```

MANIFEST (JSON): `{"records_root": DIR, "fin_bases": DIR, "rows": [{"species", "record", "trace", "photo", "box"?}]}`.
The live one is plans/species_trace/manifest.json in project files.

## What it writes (write.py)

| Field | From | Label |
|---|---|---|
| outline.top / bot | photo body edge at fixed stations (dense at the head) plus extra stations wherever a straight run would leave the edge by more than 0.15 % SL; first station = the lip block at 0.6 % SL | MEASURED (part ESTIMATE when a span under a fin had no base points) |
| under the dorsal / anal fin | through fin-base points read by eye on the same photo (monotone cubic); short gaps under 10 % SL with no points: convex arc | MEASURED / ESTIMATE, listed in outline._bridges |
| skeleton.eye u, y, R | eye landmark; R held 0.3 % SL inside the outline when the photo eye reaches the profile | MEASURED (R ESTIMATE when held) |
| mouth.seam, rictus | straight from the snout tip to the closed-lip junction | ends MEASURED, line ESTIMATE |
| gill.u, opercle margin | gill-cover rear edge on the photo | MEASURED |
| skeleton.median d1/d2/an/d .u and .edge, caudal .edge | fin edges traced on the photo (maker PR #50 reads .edge) | MEASURED |
| pectoral / pelvic base | landmarks | MEASURED |
| everything else with an absolute position | keeps its section fraction on the new outline (reseat.py) | ESTIMATE |

Every record gets a `_trace` block listing MEASURED and ESTIMATE fields, the photo, the trace and the tool version.

## The check (check.py, SIL2)

Independent of the rule that wrote the outline: the reference is the photo's segmentation mask and the fin-base points.
OUT (no bulge past the fish, read against the mask closed with the tracer's 1.2 % SL envelope disc), FREE (on free edges
the outline is within 1 % SL of the mask edge over any run of 3 % SL or more), BASE (within 1 % SL of every fin-base point),
EYE (centre within 1.5 % SL of the landmark), and the writer's FAULT notes. Two planted faults per record (template forehead,
4 % SL bulge under a fin) must be caught. A record is written only if it passes, catches both, and its photo is not
flagged WAIT.

## Inputs read by eye (stand-ins, logged in HARD_PROBLEMS.md)

plans/species_trace/fin_bases/<species>.json: `top` / `bot` points on the body edge under the fins (photo %), `wait`
(why this photo cannot give the outline), `appendages` (spans where the mask edge is a barbel or similar, not the body),
`from_mask` (gap points taken from the mask edge where the belly is free, checked by eye). Automatic fin-base detection
would replace these.
