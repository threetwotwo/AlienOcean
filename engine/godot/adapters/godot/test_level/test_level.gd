## TestLevel 0.1.0 (adapters/godot/test_level; test level thread, 28 Nov 2026): the playtest scene Gary opens on his Mac (T1 of
## plans/test_level/PLAN.md in the project files). It builds the shared GameRoot (no second loop or clock) with the dressed
## key-frame lagoon, two trevally schools, the sea, sky and water light, and gives every system a switch, a teleport list and
## an issue report. The debug panel (debug_panel.gd) is only a view on this node: everything here runs headless for the test
## (tests/test_test_level.gd), so the cloud checks the same switches Gary flips.
##
## Assets live outside git (assets.lock.json). Default folders, relative to the project (override with the same env vars as
## game_main.gd): res://assets/world/lagoon_base (AO_PIECES), res://assets/world/worldtex (AO_WORLDTEX),
## res://assets/world/lagoon_keyframe (AO_DRESS_PIECES). A missing folder falls back to the stand-in floor and says so.
class_name TestLevel
extends Node

const DEFAULT_PIECES := "res://assets/world/lagoon_base"
const DEFAULT_WORLDTEX := "res://assets/world/worldtex"
const DEFAULT_DRESS := "res://world_dress/lagoon_keyframe.json"
const DEFAULT_DRESS_PIECES := "res://assets/world/lagoon_keyframe"
const SEA_STATES := ["lagoon", "B0", "B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8", "B9", "B10", "B11", "B12"]
const DAY_SPEEDS := {"hold": 0.0, "24 min day": 24.0 / (24.0 * 60.0), "2 min day": 24.0 / 120.0}
const FRAME_HISTORY := 600

var game: GameRoot
var grass: GrassField
var ready_done := false
var missing_assets: Array[String] = []
var teleports: Array = []             # [{name, feet: Vector3, yaw, swim}]
var sea_state := "lagoon"
var day_speed := "hold"
var frame_ms := PackedFloat32Array()  # the last FRAME_HISTORY frame times (ms), oldest first
var mouse_look := Vector2.ZERO        # this tick's mouse look (rad/s), added to the pad's look
var mouse_sensitivity := 0.0025       # rad per pixel
var mouse_captured := false
var _mouse_acc := Vector2.ZERO
var _show_collider := false
var _collider_mesh: MeshInstance3D = null

func _ready() -> void:
	name = "TestLevel"
	var e := func(k: String, d := ""): return OS.get_environment(k) if OS.get_environment(k) != "" else d
	game = GameRoot.new()
	game.pieces_dir = _asset_dir(e.call("AO_PIECES", DEFAULT_PIECES))
	game.worldtex_dir = _asset_dir(e.call("AO_WORLDTEX", DEFAULT_WORLDTEX))
	var dp := _asset_dir(e.call("AO_DRESS_PIECES", DEFAULT_DRESS_PIECES))
	if dp != "": game.dress_manifest = e.call("AO_DRESS", DEFAULT_DRESS); game.dress_pieces = dp
	game.start_hour = float(e.call("AO_HOUR", "12"))
	game.spawn_feet = Vector3(24.0, 1.2, 22.0)      # just behind the key-frame camera (anchor 24, 20), swimming
	for i in 2:
		game.schools.append({"species": "trevally", "home": [Vector3(21.5, 1.8, 12.5), Vector3(28, 2.2, 15)][i], "seed": i + 1})
	game.input_source = _read_input
	add_child(game)
	if game.reader == null:                          # input_source set, so GameRoot made no reader: the level owns one
		game.reader = preload("res://adapters/godot/input_reader.gd").new(); add_child(game.reader)
	await get_tree().physics_frame
	await get_tree().physics_frame
	if game.dress_manifest != "": game.seat_dress()
	# grass 0.1.0: instanced blades in place of the seagrass tile meshes (switch "grass_v2"; off = the tiles as before)
	grass = GrassField.new(); grass.name = "Grass"; add_child(grass)
	grass.girl_fn = func(): return game.girl.centre()
	grass.schools = game.school_nodes
	grass.adopt(game.lagoon)
	if OS.get_environment("AO_GRASS") == "0": grass.set_enabled(false)
	_make_teleports()
	# Retina (screen scale 2): render at half resolution, upscaled. Gary's M1 Pro bench, key-frame view at 2704x1696: 83 ms -> 28 ms;
	# the picture keeps the pixel count of a non-Retina screen of the same size. AO_FULL_RES=1 keeps full resolution.
	if DisplayServer.get_name() != "headless" and DisplayServer.screen_get_scale() >= 1.99 and OS.get_environment("AO_FULL_RES") != "1":
		set_toggle("half_res", true)
	ready_done = true

func _asset_dir(p: String) -> String:
	if DirAccess.dir_exists_absolute(p): return p
	missing_assets.append(p)
	push_warning("TestLevel: asset folder missing: %s (see assets.lock.json; the level runs without it)" % p)
	return ""

# ---- input: the pad and keys through InputReader, plus mouse look while the mouse is captured ----

func _read_input(_t: float):
	var inp = game.reader.read(1.0 / Engine.physics_ticks_per_second)
	var dt := 1.0 / Engine.physics_ticks_per_second
	mouse_look = Vector2(_mouse_acc.x, -_mouse_acc.y) * mouse_sensitivity / dt   # rad/s, the same unit as the stick's look
	_mouse_acc = Vector2.ZERO
	inp.look += mouse_look
	return inp

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_captured:
		_mouse_acc += event.relative
	elif event is InputEventMouseButton and event.pressed and not mouse_captured:
		set_mouse_captured(true)

func set_mouse_captured(on: bool) -> void:
	mouse_captured = on
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE

func _process(delta: float) -> void:
	frame_ms.append(delta * 1000.0)
	if frame_ms.size() > FRAME_HISTORY: frame_ms = frame_ms.slice(frame_ms.size() - FRAME_HISTORY)
	if _collider_mesh != null: _collider_mesh.global_position = game.girl.body.global_position + game.girl.body.col.position

func worst_frame_ms(seconds := 10.0) -> float:
	var acc := 0.0; var worst := 0.0
	for i in range(frame_ms.size() - 1, -1, -1):
		worst = maxf(worst, frame_ms[i]); acc += frame_ms[i] / 1000.0
		if acc >= seconds: break
	return worst

# ---- switches: every one has a getter and a setter, so the test can prove each one returns to where it was ----

func toggle_names() -> Array:
	return ["sdfgi", "god_rays", "caustics", "agx", "taa", "ssao", "cortao", "ssil", "shadows", "half_res", "grass_v2", "schools", "sea", "lagoon", "tide", "collider"]

func get_toggle(n: String) -> bool:
	var wr := game.world_root
	match n:
		"sdfgi": return wr.sdfgi_wanted
		"god_rays": return wr.god_rays
		"caustics": return wr.caustics.enabled
		"agx": return wr.agx_fx.enabled
		"taa": return get_viewport().use_taa
		"ssao": return wr.env.ssao_enabled
		"cortao": return wr.ao_mode == "cortao"
		"ssil": return wr.env.ssil_enabled
		"shadows": return wr.light.shadow_enabled
		"half_res": return get_viewport().scaling_3d_scale < 0.99
		"grass_v2": return grass != null and grass.enabled
		"schools": return game.mounts.is_mounted("fauna")
		"sea": return game.mounts.is_mounted("sea")
		"lagoon": return game.mounts.is_mounted("lagoon")
		"tide": return wr.tide_on
		"collider": return _show_collider
	push_error("TestLevel: unknown toggle " + n); return false

func set_toggle(n: String, on: bool) -> void:
	var wr := game.world_root
	match n:
		"sdfgi": wr.sdfgi_wanted = on; wr.env.sdfgi_enabled = on
		"god_rays": wr.god_rays = on
		"caustics": wr.caustics.enabled = on
		"agx": wr.set_agx(on)
		"taa": get_viewport().use_taa = on
		"ssao": wr.set_ao("ssao" if on else ("off" if wr.ao_mode != "cortao" else "cortao"))
		"cortao": wr.set_ao("cortao" if on else "ssao")   # CORTAO in place of SSAO (ao thread 28 Nov); off = back to SSAO
		"ssil": wr.env.ssil_enabled = on
		"shadows": wr.light.shadow_enabled = on
		"half_res":
			# half the pixels each way, upscaled by AMD FSR 1 (spatial: safe with the AgX and water post effects)
			get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if on else Viewport.SCALING_3D_MODE_BILINEAR
			get_viewport().scaling_3d_scale = 0.5 if on else 1.0
		"grass_v2": if grass: grass.set_enabled(on)
		"schools":
			game.mounts.set_mount("fauna", on)
			for s in game.school_nodes: s.visible = on
		"sea": game.mounts.set_mount("sea", on)
		"lagoon":
			game.mounts.set_mount("lagoon", on)
			if grass: grass.visible = on
		"tide": wr.tide_on = on; game.tide_on = on
		"collider": _set_collider(on)
		_: push_error("TestLevel: unknown toggle " + n); return
	_relight()

func _set_collider(on: bool) -> void:
	_show_collider = on
	if on and _collider_mesh == null:
		_collider_mesh = MeshInstance3D.new(); _collider_mesh.name = "ColliderView"
		var shape: Shape3D = game.girl.body.col.shape
		_collider_mesh.mesh = shape.get_debug_mesh()
		var m := StandardMaterial3D.new(); m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(1, 0.3, 0.2); m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; m.albedo_color.a = 0.6
		_collider_mesh.material_override = m
		add_child(_collider_mesh)
	if _collider_mesh != null: _collider_mesh.visible = on

## The hour of day (0-24) and how fast it runs.
func get_hour() -> float:
	return fposmod(game.clock.hours, 24.0)

func set_hour(h: float) -> void:
	game.clock.set_hours(h)
	_relight()

func set_day_speed(k: String) -> void:
	if not DAY_SPEEDS.has(k): push_error("TestLevel: unknown day speed " + k); return
	day_speed = k
	var h := game.clock.hours
	game.clock.hours_per_second = DAY_SPEEDS[k]
	game.clock.set_hours(h)              # keep the hour where it is when the speed changes

## Sea state: the calm lagoon's own sea, or the open sea's spectrum at Beaufort 0-12 (water surface thread's SeaSpectrum).
## STRESS: force 8+ over a 4 m lagoon puts troughs on the sand; that is the point of the switch, not the real lagoon.
func set_sea_state(s: String) -> void:
	if not s in SEA_STATES: push_error("TestLevel: unknown sea state " + s); return
	sea_state = s
	var p: Dictionary = SeaSpectrum.LAGOON if s == "lagoon" else SeaSpectrum.beaufort(int(s.substr(1)))
	if game.sea != null: game.sea.fft.set_params(p)

func _relight() -> void:
	game._applied_hours = -INF           # GameRoot re-applies sky, light and water on its next world phase

func get_state() -> Dictionary:
	var t := {}
	for n in toggle_names(): t[n] = get_toggle(n)
	return {"toggles": t, "hour": snappedf(get_hour(), 0.001), "day_speed": day_speed, "sea_state": sea_state}

func apply_state(st: Dictionary) -> void:
	for n in st.get("toggles", {}): set_toggle(n, bool(st.toggles[n]))
	if st.has("day_speed"): set_day_speed(st.day_speed)
	if st.has("hour"): set_hour(float(st.hour))
	if st.has("sea_state"): set_sea_state(st.sea_state)

# ---- teleports ----

func _make_teleports() -> void:
	var dress = game._dress
	var kf := func(v: Array, up: float) -> Vector3:
		var w: Vector3 = dress.on_sand(v) if dress != null else Vector3(24.0 + v[0], 0.0, 20.0 - v[1])
		return w + Vector3.UP * up
	var surf: float = game.world_root.water.level
	teleports = [
		{"name": "Start", "feet": game.spawn_feet, "yaw": 0.0, "swim": true},
		{"name": "Key-frame view", "feet": kf.call([0.0, 0.0], 0.6), "yaw": 0.08, "swim": true},
		{"name": "Arch gate", "feet": kf.call([-1.96, 7.0], 0.5), "yaw": 0.0, "swim": true},
		{"name": "Trevally school", "feet": game.schools[0].home + Vector3(0, -0.4, 5.0), "yaw": 0.0, "swim": true},
		{"name": "At the surface", "feet": Vector3(24.0, surf - 0.6, 26.0), "yaw": 0.0, "swim": true},
		{"name": "Snell's window (30 cm under)", "feet": Vector3(24.0, surf - 1.6, 30.0), "yaw": 0.0, "swim": true},
		{"name": "Reef edge", "feet": kf.call([6.0, 18.0], 2.5), "yaw": 0.6, "swim": true},
	]

## Move the girl and the camera to a teleport (no swoop: the camera's springs start fresh there).
func teleport(i: int) -> void:
	var tp: Dictionary = teleports[i]
	var b = game.girl.body
	var s = b.motor.swimmer
	b.global_position = tp.feet
	b.velocity = Vector3.ZERO
	s.vel = Vector3.ZERO
	s.shore_grounded = false
	b.motor.mode = b.motor.Mode.SWIM
	b.started = false                    # the body re-seats its eye and shape on its next tick, as at spawn
	if game.cam != null:
		game.cam.yaw = tp.yaw; game.cam.pitch = -0.1
		game.cam.core = game.cam.core.get_script().new()
	_relight()

## Where the girl is now (for reports and checks).
func where() -> Dictionary:
	var p: Vector3 = game.girl.body.global_position
	var c := {} if game.cam == null else {"pos": _v(game.cam.global_position), "yaw": game.cam.yaw, "pitch": game.cam.pitch, "shot": game.cam.shot}
	return {"feet": _v(p), "mode": game.girl.mode_name(), "water_level": game.world_root.water.level, "camera": c}

static func _v(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]

# ---- the numbers the panel shows (read from Godot's own monitors, so the panel can never disagree with them) ----

func stats() -> Dictionary:
	var P := Performance
	var vp := get_viewport().get_viewport_rid()
	var fps: float = P.get_monitor(P.TIME_FPS)
	return {
		"fps": fps,
		"frame_ms": 1000.0 / maxf(fps, 0.001),
		"worst_10s_ms": worst_frame_ms(10.0),
		"cpu_render_ms": RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu(),
		"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(vp),
		"process_ms": P.get_monitor(P.TIME_PROCESS) * 1000.0,
		"physics_ms": P.get_monitor(P.TIME_PHYSICS_PROCESS) * 1000.0,
		"tick_ms": game.stats.tick_ms,
		"phase_ms": game.stats.phase_ms.duplicate(),
		"draw_calls": P.get_monitor(P.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"triangles": P.get_monitor(P.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"objects": P.get_monitor(P.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"video_mem_mb": P.get_monitor(P.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"static_mem_mb": P.get_monitor(P.MEMORY_STATIC) / 1048576.0,
		"fish": game.school_nodes.reduce(func(a, s): return a + (int(s.sim.N) if s.sim != null else 0), 0),
		"school_main_ms": game.school_nodes.reduce(func(a, s): return a + float(s.main_ms), 0.0),
		"school_step_ms": game.school_nodes.reduce(func(a, s): return maxf(a, float(s.step_ms)), 0.0),
	}

# ---- benchmark (F9 in the panel, or AO_BENCH=1 at start: run_benchmark.command): the cost of each system on this machine ----

const BENCH_SWITCHES := ["sdfgi", "ssao", "cortao", "ssil", "shadows", "god_rays", "caustics", "agx", "grass_v2", "sea", "schools", "lagoon", "half_res"]
var bench_running := false
signal bench_done(path: String)

func _bench_measure(secs: float) -> Dictionary:
	var vp := get_viewport().get_viewport_rid()
	var fr := []; var gpu := []; var cpu := []
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(secs * 1000.0):
		await get_tree().process_frame
		fr.append(frame_ms[frame_ms.size() - 1] if frame_ms.size() > 0 else 0.0)
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp) + RenderingServer.get_frame_setup_time_cpu())
	var mean := func(a: Array) -> float: return a.reduce(func(s, x): return s + x, 0.0) / maxf(a.size(), 1)
	var srt := fr.duplicate(); srt.sort()
	var P := Performance
	return {"frame_ms": snappedf(mean.call(fr), 0.01), "gpu_ms": snappedf(mean.call(gpu), 0.01), "cpu_render_ms": snappedf(mean.call(cpu), 0.01),
		"p95_frame_ms": snappedf(srt[int(srt.size() * 0.95)] if srt.size() > 0 else 0.0, 0.01), "frames": fr.size(),
		"tick_ms": snappedf(game.stats.tick_ms, 0.01), "draw_calls": P.get_monitor(P.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"triangles": P.get_monitor(P.RENDER_TOTAL_PRIMITIVES_IN_FRAME)}

## Stand at the key-frame view; measure everything on, then each system off in turn (back on after), then all of them off.
## Writes playtest_reports/bench_<utc>.json (IssueReport.root_dir) and returns its path.
func run_bench(settle := 2.0, secs := 4.0) -> String:
	if bench_running: return ""
	bench_running = true
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var s0 := get_state()
	teleport(1)
	await get_tree().create_timer(settle * 2.0).timeout
	var rows := []
	var base: Dictionary = await _bench_measure(secs)
	rows.append({"case": "everything on", "r": base})
	for n in BENCH_SWITCHES:
		var on: bool = get_toggle(n)             # flip from the current state (half_res is on by default on Retina screens)
		set_toggle(n, not on)
		await get_tree().create_timer(settle).timeout
		var r: Dictionary = await _bench_measure(secs)
		rows.append({"case": ("%s on" % n) if not on else ("%s off" % n), "r": r, "saves_ms": snappedf(base.frame_ms - r.frame_ms, 0.01),
			"saves_gpu_ms": snappedf(base.gpu_ms - r.gpu_ms, 0.01)})
		set_toggle(n, on)
	for n in BENCH_SWITCHES:
		if not n in ["half_res", "lagoon", "grass_v2", "cortao"]: set_toggle(n, false)
	await get_tree().create_timer(settle).timeout
	rows.append({"case": "all effects off (lagoon kept)", "r": await _bench_measure(secs)})
	apply_state(s0)
	var P := Performance
	var out := {"utc": Time.get_datetime_string_from_system(true), "version": IssueReport._version(),
		"machine": {"os": OS.get_name(), "cpu": OS.get_processor_name(), "gpu": RenderingServer.get_video_adapter_name(),
			"driver": RenderingServer.get_video_adapter_api_version(), "resolution": get_viewport().get_visible_rect().size,
			"screen_scale": DisplayServer.screen_get_scale(), "vsync": DisplayServer.window_get_vsync_mode()},
		"view": "Key-frame view", "rows": rows, "video_mem_mb": P.get_monitor(P.RENDER_VIDEO_MEM_USED) / 1048576.0}
	var dir := IssueReport.root_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("bench_%s.json" % Time.get_datetime_string_from_system(true).replace(":", "-"))
	var f := FileAccess.open(path, FileAccess.WRITE); f.store_string(JSON.stringify(out, "  ")); f.close()
	print("BENCH ", path)
	for r in rows: print("BENCH %-30s frame %7.2f ms  gpu %7.2f ms  saves %s ms" % [r.case, r.r.frame_ms, r.r.gpu_ms, str(r.get("saves_ms", "-"))])
	bench_running = false
	bench_done.emit(path)
	return path
