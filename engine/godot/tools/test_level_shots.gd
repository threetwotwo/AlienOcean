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
	for s in SHOTS:
		lvl.set_sea_state(s.sea); lvl.set_hour(s.hour); lvl.teleport(s.tp)
		panel.set_open(s.get("panel", false))
		for i in warm:
			if s.has("pitch") and lvl.game.cam != null: lvl.game.cam.pitch = s.pitch
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_png(out.path_join(s.name + ".png"))
		var st := lvl.stats()
		print("SHOT %s  frame %.1f ms  tris %d  draws %d" % [s.name, st.frame_ms, st.triangles, st.draw_calls])
	quit(0)
