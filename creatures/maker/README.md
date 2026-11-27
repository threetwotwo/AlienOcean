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
python -m creature_maker glb OUT --record RECORD.json           # Blender's Python (bpy): bake, rig, clips, LODs, collision -> OUT/fish.glb + LODs
python -m creature_maker ship OUT ../../engine/godot/assets/creatures/<species>   # copy to the engine, list in assets.lock.json
python -m creature_maker check OUT RECORD.json --planted        # every check, and each planted fault must be caught
python -m creature_maker board OUTROOT RECORD_DIR...            # all records: proves a rule is universal, not hero-only
python -m creature_maker silboard OUTROOT RECORD_DIR...         # SIL1 only, fast: built vs traced outline per species + sheet.png
python -m creature_maker sheet OUT RECORD.json                  # turnarounds: 8 angles x rest / real size / stylized, faults magenta
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
| 8 | Export | `blender/export_glb.py` (+ `rig.py`, `swim_clip.py`, `collision.py`, `blender/interior.py`, `rigging.py`, `lods.py`, `glbpatch.py`) | everything above + `form_mc.npz` + the record | normal/AO bake, interior slot, rig, clips, swim extras, LODs, collision, `fish.glb`, `fish_LOD1.glb`, `fish_LOD2.glb`, `glb_stats.json`, `swim.json` |
| 9 | Checks | `checks.py`, `pose.py` | build folder + record | `checks.json` |

`build.py` runs stages 1 to 7 and writes `cage.npz` + `cage.json`; `board.py` runs it over many records.

### The cage, feature by feature (`cage/`)

| Module | Feature | Key rules |
|---|---|---|
| `template.py` | 50 rings x 36 columns evaluated on the loft; tail-root pole | denser rings at the head |
| `eye.py` | eye hole in the template filled with 4 rings to the rim, then a tuck ring into the orbit | block = the columns within the eye margin of the rim plus one each side; rings laid out in the loft (x, theta) plane with radial spokes (border vertex to the rim point at its own angle), spaced by length on the skin; rim on the record eye circle (EY1); tuck goes down the socket axis, depth scaled to the eye and kept on its own side |
| `mouth.py` | lip loop on the record mouth line, loops out to the shared head ring, lip roll, oval cavity, domed pharynx | snout chart (no snout pole); corner fan at the rictus; shared head ring bends round the eye (same eye margin as the eye block, measured on the skin; eye and lip margins shrink together, the ring never enters the eye); lip roll turns forward at the corners |
| `gill.py` | one ring bent onto the cover edge and cut into a slit (flap over body lip), flat passage to a hole in the cavity wall | passage loops match the hole loop |
| `finish.py` | one winding over skin and interior; snap onto the full form | rims, linings and the first lip loop follow their neighbours' snap |
| `../mesh.py` | the mesh under construction, `relax_rings` | rings slide, never shrink across a corner |

Designed creases are registered where they are made (`rolls`, `junctions`, `commissures` in `cage.json`), so the fold
check can tell a designed crease from a fault.

## Checks

**Silhouette first (SIL1, Gary 27 Nov).** The built fish seen from the side (skin plus dorsal, anal and caudal fin cards,
holes filled) must overlap its traced reference outline by IoU 0.90 or more, for the whole fish and for the head alone
(in front of the gill cover's rear edge), before finer anatomy counts. The reference is
`silhouettes/<record name>.json` beside the record (or its parent folder, or `CREATURE_SIL_DIR`):
`{"source": "<photo>", "traced_by": "...", "side": [[x, y], ...], "side_body": [[x, y], ...]}` in the record's SL units
(snout at x 0, standard-length end at x 1, y as in the record outline; `side_body` is optional, without fins). A record
with no traced reference fails SIL1 with the note "no traced reference silhouette yet". `silhouette.overlay` draws built
(red) over reference (blue).

**Traced fins.** A median fin (or the caudal) may carry `edge`: its free outline from the photo, in record units, from
where the leading edge leaves the body to where the rear margin meets it (dorsal and anal front to back, caudal top to
bottom). The fin card then spans its root and that outline, with the rows between relaxed so swept lobes and filaments
follow the photo instead of being cut by straight rays. Without `edge` the card is guessed from `h` and `lean`.
`silhouette.fin_edges(ref, rec)` reads these outlines off a traced reference for the tracer to write into the record (the
record stays the only build input, the reference stays the test) and lists fins whose outline meets the body far from
the record's root ends. On the 28 traced drafts (27 Nov): SIL1 passes 3 with guessed fins, 24 with traced outlines; the
other 4 have record fin roots that disagree with their photo.

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
carries the form, P7 bones, P8 Khronos glTF validator, EX1/EX2 the exported jaw and gill covers skin into exactly the stress
test's gape and flare (within 0.01 % SL), EX3 interior slot on every LOD, EX4 clips and a closed swim loop, EX5 collision
covers the body, EX6 swim settings in the glTF. Each check has a planted fault in `checks.planted`.

## Art direction

`build --style eye=1.5,mouth=1.2,girth=0.8` deviates from the record (eye and orbit size, mouth length about its tip,
body half-width) before the form is made, so every stage and check sees one consistent stylized fish. `deviate` runs a
ladder of these on every record and reports per species the widest range that still builds with real openings, the
interior inside, a manifold skin, the eye on its circle and no extra rest crossings (`deviate.json`).

## The export stage (`glb`), part by part

| Part | Where | Rule |
|---|---|---|
| Interior slot | `blender/interior.py` | every `cavity` and `gill` face on material `interior` with its own 512 maps: base colour by tissue (mouth lining, grading to gill red down each passage; colours are STAND-INs, HARD_PROBLEMS EXP-INT-1), AO baked from the mouth's own walls, wet roughness |
| Rig | `rig.py`, `blender/rigging.py` | spine chain (record bones) + `jaw` (pivot `openings.jaw_joint`, axis +z) + `opercleL`/`opercleR` (pivot the opercle hinge on each side's skin, vertical axis) + one root bone per fin (`fin_<name>_root`). Jaw and cover weights are `pose.jaw_weights` / `pose.cover_weights` as the stress tests use them, so the exported mouth opens into the pose the tests passed (EX1/EX2) |
| Clips | `swim_clip.py`, `motion/` | `swim_loop`: one tail beat at the record's cruise speed from the project swim engine (`motion/swim.js` v18, ported verbatim from project files motion/swim/v18: record body wave, Lighthill recoil, Bainbridge beat law); `breathe_loop`: one breath at rest (opercles); `gape`, `flare`: 0 -> real size -> 0 in 1 s. Godot's importer strips `_loop` and loops those clips |
| Swim extras | `swim_clip.py`, `glbpatch.py` | rig node `extras.alien_ocean.swim`: measured amplitude envelope (BL), wavelength, beat law f(U), amplitude and alpha laws, playback rule, head bone pivots and axes, SR1 safe limits (when `checks.json` exists); copy in `swim.json` |
| LODs | `blender/lods.py` | meshoptimizer on a seam-split copy, vertex normals as an attribute, designed creases (cage `rolls`) locked, so LOD1 (40 %) and LOD2 (14 %) keep their lips, gill slits and eye rims; slivers dropped. LODs share LOD0's vertices and weights |
| Collision | `collision.py` | convex hulls of the form cut into runs of 2 spine bones (overlapping 1 % SL), at most 64 points each, each hull on its middle bone, named `-convcolonly` for Godot's importer. Not CoACD: it cut the bending trunk into one hull |

## Output for the engine

Build folders and glTFs are big binaries and stay out of git (`.gitignore`); published ones are listed in
`assets.lock.json`. Godot imports `fish.glb` from `engine/godot/assets/creatures/<species>/` (agreed with the engine thread).

## History

Rounds 0.1 and 0.2 were proofs in the project files (`plans/fish_restart/proof/`, frozen copies in `archive_v0.2.0/`).
0.3 moves the maker here as stage modules; the first commit's output is byte-identical to the last proof script on both
fish (cage, UVs, maps, fins).
