## Motion film 0.1.0: renders the movement test so people can see it (cloud: CPU Vulkan under xvfb).
## Runs the same motor + worlds as tests/test_motor.gd with plain stand-in meshes, a side-tracking documentary camera,
## and writes a PNG every 0.25 s of simulated time plus a log of mode/depth per frame (frames.json).
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --fixed-fps 15 --script res://tools/motion_film.gd -- <out_dir> <scene>
##   scene: shore (walk -> wade -> swim -> tread -> back out) | cave (1.0 m tube, cutaway) | steps
##          cam_shore / cam_wall: filmed through the game camera itself (M03), shot changes and boom pull-in
extends SceneTree

const Packet := preload("res://core/m01_input/input_packet.gd")
const Body := preload("res://adapters/godot/player_body.gd")
const Worlds := preload("res://core/m23_harness/test_worlds.gd")
const Motor := preload("res://core/m02_motor/player_motor.gd")
const Rig := preload("res://adapters/godot/camera_rig.gd")
var rig
var suit_mats := []

var out := "/tmp/film"
var scene := "shore"
var world: Node3D
var body
var env
var cam: Camera3D
var girl: Node3D
var t := 0.0
var next_shot := 0.0
var n := 0
var log := []
var dur := 34.0
var warm := 3

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: out = a[0]
	if a.size() > 1: scene = a[1]
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(960, 540)
	Engine.physics_ticks_per_second = 60
	Engine.max_physics_steps_per_frame = 8
	var rock := StandardMaterial3D.new(); rock.albedo_color = Color(0.78, 0.72, 0.6); rock.roughness = 0.95
	if scene == "cave":
		rock.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; rock.albedo_color = Color(0.7, 0.66, 0.58, 0.35)
	Worlds.visual_material = rock
	world = Node3D.new(); root.add_child(world)
	var p := {}
	match scene:
		"shore": p = {"start": Vector3(18.6, 1.05, 4)}
		"cam_shore": p = {"start": Vector3(0, 1.05, 6)}; dur = 30.0
		"cam_wall": p = {"start": Vector3(1.2, 0.05, 0)}; dur = 14.0
		"cave": p = {"s": 1.0, "start": Vector3(0, -10.42, 2), "mode": Motor.Mode.SWIM}; dur = 12.0
		"steps": p = {"h": 0.3, "start": Vector3(0, 0.05, 2)}; dur = 6.0
	env = Worlds.build(world, {"steps": "step", "cam_shore": "shore", "cam_wall": "wall"}.get(scene, scene), p)
	body = Body.new(); body.position = p.start; world.add_child(body)
	if p.has("mode"): body.motor.mode = p.mode
	# stand-in girl: 1.38 m capsule (orange suit) + head; lies along her heading when swimming (visual only)
	girl = Node3D.new(); body.add_child(girl)
	var suit := MeshInstance3D.new(); var cm := CapsuleMesh.new(); cm.radius = 0.2; cm.height = 1.15; suit.mesh = cm
	var sm := StandardMaterial3D.new(); sm.albedo_color = Color(0.95, 0.45, 0.15); suit.material_override = sm
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; suit_mats.append(sm)
	suit.position = Vector3(0, 0.6, 0); girl.add_child(suit)
	var head := MeshInstance3D.new(); var hm := SphereMesh.new(); hm.radius = 0.13; hm.height = 0.26; head.mesh = hm
	var hmat := StandardMaterial3D.new(); hmat.albedo_color = Color(0.98, 0.85, 0.7); head.material_override = hmat
	hmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; suit_mats.append(hmat)
	head.position = Vector3(0, 1.28, 0); girl.add_child(head)
	# water: a translucent sheet at the surface + blue depth fog
	var has_water: bool = env.level > -999.0
	if has_water:
		# a translucent water volume (so the submerged part of the frame reads as water from the side)
		var w := MeshInstance3D.new(); var bx := BoxMesh.new(); bx.size = Vector3(44.4, 30, 120); w.mesh = bx
		var wm := StandardMaterial3D.new(); wm.albedo_color = Color(0.02, 0.3, 0.5, 0.6); wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		wm.cull_mode = BaseMaterial3D.CULL_DISABLED; wm.roughness = 0.2; wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		w.material_override = wm; w.position = Vector3(0, env.level - 15.0, -40); world.add_child(w)
		# the surface itself: a bright thin band so the water line reads at a glance
		var sf := MeshInstance3D.new(); var sb := BoxMesh.new(); sb.size = Vector3(44.6, 0.04, 120.2); sf.mesh = sb
		var sfm := StandardMaterial3D.new(); sfm.albedo_color = Color(0.75, 0.92, 1.0, 0.55); sfm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sfm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; sf.material_override = sfm
		sf.position = Vector3(0, env.level, -40); world.add_child(sf)
	var we := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.55, 0.75, 0.88) if scene != "cave" else Color(0.05, 0.25, 0.35)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.6, 0.7, 0.75); e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	if scene == "cave":
		e.fog_enabled = true; e.fog_light_color = Color(0.08, 0.35, 0.45); e.fog_density = 0.02
	we.environment = e; world.add_child(we)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-55, 35, 0); sun.light_energy = 1.4; sun.shadow_enabled = true; world.add_child(sun)
	if scene.begins_with("cam_"):
		rig = Rig.new(); world.add_child(rig); rig.exclude.append(body.get_rid()); rig.body = body; rig.current = true
	else:
		cam = Camera3D.new(); cam.fov = 50.0; world.add_child(cam); cam.current = true

func _input_for(tt: float):
	var k = Packet.new()
	match scene:
		"shore": k.move = Vector2(0, 1); k.cam_yaw = 0.0 if tt < 16.0 else PI
		"cam_shore": k.move = Vector2(0, 1) if tt < 13.0 or tt > 19.0 else Vector2(0, 0.3)
		"cam_wall": k.move = Vector2.ZERO
		_: k.move = Vector2(0, 1)
	if rig != null:
		k.cam_yaw = rig.yaw; k.cam_pitch = rig.pitch
	return k

## camera script for the cam_ scenes: [look input, shot]
func _cam_for(tt: float, m: String) -> Array:
	match scene:
		"cam_shore":
			var shot := "swim" if (m == "SWIM" or m == "TREAD") else "explore"
			if tt > 15.0 and tt < 19.0: shot = "first_person"
			if tt > 22.0 and tt < 25.0: shot = "observe"
			var lx := 0.35 if tt > 19.0 and tt < 22.0 else 0.0
			return [Vector2(lx, -0.15 if tt < 3.0 else 0.0), shot]
		_:
			return [Vector2(0.9, 0.25 * sin(tt)), "first_person" if tt > 9.5 and tt < 12.0 else "explore"]

func _physics_process(dt: float) -> bool:
	if warm > 0:
		warm -= 1; return false
	body.tick(dt, _input_for(t), env, t)
	t += dt
	var m: String = body.motor.mode_name()
	var swim := m == "SWIM" or m == "TREAD"
	var lie := 1.0 if m == "SWIM" else (0.35 if m == "TREAD" else 0.0)
	girl.rotation = Vector3(-lie * PI * 0.5, body.motor.facing_yaw, 0)
	girl.position = Vector3(0, 0.42 if swim else 0.0, 0) if lie > 0.5 else Vector3.ZERO
	var p: Vector3 = body.global_position
	var shot := ""
	if rig != null:
		var c := _cam_for(t, m)
		shot = c[1]
		rig.request(shot)
		var wy: float = env.water_y(p.x, p.z, t) if env.level > -999.0 else -INF
		var f: Dictionary = rig.tick(dt, body.eye_point(), c[0], wy)
		for mt in suit_mats: mt.albedo_color.a = f.body_alpha
	match scene:
		"cam_shore", "cam_wall": pass
		"cave": cam.global_position = p + Vector3(5.5, 1.5, 0); cam.look_at(p + Vector3(0, 0.3, 0))
		"steps": cam.global_position = p + Vector3(4.5, 1.2, 1.0); cam.look_at(p + Vector3(0, 0.6, 0))
		_: cam.global_position = Vector3(p.x + 6.5, maxf(p.y, -1.5) + 1.0, p.z + 0.5); cam.look_at(Vector3(p.x, maxf(p.y, -1.5) + 0.5, p.z))
	if t >= next_shot:
		next_shot += 0.25
		RenderingServer.frame_post_draw.connect(_save.bind(n, t, m if shot == "" else m + "|" + shot, body.last_sense.water_y - body.last_sense.feet.y if not body.last_sense.is_empty() else 0.0), CONNECT_ONE_SHOT)
		n += 1
	if t >= dur:
		var f := FileAccess.open(out + "/frames.json", FileAccess.WRITE); f.store_string(JSON.stringify(log))
		return true
	return false

func _save(i: int, tt: float, m: String, depth: float) -> void:
	var img := root.get_texture().get_image()
	img.save_png("%s/f%04d.png" % [out, i])
	log.append({"i": i, "t": snappedf(tt, 0.01), "mode": m, "depth": snappedf(depth, 0.01)})
