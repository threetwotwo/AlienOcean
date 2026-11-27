## Dress cell 0.1.0 (Dress the lagoon thread, 27 Nov 2026): builds an authored place (a dress manifest, world_dress/<name>.json) from
## world pieces (GLB, tools/lagoon_dress/export_pieces.py) into one node: meshes in the water-lit look/ material, collision from the
## pieces' own hulls, every item seated on the drawn ground. One node per place, so the cell streamer can load it as a cell.
## Layout is authored (the manifest); detail inside each piece is grown by its maker (reef kit, colony maker, meadow).
## Collision: <piece>_COL_<k> meshes -> convex shapes on a StaticBody3D; <piece>_TRI -> concave (static only); grass -> soft Area3D
## (swim-through, no blocking: the gameplay thread reads it for drag/sway). Keep-clear volumes are exported as Marker3D/Area3D for the
## school system and checked: no item may intrude (keep_clear_report()).
class_name DressCell
extends Node3D

const SEABED := "res://look/seabed_surface.gdshader"
var manifest: Dictionary = {}
var pieces_dir := ""
var ground_material: Material = null   # the floor's own material for sand skirts (ground_surface), else seabed + sand_lock
var anchor_xform := Transform3D.IDENTITY
var items: Array = []        # [{node, body, item, aabb}]
var cache := {}              # piece -> generated scene (template)
var stats := {"items": 0, "tris": 0, "hulls": 0, "concave": 0, "soft": 0, "missing": []}
var _seabed: ShaderMaterial
var _space: PhysicsDirectSpaceState3D = null
var _excl: Array = []
var _cam_ground := {}        # cam name -> [sand y under at, sand y under look] (seat() fills it)

static func load_manifest(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: push_warning("no dress manifest " + path); return {}
	return JSON.parse_string(f.get_as_text())

## key frame frame (x right, y forward, z up) -> godot local (x, z, -y)
static func kf(v: Array) -> Vector3:
	return Vector3(float(v[0]), float(v[2]) if v.size() > 2 else 0.0, -float(v[1]))

func to_world(v: Array) -> Vector3:
	return anchor_xform * kf(v)

func setup(manifest_path: String, pieces: String) -> void:
	manifest = load_manifest(manifest_path); pieces_dir = pieces
	name = String(manifest.get("name", "dress"))
	var a: Dictionary = manifest.get("anchor", {})
	var yaw := deg_to_rad(float(a.get("yaw_deg", 0.0)))
	if a.has("match_sun_hour"):   # turn the place so the sun stands where it stood in the key frame (relative to the key camera)
		var st := SkyClock.sky_state(float(a.match_sun_hour))
		var s := WorldRoot.to_godot(st.sun.dir)
		var k := kf(a.get("keyframe_sun", [0.0, 1.0, 1.0]))
		if Vector2(s.x, s.z).length() > 0.01 and Vector2(k.x, k.z).length() > 0.01:
			yaw = atan2(-s.z, s.x) - atan2(-k.z, k.x)
	anchor_xform = Transform3D(Basis(Vector3.UP, yaw), Vector3(float(a.get("x", 0.0)), 0.0, float(a.get("z", 0.0))))
	_seabed = ShaderMaterial.new(); _seabed.shader = load(SEABED)

func _template(p: String) -> Node3D:
	if cache.has(p): return cache[p]
	var path := pieces_dir.path_join(p + ".glb")
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	if not FileAccess.file_exists(path) or doc.append_from_file(path, st) != OK:
		stats.missing.append(p); cache[p] = null; return null
	cache[p] = doc.generate_scene(st)
	return cache[p]

func _material_for(kind: String) -> Material:
	if kind == "skirt":
		if ground_material: return ground_material
		var m := _seabed.duplicate(); m.set_shader_parameter("sand_lock", 1.0); return m
	return _seabed

## Builds every item (unseated: y from the manifest). Call seat() once the floor collision is in the physics space.
func build() -> void:
	for it in manifest.get("items", []):
		_add(it, String(it.p))
		if it.has("with"):   # companion pieces sharing the item's transform (sand skirt, rubble foot): one name or a list
			var w = it["with"]
			for q in (w if w is Array else [w]): _add(it, String(q))
	print("DRESS ", name, " ", stats)

func _kind(p: String) -> String:
	if p.begins_with("SB_Skirt"): return "skirt"
	if p.begins_with("SB_"): return "rock"
	if "seagrass" in p: return "grass"
	return "coral"

func _add(it: Dictionary, p: String) -> void:
	var tpl := _template(p)
	if tpl == null: return
	var kind := _kind(p)
	var inst := tpl.duplicate() as Node3D
	var holder := Node3D.new(); holder.name = "%s_%d" % [p, items.size()]
	var s := float(it.get("s", 1.0))
	holder.transform = Transform3D(anchor_xform.basis * Basis(Vector3.UP, float(it.get("rot", 0.0))).scaled(Vector3.ONE * s), to_world(it.at))
	add_child(holder)
	var body: CollisionObject3D = null
	if kind == "grass":
		body = Area3D.new(); body.monitoring = false; body.monitorable = true; body.set_meta("soft", true)
	else:
		body = StaticBody3D.new()
	body.name = "Body"; holder.add_child(body)
	var mat := _material_for(kind)
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		var n := String(mi.name)
		var xf: Transform3D = mi.transform   # pieces are exported flat (one level), mesh at its node transform
		if "_COL_" in n:
			var cs := CollisionShape3D.new(); var sh := ConvexPolygonShape3D.new(); sh.points = mi.mesh.get_faces()
			cs.shape = sh; cs.transform = xf; body.add_child(cs); stats.hulls += 1
		elif n.ends_with("_TRI"):
			var cs := CollisionShape3D.new(); var sh := ConcavePolygonShape3D.new(); sh.set_faces(mi.mesh.get_faces())
			cs.shape = sh; cs.transform = xf; body.add_child(cs); stats.concave += 1
		else:
			var vis := MeshInstance3D.new(); vis.name = n; vis.mesh = mi.mesh; vis.transform = xf
			for si in vis.mesh.get_surface_count(): vis.set_surface_override_material(si, mat)
			holder.add_child(vis); stats.tris += vis.mesh.get_faces().size() / 3
			if kind == "grass":   # soft volume: the tile's own box (swim-through)
				var cs := CollisionShape3D.new(); var bx := BoxShape3D.new(); var bb: AABB = vis.mesh.get_aabb()
				bx.size = bb.size; cs.shape = bx; cs.transform = xf * Transform3D(Basis(), bb.get_center()); body.add_child(cs); stats.soft += 1
	inst.free()
	items.append({"node": holder, "item": it, "kind": kind, "p": p})
	stats.items += 1

func _aabb_world(holder: Node3D) -> AABB:
	var out := AABB(); var first := true
	for mi in holder.get_children():
		if mi is MeshInstance3D:
			var bb: AABB = mi.global_transform * mi.get_aabb()
			out = bb if first else out.merge(bb); first = false
	return out

## Drops every item onto the ground under it. Items whose origin is their base (rocks, corals) are seated at the origin; tiles that
## keep their own offsets (meadow beds) are seated by their footprint's lowest point, 1.5 cm into the sand (habitat.seat_blades).
func seat(space: PhysicsDirectSpaceState3D, sink := 0.015) -> Dictionary:
	var rep := {"seated": 0, "no_ground": 0, "dy": []}
	for e in items:
		var h: Node3D = e.node
		var keep: bool = int(e.item.get("keep", 0)) == 1
		var probe: Vector3 = h.global_position
		var bb := _aabb_world(h)
		if keep: probe = bb.get_center()
		var q := PhysicsRayQueryParameters3D.create(Vector3(probe.x, 20.0, probe.z), Vector3(probe.x, -20.0, probe.z))
		q.collide_with_areas = false
		var excl := []
		for x in items: excl.append(x.node.get_node("Body").get_rid())
		q.exclude = excl
		var hit := space.intersect_ray(q)
		if hit.is_empty(): rep.no_ground += 1; continue
		var gy: float = hit.position.y
		var dy := (gy - sink - bb.position.y) if keep else (gy + float(e.item.at[2]) - h.global_position.y)
		h.global_position.y += dy; rep.seated += 1; rep.dy.append(snappedf(dy, 0.001))
	# cameras stand on the sand like the items: the key frame's heights (cam 1.05 m, look 0.58 m) are over ITS sand (z 0). r7: on the
	# drawn floor (0.17 m under the anchor here) an anchor-relative camera stood 1.22 m up, so the near corals sat ~7 % low in frame.
	var excl2 := []
	for x in items: excl2.append(x.node.get_node("Body").get_rid())
	for cn in manifest.get("cams", {}):
		var g := []
		for key in ["at", "look"]:
			var w := to_world(manifest.cams[cn][key])
			var q2 := PhysicsRayQueryParameters3D.create(Vector3(w.x, 20.0, w.z), Vector3(w.x, -20.0, w.z))
			q2.exclude = excl2; q2.collide_with_areas = false
			var hit2 := space.intersect_ray(q2)
			g.append(0.0 if hit2.is_empty() else float(hit2.position.y) - anchor_xform.origin.y)
		_cam_ground[cn] = g
	rep["cam_ground"] = _cam_ground
	_space = space; _excl = excl2
	return rep

## A key-frame point (x, y, z over the sand) in the world, its height over the drawn sand under it (after seat()).
func on_sand(v: Array) -> Vector3:
	var w := to_world(v)
	if _space == null: return w
	var q := PhysicsRayQueryParameters3D.create(Vector3(w.x, 20.0, w.z), Vector3(w.x, -20.0, w.z))
	q.exclude = _excl; q.collide_with_areas = false
	var hit := _space.intersect_ray(q)
	return w if hit.is_empty() else w + Vector3.UP * (float(hit.position.y) - anchor_xform.origin.y)

## No item may stand in a keep-clear volume (the school's space). Checked against the real collision (hulls), not boxes: an arch's
## box covers its own gate. Returns the intruders.
func keep_clear_report(space: PhysicsDirectSpaceState3D) -> Array:
	var bad := []
	for kc in manifest.get("keep_clear", []):
		if not kc.has("size"): continue
		var bx := BoxShape3D.new(); bx.size = Vector3(float(kc.size[0]), float(kc.size[2]), float(kc.size[1])) * 2.0
		var q := PhysicsShapeQueryParameters3D.new(); q.shape = bx
		q.transform = Transform3D(anchor_xform.basis * Basis(Vector3.UP, float(kc.get("heading", 0.0))), to_world(kc.at))
		q.collide_with_areas = true
		for hit in space.intersect_shape(q, 32):
			var n: Node = hit.collider
			bad.append([kc.what, String(n.get_parent().name)])
	return bad

func cam(name_: String) -> Array:
	var c: Dictionary = manifest.cams[name_]
	var g: Array = _cam_ground.get(name_, [0.0, 0.0])   # heights over the sand once seat() has run
	return [to_world(c.at) + Vector3.UP * g[0], to_world(c.look) + Vector3.UP * g[1], float(c.vfov)]
