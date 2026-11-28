## Camera rock sweep 0.1.0 (test level thread): does the third-person lens end up inside or behind the lagoon's rocks?
## At every teleport the look turns a full circle at three pitches; each settled tick casts a ray from the girl's head
## to the lens (back faces count, so a lens inside a hollow trimesh rock is caught) and an inside test by up-ray parity.
## Run: godot --headless --fixed-fps 60 --path . --script res://tools/camera_rock_sweep.gd -- <out.json> [--no-probe]
extends SceneTree

var lvl: TestLevel

func _initialize() -> void:
	lvl = TestLevel.new(); root.add_child(lvl)
	_run.call_deferred()

func _run() -> void:
	while not lvl.ready_done: await process_frame
	var space := lvl.get_viewport().world_3d.direct_space_state
	var fault := "--no-probe" in OS.get_cmdline_user_args()    # planted fault: the spring arm off must be caught
	if fault: lvl.game.cam.probe_enabled = false
	var ex: Array[RID] = [lvl.game.girl.body.get_rid()]
	var rows := []
	var total := 0; var bad := 0
	for tp in lvl.teleports.size():
		lvl.teleport(tp)
		for i in 30: await physics_frame
		var hits := []
		for pi in [-0.5, -0.1, 0.4]:
			for k in 36:
				var cam = lvl.game.cam
				cam.yaw = wrapf(k * TAU / 36.0, -PI, PI); cam.pitch = pi
				for j in 10:
					cam.yaw = wrapf(k * TAU / 36.0, -PI, PI); cam.pitch = pi
					await physics_frame
				var head: Vector3 = cam.last_frame.head_pos
				var lens: Vector3 = cam.global_position
				var q := PhysicsRayQueryParameters3D.create(head, lens); q.exclude = ex; q.hit_back_faces = true
				q.collide_with_areas = false
				var h := space.intersect_ray(q)
				total += 1
				if not h.is_empty():
					bad += 1
					hits.append({"yaw_deg": k * 10, "pitch": pi, "lens": [snappedf(lens.x, 0.01), snappedf(lens.y, 0.01), snappedf(lens.z, 0.01)],
						"hit": str(h.collider.get_parent().name if h.collider else "?"), "depth_m": snappedf(h.position.distance_to(lens), 0.01)})
		rows.append({"teleport": tp, "where": lvl.where(), "blocked": hits.size(), "of": 108, "hits": hits.slice(0, 8)})
		print("CAMSWEEP tp %d blocked %d/108 %s" % [tp, hits.size(), str(hits.slice(0, 3))])
	var res := {"blocked": bad, "of": total, "fault": fault, "rows": rows}
	print("CAMSWEEP total blocked %d of %d" % [bad, total])
	var a := OS.get_cmdline_user_args()
	if a.size() > 0 and not a[0].begins_with("--"):
		var f := FileAccess.open(a[0], FileAccess.WRITE); f.store_string(JSON.stringify(res, " ")); f.close()
	quit()
