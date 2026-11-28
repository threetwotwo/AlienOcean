## Perf runner 0.1.0 (perf runner thread, 28 Nov 2026): plays the test level by itself on a real GPU and measures it, so nobody
## has to fly around to find what is slow. Built on the test level's own setters (TestLevel: teleport, set_hour, set_sea_state,
## set_toggle, stats), never a second copy of them.
## For each station (a teleport + camera yaw/pitch + hour + sea state, from a JSON file): settle, then time every frame with
## vsync off (true cost, not the display cap): mean / p50 / p95 / p99 / worst frame ms, GPU and CPU render ms, draws, triangles,
## GameRoot phase ms, a screenshot, and image numbers (mean brightness, share of near-white pixels = the "white void" check).
## Then at each toggle station every switch is flipped, timed and flipped back: the ms each system costs in that view.
## Each flip is compared with the switch-unflipped frames measured right before AND right after it (ABA, --ab-rounds N
## repeats the AB pair): one base taken at the start drifts over the minutes of later flips (the girl settles, other
## systems warm up), which once billed the last switch in the list (bubbles) ~5 ms it never cost (bubbles thread, 28 Nov).
## Output: <out>/results.json + station PNGs; tools/perf_runner/summarize.py turns it into summary.md and report.html.
## Run (tools/perf_runner/run_perf.sh does all of it):
##   godot --path . --script res://tools/perf_runner/perf_runner.gd -- --out DIR [--stations res://...json] [--settle 1.5]
##         [--measure 3.0] [--toggle-measure 2.0] [--only name,name] [--no-toggles] [--fault slow] [--label NAME]
##         [--toggles name,name] [--ab-rounds 1]
## --fault slow: planted fault, burns 40 ms of CPU per frame at the station "keyframe_view"; the summary must show it as the
## worst station (tests/run_perf_runner.sh checks it).
extends SceneTree

var out := ""
var stations_path := "res://tools/perf_runner/stations_test_level.json"
var settle_s := 1.5
var measure_s := 3.0
var toggle_measure_s := 2.0
var only: Array = []
var do_toggles := true
var only_toggles: Array = []
var ab_rounds := 1
var fault := ""
var run_label := ""
var _burn_ms := 0.0
var lvl = null
var results := {}
var _size0 := Vector2i.ZERO

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var i := 0
	while i < a.size():
		var k: String = a[i]
		var v: String = a[i + 1] if i + 1 < a.size() else ""
		match k:
			"--out": out = v; i += 1
			"--stations": stations_path = v; i += 1
			"--settle": settle_s = float(v); i += 1
			"--measure": measure_s = float(v); i += 1
			"--toggle-measure": toggle_measure_s = float(v); i += 1
			"--only": only = Array(v.split(",")); i += 1
			"--fault": fault = v; i += 1
			"--label": run_label = v; i += 1
			"--no-toggles": do_toggles = false
			"--toggles": only_toggles = Array(v.split(",")); i += 1
			"--ab-rounds": ab_rounds = maxi(1, int(v)); i += 1
		i += 1
	if out == "":
		push_error("perf_runner: --out DIR is required"); quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# Pin the window: a window the OS or a person enlarges mid-run (seen 28 Nov: 960x540 -> 2704x1696 halfway through a
	# benchmark) changes the pixel count and makes every later number meaningless. Each station also records its size.
	# (only for an explicit --resolution window: the test level goes full screen by default, and a locked window can't)
	if "--resolution" in OS.get_cmdline_args():
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_RESIZE_DISABLED, true)
	Engine.max_fps = 0
	var main = load("res://scenes/test_level.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred(main)

func _process(_delta: float) -> bool:
	if _burn_ms > 0.0:
		var t0 := Time.get_ticks_usec()
		while Time.get_ticks_usec() - t0 < int(_burn_ms * 1000.0): pass
	return false

func _run(main) -> void:
	while lvl == null or not lvl.ready_done:
		await process_frame
		if main.get_child_count() > 0: lvl = main.get_child(0)
	await process_frame
	for c in main.get_children():          # hide the debug panel's HUD: it is not part of what Gary's view costs
		if c != lvl and c is CanvasItem: c.visible = false
		elif c != lvl and c.has_method("set_open"): c.set_open(false); _hide_canvas(c)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	_size0 = root.size
	var f := FileAccess.open(stations_path, FileAccess.READ)
	if f == null: push_error("perf_runner: cannot read " + stations_path); quit(2); return
	var cfg: Dictionary = JSON.parse_string(f.get_as_text())
	var base_state: Dictionary = lvl.get_state()
	results = {
		"tool": "perf_runner 0.1.0", "utc": Time.get_datetime_string_from_system(true), "stations_file": stations_path,
		"version": IssueReport._version(),
		"machine": {"os": OS.get_name(), "cpu": OS.get_processor_name(), "gpu": RenderingServer.get_video_adapter_name(),
			"driver": RenderingServer.get_video_adapter_api_version(), "godot": Engine.get_version_info().string},
		"window": [root.size.x, root.size.y], "fullscreen": DisplayServer.window_get_mode() >= DisplayServer.WINDOW_MODE_FULLSCREEN, "screen": [DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y], "vsync": "off", "settle_s": settle_s, "measure_s": measure_s,
		"fault": fault, "label": run_label, "base_state": base_state, "missing_assets": lvl.missing_assets,
		"stations": [], "toggles": [],
	}
	var by_name := {}
	for st in cfg.stations:
		if not only.is_empty() and not st.name in only: continue
		lvl.apply_state(base_state)
		var r := await _station(st, true)
		results.stations.append(r); by_name[st.name] = st
		print("PERF %-24s mean %6.1f ms  p95 %6.1f  worst %6.1f  gpu %5.1f  tris %8d  draws %4d  white %.2f" % [st.name, r.mean_ms, r.p95_ms, r.worst_ms, r.gpu_ms, r.triangles, r.draw_calls, r.image.white_frac])
		_save()
	if do_toggles:
		var skip: Array = cfg.get("skip_toggles", [])
		for sn in cfg.get("toggle_stations", []):
			if not by_name.has(sn): continue
			lvl.apply_state(base_state)
			var base := await _station(by_name[sn], false, toggle_measure_s)
			for t in lvl.toggle_names():
				if t in skip: continue
				if not only_toggles.is_empty() and not t in only_toggles: continue
				var was: bool = lvl.get_toggle(t)
				var bases := [base]; var flips := []
				for k in ab_rounds:
					lvl.set_toggle(t, not was)
					flips.append(await _station(by_name[sn], false, toggle_measure_s, false))
					lvl.set_toggle(t, was)
					bases.append(await _station(by_name[sn], false, toggle_measure_s, false))
				base = bases[bases.size() - 1]          # the next switch's "before"
				var b := _mean_rows(bases); var r := _mean_rows(flips)
				var row := {"station": sn, "toggle": t, "default_on": was, "flipped_to": not was, "ab_rounds": ab_rounds,
					"base_mean_ms": b.mean_ms, "flipped_mean_ms": r.mean_ms, "base_gpu_ms": b.gpu_ms, "flipped_gpu_ms": r.gpu_ms,
					"base_spread_ms": b.spread_ms, "flipped_spread_ms": r.spread_ms,
					"cost_ms": (b.mean_ms - r.mean_ms) if was else (r.mean_ms - b.mean_ms),
					"gpu_cost_ms": (b.gpu_ms - r.gpu_ms) if was else (r.gpu_ms - b.gpu_ms),
					"base_p95_ms": b.p95_ms, "flipped_p95_ms": r.p95_ms, "flipped_worst_ms": r.worst_ms}
				results.toggles.append(row)
				print("TOGGLE %-20s %-9s %s: %6.1f -> %6.1f ms (cost %+.1f ms, gpu %+.1f; base spread %.1f)" % [sn, t, "off" if was else "on", b.mean_ms, r.mean_ms, row.cost_ms, row.gpu_cost_ms, b.spread_ms])
				_save()
	lvl.apply_state(base_state)
	results["finished_utc"] = Time.get_datetime_string_from_system(true)
	_save()
	print("PERF done -> " + out)
	quit(0)

func _hide_canvas(n: Node) -> void:
	for c in n.get_children():
		if c is CanvasItem: c.visible = false
		_hide_canvas(c)

func _save() -> void:
	var f := FileAccess.open(out.path_join("results.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(results, "  "))
	f.close()

## The mean of several timed runs of one view, and how far apart their means are (max - min: the noise floor of a cost).
static func _mean_rows(rows: Array) -> Dictionary:
	var m := {"mean_ms": 0.0, "gpu_ms": 0.0, "p95_ms": 0.0, "worst_ms": 0.0}
	var lo := INF; var hi := -INF
	for r in rows:
		for k in m: m[k] += float(r[k]) / rows.size()
		lo = minf(lo, r.mean_ms); hi = maxf(hi, r.mean_ms)
	m["spread_ms"] = hi - lo
	return m

## Go to a station, settle, time frames for `secs`, optionally save a screenshot. retp=false keeps the girl where she is
## (toggle runs at the same station) and only re-applies the camera angles.
func _station(st: Dictionary, shot: bool, secs := -1.0, retp := true) -> Dictionary:
	if secs < 0.0: secs = measure_s
	lvl.set_sea_state(st.get("sea", "lagoon"))
	for t in st.get("toggles", {}): lvl.set_toggle(t, bool(st.toggles[t]))   # optional per-station switches, e.g. {"sea": false}
	lvl.set_hour(float(st.get("hour", 12.0)))
	if retp: lvl.teleport(_tp_index(st))
	_burn_ms = 40.0 if (fault == "slow" and st.name == "keyframe_view") else 0.0
	var cam = lvl.game.cam
	var settle := settle_s if retp else minf(settle_s, 1.0)
	var t_end := Time.get_ticks_usec() + int(settle * 1e6)
	var n := 0
	while Time.get_ticks_usec() < t_end or n < 10:
		_aim(cam, st); await process_frame; n += 1
	var ms := PackedFloat32Array(); var gpu := 0.0; var cpu := 0.0
	var phase := {}; var tick := 0.0
	var vp := root.get_viewport_rid()
	var prev := Time.get_ticks_usec()
	t_end = prev + int(secs * 1e6)
	while Time.get_ticks_usec() < t_end or ms.size() < 20:
		_aim(cam, st)
		await process_frame
		var now := Time.get_ticks_usec()
		ms.append((now - prev) / 1000.0); prev = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu()
		tick += float(lvl.game.stats.tick_ms)
		for k in lvl.game.stats.phase_ms: phase[k] = phase.get(k, 0.0) + float(lvl.game.stats.phase_ms[k])
	var N := float(ms.size())
	var s := ms.duplicate(); s.sort()
	var sum := 0.0
	for x in ms: sum += x
	var P := Performance
	var r := {
		"name": st.name, "station": st, "frames": ms.size(), "mean_ms": sum / N, "fps": 1000.0 * N / sum,
		"p50_ms": s[int(N * 0.5)], "p95_ms": s[mini(int(N * 0.95), s.size() - 1)], "p99_ms": s[mini(int(N * 0.99), s.size() - 1)],
		"worst_ms": s[s.size() - 1], "gpu_ms": gpu / N, "cpu_render_ms": cpu / N, "tick_ms": tick / N,
		"phase_ms": {}, "draw_calls": int(P.get_monitor(P.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"triangles": int(P.get_monitor(P.RENDER_TOTAL_PRIMITIVES_IN_FRAME)), "objects": int(P.get_monitor(P.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"video_mem_mb": P.get_monitor(P.RENDER_VIDEO_MEM_USED) / 1048576.0, "where": lvl.where(), "frame_ms": Array(ms),
		"image": {"white_frac": 0.0, "mean_luma": 0.0}, "shot": "", "viewport": [root.size.x, root.size.y],
		"resized": root.size != _size0,
	}
	for k in phase: r.phase_ms[k] = phase[k] / N
	if shot:
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		r.shot = st.name + ".png"
		img.save_png(out.path_join(r.shot))
		var th := img.duplicate() as Image           # small JPEG for the phone page (report.html embeds these)
		th.resize(640, int(640.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR)
		th.save_jpg(out.path_join(st.name + "_thumb.jpg"), 0.8)
		r.image = _image_numbers(img)
	return r

## The station's teleport: "tp" = one of the level's own teleports, or "pos" = [x, metres below the surface, z] (Godot x z),
## added to the level's teleport list once so the move goes through TestLevel.teleport like every other.
func _tp_index(st: Dictionary) -> int:
	if not st.has("pos"): return int(st.get("tp", 0))
	var nm := "perf: " + str(st.name)
	for i in lvl.teleports.size():
		if lvl.teleports[i].name == nm: return i
	var surf: float = lvl.game.world_root.water.level
	lvl.teleports.append({"name": nm, "feet": Vector3(float(st.pos[0]), surf - float(st.pos[1]), float(st.pos[2])),
		"yaw": float(st.get("yaw", 0.0)), "swim": true})
	return lvl.teleports.size() - 1

func _aim(cam, st: Dictionary) -> void:
	if cam == null: return
	cam.yaw = float(st.get("yaw", 0.0)); cam.pitch = float(st.get("pitch", -0.1))

## Brightness numbers of a frame on a 160x90 copy: mean luma (0-1) and the share of pixels brighter than 0.92 with almost
## no colour (the white void Gary saw looking down in open water reads as a large share here).
static func _image_numbers(img: Image) -> Dictionary:
	var im := img.duplicate() as Image
	im.convert(Image.FORMAT_RGB8)
	im.resize(160, 90, Image.INTERPOLATE_BILINEAR)
	var white := 0; var luma := 0.0
	for y in 90:
		for x in 160:
			var c := im.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			luma += l
			if l > 0.92 and maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)) < 0.08: white += 1
	return {"white_frac": white / 14400.0, "mean_luma": luma / 14400.0}
