# Creature maker

Version: 0.3.0-dev

Turns a native Species record into a game-ready creature: a designed low-poly cage with real openings (mouth, gills,
throat, eye sockets), UVs, baked maps, fins, a rig and a glTF that Godot imports. One code path for every species: no
species names in the code, every value traced to a record field or listed as a DEFAULT.

Proven so far on fish (the alfonsino proof record and the trevally Species record); 21 of the 38 native records build.

## Run

```
pip install -r requirements.txt
cd creatures/maker
python -m creature_maker build RECORD.json OUT [--res 2048]    # numpy only, a few seconds
python -m creature_maker glb OUT                                # Blender's Python (bpy) bakes and exports OUT/fish.glb + LODs
python -m creature_maker check OUT RECORD.json --planted        # every check, and each planted fault must be caught
python -m creature_maker board OUTROOT RECORD_DIR...            # all records: proves a rule is universal, not hero-only
python -m creature_maker deviate OUTROOT RECORD_DIR...          # stylized proportions (eye, mouth, girth) on all records
```

## Stages and their contracts

Each stage reads only what the stage before it wrote. Rules live in the stage that owns them, written next to the code
as a comment that says why.

| # | Stage | Module | Reads | Writes |
|---|---|---|---|---|
| 1 | Record | `record.py` | native Species record (`alien-ocean/sculptor-record/1`) | adapted record in SL units, provenance rows, defaults used, input faults |
| 2 | Form | `form.py` | adapted record | `Form`: loft + bone plates (side: opercle, preopercle, maxilla; from below: lower-jaw rami, branchiostegal membrane) + orbit ring + mouth cleft as a signed-distance solid (bake source, snap target) |
| 3 | Chart | `chart.py` | Form | unrolled (length, arc) chart of the loft, near-isometric, where patches are laid out |
| 4 | Cage | `cage/` | Form, Chart, record | quad cage: vertices, tagged faces, designed-crease registers, openings |
| 5 | UV | `uv.py` | cage | two skin islands at one texel density, interior island, SLIM relax |
| 6 | Maps | `maps.py` | cage, UV, Form | `body_base.png`, `body_orm_pre.png`, `body_height.npy`, `body_mask.npy` |
| 7 | Fins | `fins.py` | Form, record | fin cards + `fin_base.png`, `fin_normal.png` |
| 8 | Export | `blender/export_glb.py` | everything above + `form_mc.npz` | normal/AO bake, rig, materials, `fish.glb`, `fish_LOD1.glb`, `fish_LOD2.glb`, `glb_stats.json` |
| 9 | Checks | `checks.py`, `pose.py` | build folder + record | `checks.json` |

`build.py` runs stages 1 to 7 and writes `cage.npz` + `cage.json`; `board.py` runs it over many records.

### The cage, feature by feature (`cage/`)

| Module | Feature | Key rules |
|---|---|---|
| `template.py` | 50 rings x 36 columns evaluated on the loft; tail-root pole | denser rings at the head |
| `eye.py` | eye hole in the template filled with 4 rings to the rim, then a tuck ring into the orbit | block = the columns within the eye margin of the rim plus one each side; rings laid out in the loft (x, theta) plane with radial spokes (border vertex to the rim point at its own angle), spaced by length on the skin; rim on the record eye circle (EY1); tuck goes down the socket axis, depth scaled to the eye and kept on its own side |
| `mouth.py` | lip loop on the record mouth line, loops out to the shared head ring, lip roll, oval cavity, domed pharynx | snout chart (no snout pole); corner fan at the rictus; shared head ring bends round the eye (same eye margin as the eye block, measured on the skin; eye and lip margins shrink together, the ring never enters the eye); lip roll turns forward at the corners |
| `gill.py` | one ring bent onto the cover edge and cut into a slit (flap over body lip); where the cover has a free membrane the cut turns the corner and runs forward under the head along one column, bent onto the form's gill V; flat passage to a hole in the cavity wall | passage loops match the hole loop; the hole is planned with the slit (`gill.holes`): a slot along one cavity band, turning forward along the floor edge behind the jaw joint when the slit has a ventral leg; the leg stops two rings behind the mouth ring and at 17 slit edges (what one side of a cavity ring holds); first passage row designed near the leg (the flap lining turns back under the flap) |
| `finish.py` | one winding over skin and interior; snap onto the full form | rims, linings and the first lip loop follow their neighbours' snap |
| `../mesh.py` | the mesh under construction, `relax_rings` | rings slide, never shrink across a corner |

### The underside of the head

Two Vs show from below, both from the record:

| V | Record fields | Rule |
|---|---|---|
| lower jaw | `jaw.dentary`, `jaw.mandibleLow` (DEFAULT: mouth tip to jaw joint on the skin; inner edge at half the width, meeting at the chin) | form plate per ramus: between the dentary line (outer) and the mandible's lower edge (inner) seen from below, under the dentary line seen from the side, out to the jaw joint |
| gill | `skeleton.gills.opercle.margin`, `subopercle` (down to the cover's lower corner, where it turns to run more forward than down), `interopercle` (front end = apex; DEFAULT jaw joint x), `branchiostegals.th0, dth, n` (DEFAULT -70, 9, 6) | the free edge runs straight, seen from below, from the corner to the isthmus at the apex; isthmus half-width = half-width x sin(90 + th0); a cover whose corner lies above the membrane's top ray (wider than half-width x cos(th0 + (n - 1) dth)) has no free membrane and keeps a side slit (puffers, triggerfish, filefish). Form: a membrane plate with its stepped free edge on that line. Cage: the slit's ventral leg on the same line. Pose: the membrane takes the cover's weight and the flare swings it about the line from the opercle hinge to the V's apex |

The branchiostegal angles are read round the section scaled to its half-width (0 = flank, -90 = ventral midline); `t0, dt, u1,
du` place the rays inside the head and are not used. The record has no field yet for membranes joined to the isthmus (gobies,
blennies): those get a V like the others.

Designed creases are registered where they are made (`rolls`, `junctions`, `commissures` in `cage.json`), so the fold
check can tell a designed crease from a fault.

## Checks

Cage (no Blender): P2 quad share and corners, P3 manifold, P4 skin on the form, P5 skin UV stretch and folds, IC1 parts
from the record, EY1 eye size, OP1 openings are topology (genus 2, the lips reach both gill slits through interior faces),
OP2 interior inside the body, OP3 no fold outside designed creases, GP0 no crossing faces at rest, GP1 gape to the record's real gape
(`jaw.linkage.gape`, DEFAULT 30) and GF1 gill flare 0-20 deg (cover and branchiostegal membrane together, about the hinge-to-apex line when there is a gill V) add no crossings or flipped faces and leave the eye rims in place (`pose.py`), SR1 stylized range:
gape, flare, body C-bend, S-wave, arch and all of them at once are each swept until the first new crossing, fold
(neighbours turning past 90 deg) or crush (a skin triangle under 10 % of its rest area). The target is what the species
can really do, times 1.3: the record gape (capped at 65 deg); for the body, the muscle strain limit (the inside of a bend
shortens by curvature x half-width, at most 30 %); combo is all of them at once at real size. A pose under 10 deg is not
one the body makes and is skipped (no S-wave for a puffer). Pose weights are the cage's structural rules softened by neighbour averaging, with lips, eyes, gill lips and the throat
midline held, so a large pose does not fold the skin where two rules meet. Export: P1 triangle budget and LODs, P6 normal map
carries the form, P7 bones, P8 Khronos glTF validator. Each check has a planted fault in `checks.planted`.

## Art direction

`build --style eye=1.5,mouth=1.2,girth=0.8` deviates from the record (eye and orbit size, mouth length about its tip,
body half-width) before the form is made, so every stage and check sees one consistent stylized fish. `deviate` runs a
ladder of these on every record and reports per species the widest range that still builds with real openings, the
interior inside, a manifold skin, the eye on its circle and no extra rest crossings (`deviate.json`).

## Output for the engine

Build folders and glTFs are big binaries and stay out of git (`.gitignore`); published ones are listed in
`assets.lock.json`. Godot imports `fish.glb` from `engine/godot/assets/creatures/<species>/` (agreed with the engine thread).

## History

Rounds 0.1 and 0.2 were proofs in the project files (`plans/fish_restart/proof/`, frozen copies in `archive_v0.2.0/`).
0.3 moves the maker here as stage modules; the first commit's output is byte-identical to the last proof script on both
fish (cage, UVs, maps, fins).
