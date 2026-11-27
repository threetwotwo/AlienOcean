# Lagoon dress: authored places from the project's existing assets (Dress the lagoon thread, 27 Nov 2026)

Ports the approved lagoon key frame (Blender, 15-21 Nov; `papers/process/art_bible/style_level/keyframe/`) into the open-world
Godot lagoon. PORT, DON'T REBUILD: every piece is an asset that already existed; nothing is modelled here.

| Step | File | What it does |
|---|---|---|
| 1 pieces | `tools/lagoon_dress/export_pieces.py` (Blender bpy 5.3) | one GLB per source asset, Godot axes, collision inside (`<piece>_COL_<k>` convex hulls, `<piece>_TRI` concave), key frame palette in COLOR_0 (linear) |
| 1b paint | `tools/lagoon_dress/kf_paint.py` | the key frame material family (`kf_family.py`: palette, saturation, zones, one-gradient rules) evaluated per vertex |
| 2 layout | `world_dress/<place>.json` | the authored composition: items, anchor in the world, keep-clear volumes (school space, lanes), cameras |
| 3 build | `world_dress/dress_cell.gd` (`DressCell`) | builds the place: water-lit `look/seabed_surface` material, StaticBody3D + hulls, grass as soft Area3D, seats every item on the floor, checks keep-clear against real collision |
| test | `tests/test_dress_cell.gd` | synthetic pieces: collision, seating, school space, axis map; planted fault must be caught |

Sources (unchanged): reef kit v18 heads + sand skirts and their UCX hulls (`seabed/handover/reef_kit_v18/`), Rock's heads_v18c b0 arch
(`world/rock/lagoon/heads_v18c/`, CoACD hulls via `tools/collision/acd_hulls.py`), colony maker corals kinds_v27
(`life/colony_maker/lagoon_slice/kinds_v27/obj/`, CoACD hulls), the grown meadow tiles from `island/lagoon/lagoon_slice_v24.zip`
(archive bundle `archive/ue_era/island.tar.gz`; their COLOR_0 was sRGB bytes, linearized here).

## Run
```
pip install bpy==5.3.0 coacd scipy trimesh fast-simplification rtree networkx    # one venv
<venv>/bin/python3 tools/lagoon_dress/export_pieces.py <pieces_dir>/ <slice_v24_dir>/
AO_DRESS=res://world_dress/lagoon_keyframe.json AO_DRESS_PIECES=<pieces_dir> xvfb-run -a godot --path . --rendering-driver vulkan \
  --script res://tools/lagoon_shots.gd -- <lagoon pieces> <fish.glb> <out_dir> 960 540
```
Built pieces live outside git in the project files: `assets/world/lagoon_keyframe/` (GLBs + `pieces.json` with source md5s).

## Not done here (owners)
Light, fog, water and the material shader: engine thread (`look/`). The school: fish school thread (keep-clear volume in the
manifest). The fish: creature maker. Terrain's fallen gate blocks and sand seat for v18c (`seabed/arch_seat_v18c_*`) are not in the
project files any more; the head stands on the floor without its banked seat (logged).
