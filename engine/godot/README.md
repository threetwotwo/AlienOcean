# Alien Ocean, Godot slice (0.6.x setup -> 0.7.0 slice)

Gary chose "Prototype a Godot slice first" on 27 Nov 2026 14:12Z. Study and audit: https://claude.ai/artifact/UZeHCSn79Jn1TshjJ6Qe4A
(copy plans/engine_study/engine_study_v1.html). Unreal stays untouched until the slice is judged.

## Pass checks (written before building); stop rule: P1, P4 or P9 failing after one root-fix round -> stay on Unreal
P1 speed: lagoon worst view <= 16.7 ms on the M1 Pro with the GI stack and a school (Mac run, Gary's tap)
P2 cloud frames close enough to Mac frames for the cloud to judge form; colour stays a Mac call
P3 import: fish GLB + terrain pieces keep COLOR_0 (as data), skeleton, collision, LODs   [first half seen: turnaround run 27 Nov]
P4 look: independent critique rates it equal or better than the Unreal key frame and the style target
P5 camera: 20 scripted 3P -> 1P -> 3P blends, no cut, no clipping, no frame jump over the limit
P6 controls: gamepad first, all input via InputMap, remapping
P7 motion: stand-in girl rig swims with blend spaces + IK, contacts measured
P8 memory: editor + game leave clear headroom on 16 GB
P9 streaming: swim + fast sub across >= 4 x 4 km, no loading screen, no load-caused frame > 33 ms, flat memory, no pop inside fog
   [core logic PASS 27 Nov; needs the adapter on a real cell world + frame timing]

## Layout
core/<module>/        engine-agnostic logic (module ids follow the gameplay study M01-M28; M12 = world streaming)
adapters/godot/       thin Godot side of each module
tools/                cloud_render.sh (turnaround | test), turnaround.gd
tests/                headless tests, each with a planted fault
scenes/               probe scene (cloud render proof)

## Versions
Game: 0.6.0 setup, 0.7.0 slice judged by P1-P9, 1.0.0 first playable slice. Each module carries its own version in its header.
Moves into the game repo once Gary creates it (name settled on the workspace cleanup card).

## M12 streaming: next version 0.2.0 (seams asked by the gameplay thread, 27 Nov 14:19Z; none block the slice)
1 Pins: `update(viewers, pins)`; each pin {x, z, radius, priority} keeps or prefetches cells (next probe-trail site, set-piece arena).
2 Attached sets: vessel interiors (Haven, Halcyon) stream as cell sets in a moving vessel frame, listed separately from the
  world grid; the grid key stays world-space; Haven's migration moves the frame.
3 Per-cell state: load/unload hooks hand each cell its save blob (ISaveBlob) so her changes persist across unloads.
4 Depth: ignored for now; key() stays easy to extend with a coarse y band (vents, caves under reefs).
Clock: update() takes plain values; dt comes from whatever drives it. Frame budgets live in the adapter.

## Portability note
Core modules are GDScript on RefCounted with no Node/scene types: portable at the logic level (the design and tests
carry to another engine), not at the language level (another engine means rewriting the code).
