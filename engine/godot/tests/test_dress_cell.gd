## Headless test for world_dress/dress_cell.gd (Dress the lagoon thread). Run: godot --headless --path . --script res://tests/test_dress_cell.gd
## Builds tiny synthetic pieces (a 1 m rock with one hull, a soft grass tile) and a floor 0.3 m below y=0, then checks:
## D1 every rock/coral item has blocking collision, grass is soft (Area3D) only; D2 every item is seated on the floor (rock base within
## 1 mm of the ground, grass tile's lowest point 1.5 cm into it); D3 the keep-clear volume is empty; D4 the key frame -> Godot axis map.
## Planted fault: a keep-clear volume moved onto the rock must be REPORTED (proves D3 can fail).
extends SceneTree

const DIR := "user://dress_test"
var fails := 0

func check(name: String, ok: bool, info := "") -> void:
	print("%s  %s %s" % ["PASS" if ok else "FAIL", name, info]); if not ok: fails += 1

func _box_mesh(size: Vector3, off := Vector3.ZERO) -> ArrayMesh:
	var bm := BoxMesh.new(); bm.size = size
	var arr := bm.get_mesh_arrays(); var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in v.size(): v[i] += off
	arr[Mesh.ARRAY_VERTEX] = v
	var m := ArrayMesh.new(); m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr); return m

func _write(name: String, parts: Dictionary) -> void:
	var root := Node3D.new(); root.name = name
	for n in parts:
		var mi := MeshInstance3D.new(); mi.name = n; mi.mesh = parts[n]; root.add_child(mi); mi.owner = root
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	doc.append_from_scene(root, st); doc.write_to_filesystem(st, ProjectSettings.globalize_path(DIR).path_join(name + ".glb")); root.free()

func _init():
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	_write("t_rock", {"t_rock": _box_mesh(Vector3(1, 1, 1), Vector3(0, 0.5, 0)), "t_rock_COL_00": _box_mesh(Vector3(1, 1, 1), Vector3(0, 0.5, 0))})
	_write("t_LG_seagrass", {"t_LG_seagrass": _box_mesh(Vector3(2, 0.3, 2), Vector3(5, 2.4, 0))})   # a tile far from its origin, 2.25 m up (as slice v24)
	var man := {"name": "t", "anchor": {"x": 10.0, "z": -4.0, "yaw_deg": 90.0}, "items": [
		{"p": "t_rock", "at": [0.0, 3.0, 0.0], "rot": 0.0}, {"p": "t_LG_seagrass", "at": [0.0, 0.0, 0.0], "keep": 1}],
		"keep_clear": [{"what": "school", "at": [0.0, 3.0, 2.5], "size": [0.5, 0.5, 0.4]}], "cams": {"k": {"at": [0.0, -2.0, 1.05], "look": [0.0, 3.0, 0.58], "vfov": 44}}}
	var f := FileAccess.open(DIR + "/t.json", FileAccess.WRITE); f.store_string(JSON.stringify(man)); f.close()
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run():
	var floor := StaticBody3D.new(); var cs := CollisionShape3D.new(); var bx := BoxShape3D.new(); bx.size = Vector3(200, 1, 200)
	cs.shape = bx; cs.position = Vector3(0, -0.8, 0); floor.add_child(cs); root.add_child(floor)   # ground top at y = -0.3
	var d := DressCell.new(); root.add_child(d); d.setup(DIR + "/t.json", ProjectSettings.globalize_path(DIR)); d.build()
	check("D4 axis map", DressCell.kf([1.0, 2.0, 3.0]).is_equal_approx(Vector3(1, 3, -2)))
	check("D1 pieces found", d.stats.missing.is_empty() and d.stats.items == 2, str(d.stats))
	var rock: Node3D = d.items[0].node; var grass: Node3D = d.items[1].node
	check("D1 rock blocks", rock.get_node("Body") is StaticBody3D and rock.get_node("Body").get_child_count() == 1 and d.stats.hulls == 1)
	check("D1 grass soft", grass.get_node("Body") is Area3D and d.stats.soft == 1)
	await physics_frame; await physics_frame
	var space := root.get_world_3d().direct_space_state
	var rep := d.seat(space)
	check("D2 all seated", rep.seated == 2 and rep.no_ground == 0, str(rep))
	check("D2 rock base on ground", absf(rock.global_position.y - (-0.3)) < 0.001, str(rock.global_position.y))
	check("D2 grass roots 1.5 cm in", absf(d._aabb_world(grass).position.y - (-0.315)) < 0.002, str(d._aabb_world(grass).position.y))
	var kc: Array = d.cam("k")
	check("D5 camera over the sand", absf(kc[0].y - (-0.3 + 1.05)) < 0.001 and absf(kc[1].y - (-0.3 + 0.58)) < 0.001, str(kc))
	await physics_frame
	check("D3 keep-clear empty", d.keep_clear_report(space).is_empty(), str(d.keep_clear_report(space)))
	d.manifest.keep_clear[0].at = [0.0, 3.0, 0.5]   # planted fault: the school volume inside the rock
	check("D3 planted fault caught", not d.keep_clear_report(space).is_empty())
	print("DRESS CELL ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails else 0)
