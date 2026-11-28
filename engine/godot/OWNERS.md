# Who edits what in the Godot slice (agreed 27 Nov 2026; edit only your own rows, ask the owner for the rest)

| Path | Owner thread |
|---|---|
| project.godot [application] [display] [rendering] sections, VERSION look/render notes | Engine (Decide whether to move to Godot) |
| scenes/probe*, look/ (water, fog, caustics, GI stack, grade) | Engine |
| tools/turnaround.gd, tools/cloud_render.sh | Engine |
| core/m12_streaming/, adapters/godot/stream_loader.gd, tests/test_cell_streamer.gd, tests/test_stream_world.gd | Engine |
| core/world/ (sky clock, water optics, lagoon water), adapters/godot/world_root.gd, adapters/godot/world_textures.gd, tools/lagoon_shots.gd, tools/ws_to_godot.py, tests/test_world_clock.gd | Engine |
| docs/ engine and look evidence | Engine |
| project.godot [input] [physics] [layer_names] [autoload] sections | Gameplay (Build the core gameplay modules) |
| core/<every other module>/, adapters/godot/<its modules>, tests/test_<its modules>.gd, harness | Gameplay |
| core/m31_school/, adapters/godot/school_node.gd, fish/, tests/test_school.gd, tests/test_golden_school.gd, tests/golden/school_*, tests/run_school.sh, tools/school_film.gd | Fish schools (Build the fish school system) |
| VERSION bumps and CHANGELOG release headings (game code owner) | Gameplay |
| core/m32_game/, core/world/sim_clock.gd, adapters/godot/game_root.gd, game_services.gd, actor_rig.gd, scenes/game*, tests/test_game_root.gd, tests/run_game_root.sh, tools/game_film.gd | Game root (Build the shared game root) |
| blockout/, tests/test_blockout.gd, tests/run_blockout.sh, tools/blockout_shots.gd, run_blockout.command; tests/harness/test_worlds.gd is now its shim | Blockout kit (Build the blockout test kit) |
| core/m33_interact/, core/m01_input/haptics.gd, adapters/godot/ui/, tests/test_player_ui.gd, tests/run_player_ui.sh, tools/player_ui_shots.gd | Player UI (Port player UI and gamepad controls) |
| core/m34_bubbles/, adapters/godot/bubbles.gd, look/bubble.gdshader, tests/test_bubbles.gd, tests/run_bubbles.sh, tools/bubble_shots.gd | Bubbles (Port Thalassa's bubbles) |
| README.md, CHANGELOG.md entries | shared: each owner edits only its own section / appends its own entries |

Rules: re-read a shared file just before editing it (this is a network folder; last write wins). A change that touches the
other owner's path goes to that thread first as a message.
