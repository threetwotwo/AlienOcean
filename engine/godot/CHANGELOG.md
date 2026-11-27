# Changelog (Semantic Versioning; Unreal era filed as 0.1-0.5, Godot work starts at 0.6.0, 1.0.0 = first playable slice)

## 0.6.0-dev (27 Nov 2026), slice setup, not yet in a git repo
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
