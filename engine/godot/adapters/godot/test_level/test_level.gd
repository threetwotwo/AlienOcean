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
var ui: PlayerUI                      # gamepad layer: pause menu, interact prompt, rumble (adapters/godot/ui/player_ui.gd)
var samples := {}                     # school id -> DNA samples taken (the slice's interact)

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
	grass.girl_capsule_fn = func(): return [game.girl.capsule.centre, game.girl.capsule.axis, game.girl.capsule.half_len] if not game.girl.pose.is_empty() else [game.girl.centre(), Vector3.UP, 0.3]
	grass.schools = game.school_nodes
	grass.adopt(game.lagoon)
	if OS.get_environment("AO_GRASS") == "0": grass.set_enabled(false)
	_make_teleports()
	# player UI 0.1.0: pause (Options / Esc), interact (Square / X / E, hold to sample a fish), rumble, remap
	ui = PlayerUI.new(); ui.name = "PlayerUI"; ui.game = game; ui.reader = game.reader
	ui.targets_fn = interact_targets
	ui.on_pause = func(on): if on: set_mouse_captured(false)
	ui.interacted.connect(_on_interact)
	add_child(ui)
	# Full screen by default (Gary 28 Nov: "make it fullscreen, for a more accurate reading and look"), so benches and the look
	# are judged at the real screen size. AO_WINDOWED=1, or an explicit --resolution (cloud shots, the perf runner's window
	# profile), keeps a window.
	if DisplayServer.get_name() != "headless":
		# project.godot opens full screen at window creation (macOS can ignore a switch made after load); a window only on request
		var want_window := OS.get_environment("AO_WINDOWED") == "1" or "--resolution" in OS.get_cmdline_args() or "--windowed" in OS.get_cmdline_args()
		if want_window: DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		else: _hold_fullscreen()
	# Retina (screen scale 2): render at half resolution, upscaled. Gary's M1 Pro bench, key-frame view at 2704x1696: 83 ms -> 28 ms;
	# the picture keeps the pixel count of a non-Retina screen of the same size. AO_FULL_RES=1 keeps full resolution.
	if DisplayServer.get_name() != "headless" and DisplayServer.screen_get_scale() >= 1.99 and OS.get_environment("AO_FULL_RES") != "1":
		set_toggle("half_res", true)
	ready_done = true

## What the girl can act on now: the nearest fish of each school (hold to take a DNA sample). One id per school, so the
## prompt stays on the school while the nearest fish changes inside it.
func interact_targets() -> Array:
	var out := []
	var eye: Vector3 = game.girl.eye_point()
	for i in game.school_nodes.size():
		var sn = game.school_nodes[i]
		var best := Vector3.ZERO
		var bd := INF
		for p in sn._cur:
			var d: float = p.distance_squared_to(eye)
			if d < bd: bd = d; best = p
		if bd < INF:
			out.append({"id": "school:%d" % i, "pos": best, "verb": "Sample DNA", "range": 3.0, "hold": 0.8})
	return out

func _on_interact(id: String) -> void:
	samples[id] = samples.get(id, 0) + 1
	ui.toast("Trevally sample logged  (%d from this school)" % samples[id])

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

var _last_us := 0
func _process(_delta: float) -> void:
	# clock time between frames: _process delta is smoothed and snaps to the display refresh step (read 6.94 ms on a 144 Hz
	# Mac for every bench row while real frames took 8-13 ms)
	var now := Time.get_ticks_usec()
	if _last_us > 0: frame_ms.append((now - _last_us) / 1000.0)
	_last_us = now
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
	return ["sdfgi", "god_rays", "caustics", "agx", "taa", "ssao", "cortao", "gtao", "vbao", "ssil", "shadows", "half_res", "grass_v2", "schools", "sea", "lagoon", "tide", "collider", "bubbles"]

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
		"gtao": return wr.ao_mode == "gtao"
		"vbao": return wr.ao_mode == "vbao"
		"ssil": return wr.env.ssil_enabled
		"shadows": return wr.light.shadow_enabled
		"half_res": return get_viewport().scaling_3d_scale < 0.99
		"grass_v2": return grass != null and grass.enabled
		"schools": return game.mounts.is_mounted("fauna")
		"sea": return game.mounts.is_mounted("sea")
		"lagoon": return game.mounts.is_mounted("lagoon")
		"tide": return wr.tide_on
		"collider": return _show_collider
		"bubbles": return game.bubbles != null and game.bubbles.visible
	push_error("TestLevel: unknown toggle " + n); return false

func set_toggle(n: String, on: bool) -> void:
	var wr := game.world_root
	match n:
		"sdfgi": wr.sdfgi_wanted = on; wr.env.sdfgi_enabled = on
		"god_rays": wr.god_rays = on
		"caustics": wr.caustics.enabled = on
		"agx": wr.set_agx(on)
		"taa": get_viewport().use_taa = on
		"ssao", "cortao", "gtao", "vbao": _set_ao_toggle(wr, n, on)
		"ssil": wr.env.ssil_enabled = on
		"shadows": wr.light.shadow_enabled = on
		"half_res":
			# half the pixels each way, upscaled (upscaler(): AMD FSR 1 + Godot TAA by default; AO_UPSCALER picks another).
			# A spatial upscaler brings TAA with it, so thin edges (grass) stay anti-aliased.
			var m := upscaler()
			get_viewport().scaling_3d_mode = m if on else Viewport.SCALING_3D_MODE_BILINEAR
			get_viewport().scaling_3d_scale = 0.5 if on else 1.0
			if on and needs_taa(m): get_viewport().use_taa = true
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
		"bubbles": if game.bubbles: game.bubbles.visible = on     # the draw (its births cost 0.03 ms CPU and keep running)
		_: push_error("TestLevel: unknown toggle " + n); return
	_relight()

## The upscaler behind half_res. AO_UPSCALER = fsr | fsr2 | metalfx | metalfx_temporal picks one; by default AMD FSR 2, a temporal
## upscaler that does its own anti-aliasing (TAA stays off); now FSR 1 + Godot TAA, the best look per ms on the Mac (below). FSR 1 was the default (8.8 ms vs MetalFX temporal 11.5 ms on the M1 Pro),
## but it is spatial, with no anti-aliasing: Gary's fullscreen playtest (28 Nov) showed stair-stepped grass, pixelation and shimmer.
## At 2704x1756 FSR 2 draws the grass clean where FSR 1 aliases (look thread, plans/godot_look/iq_28nov.jpg); Gary approved the cost.
static func upscaler() -> int:
	var rd := RenderingServer.get_rendering_device()
	var mfx_t := rd != null and rd.has_feature(RenderingDevice.SUPPORTS_METALFX_TEMPORAL)
	var mfx_s := rd != null and rd.has_feature(RenderingDevice.SUPPORTS_METALFX_SPATIAL)
	match OS.get_environment("AO_UPSCALER"):
		"fsr": return Viewport.SCALING_3D_MODE_FSR
		"fsr2": return Viewport.SCALING_3D_MODE_FSR2
		"metalfx": return Viewport.SCALING_3D_MODE_METALFX_SPATIAL if mfx_s else Viewport.SCALING_3D_MODE_FSR
		"metalfx_temporal": return Viewport.SCALING_3D_MODE_METALFX_TEMPORAL if mfx_t else Viewport.SCALING_3D_MODE_FSR
	# default FSR 1 + Godot TAA (needs_taa). Mac matrix 28 Nov, 2704x1696 all on, key-frame / floor ms: FSR 1 + TAA 31.7 / 31.1 (soft,
	# no stair-steps), MetalFX temporal 37.6 / 37.6 (as soft), FSR 2 42.6 / 37.2 (crispest, grainy grass), FSR 1 alone 28.5 / 35.1
	# (jagged). Best look per ms.
	return Viewport.SCALING_3D_MODE_FSR

static func needs_taa(mode: int) -> bool:
	## a spatial upscaler does no anti-aliasing of its own: TAA goes with it
	return mode == Viewport.SCALING_3D_MODE_FSR or mode == Viewport.SCALING_3D_MODE_METALFX_SPATIAL or mode == Viewport.SCALING_3D_MODE_BILINEAR

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
	_add_reef_teleports(surf)

## The reef drop-off's stress sectors (core/world/bathymetry.gd, water surface thread's spots): per sector one view from the crest
## out over the drop, and one hanging in the water at 10 m facing the wall; plus the sand pass at 3 m. Only with the reef drawn.
func _add_reef_teleports(surf: float) -> void:
	if not game.reef_on or game.world_root.lagoon_radius <= 0.0 or game.pieces_dir == "": return
	var b: Bathymetry = game.world_root.bathymetry()
	var face := func(d: Vector2) -> float: return atan2(-d.x, -d.y)   # yaw that looks along d (forward = (-sin yaw, -cos yaw))
	for k in Bathymetry.SECTOR_WALL_M.size():
		var th := b.sector_mid(k)
		var out := Vector2(cos(th), sin(th))
		var nm: String = Bathymetry.SECTOR_NAMES[k]
		var c := b.at(th, 27.0)                                        # just past the crest, over the reef flat (1.2 m deep)
		teleports.append({"name": "Reef %d %s: crest" % [k, nm], "feet": Vector3(c.x, surf - 0.7, c.y), "yaw": face.call(out), "swim": true})
		var w := b.at(th, 27.0 + b.wall_m(th) * 0.5 + 25.0)           # off the wall, in open water
		teleports.append({"name": "Reef %d %s: wall at 10 m" % [k, nm], "feet": Vector3(w.x, surf - 10.0, w.y), "yaw": face.call(-out), "swim": true})
	var tp := b.sector_mid(Bathymetry.PASS_SECTOR)
	var p := b.at(tp, 7.0)
	teleports.append({"name": "Reef pass at 3 m", "feet": Vector3(p.x, surf - 3.0, p.y), "yaw": face.call(Vector2(cos(tp), sin(tp))), "swim": true})

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

const BENCH_SWITCHES := ["ssao", "cortao", "ssil", "shadows", "god_rays", "caustics", "agx", "grass_v2", "sea", "schools", "lagoon", "half_res", "sdfgi"]   # sdfgi last: it rebuilds for seconds after it comes back
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
	# median frame time: a toggle's first frames compile pipelines and spike; the median ignores them, the mean did not
	return {"frame_ms": snappedf(srt[srt.size() / 2] if srt.size() > 0 else 0.0, 0.01), "mean_frame_ms": snappedf(mean.call(fr), 0.01), "gpu_ms": snappedf(mean.call(gpu), 0.01), "cpu_render_ms": snappedf(mean.call(cpu), 0.01),
		"p95_frame_ms": snappedf(srt[int(srt.size() * 0.95)] if srt.size() > 0 else 0.0, 0.01), "frames": fr.size(),
		"tick_ms": snappedf(game.stats.tick_ms, 0.01), "draw_calls": P.get_monitor(P.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"triangles": P.get_monitor(P.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"cortao_gpu_ms": snappedf(game.world_root.cortao_fx.gpu_ms, 0.001) if game.world_root.ao_mode in ["cortao", "gtao", "vbao"] else 0.0}

func _bench_floor(secs: float) -> Dictionary:
	## as _bench_measure, holding the camera on the floor while it measures
	var done := false
	var hold := func():
		while not done:
			if game.cam: game.cam.pitch = -1.15
			await get_tree().process_frame
	hold.call()
	var r: Dictionary = await _bench_measure(secs)
	done = true
	return r

## Stand at the key-frame view; measure everything on, then each system off in turn (back on after), then all of them off.
## Writes playtest_reports/bench_<utc>.json (IssueReport.root_dir) and returns its path.
## A bench run is invalid when the GPU hung (Godot 4.7 on Metal logs "timeout waiting for fence"; afterwards every frame
## reads a flat ~6.9-7.3 ms) or when every row's frame time sits within +-0.2 ms (no switch changed anything = not measuring).
func _bench_invalid(rows: Array) -> String:
	var lo := INF; var hi := -INF
	for r in rows:
		var fm: float = r.r.frame_ms
		lo = minf(lo, fm); hi = maxf(hi, fm)
	if rows.size() > 3 and hi - lo <= 0.4: return "flat frame times (%.2f-%.2f ms across all rows)" % [lo, hi]
	var logp := "user://logs/godot.log"
	if FileAccess.file_exists(logp):
		var t := FileAccess.get_file_as_string(logp)
		if "timeout waiting for fence" in t: return "GPU hang in this session's log (timeout waiting for fence)"
	return ""

func run_bench(settle := 2.0, secs := 4.0) -> String:
	if bench_running: return ""
	bench_running = true
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var s0 := get_state()
	# a fair run (Mac thread, 28 Nov): no vsync (it rounds frame times to 16.7 ms steps), and a window that can't change size
	# mid-run (macOS resized it to the full Retina size once, which made a whole run invalid)
	var vs0 := DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# full screen (the default) must have taken before the size is read; a full-screen window is never locked or resized (on
	# macOS that can drop it out of full screen, which left small windows on 28 Nov); only a requested window is locked
	var tw := Time.get_ticks_msec() + 10000
	while not fullscreen_ok and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED and Time.get_ticks_msec() < tw:
		await get_tree().process_frame
	var lock_win := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED
	var win0 := DisplayServer.window_get_size()
	if lock_win: DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_RESIZE_DISABLED, true)
	await get_tree().process_frame
	if lock_win and DisplayServer.window_get_size() != win0: DisplayServer.window_set_size(win0)
	teleport(1)
	await get_tree().create_timer(settle * 2.0).timeout
	var rows := []
	# warm-up: flip every switch once so each pipeline is compiled before anything is timed (compiles read as negative savings)
	for n in BENCH_SWITCHES:
		if n == "sdfgi": continue
		var w: bool = get_toggle(n)
		set_toggle(n, not w); await get_tree().create_timer(0.5).timeout
		set_toggle(n, w); await get_tree().create_timer(0.5).timeout
	await get_tree().create_timer(settle).timeout
	var base: Dictionary = await _bench_measure(secs)
	rows.append({"case": "everything on", "r": base})
	# each switch is measured as a pair (its normal state, then flipped) so slow drift (heat, GI settling) cancels out
	for n in BENCH_SWITCHES:
		var on: bool = get_toggle(n)             # flip from the current state (half_res is on by default on Retina screens)
		var a: Dictionary = await _bench_measure(secs * 0.5)
		set_toggle(n, not on)
		await get_tree().create_timer(settle).timeout
		var r: Dictionary = await _bench_measure(secs)
		set_toggle(n, on)
		await get_tree().create_timer(settle * (3.0 if n == "sdfgi" else 1.0)).timeout
		# A-B-A: the baseline is measured before and after the flip, so a restore cost cannot leak into the next row
		var a2: Dictionary = await _bench_measure(secs * 0.5)
		var am: float = (float(a.frame_ms) + float(a2.frame_ms)) * 0.5
		rows.append({"case": ("%s on" % n) if not on else ("%s off" % n), "r": r, "paired_ms": snappedf(am, 0.01),
			"aba_spread_ms": snappedf(absf(a.frame_ms - a2.frame_ms), 0.01),
			"saves_ms": snappedf(am - r.frame_ms, 0.01), "saves_gpu_ms": snappedf((a.gpu_ms + a2.gpu_ms) * 0.5 - r.gpu_ms, 0.01)})
		if DisplayServer.window_get_size() != win0:
			rows[-1]["window_changed"] = true
			# macOS can change the content size when the resize flag flips (title bar re-layout): put a window back before the next row
			if lock_win:
				DisplayServer.window_set_size(win0)
				await get_tree().create_timer(settle).timeout
	for n in BENCH_SWITCHES:
		if not n in ["half_res", "lagoon", "grass_v2", "cortao", "gtao", "vbao"]: set_toggle(n, false)
	await get_tree().create_timer(settle).timeout
	rows.append({"case": "all effects off (lagoon kept)", "r": await _bench_measure(secs)})
	apply_state(s0)
	# the floor view (Gary: slowest when looking at the floor): everything on, then the lagoon (floor material) off
	teleport(1)
	await get_tree().create_timer(settle).timeout
	var fl: Array = []
	for k in 2:
		if k == 1: set_toggle("lagoon", false)
		var tend := Time.get_ticks_msec() + int(settle * 1000.0)
		while Time.get_ticks_msec() < tend:
			if game.cam: game.cam.pitch = -1.15
			await get_tree().process_frame
		var r: Dictionary = await _bench_floor(secs)
		fl.append(r)
	set_toggle("lagoon", true)
	rows.append({"case": "floor view, everything on", "r": fl[0]})
	rows.append({"case": "floor view, lagoon off", "r": fl[1], "saves_ms": snappedf(fl[0].frame_ms - fl[1].frame_ms, 0.01)})
	apply_state(s0)
	DisplayServer.window_set_vsync_mode(vs0)
	if lock_win: DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_RESIZE_DISABLED, false)
	var P := Performance
	var out := {"utc": Time.get_datetime_string_from_system(true), "version": IssueReport._version(),
		"machine": {"os": OS.get_name(), "cpu": OS.get_processor_name(), "gpu": RenderingServer.get_video_adapter_name(),
			"driver": RenderingServer.get_video_adapter_api_version(), "resolution": get_viewport().get_visible_rect().size,
			"screen_scale": DisplayServer.screen_get_scale(), "vsync_during_run": "off", "window": win0, "fullscreen": not lock_win, "screen": DisplayServer.screen_get_size(),
			"render_scale": get_viewport().scaling_3d_scale, "upscaler": get_viewport().scaling_3d_mode},
		"view": "Key-frame view", "rows": rows, "video_mem_mb": P.get_monitor(P.RENDER_VIDEO_MEM_USED) / 1048576.0}
	var inval := _bench_invalid(rows)
	out["valid"] = inval.is_empty()
	if not inval.is_empty(): out["invalid_reason"] = inval; print("BENCH INVALID: ", inval)
	var dir := IssueReport.root_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("bench_%s.json" % Time.get_datetime_string_from_system(true).replace(":", "-"))
	var f := FileAccess.open(path, FileAccess.WRITE); f.store_string(JSON.stringify(out, "  ")); f.close()
	print("BENCH ", path)
	for r in rows: print("BENCH %-30s frame %7.2f ms  gpu %7.2f ms  saves %s ms" % [r.case, r.r.frame_ms, r.r.gpu_ms, str(r.get("saves_ms", "-"))])
	bench_running = false
	bench_done.emit(path)
	return path

var _ao_prev := "off"
func _set_ao_toggle(wr: WorldRoot, mode: String, on: bool) -> void:
	## the AO switches are one choice (ssao / cortao (default) / gtao / vbao): on = that one, off = back to the one before it
	if on:
		if wr.ao_mode != mode: _ao_prev = wr.ao_mode
		wr.set_ao(mode)
	elif wr.ao_mode == mode:
		wr.set_ao(_ao_prev if _ao_prev != mode else "off")


## Keep asking for full screen until macOS has actually done it (Mac thread, 28 Nov). A request made while another full-screen
## space is still closing (a Godot that just quit full screen) or during load is dropped silently, which left small windows.
## Tries every 0.5 s for 10 s; fullscreen_ok says whether it took.
var fullscreen_ok := false
func _hold_fullscreen() -> void:
	var t_end := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < t_end:
		if DisplayServer.window_get_mode() >= DisplayServer.WINDOW_MODE_FULLSCREEN and DisplayServer.window_get_size().x >= DisplayServer.screen_get_usable_rect().size.x:
			fullscreen_ok = true
			return
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		await get_tree().create_timer(0.5).timeout
	push_warning("TestLevel: full screen did not take (window %s)" % DisplayServer.window_get_size())
