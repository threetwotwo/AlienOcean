## Lagoon look 0.2.0 (engine thread): builds the calm lagoon from world pieces (GLB, world coordinates) plus one hero fish,
## lights it with the ported Unreal systems, and renders a shot set. Assets are outside git: pass their folder.
## 0.2.0: light, exposure and water are no longer picked by eye. The world clock (core/m30_world_clock, the Unreal
## sky clock's maths) drives the sun/moon light and EV100; the water is the Unreal lagoon's physics (look/water_optics.gd,
## Cdom 0.03, ScatK 0.40, GlowK 2.50) in the seabed, surface and underwater-view shaders. Env: AO_HOUR (default 12).
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --script res://look/lagoon_look.gd -- <pieces_dir> <fish.glb> <out_dir> [w h]
## Still to port: the sky (drawn sun, moons, stars), the surface's waves and mirror detail, the sand maps, god rays.
extends SceneTree

const WATER_Y := LagoonWaterField.SURFACE_Y   # the Unreal lagoon's saved surface: SurfaceZ 400 cm (tide 0)
var args: PackedStringArray
var shots := []               # [name, cam pos, look target, fov]
var cam: Camera3D
var i := -1
var wait := 0
var fish: Node3D
var ap: AnimationPlayer
var clock: SkyClockDriver

func _init():
	args = OS.get_cmdline_user_args()
	var w := int(args[3]) if args.size() > 3 else 1280
	var h := int(args[4]) if args.size() > 4 else 720
	root.size = Vector2i(w, h)
	DirAccess.make_dir_recursive_absolute(args[2])
	process_frame.connect(_setup, CONNECT_ONE_SHOT)

func _load(path: String) -> Node:
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		push_warning("could not read " + path); return null
	return doc.generate_scene(st)

func _setup():
	WaterOptics.declare_globals()
	var world := Node3D.new(); world.name = "Lagoon"; root.add_child(world)
	var seabed := ShaderMaterial.new(); seabed.shader = load("res://look/seabed_surface.gdshader")
	var n := 0
	for f in DirAccess.get_files_at(args[0]):
		if not f.ends_with(".glb"): continue
		var sc := _load(args[0].path_join(f))
		if sc == null: continue
		world.add_child(sc); n += 1
		for mi in sc.find_children("*", "MeshInstance3D", true, false):
			for s in mi.mesh.get_surface_count(): mi.set_surface_override_material(s, seabed)
	print("PIECES ", n)
	var lo := INF; var hi := -INF
	for mi in world.find_children("*", "MeshInstance3D", true, false):
		if "floor" in String(mi.get_parent().name).to_lower() or "floor" in String(mi.name).to_lower():
			var bb: AABB = mi.global_transform * mi.get_aabb(); lo = minf(lo, bb.position.y); hi = maxf(hi, bb.end.y)
	print("FLOOR y ", lo, " .. ", hi)
	# key light, environment and exposure: driven by the world clock
	var sun := DirectionalLight3D.new(); sun.shadow_enabled = true; sun.directional_shadow_max_distance = 60.0
	world.add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR; env.background_color = Color(0, 0, 0)
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true; env.ssao_radius = 1.2; env.ssao_intensity = 1.6
	env.ssil_enabled = true; env.ssil_radius = 4.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.glow_enabled = true; env.glow_intensity = 0.3
	var we := WorldEnvironment.new(); we.environment = env; world.add_child(we)
	clock = SkyClockDriver.new(); clock.light = sun; clock.env = env; clock.water_y = WATER_Y
	clock.hours = float(OS.get_environment("AO_HOUR")) if OS.get_environment("AO_HOUR") != "" else 12.0
	clock.cam_attr = CameraAttributesPhysical.new(); clock.cam_attr.auto_exposure_enabled = false
	world.add_child(clock)
	# water surface overhead
	var surf := MeshInstance3D.new(); var pm := PlaneMesh.new(); pm.size = Vector2(160, 160); surf.mesh = pm
	surf.position.y = WATER_Y; var wm := ShaderMaterial.new(); wm.shader = load("res://look/water_surface.gdshader"); surf.material_override = wm
	surf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; world.add_child(surf)
	# hero fish, hovering near the coral heads
	fish = _load(args[1]) as Node3D
	if fish:
		world.add_child(fish); fish.position = Vector3(1.2, 0.9, -9.6); fish.rotation_degrees.y = 25
		for mi in fish.find_children("*", "MeshInstance3D", true, false):
			for s in mi.mesh.get_surface_count():
				var m = mi.get_active_material(s)
				if m is BaseMaterial3D: m.vertex_color_use_as_albedo = false   # our fish COLOR_0 is data
		var aps := fish.find_children("*", "AnimationPlayer", true, false)
		if aps.size() > 0:
			ap = aps[0]; var a = ap.get_animation_list()[0]; ap.get_animation(a).loop_mode = Animation.LOOP_LINEAR; ap.play(a)
	var fp := fish.position if fish else Vector3(1.2, 0.9, -9.6)
	shots = [
		["01_hero_3p", fp + Vector3(-0.55, 0.18, 0.5), fp, 50.0],
		["02_reef_wide", Vector3(-6, 2.2, -2), Vector3(2, 0.6, -12), 60.0],
		["03_look_up", fp + Vector3(-1.0, -0.4, 1.0), fp + Vector3(0, 4, -2), 70.0],
		["04_sand_far", Vector3(0, 1.4, 18), Vector3(0, 0.8, -20), 60.0],
	]
	cam = Camera3D.new(); world.add_child(cam); cam.current = true
	cam.attributes = clock.cam_attr; clock.cam_attr.frustum_near = 0.02; clock.cam_attr.frustum_far = 400.0
	# the water between the eye and every pixel
	var q := MeshInstance3D.new(); var qm := QuadMesh.new(); qm.size = Vector2(2, 2); q.mesh = qm
	var qmat := ShaderMaterial.new(); qmat.shader = load("res://look/underwater_view.gdshader"); q.material_override = qmat
	q.extra_cull_margin = 16384.0; q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; cam.add_child(q)
	_next()

func _next():
	i += 1
	if i >= shots.size(): quit(0); return
	clock.cam_attr.frustum_focal_length = 18.0 / tan(deg_to_rad(shots[i][3]) * 0.5)
	cam.look_at_from_position(shots[i][1], shots[i][2], Vector3.UP); wait = 0
	print("LIGHT ", shots[i][0], " ", clock.apply(shots[i][1].y))

func _process(_d):
	if cam == null or i < 0 or i >= shots.size(): return false
	wait += 1
	if wait == 24:   # let volumetric fog and SSIL settle (they accumulate over frames)
		var p: String = args[2].path_join(shots[i][0] + ".png"); root.get_texture().get_image().save_png(p); print("SHOT ", p); _next()
	return false
