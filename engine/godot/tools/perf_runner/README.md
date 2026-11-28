# Perf runner 0.1.0

Plays a level by itself on a real GPU and measures it, so nobody has to fly around to find what is slow.
Built on the test level's own controls (TestLevel: `teleport`, `set_hour`, `set_sea_state`, `toggle_names` /
`set_toggle`, `stats`); new switches added to the test level are picked up automatically.

## What it does
1. For each **station** in a JSON file (teleport + camera yaw/pitch + hour + sea state) it settles, then times every
   frame with **vsync off** (the real cost, not the display cap): mean, p50, p95, p99, worst frame ms, fps, draws,
   triangles, GameRoot phase ms, and a **screenshot** with image numbers (mean brightness, share of near-white
   pixels; above 0.25 the view is flagged `VOID`, the white-void check).
2. At each **toggle station** it flips every switch, times it, flips it back: the ms each system costs in that view.
3. The window is pinned (resize disabled) and every station records its size; a run where it changed is flagged.
4. `summarize.py` writes `summary.md` (tables) and `report.html` (one page, screenshots embedded, phone friendly).

## Run
```
tools/perf_runner/run_perf.sh                      # window (960x540) and full screen, all stations and switches
PROFILES=window tools/perf_runner/run_perf.sh --only floor_look_down,openwater_look_down --no-toggles
PROFILES="1920x1080" tools/perf_runner/run_perf.sh # any resolution
AO_GRASS=0 tools/perf_runner/run_perf.sh           # test level env switches pass straight through
```
Output: `<repo>/playtest_reports/perf/<UTC stamp>/` (per profile: results.json, PNGs, godot.log; summary.md, report.html).
Godot: `GODOT=...`, else `../Godot_4.7` beside the repo, else `/Applications/Godot.app`. Needs a GPU and a window
(on a Mac nothing else; in the cloud xvfb + vulkan). No macOS permission needed: screenshots come from Godot's own frame.

## Inputs and outputs
- Stations: `stations_test_level.json` (copy it for another level; `--stations res://...`). Fields: name, tp (a level teleport) or pos ([x, metres below the surface, z], e.g. the open ocean past the reef), yaw,
  pitch (-1.4 = straight down), hour, sea; `toggle_stations`, `skip_toggles`.
- `results.json`: machine, window, build version, base state, per station all the numbers plus every frame's ms,
  toggle rows (default, ms with and without, cost).

## Test
`tests/run_perf_runner.sh`: a short run with the planted fault `--fault slow` (40 ms burned per frame at
keyframe_view). Pass = that station is the slowest and over 40 ms, files written, no script errors.

## Known limits
- Godot 4.7 reports 0 GPU ms on Metal, so frame ms is the whole frame (CPU + GPU); the toggle deltas are the useful split.
- Switching SDFGI back on rebuilds its cascades; the toggle pass settles 1 s after each switch.
