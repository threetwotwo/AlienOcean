## LOD probe 0.1.0 (test level thread): triangles and draw calls the test level draws at a few views, for the A/B between
## full-detail GLBs (AO_GLB_LODS=0) and GlbLoader LODs.
## Run: xvfb-run -a godot --path . --resolution 960x540 --script res://tools/lod_probe.gd -- <out.json>
extends SceneTree

const VIEWS := [{"name": "key-frame", "tp": 1, "pitch": null}, {"name": "floor", "tp": 1, "pitch": -1.1}]

func _initialize() -> void:
	var main = load("res://scenes/test_level.tscn").instantiate(); root.add_child(main)
	_run.call_deferred(main)

func _run(main) -> void:
	var lvl: TestLevel = null
	while lvl == null or not lvl.ready_done:
		await process_frame
		lvl = main.get_child(0) as TestLevel
	var rows := []
	for v in VIEWS:
		lvl.teleport(v.tp)
		for i in 6:
			if v.pitch != null and lvl.game.cam != null: lvl.game.cam.pitch = v.pitch
			await process_frame
		await RenderingServer.frame_post_draw
		rows.append({"view": v.name, "tris": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			"objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)})
		print("LODPROBE ", JSON.stringify(rows[-1]))
	# what the key-frame view's triangles are made of: each switch off on its own
	lvl.teleport(1)
	for sw in ["sea", "schools", "shadows", "grass_v2", "lagoon", "sdfgi"]:
		lvl.set_toggle(sw, not lvl.get_toggle(sw))
		for i in 4: await process_frame
		await RenderingServer.frame_post_draw
		rows.append({"view": "key-frame, %s flipped" % sw, "tris": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)})
		print("LODPROBE ", JSON.stringify(rows[-1]))
		lvl.set_toggle(sw, not lvl.get_toggle(sw))
	var a := OS.get_cmdline_user_args()
	var res := {"lods": GlbLoader.lods, "glb": GlbLoader.stats, "rows": rows}
	if a.size() > 0:
		var f := FileAccess.open(a[0], FileAccess.WRITE); f.store_string(JSON.stringify(res, " ")); f.close()
	quit()
