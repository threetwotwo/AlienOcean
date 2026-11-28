## Swim shots 0.1.0 (perf runner thread, 28 Nov 2026): the girl swims by herself through the test level's biggest seagrass meadow
## (GrassField's tile with the most blades) and pictures are taken while she is in it and after she leaves, so the grass
## push and its fading trail can be judged without anyone playing. Movement goes through the real input actions
## (Input.action_press "move_forward"), so it is the same path a player's key takes.
## Run: godot --path . --script res://tools/perf_runner/swim_shots.gd -- --out DIR [--speed 0.35] [--pitch -0.45]
##        [--after 2.0] [--height 0.5]
## Output: DIR/swim_01_start.png, swim_02_in_grass.png (half way across), swim_03_leaving.png, swim_04_after_<s>s_looking_back.png, swim_05_later_looking_back.png,
## swim.json (positions, times, frame ms, pushers seen by the grass).
extends SceneTree

var out := ""
var speed := 0.35
var pitch := -0.45
var after_s := 2.0
var height := 0.5
var lvl = null
var log_rows := []

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var i := 0
	while i < a.size():
		var v: String = a[i + 1] if i + 1 < a.size() else ""
		match a[i]:
			"--out": out = v; i += 1
			"--speed": speed = float(v); i += 1
			"--pitch": pitch = float(v); i += 1
			"--after": after_s = float(v); i += 1
			"--height": height = float(v); i += 1
		i += 1
	if out == "": push_error("swim_shots: --out DIR is required"); quit(2); return
	DirAccess.make_dir_recursive_absolute(out)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_RESIZE_DISABLED, true)
	var main = load("res://scenes/test_level.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred(main)

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))
	var p: Vector3 = lvl.game.girl.body.global_position
	log_rows.append({"shot": name, "t_ms": Time.get_ticks_msec(), "feet": [p.x, p.y, p.z], "stats_ms": lvl.stats().frame_ms})
	print("SWIM shot %s at %s" % [name, p])

func _hide(n: Node) -> void:
	if n is CanvasItem: n.visible = false
	for k in n.get_children(): _hide(k)

func _run(main) -> void:
	while lvl == null or not lvl.ready_done:
		await process_frame
		if main.get_child_count() > 0: lvl = main.get_child(0)
	for c in main.get_children():
		if c != lvl and c.has_method("set_open"): c.set_open(false)
		if c != lvl: _hide(c)
	var g = lvl.grass
	if g == null or g.tiles.is_empty(): push_error("swim_shots: no grass tiles"); quit(3); return
	var best = g.tiles[0]
	for t in g.tiles:
		if t.blades > best.blades: best = t
	var box: AABB = best.aabb
	var gx: Transform3D = best.mmi.global_transform
	var c: Vector3 = gx * box.get_center()
	var size: Vector3 = box.size
	# cross the meadow along its longer side, starting 1.5 m outside it
	var along := Vector3(1, 0, 0) if size.x >= size.z else Vector3(0, 0, 1)
	var half := (size.x if size.x >= size.z else size.z) * 0.5
	var start := c - along * (half + 1.5)
	var floor_y: float = gx.origin.y + box.position.y
	start.y = floor_y + height
	var yaw := atan2(-along.x, -along.z)
	lvl.teleports.append({"name": "swim: meadow", "feet": start, "yaw": yaw, "swim": true})
	lvl.teleport(lvl.teleports.size() - 1)
	var cam = lvl.game.cam
	for i in 90:
		cam.yaw = yaw; cam.pitch = pitch; await process_frame
	await _shot("swim_01_start")
	Input.action_press("move_forward", speed)
	var far_end := c + along * (half + 0.5)
	var took_mid := false; var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 60000:
		cam.yaw = yaw; cam.pitch = pitch
		await process_frame
		var p: Vector3 = lvl.game.girl.body.global_position
		var s := (p - c).dot(along)
		if not took_mid and s >= 0.0: took_mid = true; await _shot("swim_02_in_grass")
		if s >= half + 0.5: break
	await _shot("swim_03_leaving")
	Input.action_release("move_forward")
	var t1 := Time.get_ticks_msec()
	var back := wrapf(yaw + PI, -PI, PI)        # look back at the meadow she just crossed (the trail)
	while Time.get_ticks_msec() - t1 < int(after_s * 1000.0):
		cam.yaw = back; cam.pitch = pitch; await process_frame
	await _shot("swim_04_after_%ss_looking_back" % str(after_s))
	for i in 240:                               # and once the trail has had time to fade
		cam.yaw = back; cam.pitch = pitch; await process_frame
	await _shot("swim_05_later_looking_back")
	var f := FileAccess.open(out.path_join("swim.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"meadow_centre": [c.x, c.y, c.z], "meadow_size": [size.x, size.y, size.z], "blades": best.blades,
		"along": [along.x, along.z], "speed": speed, "reached_mid": took_mid, "shots": log_rows}, "  "))
	f.close()
	print("SWIM done -> " + out)
	quit(0)
