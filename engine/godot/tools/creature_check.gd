## Creature import check 0.1.0: loads a creature the way the game does (editor import of res://assets/creatures/<species>/fish.glb,
## so the importer's name rules run: "-convcolonly" -> collision shapes, "_loop" -> looping clips), reports what arrived, and renders:
##   turnaround: 8 views (side L, side R, top, bottom, front, back, three-quarter above and below), rest pose
##   jaw: the gape clip at its peak, from the front three-quarter below and the side (the mouth interior must show)
##   film: frames of swim_loop (3 beats), gape, flare and breathe_loop from the three-quarter above, for a video
## Run (cloud, after `godot --headless --path . --import`):
##   xvfb-run -a godot --path . --rendering-driver vulkan --script res://tools/creature_check.gd -- res://assets/creatures/<sp>/fish.glb <out_dir> [size]
## Writes <out_dir>/report.json, view_*.png, jaw_*.png, film/*.png.
extends SceneTree

const VIEWS := [["side_L", Vector3(0, 0, 1)], ["side_R", Vector3(0, 0, -1)], ["top", Vector3(0, 1, 0.001)], ["bottom", Vector3(0, -1, 0.001)],
	["front", Vector3(-1, 0, 0)], ["back", Vector3(1, 0, 0)], ["q_above", Vector3(-0.6, 0.55, 0.6)], ["q_below", Vector3(-0.6, -0.55, 0.6)]]
var args: PackedStringArray
var out := ""
var size := 720
var cam: Camera3D
var scene: Node3D
var ap: AnimationPlayer
var center: Vector3
var radius: float
var jobs := []          # [name, anim, time, dir, zoom, target_offset]
var j := -1
var wait := 0
var report := {}

func _init():
	args = OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: -- <res://.../fish.glb> <out_dir> [size]"); quit(2); return
	out = args[1]
	if args.size() > 2: size = int(args[2])
	DirAccess.make_dir_recursive_absolute(out + "/film")
	root.size = Vector2i(size, int(size * 0.62))
	process_frame.connect(_setup, CONNECT_ONE_SHOT)

func _all(n: Node) -> Array:
	var a := [n]
	for c in n.get_children(): a += _all(c)
	return a

func _setup():
	var ps = ResourceLoader.load(args[0])
	if ps == null or not ps is PackedScene:
		print("FAIL not imported as a scene: ", args[0]); quit(1); return
	scene = ps.instantiate(); root.add_child(scene)
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.80, 0.85, 0.88); e.background_intensity = 1.2
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.7, 0.75, 0.8); e.ambient_light_energy = 0.5
	e.ssao_enabled = true; e.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.environment = e; root.add_child(env)
	var key := DirectionalLight3D.new(); key.rotation_degrees = Vector3(-50, 30, 0); key.light_intensity_lux = PI * 1.2 * 1.6; key.shadow_enabled = true; root.add_child(key)
	var fill := DirectionalLight3D.new(); fill.rotation_degrees = Vector3(40, -150, 0); fill.light_intensity_lux = PI * 1.2 * 0.4; root.add_child(fill)
	# report
	var aabb := AABB(); var first := true; var meshes := []; var mats := {}; var tris := 0; var color := false; var bones := []
	var shapes := 0; var anims := {}; var extras = null; var tinted := {}
	for n in _all(scene):
		if n is MeshInstance3D and n.mesh and n.visible:
			meshes.append(n.name)
			for s in n.mesh.get_surface_count():
				var a: Array = n.mesh.surface_get_arrays(s)
				var idx = a[Mesh.ARRAY_INDEX]; tris += (idx.size() if idx else a[Mesh.ARRAY_VERTEX].size()) / 3
				if a[Mesh.ARRAY_COLOR] and a[Mesh.ARRAY_COLOR].size() > 0: color = true
				var m = n.get_active_material(s)
				if m: mats[m.resource_name] = mats.get(m.resource_name, 0) + 1
				if m is BaseMaterial3D:
					if m.vertex_color_use_as_albedo: tinted[m.resource_name] = true   # reported: the game's importer must switch it off too
					m.vertex_color_use_as_albedo = false   # COLOR_0 is data (fin thickness), never paint
			var b: AABB = n.global_transform * n.mesh.get_aabb(); aabb = b if first else aabb.merge(b); first = false
		if n is Skeleton3D:
			for i in n.get_bone_count(): bones.append(n.get_bone_name(i))
		if n is CollisionShape3D: shapes += 1
		if n is AnimationPlayer:
			ap = n
			for an in n.get_animation_list():
				var A: Animation = n.get_animation(an); anims[an] = {"length": snappedf(A.length, 0.0001), "loop": A.loop_mode != Animation.LOOP_NONE, "tracks": A.get_track_count()}
		if n.has_meta("extras") and extras == null: extras = n.get_meta("extras")
	center = aabb.get_center(); radius = aabb.size.length() * 0.5
	report = {"file": args[0], "meshes": meshes, "materials": mats, "triangles": tris, "vertex_colour": color, "bones": bones,
		"collision_shapes": shapes, "colour0_tints_albedo_on_import": tinted.keys(), "animations": anims, "size_m": [aabb.size.x, aabb.size.y, aabb.size.z],
		"swim_extras_arrived": extras != null and typeof(extras) == TYPE_DICTIONARY and extras.has("alien_ocean")}
	print("IMPORT ", JSON.stringify(report))
	cam = Camera3D.new(); cam.fov = 26.0; cam.near = radius * 0.01; cam.far = radius * 20.0; root.add_child(cam); cam.current = true
	for v in VIEWS: jobs.append(["view_" + v[0], "", 0.0, v[1], 0.6, Vector3.ZERO])
	var head := Vector3(aabb.position.x + aabb.size.x * 0.12, center.y, center.z)       # snout end is -X... set below from bones
	var jaw_peak := 0.5
	if ap and ap.has_animation("gape"): jaw_peak = ap.get_animation("gape").length * 0.5
	jobs.append(["jaw_q_below", "gape", jaw_peak, Vector3(-0.75, -0.35, 0.55), 0.38, Vector3.ZERO])
	jobs.append(["jaw_side", "gape", jaw_peak, Vector3(0, 0, 1), 0.42, Vector3.ZERO])
	jobs.append(["jaw_front", "gape", jaw_peak, Vector3(-1, -0.05, 0.02), 0.34, Vector3.ZERO])
	jobs.append(["jaw_rest_q_below", "", 0.0, Vector3(-0.75, -0.35, 0.55), 0.38, Vector3.ZERO])
	jobs.append(["flare_top", "flare", 0.5, Vector3(0, 1, 0.001), 0.32, Vector3.ZERO])
	jobs.append(["flare_rest_top", "", 0.0, Vector3(0, 1, 0.001), 0.32, Vector3.ZERO])
	var fps := 30.0; var k := 0
	# Godot's importer strips "_loop" and sets the loop flag: swim_loop arrives as "swim", breathe_loop as "breathe"
	for an in ["swim", "gape", "flare", "breathe"]:
		if not (ap and ap.has_animation(an)): continue
		var A: Animation = ap.get_animation(an); var L: float = A.length
		var dur: float = L * (3.0 if an == "swim" else (2.0 if an == "breathe" else 1.0))
		var n := int(ceil(dur * fps))
		for f in n:
			var t: float = fmod(f / fps, L) if A.loop_mode != Animation.LOOP_NONE else min(f / fps, L)
			jobs.append(["film/%04d" % k, an, t, Vector3(-0.6, 0.45, 0.65) if an != "flare" else Vector3(-0.35, 0.9, 0.25), 0.5 if an == "swim" else 0.34, Vector3.ZERO]); k += 1
	report["film_frames"] = k
	process_frame.connect(_tick)
	_next()

func _head_point() -> Vector3:
	for n in _all(scene):
		if n is Skeleton3D:
			var i: int = n.find_bone("jaw")
			if i >= 0: return n.global_transform * n.get_bone_global_pose(i).origin
	return center

func _next():
	j += 1
	if j >= jobs.size():
		var f := FileAccess.open(out + "/report.json", FileAccess.WRITE); f.store_string(JSON.stringify(report, " ")); f.close()
		print("DONE ", jobs.size()); quit(0); return
	var jb = jobs[j]
	if ap:
		if jb[1] != "": ap.play(jb[1]); ap.seek(jb[2], true); ap.pause()
		else: ap.stop(); _rest()
	var tgt := center
	if jb[0].begins_with("film/") and jb[1] != "swim": tgt = _head_point()
	if jb[0].begins_with("jaw") or jb[0].begins_with("flare"): tgt = _head_point()
	var d: Vector3 = jb[3].normalized()
	var dist: float = radius * jb[4] / tan(deg_to_rad(cam.fov * 0.5)) * 1.05
	cam.position = tgt + d * dist
	cam.look_at(tgt, Vector3(0, 0, -1) if abs(d.y) > 0.9 else Vector3.UP)
	wait = 3

func _rest():
	for n in _all(scene):
		if n is Skeleton3D: n.reset_bone_poses()

func _tick():
	wait -= 1
	if wait > 0: return
	var img := root.get_texture().get_image()
	img.save_png(out + "/" + jobs[j][0] + ".png")
	_next()
