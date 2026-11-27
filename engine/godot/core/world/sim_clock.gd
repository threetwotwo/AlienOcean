## Sim clock 0.1.0 (core/world, the SimClock contract; game root thread, 27 Nov 2026): the one owner of game time.
## Architecture review 27 Nov (plans/architecture/fable_critique_2026-11-27.md, cleanup 1): one clock that owns sim time
## and the world hour, and passes t into every tick, instead of five private clocks. Game root steps it once per
## physics tick, first, and hands .t / .hours to everything after it.
## t is tick * dt (not a running sum), so the same number of ticks gives the same t on every machine and render rate.
## hours drives the world clock (core/world/sky_clock.gd: the sun, the two moons, the tide); hours_per_second = 0
## holds the time of day (reference shots), 24 / 1200 = a 20-minute day.
class_name SimClock
extends RefCounted

var dt := 1.0 / 60.0            # the fixed simulation tick (project physics rate)
var tick := 0                   # ticks since start
var t := 0.0                    # sim seconds since start = tick * dt
var start_hours := 12.0
var hours := 12.0               # world clock hour (may run past 24: SkyClock counts days)
var hours_per_second := 0.0     # game hours per sim second; 0 = time of day held
var paused := false

func _init(start_hour := 12.0, tick_dt := 1.0 / 60.0) -> void:
	start_hours = start_hour; hours = start_hour; dt = tick_dt

## One tick. Returns the tick's dt (0 while paused, so movers hold still and nothing integrates).
func step() -> float:
	if paused: return 0.0
	tick += 1
	t = tick * dt
	hours = start_hours + t * hours_per_second
	return dt

## Jump the time of day (a sleep, a cut scene); t keeps counting so nothing that integrates over t jumps.
func set_hours(h: float) -> void:
	start_hours = h - t * hours_per_second
	hours = h
