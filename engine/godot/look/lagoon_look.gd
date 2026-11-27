## Lagoon look 0.1.0 (engine thread): builds the calm lagoon from world pieces (GLB, world coordinates) plus one hero fish,
## applies the look stack, and renders a shot set. Assets are outside git: pass their folder.
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --script res://look/lagoon_look.gd -- <pieces_dir> <fish.glb> <out_dir> [w h]
## Look stack (study section 3): volumetric fog for depth colour and shafts, SSIL + SSAO, sun with shadows, seabed caustics,
## water surface overhead. Baked LightmapGI comes in 0.2.0 (needs the editor bake step).
extends SceneTree

const WATER_Y := 5.0          # lagoon depth stand-in: surface 5 m above the sand
var args: PackedStringArray
var shots := []               # [name, cam pos, look target, fov]
var cam: Camera3D
var i := -1
var wait := 0
var fish: Node3D
var ap: AnimationPlayer

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
	# sun
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-62, 28, 0)
	sun.light_color = Color(0.78, 0.96, 0.92); sun.light_energy = 1.7;   # sunlight after ~5 m of water: red absorbed
	sun.shadow_enabled = true
	sun.light_volumetric_fog_energy = 1.6; sun.directional_shadow_max_distance = 60.0
	world.add_child(sun)
	seabed.set_shader_parameter("sun_dir_world", -sun.global_transform.basis.z)
	# environment
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR; env.background_color = Color(0.06, 0.30, 0.38)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; env.ambient_light_color = Color(0.18, 0.48, 0.55); env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true; env.ssao_radius = 1.2; env.ssao_intensity = 1.6
	env.ssil_enabled = true; env.ssil_radius = 4.0
	# distance murk = depth fog in the water colour (absorption + scattering toward the view)
	env.fog_enabled = true; env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = Color(0.07, 0.33, 0.40); env.fog_density = float(OS.get_environment("AO_FOGD")) if OS.get_environment("AO_FOGD") != "" else 0.2; env.fog_sky_affect = 1.0
	env.fog_sun_scatter = 0.25
	# light shafts = thin volumetric fog lit by the sun, dark albedo so it adds beams, not haze
	env.volumetric_fog_enabled = OS.get_environment("AO_VOLFOG") == "1"; env.volumetric_fog_density = 0.012   # off until shafts are confined (round 2 finding: global volumetric fog washes the whole view grey)
	env.volumetric_fog_albedo = Color(0.25, 0.55, 0.6); env.volumetric_fog_emission = Color(0, 0, 0)
	env.volumetric_fog_anisotropy = 0.7; env.volumetric_fog_length = 40.0
	env.glow_enabled = true; env.glow_intensity = 0.5
	var we := WorldEnvironment.new(); we.environment = env; world.add_child(we)
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
	cam = Camera3D.new(); cam.near = 0.02; cam.far = 200.0; world.add_child(cam); cam.current = true
	_next()

func _next():
	i += 1
	if i >= shots.size(): quit(0); return
	cam.fov = shots[i][3]; cam.look_at_from_position(shots[i][1], shots[i][2], Vector3.UP); wait = 0

func _process(_d):
	if cam == null or i < 0 or i >= shots.size(): return false
	wait += 1
	if wait == 24:   # let volumetric fog and SSIL settle (they accumulate over frames)
		var p: String = args[2].path_join(shots[i][0] + ".png"); root.get_texture().get_image().save_png(p); print("SHOT ", p); _next()
	return false
