## Tide (water surface thread): core/world/tide.gd must be the Unreal OceanWorld plugin's Model::TideAt (as lagoonwater
## v82 read it back) on the world clock's own hour angles.
##  T1 the plugin's formula, rewritten here independently, with moon B's epoch at 0 (the one deliberate change), agrees
##     to 0.1 mm over 60 game days (SkyClock.orbit_offset returns a single-precision Vector2: ~1e-5 m of noise).
##  T2 the lagoon (gain 0.67) stays within +-0.335 m (the Unreal log: 367..433 cm) about the 400 cm mean over 60 days
##     (Gary 14 Nov "calm it to about a third"), and swings at least 0.5 m somewhere in it (springs).
##  T3 high water comes with the moons: at a moment when moon A is due south of overhead (its hour angle 0), its own
##     bulge term is at its peak.
##  T4 planted fault: the open-sea gain (2.0) must break T2's band.
##  T5 LagoonWaterField follows: set_clock moves level and water_y by the tide.
## Run: godot --headless --path . --script res://tests/test_tide.gd
extends SceneTree

func plugin_tide(sec: float, gain: float) -> float:
	var day := 24.0 * 3600.0
	var sh := TAU * (sec / day - 0.5)
	var ha := sh - TAU * sec / (29.5 * day)
	var hb := sh - TAU * sec / (8.0 * day)          # epoch 0 (the plugin: -8.5 h)
	return gain * (0.24 * cos(2.0 * ha) + 0.15 * cos(2.0 * hb) + 0.11 * cos(2.0 * sh))

func _init():
	var bad := 0
	var worst := 0.0
	for i in 60 * 24 * 4:
		var h := i * 0.25
		worst = maxf(worst, absf(Tide.height(h, 0.67) - plugin_tide(h * 3600.0, 0.67)))
	print("T1 plugin formula: max diff %s m -> %s" % [str(worst), "PASS" if worst < 1e-4 else "FAIL"])
	if worst >= 1e-4: bad += 1
	var r := Tide.range_over(60.0, 0.67)
	var amp := 0.67 * (Tide.MOON_A_AMP + Tide.MOON_B_AMP + Tide.SUN_AMP)   # 0.335 m: all three bulges together
	var ok2 := r.x >= -amp - 1e-6 and r.y <= amp + 1e-6 and r.y - r.x >= 0.5
	print("T2 lagoon range over 60 days: %.1f .. %.1f cm about the mean -> %s" % [r.x * 100.0, r.y * 100.0, "PASS" if ok2 else "FAIL"])
	if not ok2: bad += 1
	# T3: find an hour where moon A's hour angle is ~0 (it crosses the meridian once per lunar day)
	var found := false
	for i in 24 * 60:
		var h := i / 60.0
		var ha := Tide.hour_angles(h)
		if absf(wrapf(ha.y, -PI, PI)) < 0.01:
			found = absf(cos(2.0 * ha.y) - 1.0) < 1e-3
			break
	print("T3 moon A overhead -> its bulge at peak: %s" % ("PASS" if found else "FAIL"))
	if not found: bad += 1
	var ro := Tide.range_over(60.0, Tide.GAIN.open_ocean)
	var caught := ro.x < -0.336 or ro.y > 0.336
	print("T4 planted fault (open-sea gain 2.0 in the lagoon): %s" % ("caught -> PASS" if caught else "NOT caught -> FAIL"))
	if not caught: bad += 1
	var w := LagoonWaterField.new()
	w.set_clock(12.0)
	var ok5 := absf(w.level - (LagoonWaterField.SURFACE_Y + Tide.height(12.0, 0.67))) < 1e-9 and w.water_y(1.0, 2.0, 0.0) == w.level and absf(w.tide) > 0.01
	print("T5 LagoonWaterField follows the tide (noon day 0: %.3f m): %s" % [w.level, "PASS" if ok5 else "FAIL"])
	if not ok5: bad += 1
	print("tide: %s" % ("PASS" if bad == 0 else "FAIL"))
	quit(0 if bad == 0 else 1)
