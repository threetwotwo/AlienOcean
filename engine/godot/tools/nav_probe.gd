## Nav probe 0.1.0 (game root thread, 27 Nov 2026): does Godot's built-in Recast navigation (NavigationServer3D) work on the
## real lagoon, and what does it cost? Builds the GameRoot lagoon (pieces + the authored key-frame place), bakes one
## navigation mesh from its collision for a walker the girl's size (radius 0.3 m, height 1.38 m, step 0.35 m, slope 40 deg),
## then asks for paths between seeded random floor points. Prints bake ms, polygons, path success and query ms.
## Run: godot --headless --path . --script res://tools/nav_probe.gd -- <pieces_dir> <dress_pieces_dir> [queries]
extends SceneTree

var g: GameRoot
var queries := 200

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 2: queries = int(a[2])
	g = GameRoot.new()
	g.pieces_dir = a[0]; g.dress_manifest = "res://world_dress/lagoon_keyframe.json"; g.dress_pieces = a[1]
	g.use_camera = false; g.use_sea = false; g.with_mannequin = false
	g.input_source = func(_t): return preload("res://core/m01_input/input_packet.gd").new()
	root.add_child.call_deferred(g)
	g.ready.connect(_go)

func _go() -> void:
	await physics_frame; await physics_frame
	print("DRESS ", g.seat_dress())
	var nm := NavigationMesh.new()
	nm.agent_radius = 0.3; nm.agent_height = 1.38; nm.agent_max_climb = 0.35; nm.agent_max_slope = 40.0
	nm.cell_size = 0.15; nm.cell_height = 0.05
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	var src := NavigationMeshSourceGeometryData3D.new()
	var t0 := Time.get_ticks_usec()
	NavigationServer3D.parse_source_geometry_data(nm, src, g.lagoon)
	var t1 := Time.get_ticks_usec()
	NavigationServer3D.bake_from_source_geometry_data(nm, src)
	var t2 := Time.get_ticks_usec()
	print("NAV parse %.0f ms, bake %.0f ms, polygons %d, vertices %d" % [(t1 - t0) / 1000.0, (t2 - t1) / 1000.0, nm.get_polygon_count(), nm.vertices.size()])
	var map := NavigationServer3D.map_create(); NavigationServer3D.map_set_active(map, true)
	NavigationServer3D.map_set_cell_size(map, nm.cell_size); NavigationServer3D.map_set_cell_height(map, nm.cell_height)
	var reg := NavigationServer3D.region_create(); NavigationServer3D.region_set_map(reg, map)
	NavigationServer3D.region_set_navigation_mesh(reg, nm)
	NavigationServer3D.region_set_enabled(reg, true); NavigationServer3D.region_set_transform(reg, Transform3D.IDENTITY)
	for k in 10: await physics_frame   # the server syncs maps on its own step
	print("NAV map iteration ", NavigationServer3D.map_get_iteration_id(map))
	var bb := AABB()
	for i in nm.vertices.size():
		var v: Vector3 = nm.vertices[i]
		bb = AABB(v, Vector3.ZERO) if i == 0 else bb.expand(v)
	print("NAV covers ", bb)
	var rng := RandomNumberGenerator.new(); rng.seed = 11
	var ok := 0; var total_ms := 0.0; var worst := 0.0; var lens := 0.0
	for q in queries:
		var p0 := NavigationServer3D.map_get_closest_point(map, Vector3(rng.randf_range(bb.position.x, bb.end.x), 0.5, rng.randf_range(bb.position.z, bb.end.z)))
		var p1 := NavigationServer3D.map_get_closest_point(map, Vector3(rng.randf_range(bb.position.x, bb.end.x), 0.5, rng.randf_range(bb.position.z, bb.end.z)))
		var tq := Time.get_ticks_usec()
		var path := NavigationServer3D.map_get_path(map, p0, p1, true)
		var ms := (Time.get_ticks_usec() - tq) / 1000.0
		total_ms += ms; worst = maxf(worst, ms)
		if path.size() >= 2 and path[path.size() - 1].distance_to(p1) < 0.5:
			ok += 1
			for k in path.size() - 1: lens += path[k].distance_to(path[k + 1])
	print("NAV paths %d/%d reach their goal, mean %.3f ms, worst %.3f ms, mean length %.1f m" % [ok, queries, total_ms / queries, worst, lens / maxf(ok, 1)])
	quit(0)
