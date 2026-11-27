## Tide 0.1.0 (core/world; water surface thread, 27 Nov 2026): the sea level from the two moons and the sun.
## Port of the Unreal OceanWorld plugin's Model::TideAt (as lagoonwater v82 read it back, line 6715): an equilibrium
## tide, each body's semidiurnal bulge cos(2 x its hour angle):
##     tide = gain x (A_amp cos 2 H_A + B_amp cos 2 H_B + sun_amp cos 2 H_sun)   m, about the mean level
## with the plugin's amplitudes (moon A 0.24 m, moon B 0.15 m, sun 0.11 m) and the lagoon's gain 0.67 (Gary 14 Nov
## 03:57Z "Calm it to about a third"; the plugin default 2.0 stays the open sea's).
## One change, on purpose: the hour angles are the world clock's own (SkyClock.sky_state: sun_h - the moon's orbit
## offset), so high water always comes with a moon over or under the island. The plugin kept moon B on its own epoch
## (-8.5 h), which put its bulge 8.5 h away from the moon B drawn in the sky (sun_v184 has no epoch for B).
## Engine-agnostic. LagoonWaterField reads it; WorldRoot pushes the level to the shaders (water_y).
class_name Tide
extends RefCounted

const MOON_A_AMP := 0.24      # m (plugin moon_a_tide)
const MOON_B_AMP := 0.15      # m (plugin moon_b_tide)
const SUN_AMP := 0.11         # m (plugin sun_tide)
const GAIN := {"calm_lagoon": 0.67, "open_ocean": 2.0}
const LAG_HOURS := 0.0        # plugin tide_lag_hours

static func hour_angles(hours: float, day_hours := 24.0, months := SkyClock.MONTHS, orbits := SkyClock.ORBITS) -> Vector3:
	## (sun, moon A, moon B) hour angles in rad, as SkyClock.sky_state() places the bodies
	var days := (hours - LAG_HOURS) / day_hours
	var sun_h := TAU * (days - 0.5)
	var ha := sun_h - SkyClock.orbit_offset(days, months[0], orbits.get("A", {})).x
	var hb := sun_h - SkyClock.orbit_offset(days, months[1], orbits.get("B", {})).x
	return Vector3(sun_h, ha, hb)

static func height(hours: float, gain := 0.67, day_hours := 24.0) -> float:
	## m above the mean sea level
	var h := hour_angles(hours, day_hours)
	return gain * (MOON_A_AMP * cos(2.0 * h.y) + MOON_B_AMP * cos(2.0 * h.z) + SUN_AMP * cos(2.0 * h.x))

static func range_over(days: float, gain := 0.67, step_h := 0.25) -> Vector2:
	## (lowest, highest) over the next `days` game days from hour 0 (for layout: the life line sits under the lowest)
	var lo := INF; var hi := -INF
	var n := int(days * 24.0 / step_h)
	for i in n:
		var t := height(i * step_h, gain)
		lo = minf(lo, t); hi = maxf(hi, t)
	return Vector2(lo, hi)
