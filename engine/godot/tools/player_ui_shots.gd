## Player UI shots 0.1.0: pictures of the gamepad layer in the real test level for the plan page and the style choice
## (same camera for every prompt style). The girl is placed beside school 0, the world clock is held so every option is
## the same frame, then the prompt styles, a half-filled hold, and the pause pages are shot.
## Run: VK_ICD_FILENAMES=/opt/lavapipe/lvp_icd.json xvfb-run -a -s "-screen 0 1280x720x24" godot --path . \
##        --rendering-driver vulkan --resolution 1280x720 --script res://tools/player_ui_shots.gd -- <out dir> [warm frames]
extends SceneTree

var out := "/tmp/ui_shots"
var warm := 60

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: warm = int(a[1])
	DirAccess.make_dir_recursive_absolute(out)
	var main = load("res://scenes/test_level.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred(main)

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("SHOT ", name)

func _frames(n: int) -> void:
	for i in n: await process_frame

func _aim(lvl, fish: Vector3) -> void:
	var cam: Camera3D = lvl.game.cam
	var d: Vector3 = (fish - lvl.game.girl.eye_point()).normalized()
	cam.yaw = atan2(-d.x, -d.z); cam.pitch = asin(clampf(d.y, -1.0, 1.0)) * 0.5 - 0.05

func _run(main) -> void:
	var lvl: TestLevel = null
	while lvl == null or not lvl.ready_done or main.get_child_count() < 2:
		await process_frame
		lvl = main.get_child(0) as TestLevel
	var ui: PlayerUI = lvl.ui
	await _frames(warm)
	# swim the girl to 1.6 m from the nearest fish of school 0, looking at it
	var g = lvl.game.girl
	for k in 240:
		var fish: Vector3 = lvl.interact_targets()[0].pos
		var to: Vector3 = fish - g.eye_point()
		if to.length() > 2.2:
			g.body.global_position += to.normalized() * minf(to.length() - 2.2, 0.06)
			g.body.motor.swimmer.pos = g.body.global_position
		_aim(lvl, fish)
		await physics_frame
		if to.length() < 2.3 and not ui.picker.current.is_empty(): break
	lvl.game.clock.paused = true                       # hold the world: every option is the same frame
	await _frames(40)
	ui.reader.family = "playstation"
	for st in ["world", "banner", "glyph"]:
		ui.prompt_style = st
		await _frames(20)
		await _shot("prompt_" + st)
	ui.prompt_style = "world"
	ui.reader.family = "xbox"; await _frames(4); await _shot("prompt_world_xbox")
	ui.reader.family = "keyboard"; await _frames(4); await _shot("prompt_world_keyboard")
	ui.reader.family = "playstation"
	# a hold half way (the ring), then the toast after a sample
	Input.action_press("interact")
	for i in 30: await physics_frame
	await _shot("hold_half")
	for i in 40: await physics_frame
	Input.action_release("interact")
	await _frames(20)
	await _shot("sample_toast")
	# pause pages
	ui.set_paused(true); await _frames(10); await _shot("pause_main")
	ui.show_page("options"); await _frames(6); await _shot("pause_options")
	ui.show_page("controls"); await _frames(6); await _shot("pause_controls_ps")
	ui.reader.family = "xbox"; ui._refresh_controls(); await _frames(4); await _shot("pause_controls_xbox")
	quit()
