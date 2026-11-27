## Game film 0.1.0 (game root thread, 27 Nov 2026): films the whole game running together through the game's own camera:
## GameRoot with the lagoon pieces, the authored key-frame place, the drawn sea and tide, the girl (motor + body rig +
## mannequin) swimming a scripted line, and fish schools fed by the actor registry. Writes f%04d.png + frames.json
## (tick, mode, girl, per-phase ms, school sees-player).
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --fixed-fps 15 --script res://tools/game_film.gd -- \
##        <pieces_dir> <worldtex_dir> <dress_pieces_dir> <out_dir> [seconds] [w h]
## Env: AO_HOUR (default 10.5), AO_FILM_EVERY (save every n-th frame, default 1).
extends SceneTree

const Packet := preload("res://core/m01_input/input_packet.gd")

var g: GameRoot
var out := ""
var dur := 20.0
var n := 0
var frame := 0
var log := []
var every := 1
var heading := 0.0

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	out = a[3]; DirAccess.make_dir_recursive_absolute(out)
	if a.size() > 4: dur = float(a[4])
	var w := int(a[5]) if a.size() > 5 else 960
	var h := int(a[6]) if a.size() > 6 else 540
	root.size = Vector2i(w, h)
	every = int(OS.get_environment("AO_FILM_EVERY")) if OS.get_environment("AO_FILM_EVERY") != "" else 1
	Engine.physics_ticks_per_second = 60
	Engine.max_physics_steps_per_frame = 8
	# the place's frame, to put the girl and the school where the key frame had them
	var manifest := "res://world_dress/lagoon_keyframe.json"
	var dc := DressCell.new(); dc.setup(manifest, a[2])
	var lane_a := dc.to_world([0.5, -1.5, 1.0]); var lane_b := dc.to_world([-5.2, 7.4, 1.0])
	var d := (lane_b - lane_a); d.y = 0.0; d = d.normalized()
	heading = atan2(-d.x, -d.z)
	g = GameRoot.new()
	g.pieces_dir = a[0]; g.worldtex_dir = a[1]; g.dress_manifest = manifest; g.dress_pieces = a[2]
	g.start_hour = float(OS.get_environment("AO_HOUR")) if OS.get_environment("AO_HOUR") != "" else 10.5
	g.spawn_feet = lane_a + Vector3(0, -0.2, 0)
	g.schools = [{"species": "trevally", "home": dc.to_world([-1.4, 4.2, 1.6]), "seed": 3},
		{"species": "trevally", "home": dc.to_world([-4.0, 9.5, 2.2]), "seed": 5}]
	dc.free()
	g.input_source = _input
	root.add_child.call_deferred(g)
	g.ready.connect(_on_ready)

func _on_ready() -> void:
	g.cam.yaw = heading; g.cam.pitch = -0.12
	await physics_frame; await physics_frame
	print("DRESS ", g.seat_dress())
	g.ticked.connect(_tick)

func _input(t: float):
	var k = Packet.new()
	# swim the lane slowly, ease to a hover by the school, look around it, then on toward the gate
	if t < 7.0: k.move = Vector2(0, 0.55)
	elif t < 12.0: k.move = Vector2(0, 0.12); k.look = Vector2(0.28, 0.02)
	else: k.move = Vector2(0.1, 0.6); k.look = Vector2(-0.22, 0.0)
	k.ascend = t > 2.0 and t < 2.6
	return k

func _tick(_tick_n: int) -> void:
	pass

func _process(_d: float) -> bool:
	if g == null or not g.ready_done or not g.ticked.is_connected(_tick): return false
	frame += 1
	if frame % every == 0:
		RenderingServer.frame_post_draw.connect(_save.bind(n, g.clock.t), CONNECT_ONE_SHOT)
		n += 1
	if g.clock.t >= dur:
		var f := FileAccess.open(out.path_join("frames.json"), FileAccess.WRITE); f.store_string(JSON.stringify(log)); f.close()
		print("FILM ", n, " frames, max tick ", g.stats.max_tick_ms, " ms")
		quit(0)
	return false

func _save(i: int, t: float) -> void:
	root.get_texture().get_image().save_png(out.path_join("f%04d.png" % i))
	var sees := []
	for s in g.school_nodes: sees.append(s.actors.size() > 0 and s.actors[0].get("kind") == "player")
	log.append({"i": i, "t": snappedf(t, 0.01), "mode": g.girl.mode_name(), "girl": [g.girl.centre().x, g.girl.centre().y, g.girl.centre().z],
		"phase_ms": g.stats.phase_ms.duplicate(), "school_sees_girl": sees, "level": g.world_root.water.level})
