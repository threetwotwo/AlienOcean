# Changelog (Semantic Versioning; Unreal era filed as 0.1-0.5, Godot work starts at 0.6.0, 1.0.0 = first playable slice)

## 0.6.0-dev (27 Nov 2026), slice setup, not yet in a git repo
- Engine: ported Unreal systems, round 1 (Gary 27 Nov 15:13Z "port working Unreal systems to Godot").
  M30 world clock 0.1.0 (`core/m30_world_clock/sky_clock.gd`): the Unreal sky clock's maths (sun_v184) as is: G2V sun twin,
  128 klx above the air, 78 deg noon, moons A and B (size, albedo, colour, phases, orbits), eclipses, twilight table, key-light
  pick and hand-over fade. `tests/test_world_clock.gd` matches the old Python at 42 points (light 1e-5, angles 1e-4 deg). PASS.
  Clock adapter 0.1.0 (`adapters/godot/sky_clock_driver.gd`): key light lux and colour, EV100 exposure (steady under-water eye
  14.75 at noon, as Unreal's 14.6-14.9), calm lagoon +1.2 compensation. Physical light units on project-wide.
  Lagoon water optics 0.1.0 (`look/water_optics.gd`, `look/water_physics.gdshaderinc`): the Unreal lagoon's water physics
  (under_model / PHYS_CODE / UNDER_PHYS) with Gary's look set Cdom 0.03, ScatK 0.40, GlowK 2.50, as global shader uniforms.
  Seabed 0.2.0 lit through the water; underwater view 0.1.0 (path glow + absorption per band); surface 0.2.0 (window + mirror).
  Lagoon look 0.2.0: surface at 4 m (Unreal's SurfaceZ 400 cm). Measured: far water L* 59 (Unreal model 58-59), near sand
  L* 68-70 (Unreal key 74-76: sand albedo and sand bounce not ported yet).
- Gameplay: M01 input 0.1.0 (16/16): bindings as data, Create and PS buttons never bound, glyph names per platform and live
  swap, remap refused onto system or taken buttons, remap survives save/reload, controller loss pauses with neutral input.
  Root fix found by the test: InputMap's per-action deadzone stacked with the core's radial deadzone (half-speed small stick);
  sticks now reach the core raw.
- Gameplay: M29 water physics 0.1.0 (8/8 at 30/60/120 fps, identical): drafts 0.499 / 0.877 m for 0.5 / 0.878 density,
  drop from 3 m settles, flat box rights from 30 deg, dense box sinks, tall pole lies down, follows Beaufort 4 waves,
  drifts at 0.95 m/s in a 1 m/s current. Root fixes: engine world damping (0.1/s) fought currents (now off for water bodies);
  drag area counted once per layer. Stand-in: heave damping for wave radiation (logged in HARD_PROBLEMS.md).
- Gameplay: M02 player motor 0.1.0 + M23 harness 0.1.0 on Jolt (Godot 4.7). 23/23 cases pass at 30, 60 and 120 fps with
  identical end states (fixed 60 Hz tick): walk, 15/30 deg slopes climb, 50 deg refuses, 10/30 cm steps climb, 50 cm refuses,
  shore walk-wade-swim-wade-walk (still and Beaufort 4 waves), cruise 3.4 / sprint 5.0 m/s, dive and rise to tread, tread holds
  in waves, 1.0 m cave passes, 0.8 m refuses, makes way against 1.5 and 3 m/s currents, 8 x 300 s monkey runs.
  Root fixes found by the monkey runs: airborne-in-water counted as wading (now floating past the chest band); wading
  turned to swimming while bobbing at 1.03 m (now needs 0.5 s afloat); slope/wave floor loss flicker (coyote 0.15 s).
  Planted fault (swim sphere 0.30 m) lets the 0.8 m cave through and is caught.
- Godot 4.5.1 project skeleton (Forward+), proven to render in the cloud on CPU Vulkan.
- M12 world streaming core 0.1.0 (`core/m12_streaming/cell_streamer.gd`): ring of live cells + far stand-ins, travel lookahead,
  hysteresis. Test `tests/test_cell_streamer.gd`: swim 2 m/s and fast sub 25 m/s across 4 x 4 km, zero cells missing inside 32 m,
  live <= 26, far <= 75, <= 2 new cells per update after the start fill; planted fault (no lookahead, 20 m ring) caught. PASS.
- Godot adapter 0.1.0 (`adapters/godot/stream_loader.gd`): threaded ResourceLoader loads, instancing spread across frames. Not yet run on a world.
- Turnaround tool 0.1.0 (`tools/turnaround.gd`): any GLB at runtime, 7 views + sheet + import report. First run: LIVE snapper LOD1
  arrived with 65,458 triangles, 86 joints, COLOR_0 present. Finding: Godot uses COLOR_0 as albedo by default, but ours is data
  (R = fin thickness), so the importer must switch that off (done in the tool; the game importer needs the same rule).
