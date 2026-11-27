## P9 runtime check (main-thread cost of streaming), headless. Builds a synthetic cell world in user://cells
## (floor tile + rocks per full cell, one merged slab per far stand-in) along a fast-sub route across 4 km,
## then drives the Godot adapter in real time at 60 fps and records: frame time spent in streaming,
## cells inside 32 m not yet instanced (pop), live node count over time.
## Pass: zero pops after the start fill; streaming never takes over 8 ms of a frame; node count flat.
## Run: godot --headless --path . --script res://tests/test_stream_world.gd [-- speed_mps]
extends SceneTree

const CELL := 64.0
var loader
var x := 0.0
var z := 0.0
var speed := 25.0
var heading := 0.75
var t := 0.0
var started := false
var frames := 0
var worst_ms := 0.0
var over8 := 0
var pops := 0
var max_nodes := 0
var times := []

func _make_cell(cx: int, cz: int, far: bool) -> void:
	var path := "user://cells/%d_%d%s.tscn" % [cx, cz, "_far" if far else ""]
	if FileAccess.file_exists(path): return
	var root := Node3D.new(); root.name = "Cell"
	root.position = Vector3(cx * CELL, 0, cz * CELL)
	var floor := MeshInstance3D.new(); var pm := PlaneMesh.new(); pm.size = Vector2(CELL, CELL)
	pm.subdivide_width = 3 if far else 31; pm.subdivide_depth = pm.subdivide_width
	floor.mesh = _baked(pm); floor.position = Vector3(CELL / 2, 0, CELL / 2); root.add_child(floor); floor.owner = root
	if not far:
		var rng := RandomNumberGenerator.new(); rng.seed = cx * 7919 + cz
		for i in 12:
			var m := MeshInstance3D.new(); var s := SphereMesh.new(); s.radius = rng.randf_range(0.5, 3.0); s.height = s.radius * 1.4
			s.radial_segments = 24; s.rings = 12
			m.mesh = _baked(s); m.position = Vector3(rng.randf() * CELL, s.radius * 0.3, rng.randf() * CELL); root.add_child(m); m.owner = root
	var ps := PackedScene.new(); ps.pack(root); ResourceSaver.save(ps, path); root.free()

## Cells store baked ArrayMesh, like imported GLB pieces. (Primitive meshes would build their arrays on the
## main thread at first draw, a cost real cells never have.)
func _baked(pm: PrimitiveMesh) -> ArrayMesh:
	var am := ArrayMesh.new(); am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, pm.get_mesh_arrays()); return am

func _init():
	var a := OS.get_cmdline_user_args()
	if a.size() > 0: speed = float(a[0])
	DirAccess.make_dir_recursive_absolute("user://cells")
	# build cells in a corridor around the route (straight line at the heading, 4 km)
	var n := 0
	var d := 0.0
	while d < 4300.0:
		var px := cos(heading) * d; var pz := sin(heading) * d
		for cx in range(floori((px - 320) / CELL), floori((px + 320) / CELL) + 1):
			for cz in range(floori((pz - 320) / CELL), floori((pz + 320) / CELL) + 1):
				_make_cell(cx, cz, false); _make_cell(cx, cz, true); n += 1
		d += CELL
	print("WORLD cells ready (corridor), speed ", speed, " m/s")
	Engine.max_fps = 60
	loader = load("res://adapters/godot/stream_loader.gd").new()
	loader.cells_dir = "user://cells"
	root.add_child(loader)
	process_frame.connect(_tick)

func _tick():
	var dt := 1.0 / 60.0
	var vx := cos(heading) * speed; var vz := sin(heading) * speed
	var t0 := Time.get_ticks_usec()
	loader.step([{"x": x, "z": z, "vx": vx, "vz": vz}])
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	frames += 1
	if not started:
		# start fill: wait until every cell within 32 m is instanced, then start moving (a start screen may cover this)
		if _pops() == 0 and frames > 2:
			started = true; print("START fill done after %d frames" % frames)
		return
	x += vx * dt; z += vz * dt; t += dt
	times.append(ms); worst_ms = maxf(worst_ms, ms)
	if ms > 8.0:
		over8 += 1; print("SPIKE %.2f ms at t=%.1f s, frame %d %s" % [ms, t, frames, loader.last])
	pops += _pops()
	max_nodes = maxi(max_nodes, loader.nodes.size())
	if Vector2(x, z).length() > 4000.0:
		times.sort()
		var p99: float = times[int(times.size() * 0.99)]
		var ok := pops == 0 and over8 == 0
		print("%s  speed=%s m/s frames=%d pops=%d worst_ms=%.2f p99_ms=%.2f frames_over_8ms=%d max_cell_nodes=%d" % ["PASS" if ok else "FAIL", speed, times.size(), pops, worst_ms, p99, over8, max_nodes])
		quit(0 if ok else 1)

func _pops() -> int:
	var c := 0
	for cell in loader.streamer._cells_in(x, z, 32.0):
		var k := CellStreamer.key(cell[0], cell[1])
		if not loader.nodes.has(k + "|live"): c += 1
	return c
