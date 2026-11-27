## School film 0.1.0 (fish school thread): renders schools in the calm lagoon so people can see them (cloud: CPU Vulkan
## under xvfb). The lagoon pieces (GLB, world coordinates, the engine thread's shot assets) get trimesh collision so the
## school meets the real rocks through WorldQuery; light, sky, exposure and water come from WorldRoot as in the game.
## The girl is a STAND-IN capsule moving on a scripted path (the M08 perceived actor). Fish are the stand-in mesh until
## the maker's trevally glb lands.
## Run: xvfb-run -a godot --path . --rendering-driver vulkan --fixed-fps 30 --script res://tools/school_film.gd -- <pieces_dir> <out_dir> <scene> [w h]
##   scene: lagoon (baitfish over their rock, the girl swims through calmly) | rush (trevally, the girl rushes in: startle wave)
##          | top (top view of the lagoon school, for the measures)
## Writes out_dir/f_0000.png ... one per frame (30 fps) and out_dir/log.json (per-second measures).
extends SceneTree

var args: PackedStringArray
var out := ""
var scene := "lagoon"
var world: Node3D
var wr: WorldRoot
var cam: Camera3D
var schools: Array = []
var girl: Node3D
var t := 0.0
var frame := 0
var dur := 14.0
var warm := 60
var log := []
var rock_tops := []
var path: Callable
var cam_path: Callable

func _init():
	args = OS.get_cmdline_user_args()
	out = args[1]
	scene = args[2] if args.size() > 2 else "lagoon"
	var w := int(args[3]) if args.size() > 3 else 960
	var h := int(args[4]) if args.size() > 4 else 540
	root.size = Vector2i(w, h)
	DirAccess.make_dir_recursive_absolute(out)
	process_frame.connect(_setup, CONNECT_ONE_SHOT)

func _load(p: String) -> Node:
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	if doc.append_from_file(p, st) != OK: return null
	return doc.generate_scene(st)

func _setup():
	WorldRoot.declare_globals()
	world = Node3D.new(); root.add_child(world)
	var seabed := ShaderMaterial.new(); seabed.shader = load("res://look/seabed_surface.gdshader")
	for f in DirAccess.get_files_at(args[0]):
		if not f.ends_with(".glb"): continue
		var sc := _load(args[0].path_join(f))
		if sc == null: continue
		world.add_child(sc)
		var mat := seabed
		if "floor" in f.to_lower():
			mat = seabed.duplicate(); mat.set_shader_parameter("sand_lock", 1.0)
		for mi in sc.find_children("*", "MeshInstance3D", true, false):
			for s in mi.mesh.get_surface_count(): mi.set_surface_override_material(s, mat)
			if "seagrass" in f.to_lower(): continue
			# collision: the piece's own triangles (test film only; game assets bring CoACD collision, FUNDAMENTALS)
			var sb := StaticBody3D.new(); var cs := CollisionShape3D.new()
			cs.shape = mi.mesh.create_trimesh_shape(); sb.add_child(cs)
			mi.add_child(sb)
			if not "floor" in f.to_lower():
				var bb: AABB = mi.global_transform * mi.get_aabb()
				rock_tops.append([f, bb])
	wr = WorldRoot.new(); wr.hours = 11.0
	world.add_child(wr)
	world.add_child(wr.make_surface())
	cam = Camera3D.new(); world.add_child(cam); cam.current = true
	wr.attach_camera(cam)
	for r in rock_tops: print("ROCK ", r[0], " ", r[1])
	# the girl (stand-in capsule, orange suit)
	girl = Node3D.new(); world.add_child(girl)
	var suit := MeshInstance3D.new(); var cm := CapsuleMesh.new(); cm.radius = 0.18; cm.height = 1.2; suit.mesh = cm
	suit.rotation_degrees = Vector3(0, 0, 90)
	var sm := StandardMaterial3D.new(); sm.albedo_color = Color(0.95, 0.45, 0.15); suit.material_override = sm
	girl.add_child(suit)
	# the school(s)
	var boulder: AABB = _rock("boulder")
	var home := boulder.get_center() + Vector3(0, boulder.size.y * 0.5 + 0.9, 0)
	match scene:
		"lagoon", "top":
			var s := _school("lagoon_baitfish", 0, 7, home, true, {"back_colour": Color(0.12, 0.24, 0.36), "stripe": 1.0})
			# she swims across the school's rock at an easy pace (0.7 m/s), 1 m above it
			path = func(tt: float) -> Vector3: return home + Vector3(-7.0 + 0.7 * maxf(tt - 4.0, 0.0), 0.0, 0.0)
			if scene == "lagoon":
				cam_path = func(tt: float) -> Array: return [home + Vector3(-0.6, 0.5, 3.4), home + Vector3(0.0, -0.1, 0.0)]
			else:
				cam_path = func(tt: float) -> Array: return [home + Vector3(0.0, 9.0, 0.01), home]
			dur = 16.0
		"rush":
			var s2 := _school("trevally", 0, 11, home + Vector3(2.0, 0.6, -2.0), false, {"back_colour": Color(0.16, 0.26, 0.30), "flank_colour": Color(0.80, 0.84, 0.86)})
			s2.sim.p.R_home = 6.0; s2.sim.p.home = Vector3.ZERO
			# she darts (2.4 m/s) straight at where the school is when she sets off, and on through it; the camera
			# watches from the side, 7 m off her line
			var st := {"a": Vector3.ZERO, "dir": Vector3.RIGHT, "set": false}
			path = func(tt: float) -> Vector3:
				var c: Vector3 = s2.sim.metrics().centre_m if not st.set else st.a
				var start := c + Vector3(-7.0, 0.0, 0.0)
				if tt < 4.0: return start
				if not st.set: st.a = c; st.set = true; st.dir = Vector3.RIGHT
				return st.a + Vector3(-7.0, 0.0, 0.0) + st.dir * (2.4 * (tt - 4.0))
			cam_path = func(tt: float) -> Array:
				var c: Vector3 = st.a if st.set else s2.sim.metrics().centre_m
				return [c + Vector3(-1.0, 1.2, 7.0), c + Vector3(-0.5, 0.0, 0.0)]
			dur = 10.0
		"close":
			var s4 := _school("trevally", 0, 5, home + Vector3(0.0, 0.8, 0.0), true, {})
			# a close look at the school (checks the creature export's mesh, material and swim wave in the school)
			path = func(tt: float) -> Vector3: return home + Vector3(-30.0, 0.0, 0.0)
			cam_path = func(tt: float) -> Array:
				var c: Vector3 = s4.sim.metrics().centre_m
				var k: float = s4.params.bl_m / 0.17       # framed for a 17 cm fish; scaled to the export's body length
				return [c + Vector3(-0.4, 0.25, 1.6) * k, c]
			dur = 6.0
		"circle":
			var s3 := _school("trevally", 0, 4, home + Vector3(0.0, 0.8, 0.0), true, {"back_colour": Color(0.16, 0.26, 0.30), "flank_colour": Color(0.80, 0.84, 0.86)})
			# she drifts in slowly and hovers: curious trevally circle her (Thalassa calm-diver behaviour)
			path = func(tt: float) -> Vector3: return home + Vector3(-6.0 + 0.5 * clampf(tt, 0.0, 6.0), 1.0, 2.0)
			cam_path = func(tt: float) -> Array:
				var g: Vector3 = home + Vector3(-6.0 + 0.5 * clampf(tt, 0.0, 6.0), 1.0, 2.0)
				var cp: Vector3 = g + Vector3(-3.0, 0.5, 6.5)
				cp.y = minf(cp.y, wr.water.water_y.call(cp.x, cp.z, 0.0) - 0.8)   # stay under the surface
				return [cp, g + Vector3(2.0, -0.4, -1.5)]
			dur = 20.0
	girl.position = path.call(0.0)

func _rock(key: String) -> AABB:
	for r in rock_tops:
		if key in r[0]: return r[1]
	return AABB(Vector3(0, 0, -10), Vector3(2, 1.5, 2))

func _school(id: String, n: int, sd: int, home: Vector3, tether: bool, look: Dictionary) -> FishSchool:
	var s := FishSchool.new()
	s.species_id = id; s.count = n; s.seed_ = sd; s.home = home; s.tethered = tether; s.look = look
	s.threaded = true
	s.water_y = wr.water.water_y
	world.add_child(s)
	s.process_mode = Node.PROCESS_MODE_DISABLED   # stepped by this tool at the film's fixed rate
	s.perceive = [girl]
	schools.append(s)
	return s

func _process(delta: float):
	if cam == null or schools.is_empty(): return false
	var dt := 1.0 / 30.0
	var tt := t - warm * dt
	girl.position = path.call(tt)
	var cp: Array = cam_path.call(tt)
	cam.look_at_from_position(cp[0], cp[1], Vector3.UP)
	if frame == 0: print("LIGHT ", wr.apply(cp[0].y))
	for s in schools: s.advance(dt)
	if frame >= warm:
		var p := out.path_join("f_%04d.png" % (frame - warm))
		root.get_texture().get_image().save_png(p)
		if (frame - warm) % 15 == 0:
			for s in schools:
				var m: Dictionary = s.metrics()
				log.append({"t": snappedf(tt, 0.01), "species": s.species_id, "P": snappedf(m.P, 0.001), "nnd": snappedf(m.nnd_mean, 0.001),
					"nnd_min": snappedf(m.nnd_min, 0.001), "speed": snappedf(m.speed, 0.001), "startled": m.startled,
					"hits": s.sim.hits, "step_ms": snappedf(s.step_ms, 0.01), "main_ms": snappedf(s.main_ms, 0.01),
					"girl_d": snappedf(m.centre_m.distance_to(girl.position), 0.01)})
				print("t %.1f %s P %.2f nnd %.2f min %.2f startled %d step %.1f ms main %.2f ms" % [tt, s.species_id, m.P, m.nnd_mean, m.nnd_min, m.startled, s.step_ms, s.main_ms])
	t += dt
	frame += 1
	if tt >= dur:
		for s in schools: s.sync()
		var f := FileAccess.open(out.path_join("log.json"), FileAccess.WRITE); f.store_string(JSON.stringify(log)); f.close()
		quit(0)
	return false
