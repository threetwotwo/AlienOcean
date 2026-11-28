## Test level shots 0.1.0 (test level thread, 28 Nov 2026): pictures of the test level for its milestone page, through the same
## TestLevel setters Gary uses (and the debug panel open in the first shot).
## Run: xvfb-run -a -s "-screen 0 960x540x24" godot --path . --rendering-driver vulkan --resolution 960x540
##        --script res://tools/test_level_shots.gd -- <out dir> [warm frames, default 90]
extends SceneTree

var out := "/tmp"
var warm := 90
const SHOTS := [
	{"name": "01_panel_noon", "tp": 1, "hour": 12.0, "sea": "lagoon", "panel": true},
	{"name": "02_gate_noon", "tp": 2, "hour": 12.0, "sea": "lagoon"},
	{"name": "03_dusk", "tp": 1, "hour": 18.2, "sea": "lagoon"},
	{"name": "04_force12_surface", "tp": 4, "hour": 12.0, "sea": "B12", "pitch": 0.05},
	{"name": "05_snell_window", "tp": 5, "hour": 12.0, "sea": "B3", "pitch": 1.2},
	{"name": "06_night", "tp": 1, "hour": 23.0, "sea": "lagoon"},
	{"name": "07_feet", "tp": 1, "hour": 12.0, "sea": "lagoon", "feet": true},   # close camera on the girl's feet and the sand (AO checks)
]

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: warm = int(a[1])
	DirAccess.make_dir_recursive_absolute(out)
	var main = load("res://scenes/test_level.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred(main)

func _run(main) -> void:
	var lvl: TestLevel = null
	while lvl == null or not lvl.ready_done or main.get_child_count() < 2:
		await process_frame
		lvl = main.get_child(0) as TestLevel
	var panel = main.get_child(1)
	# AO_AO=ssao|cortao|off: the screen AO source through the level's own switches; AO_SHOTS=07 (prefixes) picks shots
	var aom := OS.get_environment("AO_AO")
	if aom in ["cortao", "gtao", "vbao"]: lvl.set_toggle(aom, true)
	elif aom == "off": lvl.set_toggle("ssao", false)
	if OS.get_environment("AO_CORTAO_LIGHT") != "": lvl.game.world_root.cortao_fx.light_weighted = OS.get_environment("AO_CORTAO_LIGHT") == "1"   # occlusion weighted by the water light per direction
	var pick := OS.get_environment("AO_SHOTS")
	var feet_cam := Camera3D.new(); root.add_child(feet_cam)
	for s in SHOTS:
		if pick != "" and not s.name.substr(0, 2) in pick.split(","): continue
		lvl.set_sea_state(s.sea); lvl.set_hour(s.hour); lvl.teleport(s.tp)
		panel.set_open(s.get("panel", false))
		for i in warm:
			if s.has("pitch") and lvl.game.cam != null: lvl.game.cam.pitch = s.pitch
			await process_frame
		if s.get("feet", false):
			var b: Vector3 = lvl.game.girl.body.global_position
			var gc: Camera3D = lvl.game.cam
			feet_cam.attributes = gc.attributes; feet_cam.environment = gc.environment; feet_cam.compositor = gc.compositor
			feet_cam.near = gc.near; feet_cam.far = gc.far
			var fl := b + Vector3(0, -0.9, 0)   # about her feet (body origin ~ hips)
			feet_cam.fov = 45.0; feet_cam.global_position = fl + Vector3(1.6, 0.5, 1.9); feet_cam.look_at(fl + Vector3(0, -0.3, 0)); feet_cam.current = true
			print("FEET girl ", b, " cam ", feet_cam.global_position)
			for i in 20: await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_png(out.path_join(s.name + ".png"))
		var st := lvl.stats()
		if s.get("feet", false) and lvl.game.cam != null: lvl.game.cam.current = true
		print("SHOT %s  frame %.1f ms  tris %d  draws %d" % [s.name, st.frame_ms, st.triangles, st.draw_calls])
	quit(0)
