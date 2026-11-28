## Grass shots 0.1.0 (test level thread): the seagrass before (tile meshes) and after (GrassField blades) from the same views,
## plus a push check: a low view inside a meadow with the girl in it, rendered with her push on and off.
## Run: xvfb-run -a godot --path . --resolution 960x540 --script res://tools/grass_shots.gd -- <out dir> [warm frames]
extends SceneTree

var out := "/tmp"
var warm := 40

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: warm = int(a[1])
	DirAccess.make_dir_recursive_absolute(out)
	var lvl := TestLevel.new(); root.add_child(lvl)
	_run.call_deferred(lvl)

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("GRASSSHOT ", name, " tris ", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))

func _run(lvl: TestLevel) -> void:
	while not lvl.ready_done: await process_frame
	var g := lvl.grass
	print("GRASS stats ", g.stats)
	# the biggest meadow: park the girl at its edge looking in
	var best = null
	for t in g.tiles:
		if best == null or t.blades > best.blades: best = t
	var c: Vector3 = (best.aabb as AABB).get_center()
	# low view inside the meadow like Gary's Mac shot (camera near the sand, the girl lying in the grass), push on and off
	var views := [{"name": "keyframe", "tp": 1}, {"name": "meadow", "feet": c + Vector3(0, 0.3, 1.6), "yaw": 0.0, "pitch": -0.35},
		{"name": "low", "feet": c + Vector3(0, 0.25, 0.6), "yaw": 0.0, "pitch": -0.12, "push": true}]
	var girl_fn = g.girl_fn; var cap_fn = g.girl_capsule_fn
	for v in views:
		var modes := ([true] if OS.get_environment("AO_GRASS_ONLY") == "1" else [false, true])
		if v.get("push", false): modes = ["push", "nopush"]
		for on in modes:
			lvl.set_toggle("grass_v2", on is String or on)
			g.girl_fn = null if on is String and on == "nopush" else girl_fn
			g.girl_capsule_fn = null if on is String and on == "nopush" else cap_fn
			if on is String and on == "nopush": g._trail.clear()
			if v.has("tp"): lvl.teleport(v.tp)
			else:
				lvl.teleports.append({"name": "meadow", "feet": v.feet, "yaw": v.yaw, "swim": true}); lvl.teleport(lvl.teleports.size() - 1)
				lvl.teleports.pop_back()
			for i in warm:
				if v.has("pitch") and lvl.game.cam: lvl.game.cam.pitch = v.pitch
				await process_frame
			var tag: String = on if on is String else ("blades" if on else "tiles")
			await _shot("%s_%s" % [v.name, tag])
	print("GRASS stats after ", g.stats)
	quit()
