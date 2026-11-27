## Lagoon shots 0.3.0 (engine thread, was look/lagoon_look.gd): builds the calm lagoon from world pieces (GLB, world coordinates) plus one hero fish,
## lights it with the ported Unreal systems, and renders a shot set. Assets are outside git: pass their folder.
## 0.2.0: light, exposure and water are no longer picked by eye. The world clock (core/world/sky_clock.gd, the Unreal
## sky clock's maths) drives the sun/moon light and EV100; the water is the Unreal lagoon's physics (core/world/water_optics.gd,
## Cdom 0.03, ScatK 0.40, GlowK 2.50) in the seabed, surface and underwater-view shaders. Env: AO_HOUR (default 12).
## 0.3.0: the world (light, sky, exposure, water) comes from adapters/godot/world_root.gd, the same node the game uses.
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --script res://tools/lagoon_shots.gd -- <pieces_dir> <fish.glb> <out_dir> [w h]
## Env: AO_FILL_AO=0 (water fill unoccluded, as before), AO_SSAO=0, AO_SSIL=0, AO_SDFGI=1, AO_CDOM / AO_SCAT (water's yellow substance / particles, art levers), AO_TIDE=1 (the sea follows the tide; default pinned at the mean), AO_DRESS=<world_dress/x.json> + AO_DRESS_PIECES=<dir> (an authored place built by world_dress/dress_cell.gd; its cameras become shots 09+), AO_UNDER_EV (art stops under water), AO_GLOW_K (haze strength, 2.5), AO_LIGHT_NEUTRAL=0..1 (art direction: sunlight keeps its colour on the way down), AO_DEPTH_COLOUR=1 (Unreal's depth colour give-back; AO_DEPTH_SHARE its share, default 0.25), AO_AGX=0 (Godot's built-in tonemapper instead of the ported Unreal AgX), AO_AGX_MODE=1 (raw buffer, for checks), AO_SHOTS (two-digit prefixes, e.g. 01,02), AO_WORLDTEX (world texture folder: the shared ground material).
## Light net: AO_CAUS=pixel (per pixel instead of the map), AO_CAUS=waves (the map from the 32 waves instead of the FFT sea), AO_CAUS_T=<s> (hold the net and the sea at that second), AO_CAUS_DUMP=<file> (the map as raw float32 RGBA).
## God rays: AO_GOD=0 turns them off (WorldRoot.god_rays), for before/after. AO_TAA=1: Godot TAA on (Unreal ran TSR; the rays' jitter is averaged).
## Night: the Unreal night eye (WorldRoot.apply) and the Unreal stars (look/sky_stars.gdshaderinc). Try AO_HOUR=22 (moonless), 94 (moonlit).
## Still to port: the surface's waves and tide (the light net and the god rays are in: look/caustics.gdshaderinc, adapters/godot/caustics_map.gd).
extends SceneTree

const WATER_Y := LagoonWaterField.SURFACE_Y   # the Unreal lagoon's saved surface: SurfaceZ 400 cm (tide 0)
var args: PackedStringArray
var shots := []               # [name, cam pos, look target, fov]
var cam: Camera3D
var i := -1
var wait := 0
var fish: Node3D
var ap: AnimationPlayer
var wr: WorldRoot
var ground: ShaderMaterial
var _caus_dump := ""
var _t8 := 0

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
	WorldRoot.declare_globals()   # before any water shader compiles
	var world := Node3D.new(); world.name = "Lagoon"; root.add_child(world)
	var seabed := ShaderMaterial.new(); seabed.shader = load("res://look/seabed_surface.gdshader")
	var n := 0
	for f in DirAccess.get_files_at(args[0]):
		if not f.ends_with(".glb"): continue
		var sc := _load(args[0].path_join(f))
		if sc == null: continue
		world.add_child(sc); n += 1
		var mat := seabed
		if "floor" in f.to_lower():
			if ground == null and OS.get_environment("AO_WORLDTEX") != "":
				ground = WorldTextures.make_material(OS.get_environment("AO_WORLDTEX"))   # the shared world material (sand ripples, grains)
			if ground: mat = ground
			else:
				mat = seabed.duplicate(); mat.set_shader_parameter("sand_lock", 1.0)
		for mi in sc.find_children("*", "MeshInstance3D", true, false):
			for s in mi.mesh.get_surface_count(): mi.set_surface_override_material(s, mat)
	print("PIECES ", n)
	var lo := INF; var hi := -INF
	for mi in world.find_children("*", "MeshInstance3D", true, false):
		if "floor" in String(mi.get_parent().name).to_lower() or "floor" in String(mi.name).to_lower():
			var bb: AABB = mi.global_transform * mi.get_aabb(); lo = minf(lo, bb.position.y); hi = maxf(hi, bb.end.y)
	print("FLOOR y ", lo, " .. ", hi)
	# light, sky, exposure and water uniforms: one WorldRoot driven by the world clock
	wr = WorldRoot.new()
	if OS.get_environment("AO_CDOM") != "": wr.cdom = float(OS.get_environment("AO_CDOM"))
	if OS.get_environment("AO_SCAT") != "": wr.scat_k = float(OS.get_environment("AO_SCAT"))
	if OS.get_environment("AO_FILL_AO") == "0": wr.fill_occluded = false   # the water fill as emission (unoccluded), before/after
	if OS.get_environment("AO_SSIL") == "0": wr.env.ssil_enabled = false
	if OS.get_environment("AO_SSAO") == "0": wr.env.ssao_enabled = false
	if OS.get_environment("AO_SDFGI") == "1": wr.env.sdfgi_enabled = true
	if OS.get_environment("AO_SSAO_R") != "": wr.env.ssao_radius = float(OS.get_environment("AO_SSAO_R")); wr.env.ssao_intensity = float(OS.get_environment("AO_SSAO_I"))
	wr.tide_on = OS.get_environment("AO_TIDE") == "1"   # reference shots pin the sea at its mean level (AO_TIDE=1: follow the moons)
	wr.hours = float(OS.get_environment("AO_HOUR")) if OS.get_environment("AO_HOUR") != "" else 12.0
	wr.depth_colour = OS.get_environment("AO_DEPTH_COLOUR") == "1"   # Unreal v168 depth colour give-back (off by default)
	if OS.get_environment("AO_UNDER_EV") != "": wr.under_exposure_art = float(OS.get_environment("AO_UNDER_EV"))
	if OS.get_environment("AO_GLOW_K") != "": wr.glow_k = float(OS.get_environment("AO_GLOW_K"))
	if OS.get_environment("AO_LIGHT_NEUTRAL") != "": wr.light_neutral = float(OS.get_environment("AO_LIGHT_NEUTRAL"))
	if OS.get_environment("AO_DEPTH_SHARE") != "": wr.depth_colour_share = float(OS.get_environment("AO_DEPTH_SHARE"))
	world.add_child(wr)
	if OS.get_environment("AO_AGX") == "0": wr.set_agx(false)   # Godot's built-in AgX, for before/after
	if OS.get_environment("AO_AGX_MODE") != "": wr.agx_fx.mode = int(OS.get_environment("AO_AGX_MODE"))
	if OS.get_environment("AO_CAUS") == "pixel": wr.caustics.per_pixel = true   # the light net per pixel instead of from its map (checks)
	if OS.get_environment("AO_CAUS_T") != "": wr.caustics.frozen_time = float(OS.get_environment("AO_CAUS_T"))   # hold the net at this second
	if OS.get_environment("AO_GOD") == "0": wr.god_rays = false   # the god rays off (before/after)
	if OS.get_environment("AO_TAA") == "1": root.use_taa = true
	if OS.get_environment("AO_CAUS_DUMP") != "": _caus_dump = OS.get_environment("AO_CAUS_DUMP")
	var sea := wr.make_surface() as SeaSurface
	world.add_child(sea)
	if OS.get_environment("AO_CAUS") == "waves": wr.caustics.from_sea = false   # the net from the 32 waves instead of the FFT sea (checks)
	if OS.get_environment("AO_CAUS_T") != "":   # ... and hold the sea at the same second, so stills match run to run
		sea.fft.hold = true; sea.fft.time_s = float(OS.get_environment("AO_CAUS_T"))
	var dress: DressCell = null
	if OS.get_environment("AO_DRESS") != "":   # an authored place (world_dress/<name>.json) built from its pieces (AO_DRESS_PIECES), seated on the floor
		dress = DressCell.new(); dress.setup(OS.get_environment("AO_DRESS"), OS.get_environment("AO_DRESS_PIECES")); dress.ground_material = ground
		world.add_child(dress); dress.build()
		for mi in world.find_children("*", "MeshInstance3D", true, false):
			if "floor" in String(mi.get_parent().name).to_lower(): mi.create_trimesh_collision()
		await physics_frame; await physics_frame
		var space := root.get_world_3d().direct_space_state
		print("SEAT ", dress.seat(space), " KEEP_CLEAR ", dress.keep_clear_report(space))
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
			ap = aps[0]; var a = ap.get_animation_list()[0]
			for an in ap.get_animation_list():   # the maker's swim clip ("swim" after an editor import, "swim_loop" at runtime)
				if an.begins_with("swim"): a = an
			ap.get_animation(a).loop_mode = Animation.LOOP_LINEAR; ap.play(a)
	if dress and fish:
		fish.position = dress.on_sand(dress.manifest.hero.at); fish.rotation.y = dress.anchor_xform.basis.get_euler().y + float(dress.manifest.hero.rot)
	var fp := fish.position if fish else Vector3(1.2, 0.9, -9.6)
	shots = [
		["01_hero_3p", fp + Vector3(-0.55, 0.18, 0.5), fp, 50.0],
		["02_reef_wide", Vector3(-6, 2.2, -2), Vector3(2, 0.6, -12), 60.0],
		["03_look_up", fp + Vector3(-1.0, -0.4, 1.0), fp + Vector3(0, 4, -2), 70.0],
		["04_sand_far", Vector3(0, 1.4, 18), Vector3(0, 0.8, -20), 60.0],
		["05_sky_above", Vector3(0, WATER_Y + 1.5, 10), Vector3(0, WATER_Y + 9.0, -10), 75.0],
	]
	# reference: the level ray 2 m deep, looking along open sand (tools/level_ray_check.py computes it offline)
	shots.append(["08_level_ray", Vector3(0, 2.0, 20), Vector3(0, 2.0, 60), 40.0])
	# the two moons, wherever the clock puts them
	var stm := SkyClock.sky_state(wr.hours)
	var mp := Vector3(0, WATER_Y + 1.5, 10)
	shots.append(["06_moon_b", mp, mp + WorldRoot.to_godot(stm.B.dir) * 10.0, 12.0])
	shots.append(["07_moon_a", mp, mp + WorldRoot.to_godot(stm.A.dir) * 10.0, 12.0])
	if dress:   # the place's own cameras (the key frame's camera first)
		var nk := 9
		for c in dress.manifest.cams:
			var cc := dress.cam(c); shots.append(["%02d_dress_%s" % [nk, c], cc[0], cc[1], cc[2]]); nk += 1
	if OS.get_environment("AO_SHOTS") != "":
		var keep := OS.get_environment("AO_SHOTS").split(",")
		shots = shots.filter(func(sh): return sh[0].substr(0, 2) in keep)
	cam = Camera3D.new(); world.add_child(cam); cam.current = true
	wr.attach_camera(cam)
	_next()

func _next():
	i += 1
	if i >= shots.size(): quit(0); return
	wr.set_fov(shots[i][3])
	cam.look_at_from_position(shots[i][1], shots[i][2], Vector3.UP); wait = 0
	print("LIGHT ", shots[i][0], " ", wr.apply(shots[i][1].y))

func _process(_d):
	if cam == null or i < 0 or i >= shots.size(): return false
	wait += 1
	if wait == 8: _t8 = Time.get_ticks_usec()
	if wait == 24:   # let volumetric fog and SSIL settle (they accumulate over frames)
		if _caus_dump != "" and i == 0:   # the light net's map as raw floats, to check against tools/make_caustic_waves.py --dump
			var cm: Image = wr.caustics.map_vp.get_texture().get_image(); cm.convert(Image.FORMAT_RGBAF)
			var cf := FileAccess.open(_caus_dump, FileAccess.WRITE); cf.store_buffer(cm.get_data()); cf.close()
			print("CAUS_DUMP ", _caus_dump, " ", cm.get_width(), " x ", cm.get_height(), " RGBAF")
		var p: String = args[2].path_join(shots[i][0] + ".png"); root.get_texture().get_image().save_png(p); print("SHOT ", p, " frame ms ", snappedf((Time.get_ticks_usec() - _t8) / 16000.0, 0.1)); _next()
	return false
