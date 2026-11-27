## Turnaround renderer 0.1.0 (project rule: side, top, bottom, front, back, 3/4 above, 3/4 below).
## Loads any .glb at runtime (no editor import), frames it by its bounds, renders the 7 views and a contact sheet.
## Also reports what arrived: meshes, triangles, skeleton joints, vertex colour (COLOR_0) present. That is a P3 import check.
## Run (cloud): xvfb-run -a godot --path . --rendering-driver vulkan --script res://tools/turnaround.gd -- <in.glb> <out_dir> [size]
extends SceneTree

var views := [["side", Vector3(0, 0, 1)], ["top", Vector3(0, 1, 0.001)], ["bottom", Vector3(0, -1, 0.001)],
	["front", Vector3(1, 0, 0)], ["back", Vector3(-1, 0, 0)], ["q_above", Vector3(0.6, 0.55, 0.6)], ["q_below", Vector3(0.6, -0.55, 0.6)]]
var args: PackedStringArray
var cam: Camera3D
var root3d: Node3D
var center: Vector3
var radius: float
var i := -1
var wait := 0
var shots := []
var size := 640

func _init():
	args = OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: -- <in.glb> <out_dir> [size]"); quit(2); return
	if args.size() > 2: size = int(args[2])
	DirAccess.make_dir_recursive_absolute(args[1])
	root.size = Vector2i(size, size)
	process_frame.connect(_setup, CONNECT_ONE_SHOT)   # build once the tree is running (transforms need it)

func _setup():
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	if doc.append_from_file(args[0], st) != OK:
		print("FAIL could not read ", args[0]); quit(1); return
	var scene: Node = doc.generate_scene(st)
	root3d = Node3D.new(); root.add_child(root3d); root3d.add_child(scene)
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.82, 0.86, 0.88)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.7, 0.75, 0.8); e.ambient_light_energy = 0.5
	e.ssao_enabled = true; e.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.environment = e; root3d.add_child(env)
	var key := DirectionalLight3D.new(); key.rotation_degrees = Vector3(-50, 30, 0); key.light_energy = 1.6; root3d.add_child(key)
	var fill := DirectionalLight3D.new(); fill.rotation_degrees = Vector3(40, -150, 0); fill.light_energy = 0.4; root3d.add_child(fill)
	# report + bounds
	var aabb := AABB(); var first := true; var tris := 0; var meshes := 0; var color := false; var joints := 0
	for n in _all(scene):
		if n is MeshInstance3D and n.mesh:
			meshes += 1
			for s in n.mesh.get_surface_count():
				var a: Array = n.mesh.surface_get_arrays(s)
				var idx = a[Mesh.ARRAY_INDEX]
				tris += (idx.size() if idx else a[Mesh.ARRAY_VERTEX].size()) / 3
				if a[Mesh.ARRAY_COLOR] and a[Mesh.ARRAY_COLOR].size() > 0: color = true
				# Our COLOR_0 is DATA (R = fin thickness), not paint: never let it tint the surface.
				var m = n.get_active_material(s)
				if m is BaseMaterial3D: m.vertex_color_use_as_albedo = false
			var b: AABB = n.global_transform * n.mesh.get_aabb()
			aabb = b if first else aabb.merge(b); first = false
		if n is Skeleton3D: joints = maxi(joints, n.get_bone_count())
	center = aabb.get_center(); radius = aabb.size.length() * 0.5
	print("IMPORT meshes=%d triangles=%d joints=%d vertex_colour=%s size_m=%s" % [meshes, tris, joints, color, aabb.size])
	cam = Camera3D.new(); cam.fov = 30.0; cam.near = radius * 0.01; cam.far = radius * 20.0; root3d.add_child(cam); cam.current = true
	_next()

func _all(n: Node) -> Array:
	var out := [n]
	for c in n.get_children(): out += _all(c)
	return out

func _next():
	i += 1
	if i >= views.size():
		_sheet(); quit(0); return
	var d: Vector3 = views[i][1].normalized()
	cam.look_at_from_position(center + d * (radius / tan(deg_to_rad(cam.fov * 0.5)) * 0.8), center, Vector3.UP if absf(d.y) < 0.99 else Vector3.FORWARD)
	wait = 0

func _process(_dt):
	if cam == null or i < 0 or i >= views.size(): return false
	wait += 1
	if wait == 8:
		var img := root.get_texture().get_image()
		var p: String = args[1].path_join("%d_%s.png" % [i + 1, views[i][0]])
		img.save_png(p); shots.append(img); print("VIEW ", p)
		_next()
	return false

func _sheet():
	var cols := 4; var rows := 2; var w := size / 2
	var sheet := Image.create(cols * w, rows * w, false, Image.FORMAT_RGBA8); sheet.fill(Color(1, 1, 1))
	for k in shots.size():
		var im: Image = shots[k].duplicate(); im.convert(Image.FORMAT_RGBA8); im.resize(w, w)
		sheet.blit_rect(im, Rect2i(0, 0, w, w), Vector2i((k % cols) * w, (k / cols) * w))
	sheet.save_png(args[1].path_join("turnaround_sheet.png")); print("SHEET ", args[1].path_join("turnaround_sheet.png"))
