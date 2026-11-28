## Test level T1 checks (test level thread, 28 Nov 2026; plans/test_level/PLAN.md in the project files).
## Run headless:  godot --headless --fixed-fps 60 --path . --script res://tests/test_test_level.gd -- [--ticks 3600] [--fault noshot|stuck]
##        drawn:  xvfb-run -a godot --path . --rendering-driver vulkan --script res://tests/test_test_level.gd -- --frames 600
##        [--out file.json] [--need-assets] [--gate-ms 33]
## Builds the real scene (TestLevel on GameRoot, with the lagoon assets when present) and checks:
##   L1 assets     every asset folder found (gated with --need-assets; the cloud and the Mac run with them)
##   L2 run        N ticks (or N drawn frames) with the girl's position finite and the game ticking every physics frame
##                 (script errors are caught by tests/run_test_level.sh, which fails on any "SCRIPT ERROR" line)
##   L3 teleports  every teleport lands her in water or on sand, not inside a hull, within 1.5 m of its spot, after 30 ticks
##   L4 switches   every switch, the hour, the day speed and the sea state return exactly to where they were after a change
##   L5 report     F8's writer saves every required field and the screenshot; IssueReport.verify reads it back
##   L6 monitors   the panel's numbers are Godot's monitors (within 1 %)
##   L7 flip cost  drawn runs: the worst frame within 3 frames of each switch flip, against the median frame (reported;
##                 with --gate-ms X it must stay under X ms: the Mac check, not the cloud's software GPU)
## Planted faults (must FAIL): noshot (the report is written without its screenshot), stuck (a switch's setter ignores 'off').
extends SceneTree

var lvl: TestLevel
var ticks := 3600
var frames := 0
var fault := ""
var out_path := ""
var need_assets := false
var gate_ms := 0.0
var results := []
var flip_frames := []

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		match a[i]:
			"--ticks": ticks = int(a[i + 1])
			"--frames": frames = int(a[i + 1])
			"--fault": fault = a[i + 1]
			"--out": out_path = a[i + 1]
			"--need-assets": need_assets = true
			"--gate-ms": gate_ms = float(a[i + 1])
	lvl = TestLevel.new()
	root.add_child(lvl)
	_run.call_deferred()

func _ok(id: String, ok: bool, detail) -> void:
	results.append({"id": id, "ok": ok, "detail": detail})
	print("%s %s  %s" % ["PASS" if ok else "FAIL", id, str(detail)])

func _ticks(n: int) -> void:
	for i in n: await physics_frame

func _frames(n: int) -> void:
	for i in n: await process_frame

func _run() -> void:
	while not lvl.ready_done: await process_frame
	var drawn := DisplayServer.get_name() != "headless"
	# L1
	_ok("L1 assets", lvl.missing_assets.is_empty() or not need_assets, {"missing": lvl.missing_assets, "gated": need_assets})
	# L1b: the grass field built blades (a script error in GrassField.adopt once left the meadows bare and every check green)
	var gs: Dictionary = lvl.grass.stats if lvl.grass else {}
	# (the stand-in floor run has no seagrass tiles at all: then nothing to build is a pass)
	var src := 0
	for mi in lvl.game.lagoon.find_children("*", "MeshInstance3D", true, false):
		if "seagrass" in String(mi.name).to_lower() and not "_blades" in String(mi.name): src += 1
	_ok("L1b grass", lvl.grass == null or int(gs.get("blades", 0)) > 1000 or src == 0, {"stats": gs, "seagrass_tiles": src})
	# L2
	var t0: int = lvl.game.clock.tick
	var bad_pos := 0
	var n := frames if drawn and frames > 0 else ticks
	for i in n:
		if drawn and frames > 0: await process_frame
		else: await physics_frame
		var p: Vector3 = lvl.game.girl.body.global_position
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)): bad_pos += 1
	var ran: int = lvl.game.clock.tick - t0
	_ok("L2 run", bad_pos == 0 and ran >= (n - 1 if not (drawn and frames > 0) else 1),
		{"steps": n, "drawn": drawn, "ticks_ran": ran, "non_finite": bad_pos, "worst_frame_ms": lvl.worst_frame_ms(600.0)})
	# L3
	var tp_rows := []
	var space := lvl.game.get_world_3d().direct_space_state
	for i in lvl.teleports.size():
		lvl.teleport(i)
		await _ticks(30)
		var b = lvl.game.girl.body
		var feet: Vector3 = b.global_position
		var target: Vector3 = lvl.teleports[i].feet
		var q := PhysicsRayQueryParameters3D.create(feet + Vector3.UP * 0.2, feet + Vector3.DOWN * 0.4)
		q.exclude = [b.get_rid()]
		var on_sand := not space.intersect_ray(q).is_empty()
		var in_water: bool = feet.y < lvl.game.world_root.water.level
		var inside: bool = b.penetrating()
		var drift := feet.distance_to(target)
		tp_rows.append({"name": lvl.teleports[i].name, "ok": (in_water or on_sand) and not inside and drift < 1.5,
			"feet": TestLevel._v(feet), "in_water": in_water, "on_sand": on_sand, "inside": inside, "drift_m": snappedf(drift, 0.01)})
	_ok("L3 teleports", tp_rows.all(func(r): return r.ok), tp_rows)
	# L4
	var s0 := lvl.get_state()
	var rows := []
	for nm in lvl.toggle_names():
		var was := lvl.get_toggle(nm)
		var f0 := Engine.get_frames_drawn()
		lvl.set_toggle(nm, not was)
		if fault == "stuck" and nm == "god_rays": lvl.set_toggle(nm, was)   # planted: the setter 'ignores' the change
		await _frames(3)
		var changed := lvl.get_toggle(nm) != was
		lvl.set_toggle(nm, was)
		await _frames(3)
		flip_frames.append([nm, f0])
		rows.append({"switch": nm, "changed": changed, "back": lvl.get_toggle(nm) == was})
	lvl.set_hour(20.5); lvl.set_sea_state("B12"); lvl.set_day_speed("2 min day")
	await _frames(3)
	var moved := lvl.get_state()
	lvl.apply_state(s0)
	await _frames(1)
	var s1 := lvl.get_state()
	var same := JSON.stringify(s0) == JSON.stringify(s1)
	var all_changed := rows.all(func(r): return r.changed and r.back)
	_ok("L4 switches", same and all_changed and moved.sea_state == "B12" and absf(moved.hour - 20.5) < 0.1,
		{"switches": rows, "count": rows.size(), "state_same": same, "before": s0, "after": s1})
	# L5
	var dir := OS.get_user_data_dir().path_join("test_reports")
	var img: Image = null if fault == "noshot" else Image.create(64, 36, false, Image.FORMAT_RGB8)
	if img != null: img.fill(Color(0.1, 0.4, 0.6))
	var rdir := IssueReport.write(lvl, "test note", img, dir)
	var bad := IssueReport.verify(rdir)
	var fault_seen := IssueReport.verify(_strip_shot(rdir)).has("screenshot")   # the checker itself must notice a missing picture
	_ok("L5 report", bad.is_empty() and fault_seen, {"dir": rdir, "missing": bad, "checker_catches_missing_shot": fault_seen})
	# L6
	await process_frame
	var st := lvl.stats()
	var P := Performance
	var pairs := {"draw_calls": P.get_monitor(P.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), "static_mem_mb": P.get_monitor(P.MEMORY_STATIC) / 1048576.0,
		"fps": P.get_monitor(P.TIME_FPS), "physics_ms": P.get_monitor(P.TIME_PHYSICS_PROCESS) * 1000.0}
	var off := {}
	for k in pairs: off[k] = absf(float(st[k]) - float(pairs[k])) / maxf(absf(float(pairs[k])), 1e-6)
	_ok("L6 monitors", off.values().all(func(x): return x <= 0.01), off)
	# L7
	if drawn:
		var fm := Array(lvl.frame_ms); var srt := fm.duplicate(); srt.sort()
		var med: float = srt[srt.size() / 2] if srt.size() > 0 else 0.0
		var worst := 0.0
		var hist_end := Engine.get_frames_drawn()
		var per := {}
		for ff in flip_frames:
			var k: int = fm.size() - (hist_end - int(ff[1]))
			var w := 0.0
			for j in range(maxi(k, 0), mini(k + 4, fm.size())): w = maxf(w, fm[j])
			per[ff[0]] = snappedf(w, 0.1); worst = maxf(worst, w)
		_ok("L7 flip cost", gate_ms <= 0.0 or worst <= gate_ms, {"median_ms": snappedf(med, 0.1), "worst_flip_ms": snappedf(worst, 0.1),
			"ratio": snappedf(worst / maxf(med, 0.001), 0.01), "per_switch": per, "gate_ms": gate_ms})
	var ok := results.all(func(r): return r.ok)
	print("TESTLEVEL ", "ALL PASS" if ok else "FAIL", " (fault=%s)" % fault)
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE); f.store_string(JSON.stringify({"fault": fault, "results": results}, "  ")); f.close()
	quit(0 if ok else 1)

func _strip_shot(rdir: String) -> String:
	## a copy of the report folder without its picture (for the checker's own self-test)
	var d := rdir + "_noshot"
	DirAccess.make_dir_recursive_absolute(d)
	DirAccess.copy_absolute(rdir.path_join("report.json"), d.path_join("report.json"))
	return d
