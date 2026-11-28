## Teleport stress 0.1.0 (test level thread, 28 Nov 2026): hunts the Metal GPU hang ("timeout waiting for fence" / frozen frames)
## that hit 4 of 11 Mac bench runs, each right after a camera teleport. Teleports round every station many times (also with hour
## changes, which re-light the world and re-capture the floor map), times every frame for a while after each jump, and reads
## Godot's log after each one, so a hang is pinned to the jump that came before it.
## Isolation switches (env): AO_TP_FLOORMAP=0 (the sea floor map never re-captures), AO_TP_SDFGI=0 (SDFGI off), AO_TP_HOURS=0
## (no hour changes), AO_TP_SETTLE (s after a jump, default 2.5), AO_TP_ROUNDS (default 6).
## Run on the Mac (full screen like the game): ../Godot_4.7 --path engine/godot --script res://tools/perf_runner/teleport_stress.gd
## Prints TPSTRESS lines and writes user://teleport_stress.json. Pass = no fence timeout and no frame over 2 s.
extends SceneTree

var rounds := 6
var settle := 2.5
var log_path := "user://logs/godot.log"

func _initialize() -> void:
	rounds = int(OS.get_environment("AO_TP_ROUNDS")) if OS.get_environment("AO_TP_ROUNDS") != "" else 6
	settle = float(OS.get_environment("AO_TP_SETTLE")) if OS.get_environment("AO_TP_SETTLE") != "" else 2.5
	var lvl := TestLevel.new(); root.add_child(lvl)
	_run.call_deferred(lvl)

func _log_hangs() -> int:
	if not FileAccess.file_exists(log_path): return 0
	return FileAccess.get_file_as_string(log_path).count("timeout waiting for fence")

func _run(lvl) -> void:
	while not lvl.ready_done: await process_frame
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var g = lvl.game
	if OS.get_environment("AO_TP_SDFGI") == "0": lvl.set_toggle("sdfgi", false)
	if OS.get_environment("AO_TP_FLOORMAP") == "0":
		var fm = root.find_child("SeaFloorMap", true, false)
		if fm: fm.frozen = true
	var hours := OS.get_environment("AO_TP_HOURS") != "0"
	for i in 90: await process_frame
	var n: int = lvl.teleports.size()
	var rows := []
	var hangs0 := _log_hangs()
	var worst_all := 0.0
	var k := 0
	for r in rounds:
		for i in n:
			var j := (i * 3 + r) % n          # jumps in a mixed order: near and far stations follow each other
			if hours and k % 3 == 2: lvl.set_hour(fmod(lvl.get_hour() + 5.0, 24.0))
			var t0 := Time.get_ticks_usec()
			lvl.teleport(j)
			var ts := PackedFloat32Array(); var last := Time.get_ticks_usec()
			while (Time.get_ticks_usec() - t0) < int(settle * 1e6):
				await process_frame
				var now := Time.get_ticks_usec(); ts.append((now - last) / 1000.0); last = now
			var worst := 0.0; var first5 := 0.0
			for q in ts.size():
				worst = maxf(worst, ts[q])
				if q < 5: first5 += ts[q]
			var sorted := ts.duplicate(); sorted.sort()
			var h := _log_hangs() - hangs0
			var row := {"k": k, "round": r, "tp": j, "name": lvl.teleports[j].name, "hour": snappedf(lvl.get_hour(), 0.01),
				"frames": ts.size(), "first5_ms": snappedf(first5, 0.1), "worst_ms": snappedf(worst, 0.1),
				"p50_ms": snappedf(sorted[sorted.size() / 2], 0.01), "fence_timeouts_so_far": h}
			rows.append(row); worst_all = maxf(worst_all, worst)
			print("TPSTRESS %3d tp %d %-18s hour %5.2f  first5 %7.1f ms  worst %7.1f ms  p50 %6.2f ms  fence %d" % [k, j, lvl.teleports[j].name,
				lvl.get_hour(), first5, worst, sorted[sorted.size() / 2], h])
			k += 1
	var hangs := _log_hangs() - hangs0
	var ok := hangs == 0 and worst_all < 2000.0
	print("TPSTRESS %s: %d jumps, fence timeouts %d, worst frame %.0f ms" % ["PASS" if ok else "FAIL", k, hangs, worst_all])
	var f := FileAccess.open("user://teleport_stress.json", FileAccess.WRITE)
	if f: f.store_string(JSON.stringify({"pass": ok, "fence_timeouts": hangs, "worst_ms": worst_all, "rows": rows,
		"env": {"floormap": OS.get_environment("AO_TP_FLOORMAP"), "sdfgi": OS.get_environment("AO_TP_SDFGI"), "hours": hours}}, " "))
	quit(0 if ok else 1)
