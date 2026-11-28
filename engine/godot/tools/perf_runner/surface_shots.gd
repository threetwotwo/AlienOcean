## Surface shots 0.1.0 (perf runner thread, 28 Nov 2026): the girl swims up and breaches by herself (real "ascend" + "move_forward"
## input), and pictures are taken on the way up, in the air, after she lands back in, treading at the surface, and from just under
## it looking up, so the breach and the camera at the water line can be checked without anyone playing.
## Run: godot --path . --script res://tools/perf_runner/surface_shots.gd -- --out DIR [--depth 1.6]
## Output: DIR/surf_*.png and surface.json (feet, mode, camera height minus water level at each shot).
extends SceneTree

var out := ""
var depth := 1.6
var lvl = null
var rows := []

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		if a[i] == "--out" and i + 1 < a.size(): out = a[i + 1]
		if a[i] == "--depth" and i + 1 < a.size(): depth = float(a[i + 1])
	if out == "": push_error("surface_shots: --out DIR is required"); quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	var main = load("res://scenes/test_level.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred(main)

func _hide(n: Node) -> void:
	if n is CanvasItem: n.visible = false
	for k in n.get_children(): _hide(k)

func _shot(name: String) -> void:
	await process_frame; await process_frame          # (frame_post_draw can stall while the window is behind others on macOS)
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))
	var w: Dictionary = lvl.where()
	var lens_y: float = lvl.game.cam.global_position.y
	rows.append({"shot": name, "feet": w.feet, "mode": w.mode, "water_level": w.water_level, "lens_above_water_m": lens_y - w.water_level})
	print("SURF %s mode %s feet %s lens-water %.2f m" % [name, w.mode, w.feet, lens_y - w.water_level])

func _frames(n: int, yaw: float, pitch: float) -> void:
	for i in n:
		lvl.game.cam.yaw = yaw; lvl.game.cam.pitch = pitch
		await process_frame

func _run(main) -> void:
	while lvl == null or not lvl.ready_done:
		await process_frame
		if main.get_child_count() > 0: lvl = main.get_child(0)
	for c in main.get_children():
		if c != lvl: _hide(c)
	var surf: float = lvl.game.world_root.water.level
	lvl.teleports.append({"name": "surface: under", "feet": Vector3(24.0, surf - depth, 30.0), "yaw": 0.0, "swim": true})
	lvl.teleport(lvl.teleports.size() - 1)
	await _frames(90, 0.0, -0.1)
	await _shot("surf_01_under_level")
	await _frames(30, 0.0, 1.0)
	await _shot("surf_02_under_looking_up")
	# swim up and breach: ascend + forward, pitched up
	Input.action_press("ascend"); Input.action_press("move_forward", 1.0)
	var t0 := Time.get_ticks_msec(); var air := false; var peak := -INF
	while Time.get_ticks_msec() - t0 < 6000:
		await _frames(1, 0.0, 0.5)
		var w: Dictionary = lvl.where()
		peak = maxf(peak, float(w.feet[1]))
		if not air and float(w.feet[1]) > surf + 0.2: air = true; await _shot("surf_03_breach_in_air")
		if air and float(w.feet[1]) < surf - 0.3: break
	Input.action_release("ascend"); Input.action_release("move_forward")
	await _shot("surf_04_back_in")
	await _frames(120, 0.0, -0.1)
	await _shot("surf_05_settled")
	Input.action_press("ascend")
	await _frames(150, 0.0, 0.05)
	await _shot("surf_06_treading_at_surface")
	Input.action_release("ascend")
	await _frames(30, 0.0, -0.4)
	await _shot("surf_07_treading_look_down")
	var f := FileAccess.open(out.path_join("surface.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"water_level": surf, "breached": air, "peak_feet_y": peak, "shots": rows}, "  "))
	f.close()
	print("SURF done breached=%s peak feet %.2f m (water %.2f)" % [air, peak, surf])
	quit(0)
