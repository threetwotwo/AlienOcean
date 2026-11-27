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
| 2 | Form | `form.py` | adapted record | `Form`: loft + bone plates + orbit ring + mouth cleft as a signed-distance solid (bake source, snap target) |
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
| `eye.py` | eye hole in the template filled with 4 rings to the rim, then a tuck ring into the orbit | laid out on the chart; rim on the record eye circle (EY1); rim matched to the border by arc length |
| `mouth.py` | lip loop on the record mouth line, loops out to the shared head ring, lip roll, oval cavity, domed pharynx | snout chart (no snout pole); corner fan at the rictus; shared head ring bends round the eye; lip roll turns forward at the corners |
| `gill.py` | one ring bent onto the cover edge and cut into a slit (flap over body lip), flat passage to a hole in the cavity wall | passage loops match the hole loop |
| `finish.py` | one winding over skin and interior; snap onto the full form | rims, linings and the first lip loop follow their neighbours' snap |
| `../mesh.py` | the mesh under construction, `relax_rings` | rings slide, never shrink across a corner |

Designed creases are registered where they are made (`rolls`, `junctions`, `commissures` in `cage.json`), so the fold
check can tell a designed crease from a fault.

## Checks

Cage (no Blender): P2 quad share and corners, P3 manifold, P4 skin on the form, P5 skin UV stretch and folds, IC1 parts
from the record, EY1 eye size, OP1 openings are topology (genus 2, the lips reach both gill slits through interior faces),
OP2 interior inside the body, OP3 no fold outside designed creases, GP0 no crossing faces at rest, GP1 gape to the record's real gape
(`jaw.linkage.gape`, DEFAULT 30) and GF1 gill flare 0-20 deg add no crossings or flipped faces and leave the eye rims in place (`pose.py`), SR1 stylized range:
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
