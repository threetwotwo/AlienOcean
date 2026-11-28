# Libraries: what the project uses instead of writing its own

Check this list before building any system (physics, navigation, noise, mesh work, terrain, effects, materials). If a proven
library here does the job, integrate it; if you want a new one, add a row with its licence and evidence first.
Started 27 Nov 2026 from Gary's list (proven open-source libraries, 27 Nov 18:35Z) and the threads' reports. Owners add their own rows.

## Adopted
| Library | Licence | Used for | Where | Evidence |
|---|---|---|---|---|
| Godot 4.7-stable | MIT | the engine | engine/godot/ | docs/decisions/2026-11-27-godot-slice.md |
| Jolt Physics (Godot's built-in Jolt) | MIT | all rigid body, character and query physics | project.godot `3d/physics_engine="Jolt Physics"`; adapters/godot/world_query.gd | gameplay modules M02/M03/M29 stress tests |
| Recast Navigation (Godot NavigationServer3D, built in) | Zlib | paths for anything that WALKS on a surface: the girl's assisted moves, Tug and the companions on the seabed and on Haven's decks, crowd avoidance (RVO agents) | not wired yet; probe tools/nav_probe.gd | 27 Nov, real lagoon (33 pieces + key-frame place, 1.04 M tris): parse 44 ms + bake 277 ms for 100 x 100 m (walker r 0.3 m, h 1.38 m, step 0.35 m, slope 40 deg, cell 0.15 / 0.05 m), 656 polygons, 200/200 random paths reach their goal, 0.15 ms mean query, 6 ms worst (first) |
| FastNoiseLite (Godot built in) | MIT | procedural noise where a process needs it (never as "detail": SIMPLICITY rule) | engine built in | replaces FastNoise2 |
| Blender bpy | GPL (tool use only, nothing shipped) | bake, skin, glTF export | tools/, creatures/ | exporter thread |
| meshoptimizer | MIT | LOD chains, mesh simplification | export pipeline | exporter thread |
| CoACD | MIT | convex collision hulls before import | tools/collision/ | FUNDAMENTALS "collision before import" |
| Khronos glTF validator | Apache 2.0 | export checks | export pipeline | exporter thread |
| CORTAO (Circular Occluder Ray-Traced AO, v1.0.3, github.com/theagentd/CORTAO) | MIT | screen-space ambient occlusion + bent normals in place of Godot's SSAO (switch, trial) | engine/godot/third_party/cortao (headers unchanged + 16-ray occluder table); look/cortao/*.glsl wrappers; adapters/godot/cortao_effect.gd; look/screen_ao.gdshaderinc | ao thread 28 Nov: tools/cortao_check.gd C1-C4 + planted flip fault; key-frame SSAO vs CORTAO comparison on the thread |
| SDL3 game controller layer + SDL GameControllerDB (Godot 4.7 built in) | Zlib | every pad (Xbox, PlayStation, Switch Pro, Apple MFi) in one standard layout, hot plug, rumble | adapters/godot/input_reader.gd (InputMap from core/m01_input/action_table.gd) | player UI thread 28 Nov: tests/test_player_ui.gd U0-U8 + test_input.gd 16/16; real pads on Gary's Mac pending |
| Godot GUI focus navigation (built in) | MIT | pause / options / controls menus on the pad (D-pad, stick, Cross-A, Circle-B) | adapters/godot/ui/player_ui.gd | U4 checks |

## Recast and swimming (game root thread, 27 Nov)
Recast builds walkable SURFACE meshes. It does not path through open water in 3D, so swimmers (fish schools, megafauna,
the subs) keep steering on the world query (schools: M31 rules + WorldQuery ray guard) and, later, a coarse 3D grid or
the streamed cells' free-space if a creature needs real routing through caves. Plan: one navigation region per streamed
cell, baked offline with the cell (same 64 m key as M12), so streaming loads nav with the geometry; walkers ask
NavigationServer3D through a WorldQuery-style service row in core/README.md before any module uses it.

## To evaluate
| Library | Licence | For | Owner, when |
|---|---|---|---|
| Terrain3D | MIT | open-world seabed streaming | engine thread, at P9 |
| Material Maker | MIT | authoring rock and coral detail only | engine thread, at the materials step |
| Effekseer | MIT | particles (marine snow) | decide at the marine snow port |
| CORTAO (github.com/theagentd/CORTAO) | MIT | ambient occlusion + bent normals, a GTAO-class SSAO replacement (claims GTAO quality at under half the cost); GLSL compute, needs depth + view normals | look pass, after frame time is solved (Gary asked 28 Nov; SSAO costs only 0-1.3 ms on his M1 Pro, so the gain is look, not speed; 1-commit reference code) |
| Controller Icons (github.com/rsubtil/controller_icons) | MIT code, CC0 art | drawn glyph art per pad family once the UI look is picked (now: Thalassa's badges drawn as vectors, adapters/godot/ui/glyph_badge.gd) | player UI thread, after the prompt style choice |
| G.U.I.D.E. (github.com/godotneers/G.U.I.D.E) | MIT | input contexts (swim / vessel / menu / photo) and remapping UI when the action count grows | player UI thread, when vessels arrive (InputMap + action_table is enough for the slice) |
| ozz-animation | MIT | animation playback and blending | not needed while the body rig is procedural (M04); revisit if keyframed animation arrives |

## Not adopted (with reasons)
| Library | Why not |
|---|---|
| Voxel Tools | terrain is mesh clusters (FUNDAMENTALS), not voxels |
| FastNoise2 | FastNoiseLite is built in |
| The Forge | no own engine; Godot chosen |
