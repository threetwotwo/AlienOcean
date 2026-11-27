# core/: engine-free game logic

Plain GDScript (RefCounted only: no Nodes, no scenes, no physics server calls), one folder per module, numbered by the
gameplay study (M01-M28) and from M29 on in the order they were started (M29 water physics, M30 world clock, new
modules from M31). Each core gets everything it needs from the world through the service contracts below, so it can
run headless in tests and the engine side stays in adapters/godot/.

Gameplay modules M01-M04 are ports of Gary's Thalassa v20.19 prototype; tests/golden/ checks each against a recording
of the JavaScript.

## Shared service contracts

| Service | Shape | Real implementation | Test implementation |
|---|---|---|---|
| WaterQuery | `level: float` (-1000 = no water), `water_y(x, z, t) -> float`, `current(p: Vector3, t) -> Vector3` | core/world/lagoon_water.gd (LagoonWaterField) | tests/harness/test_env.gd |
| WorldQuery | `floor_height(x, z) -> float` (-INF = none), `floor_normal(x, z) -> Vector3`, `nearest_surface(p, r, filter = null) -> {dist, normal, point}` or `{}`, `point_solid(p) -> bool`, `ray(from, to) -> {position, normal}` or `{}` | adapters/godot/world_query.gd (Jolt) | the same adapter on tests/harness/test_worlds.gd geometry |
| Clock | `SkyClock`: game time, sun and moon directions, tide inputs | core/world/sky_clock.gd (SkyClock, M30) | same |
| InputSource | one `InputPacket` per tick (core/m01_input/input_packet.gd) | adapters/godot/input_reader.gd | scripted packets in tests |

In the running game adapters/godot/world_root.gd (WorldRoot) owns the shared instances: `.clock`, `.water`,
`.exposure` (core/world/water_optics.gd), `.streamer`. game_root adds it and hands it the camera.

Cores take these as a Dictionary of Callables (`env`) or as the object itself. A new service gets a row here before
any module uses it.

## Modules

| Folder | Module | Thalassa source |
|---|---|---|
| m01_input | input map, stick shaping, look filter | core/input.js |
| m02_motor | swim / wade / walk locomotion, layered moves | core/swimmer-physics.js, core/mover.js |
| m03_camera | no-cut camera | core/cinematic-camera.js |
| m04_body | body rig: springs, IK, foot placement, swim and walk poses | core/ik-rig.js, ik-solvers.js, procedural-locomotion.js, ik-poses-world.js, physics-control.js (in progress) |
| m12_streaming | open-world cell streamer (engine thread) | |
| m29_water_physics | buoyancy | |
| world | shared world state: sky clock (M30), lagoon water, water optics (engine thread) | |
