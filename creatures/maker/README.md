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
| 2 | Form | `form.py` | adapted record | `Form`: loft + bone plates (side: opercle, preopercle, maxilla; from below: lower-jaw rami, branchiostegal membrane) + orbit ring + mouth cleft as a signed-distance solid (bake source, snap target). The jaws enclose the mouth line: along the record's mouth line the loft's upper and lower edge are carried at least one lip thickness (DEFAULT `JAW_MIN` 0.3 % SL) round it, so an outline traced round an overhanging lip (its edge above the mouth line near the tip) still gives two lips with width; `form_rules.jaw_lift_pctSL` in `cage.json` says how far the outline moved (0 for a mouth inside its outline). Bone plates shape the skin as one surface: each is a patch of the skin, outlined in (x, theta), whose thickness over the bare body is a field: 0 on every outline, a bevel just inside a FREE margin (gill cover rear edge and membrane edge, preopercle margin, the maxilla's lower edge; DEFAULTS `PLATE_CHAMFER` 0.4 % SL at least, `PLATE_SLOPE` 45 deg at most), fading to nothing toward BURIED outlines; the lower jaw (no free margin) is a round ridge. The solid is body minus thickness, no unions. Opercle, subopercle and branchiostegal membrane are one gill cover with one free margin round its lower corner. Slabs cut off square (up to export r6) came out of the 0.2 % SL dense form as staircases: saw-toothed, stacked, embossed plates in the normal map |
| 3 | Chart | `chart.py` | Form | unrolled (length, arc) chart of the loft, near-isometric, where patches are laid out |
| 4 | Cage | `cage/` | Form, Chart, record | quad cage: vertices, tagged faces, designed-crease registers, openings |
| 5 | UV | `uv.py` | cage | two skin islands (left above, right below at the same place: twins) at one texel density, each flattened from the built half skin: Tutte's map, then SLIM with a free border; interior island for its own texture |
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
| `mouth.py` | lip loop on the record mouth line, loops out to the shared head ring, lip roll, mouth lining, oval cavity, domed pharynx | snout chart (no snout pole; a front-disc point straight under the mouth tip is charted at pi, the lower lip's tip); corner fan at the rictus, its spoke laid between the first loop's two neighbours of the corner; shared head ring bends round the eye (same eye margin as the eye block, measured on the skin; eye and lip margins shrink together, the ring never enters the eye); each lip column's lining runs straight in to its own point on the first oval behind the rictus (upper lip to the roof arc, lower lip to the floor arc), so the corner column is a hinge line |
| `gill.py` | one ring bent onto the cover edge and cut into a slit (flap over body lip); where the cover has a free membrane the cut turns the corner and runs forward under the head along one column, bent onto the form's gill V; flat passage to a hole in the cavity wall | passage loops match the hole loop; the hole is planned with the slit (`gill.holes`): a slot along one cavity band, turning forward along the floor edge behind the jaw joint when the slit has a ventral leg; the leg stops two rings behind the mouth ring, at 17 slit edges (what one side of a cavity ring holds) and where the head's half-width falls under 3 % SL (DEFAULT `HW_MIN`); a leg that cannot run forward past the cavity slot it drains into is not built (long side slits on deep bodies, tube snouts: the form still carries the V); first passage row designed all along every slit (the flap lining turns back under the flap, the body lip's lining runs straight in): left to the relaxation it drew its ends in along the slit, and the flap lining ran slantwise through the body lip at both ends of a slit |
| `finish.py` | one winding over skin and interior; snap onto the full form | rims, linings and the first lip loop follow their neighbours' snap; the snap goes to the outermost crossing of the form within reach (0.8 % SL, scanned every 0.05 % SL), the surface the bake's rays meet first: bisecting from the vertex itself was a coin toss at a plate's edge and fell differently on the two sides; the snap ignores the form's mouth cleft; quads at a slit corner are split from the corner vertex |
| `../mesh.py` | the mesh under construction, `relax_rings` | rings slide, never shrink across a corner |

### The skin UV (`uv.py`)

Each half of the skin is flattened from the cage as built, not from the loft's unrolled chart: Tutte's map (the half's
longest border on a circle, every other vertex at the mean of its neighbours) cannot fold, and SLIM (symmetric Dirichlet,
free border) then takes it as near to its true shape as a flat sheet allows. Gill slits are welded shut for the
flattening (the cover flap overlaps the body lip by design). The island is turned to the side view and both are packed at
one scale, the right island exactly half a texture below the left. The unrolled (length, arc) chart is still where eye
blocks are sized; as a UV map it folded on all 28 traced records (a midline vertex written as theta 2 pi went to the
belly on the left island only; midline faces of deep heads sheared past their neighbours; mouth loops live on another
chart), so SLIM, which needs a fold-free start, never ran on them.

### The underside of the head

Two Vs show from below, both from the record:

| V | Record fields | Rule |
|---|---|---|
| lower jaw | `jaw.dentary`, `jaw.mandibleLow` (DEFAULT: mouth tip to jaw joint on the skin; inner edge at half the width, meeting at the chin) | form ridge per ramus: between the dentary line seen from the side (at least 0.6 % SL under the mouth line: it stays under the lips) and the mandible's lower edge seen from below, out to the jaw joint; thickest midway, nothing at either line |
| gill | `skeleton.gills.opercle.margin`, `subopercle` (down to the cover's lower corner, where it turns to run more forward than down), `interopercle` (front end = apex; DEFAULT jaw joint x), `branchiostegals.th0, dth, n` (DEFAULT -70, 9, 6) | seen from below the free edge runs from the corner to the isthmus at the apex, at a share of the head's half-width that falls evenly (a straight V on an evenly tapering head); it keeps 1.2 % SL of skin (or half the half-width) to the midline, so the two openings never meet on a keel; isthmus half-width = half-width x sin(90 + th0); a cover whose corner lies above the membrane's top ray (wider than half-width x cos(th0 + (n - 1) dth)) has no free membrane and keeps a side slit (puffers, triggerfish, filefish). The slit's ring is the one nearest the mean x of the whole free edge, ventral margin included. Form: the gill cover's free margin runs on along that line (one plate with the opercle), bevelled, fading out toward the line from the preopercle's front to the apex. Cage: the slit's ventral leg on the same line. Pose: the membrane takes the cover's weight and the flare swings it about the line from the opercle hinge to the V's apex |

The branchiostegal angles are read round the section scaled to its half-width (0 = flank, -90 = ventral midline); `t0, dt, u1,
du` place the rays inside the head and are not used. The record has no field yet for membranes joined to the isthmus (gobies,
blennies): those get a V like the others.

### The eye and the head round it (`form.py` `_orbit`, `_tissue`)

| What | From | Rule |
|---|---|---|
| eye aim | `skeleton.eye.aim {up, fwd}`, else the elevation of a measured `skeleton.eye.gaze`, else the head's skin ring less 7.5 deg (DEFAULT `AIM_BELOW_SKIN`), kept in -6..12 deg up and 4..26 deg forward | the globe sits in the skull: its aim is its own, not the skin's. The eye's plane is square to the aim and touches the loft at the rim's outermost point, proud by `eye.bulge`; where it cannot lie inside the top view the aim gives way toward the skin |
| swelling round the rim | `eye.bulge`, `eye.groove`; DEFAULTS `SWELL_REACH` 1.6, `SWELL_SLOPE` 0.75, `SWELL_MAX` 3.0 eye radii, `ROOF_EDGE` 0.25 | the skin leaves the eye's plane at the rim with the plane's slope and has joined the record's loft 1.6 eye radii out, where the scans' skin ring begins. Where the swelling stands high (the brow of a high eye) it runs out further, no steeper than 0.75, as far as the scans' band lets the ring fill. Under the dorsal outline it closes as a roof with a round edge. It only changes a section's width: the side and top outlines stay the record's |
| the head round the eye | record sections; scans' line `RING_LINE` (skin ring up = -57.4 + 103.8 x eye height) or `skeleton.eye.skin_up`; DEFAULT `RING_HOLD` 7 deg | the skin ring (best plane of the skin 1.6-2.4 eye radii out) is the record's own. A head whose ring lies more than 7 deg over the line (it falls away round the eye) is turned back to it; a head the record draws flatter than the line keeps the record's shape |

Checks: EA1 (ring no more than 8 deg over the line, and not filled by the builder to more than 8 deg under it: `EA1_flat_by_record`
lists the heads the record itself draws under the band), EA2 (aim in the scans' range, rim seated within 6 deg of it), FM1 on
sections through the swelling (`FM1_orbit_crease_deg`, gated). `cage.json` `form_rules.orbit` carries the numbers.

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

**Front and top (SIL2, Gary 28 Nov).** The side view cannot see girth, the cross-section's shape or head width. The same
reference file may carry `"front": [[z, y], ...]` (head-on: body and median fins, no paired fins) and `"top": [[x, z], ...]`
(from above: body only), in SL units; each must overlap by IoU 0.90. The cross-section itself can be traced:
`outline.sections: [{"u": <record units>, "w": [[s, w], ...]}]`, half-width share w (0..1) at normalised height s (-1 ventral
edge, +1 dorsal edge), blended linearly between stations. Without it the section is the default (two half superellipses
from nUp/nLo, widest at mid-height, listed as a DEFAULT row) and builds byte-identical to before.

**Traced fins.** A median fin (or the caudal) may carry `edge`: its free outline from the photo, in record units, from
where the leading edge leaves the body to where the rear margin meets it (dorsal and anal front to back, caudal top to
bottom). The fin card then spans its root and that outline, with a Winslow grid between them so swept lobes and filaments
follow the photo instead of being cut by straight rays, and no cell folds over behind a lobe. Without `edge` the card is guessed from `h` and `lean`.
`silhouette.fin_edges(ref, rec)` reads these outlines off a traced reference for the tracer to write into the record (the
record stays the only build input, the reference stays the test) and lists fins whose outline meets the body far from
the record's root ends. On the 28 traced drafts (27 Nov): SIL1 passes 3 with guessed fins, 24 with traced outlines; the
other 4 have record fin roots that disagree with their photo.

**Traced paired fins** (`skeleton.pectoral` / `skeleton.pelvic`: `edge`, the side-view outline from the first root round the
tip to the last root, and `base_line`, root to root). The outline is the fin's own shape (flat in the photo's plane:
trace reach over record `length` is 1.01 in the median of the 31 traced fins; a fin standing 30 deg out of the photo
would read 0.87), so the builder (`fins.paired_sheet`) keeps every length on it and only poses it:

| Step | Rule | From |
|---|---|---|
| fair | the outline loses the trace's jitter, ends and tip held | DEFAULT `EDGE_FAIR_TOL` 0.4 % SL over `EDGE_FAIR_LEN` 5 % SL |
| grid | columns run as rays: first column the leading edge (first root to the farthest free point), top row the margin, Coons patch then Winslow's equations (`fins.winslow`: no fold behind a swept lobe); a last stretch of outline lying on the root line is not free edge | `EDGE_RAYS` columns, `PAIR_BASE_ROWS` 3 + `PAIR_ROWS` 5 rows |
| fold | the fan closes about the first root, base held, until the leading ray stands no further from the base than the record's rest angle (a specimen photo shows the pelvic fin erect); never opened past the photo | record `sweep[0]` (pelvic: deg below the belly line; pectoral: 90 + deg above the body axis) |
| hinge | the sheet turns about its base line by the record's `out`, the turn spread over the fleshy base so it leaves the skin along the skin; a blade that would pass through the body swings further out until clear (at most `PAIR_OUT_MAX` 85) | record `out`; base depth record `baseBand.w`, DEFAULT `PAIR_BASE` 0.12 of the reach |
| seat | root row on the skin at the base line, `ROOT_SINK` 0.4 % SL under it; a base drawn on the underside (skin facing down more than sideways, or the belly line itself) sits `PAIR_GAP` 0.6 % SL to its own side of the midline, the fin moved there as one piece; over its base a flank fin lies `PAIR_LIFT` 0.1 % SL off the skin | DEFAULTS |

The base carries the body's skin colour over the same depth (the fin atlas), and the card is cut away at the root so the rays come out of the skin first (`PAIR_EMERGE` 0.3 of the base depth) and the membrane between them later (0.8): no straight cut edge on the flank. How each fin was placed is written to
`cage.json` `form_rules.paired_fins` (fold factor, out used, traced and record fan angles). Median fins and the caudal
use the same Winslow grid between root row and outline. Checks: PF1 each paired fin on its own side of the midline, PF2
its reach is the trace's within 5 %, PF3 no part turned over (0.2 % of its area at most) and the blade past the base flat
within 25 deg, PF4 where it lies on the flank it leaves the skin at 20 deg or less, FN1 no median fin or tail card folded
over in the side view (1.5 % of its area at most).

Cage (no Blender): P2 quad share and corners, P3 manifold, P4 skin on the form, P5 skin UV stretch, folds and overlap (no texel
under two skin faces), IC1 parts
from the record, EY1 eye size, EY2 cornea window, EA1 the skin ring round the eye against the scans' line, EA2 the eye's aim, OP1 openings are topology (genus 2, the lips reach both gill slits through interior faces),
OP2 interior inside the body, OP3 no fold outside designed creases, FM1 the body loft is fair (no crease round a section: its normal turns at most 8 deg over 0.005 % SL of arc; no ripple along the flank: at most 1.5 deg rms about a 6 % SL running mean; traced half-widths and section rows are faired within named tolerances first, form.py `fair`; the swelling round the eye is held to the same crease limit on 13 sections of its own), FM2 bone plates have no wall (thickness of bone over the bare body, sampled on the skin every 0.1 % SL, rises nowhere faster than 1.25: a plate cut off square is sharper than the dense form carries and bakes as saw teeth), GP0 no crossing faces at rest, GP1 gape to the record's real gape
(`jaw.linkage.gape`, DEFAULT 30; the two lip tips must part by at least 95 % of the gape angle, `GP1_opening_share`: a jaw weight smeared over the snout opens nothing and crosses nothing) and GF1 gill flare 0-20 deg (cover and branchiostegal membrane together, about the hinge-to-apex line when there is a gill V) add no crossings or flipped faces and leave the eye rims in place (`pose.py`), SR1 stylized range:
gape, flare, body C-bend, S-wave, arch and all of them at once are each swept until the first new crossing, fold
(neighbours turning past 90 deg) or crush (a skin triangle under 10 % of its rest area). The target is what the species
can really do, times 1.3: the record gape (capped at 65 deg); for the body, the muscle strain limit (the inside of a bend
shortens by curvature x half-width, at most 30 %); combo is all of them at once at real size. A pose under 10 deg is not
one the body makes and is skipped (no S-wave for a puffer). The jaw weight is one field in the side view, the same for the skin and the lining under it, framed on the lower jaw's own
line (mouth tip to jaw joint; the line from rictus to joint can be 0.6 % SL long and point anywhere): the lips blend to 1/2 toward
the rictus over the length the corner must stretch (gape x rictus-to-joint distance), but never over more than half the
mouth's length (DEFAULT `HINGE_LIPS`), so the lip tips belong to their jaws; a lens-shaped blend joins rictus and
joint, and the jaw fades out by angle about the joint. The cover weights are the cage's structural rules softened by
neighbour averaging over the skin, with the body lips, eyes, mouth and the throat midline held, and never more than the jaw leaves of a vertex (jaw + cover <= 1, so the export rig skins exactly the stress pose): a slit opens as a lens (the flap
takes the weight of the cover skin it ends, the slit's two ends go with the skin round them, and every passage vertex
follows its own slit vertex, fading to the fixed hole in the cavity wall). Export: P1 triangle budget and LODs, P6 normal map
carries the form (tilt in every third that has scale relief), does not carry the cage's shape (1st percentile of normal z >= 0.8), has at most 2 specks, does not lean on the skin faces at a rim (lips, gill slit lips: their middle texel within 10 deg of flat), faces out of the skin everywhere and is the same on both sides (twin texels of the two islands), P7 bones, P8 Khronos glTF validator, EX1/EX2 the exported jaw and gill covers skin into exactly the stress
test's gape and flare (within 0.01 % SL), EX3 interior slot on every LOD, EX4 clips and a closed swim loop, EX5 collision
covers the body, EX6 swim settings in the glTF, EX9 a lining has the skin's colour where it meets the skin (lips, gill slits: interior map against skin map at every shared vertex, within 0.06 linear RGB). Each check has a planted fault in `checks.planted`.

## Art direction

`build --style eye=1.5,mouth=1.2,girth=0.8` deviates from the record (eye and orbit size, mouth length about its tip,
body half-width) before the form is made, so every stage and check sees one consistent stylized fish. `deviate` runs a
ladder of these on every record and reports per species the widest range that still builds with real openings, the
interior inside, a manifold skin, the eye on its circle and no extra rest crossings (`deviate.json`).

## The export stage (`glb`), part by part

| Part | Where | Rule |
|---|---|---|
| Skin bake | `blender/export_glb.py`, `blender/interior.py` (`slot`) | only faces that lie on the form sample it. Interior faces (cavity, gill passages) and the orbit linings sit on a throwaway bake slot while the skin's normal and AO are baked: their UVs belong to another texture and lie over the skin islands, and a lining lies inside the form. Linings take a flat tangent normal and their rim's AO |
| Interior slot | `blender/interior.py` | every `cavity` and `gill` face on material `interior` with its own 512 maps: base colour by tissue (mouth lining, grading to gill red down each passage; colours are STAND-INs, HARD_PROBLEMS EXP-INT-1), except within 0.6 % SL of a rim, where the lining is skin (its rim's skin colour, no occlusion of its own; tissue from 1.4 % SL in): a closed mouth or gill slit shows no pink or black line, AO baked from the mouth's own walls, wet roughness |
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
