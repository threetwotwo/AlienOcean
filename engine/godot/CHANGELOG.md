# Changelog (Semantic Versioning; Unreal era filed as 0.1-0.5, Godot work starts at 0.6.0, 1.0.0 = first playable slice)

## 0.6.0-dev (27 Nov 2026, late): one world root
- Engine: architecture cleanup agreed with gameplay. core/world/ holds the engine-free world state: SkyClock (was
  core/m30_world_clock), WaterOptics and LagoonWaterField (were in look/). adapters/godot/world_root.gd (WorldRoot) is
  the one node that owns the key light, environment, sky, camera exposure and the water_* shader globals; it replaces
  sky_clock_driver.gd, look/sky_driver.gd and WaterOptics.push_globals, and caches the sky dome integral. look/ now
  holds shaders only; the shot tool moved to tools/lagoon_shots.gd and builds its world through WorldRoot. Clock test
  42/42, render unchanged (far water L* 57.0 vs 57.2 before).
- Engine: shared ground material (`look/ground_surface.gdshader`): the Unreal WorldSurface.ush GroundBlend (sand
  ripples, grains, rock, turf, crust; art bible v1.6 colours) converted by tools/ws_to_godot.py into
  look/world_surface.gdshaderinc, so one HLSL source keeps feeding both engines. adapters/godot/world_textures.gd
  loads the 19 world textures (AO_WORLDTEX for the shot tool).

## 0.6.0-dev (27 Nov 2026, evening): gameplay now built on Gary's Thalassa v20.19
- M02 player motor 0.2.0 = Thalassa core/swimmer-physics.js ported line for line (SwimmerLocomotion: carve turns,
  flipper-kick burst, glide-out braking, dive-to-pullout momentum, slipstream, surface treading with swell, dolphin
  breach, plunge dip, shoreline walk/wade/jog/crouch, anticipation jump, running dive) + mover.js layered moves
  (ocean current, impulses). Golden test against the JS: worst 0.05 mm over two 20 s runs.
  Godot adapter adds what Thalassa's height field never needed: Jolt collisions, 0.35 m step limit (T1), swim sphere
  0.42 m so a child fits a 1.0 m cave (T5), no standing up under low ceilings, steep dry slopes are walls, plus two
  robustness guards found by monkey runs (no floor at a world edge; air-branch speed cap under ledges) and contact
  velocity projection (Jolt's slide redirected a push against an edge sideways and snowballed to 13 m/s).
  19/19 at 30/60/120 fps incl. 4 x 300 s monkey runs; T1 50 deg ramp test moved to 60 deg (Thalassa walks to 56 deg).
- M01 input 0.2.0 = Thalassa core/input.js DualSense map and curves: move deadzone 0.11 / exponent 1.45, look 2.4 rad/s
  with exponent 1.72, outer-zone boost 1.45, asymmetric accel/stop filter 22/34 Hz, L2 analog dive, L1 or Cross ascend,
  R2 boost / L3 sprint latch, Circle observe, Triangle board, R1 sonar, R3 view, D-pad lights / silent / Atlas / TARS.
  Changed from Thalassa for platform rules: TARS leaves the Create button (system capture) for D-pad right; radio off
  Square and the touch pad. Golden test: worst 7.5e-8. 16/16 device tests.
- M03 camera 0.2.0 = Thalassa core/cinematic-camera.js updateForActor (anchor-relative crit springs, rigid 1P lock,
  Living Observer breath / lead room / landing settle, binary-refined spring arm). Golden: worst 0.004 mm over 15 s.
  Adapter: Jolt floor ray and sphere overlap answer the arm's probes; water-line rule kept from 0.1.0 for third person
  (sprung, 3-tick crossings). 11/11 incl. 4 x 300 s camera monkeys; probe-off fault caught. Replaces the 0.1.0 director.

## 0.6.0-dev (27 Nov 2026), slice setup, not yet in a git repo
- Engine: sand step 1: Better sand colour lock (SD2: #cdcac4 bare, #c8c4bb sorted) on the floor pieces, and the sand's
  bounce light in the fish's ambient (Lighting's sand bounce). Near sand L* 70.8 -> 72.4 (Unreal key 74-76), far water
  unchanged at 59. Still to port: the ripple rule, grains and glints (WorldSurface.ush: needs a Godot converter, since
  Godot shaders have no mutable globals) and our AgX extras.
- Engine: sky port 0.1.0 (`look/sky.gdshader`, `look/sky_driver.gd`): the Unreal sun disc and corona (SUN_HLSL) and both
  moons (MOON_HLSL: Lommel-Seeliger face, maria, planetshine, soft edge, phases from the clock) drawn as is, sun x5.29;
  air extinction per band (0.0862, 0.1665, 0.2961) now also colours the key light. Dome: Godot's PhysicalSkyMaterial shape
  (stand-in for Unreal's SkyAtmosphere, an engine feature), scaled so its ground light equals the clock's sky_lux.
  Checked at day 2, 5:30 pm: Moon B 76% lit, Moon A a 9% crescent beside the low sun. Stars (STARS_HLSL) still to port.
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
