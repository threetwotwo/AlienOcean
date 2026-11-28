## Grass field 0.1.0 (test level thread, 28 Nov 2026): replaces the lagoon's seagrass tile meshes (150k triangles each, 6 mm
## blades drawn with the rock shader: no sway, no light through the blades, sub-pixel noise far away) with instanced blades
## (look/seagrass.gdshader) planted on the tiles' own blade roots, so the meadows keep the dressing thread's layout.
## Pushers (the girl with a fading trail, fish near the meadow) bend the grass away; the shader keeps blade length.
## The tiles' swim-through soft volumes stay; only their drawing is swapped (visible = false), so set_enabled(false) is the
## old picture again (A/B, the test level's "grass_v2" switch).
class_name GrassField
extends Node3D

const SHADER := "res://look/seagrass.gdshader"
const PUSHERS := 24
const TRAIL_N := 12                 # girl trail samples (the grass closes back in behind her)
const TRAIL_DT := 0.08              # seconds between trail samples
const TRAIL_TAU := 0.6              # trail fade (s)
const FISH_N := 10
const BLADE_W := 0.012              # 12 mm ribbons: turtle grass is 4-12 mm; the wide end reads clean at half resolution
const FAR_SHARE := 0.125            # the far set holds one blade in 8 (the shader's thinning floor at thin_end)
const FISH_R := 12.0                # metres from the camera: only fish this near push grass

var material: ShaderMaterial
var material_far: ShaderMaterial    # the far set: same look, set_share = FAR_SHARE, no pushers
var tiles: Array = []               # [{src: MeshInstance3D, mmi: MultiMeshInstance3D, aabb: AABB, blades: int}]
var stats := {"tiles": 0, "blades": 0, "src_tris": 0, "tris": 0, "build_ms": 0.0}
var girl_fn = null                  # Callable() -> Vector3 (her centre); null = no girl
var girl_capsule_fn = null          # Callable() -> [centre, axis, half_len] (her body capsule); pushes at head, middle and feet
var current_dir := Vector2(0.8, 0.6)  # the meadow's comb direction (matches the shader's current_dir)
var seat_mask := 0xFFFFFFFF         # physics layers the root seating ray hits (the sand and dressing colliders)
var schools: Array = []             # FishSchool nodes (their _cur positions are world space)
var enabled := true
var _trail: Array = []              # [{p: Vector3, t: float}]
var _t := 0.0
var _last_sample := -1.0
var _rng := RandomNumberGenerator.new()
var _boxes: Array = []              # tile AABBs grown 0.3 m (fish test)
var _union := AABB()                # all of them

static func blade_mesh(segments := 4) -> ArrayMesh:
	## one blade, 1 m tall (scaled per instance), BLADE_W wide at the root tapering to a point; a slight natural curl forward.
	## UV.y = 0 root .. 1 tip (the shader's height share); UV.x = 0 / 1 on the two edges (pale leaf margins).
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows := []
	for i in segments + 1:
		var h := float(i) / segments
		var w := BLADE_W * (1.0 - 0.30 * h) * (1.0 if i < segments else 0.0)
		rows.append([h, w, 0.16 * h * h])
	for i in segments:
		var a: Array = rows[i]; var b: Array = rows[i + 1]
		var p0 := Vector3(-a[1] * 0.5, a[0], a[2]); var p1 := Vector3(a[1] * 0.5, a[0], a[2])
		var p2 := Vector3(-b[1] * 0.5, b[0], b[2]); var p3 := Vector3(b[1] * 0.5, b[0], b[2])
		for q in [[p0, a[0], 0.0], [p1, a[0], 1.0], [p2, b[0], 0.0], [p1, a[0], 1.0], [p3, b[0], 1.0], [p2, b[0], 0.0]]:
			st.set_normal(Vector3(0, 0, -1)); st.set_uv(Vector2(q[2], q[1])); st.add_vertex(q[0])
	st.index()                         # shared vertices: 10 per blade instead of 24 (vertex work, run in the depth pre-pass too)
	return st.commit()

func _ready() -> void:
	_rng.seed = 2811

## Swap every seagrass tile under root for instanced blades.
func adopt(root: Node) -> void:
	var t0 := Time.get_ticks_usec()
	if material == null:
		material = ShaderMaterial.new(); material.shader = load(SHADER)
	var blade := blade_mesh()
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		if not "seagrass" in String(mi.name).to_lower() or not mi.visible or mi.mesh == null: continue
		var roots := _roots(mi)
		if roots.is_empty(): continue
		# each root is a shoot of 1-2 leaves. Art direction (key frame v7c; Gary 28 Nov "too noisy"): the meadow reads as one
		# combed mass, every leaf facing and drooping down the current with small jitter, not a random criss-cross of spikes
		var cur := Vector2(current_dir.x, current_dir.y).normalized()
		var yaw_cur := atan2(cur.x, cur.y)             # the blade curls toward local +z; yaw so +z points down the current
		var leaves := []
		for r in roots:
			var p: Vector3 = r[0] + Vector3(_rng.randf_range(-0.015, 0.015), 0.0, _rng.randf_range(-0.015, 0.015))
			var L0: float = r[1] * (0.45 + 0.5 * pow(_rng.randf(), 0.6))  # skewed: many mid blades, few long, some short
			var yaw0 := yaw_cur + _rng.randf_range(-0.45, 0.45) + 0.35 * sin(p.x * 0.9 + 1.7 * sin(p.z * 0.7))   # slow swirls, no chaos
			var hue := clampf(0.5 + 0.35 * sin(p.x * 1.7 + 2.0 * sin(p.z * 1.3)) * cos(p.z * 1.1) + _rng.randf_range(-0.12, 0.12), 0.0, 1.0)
			var n := 1 if _rng.randf() < 0.55 else 2
			for k in n:
				var side := float(k) - (n - 1) * 0.5
				var L := L0 * (1.0 - 0.15 * absf(side)) * _rng.randf_range(0.9, 1.1)
				var b := Basis(Vector3.UP, yaw0 + side * 0.18 + _rng.randf_range(-0.08, 0.08)) * Basis(Vector3.RIGHT, _rng.randf_range(0.04, 0.16))
				leaves.append([Transform3D(b.scaled(Vector3(1.0, L, 1.0)), p + b.x * side * 0.006), r[2], Color(_rng.randf() * TAU, _rng.randf_range(0.8, 1.25), clampf(hue + _rng.randf_range(-0.05, 0.05), 0.0, 1.0), L)])
		var lo := Vector3.INF; var hi := -Vector3.INF
		for l in leaves:
			var o: Vector3 = (l[0] as Transform3D).origin
			lo = lo.min(o); hi = hi.max(o + Vector3(0, (l[2] as Color).a, 0))
		var box := AABB(lo - Vector3(0.5, 0.2, 0.5), hi - lo + Vector3(1.0, 0.4, 1.0))
		# near set (every blade) while any blade can be nearer than thin_end; far set (one in 8, widened by the shader) beyond.
		# Godot measures visibility range to the box centre, so the switch is pushed out by the box's half diagonal.
		var thin_end: float = material.get_shader_parameter("thin_end") if material.get_shader_parameter("thin_end") != null else 20.0
		var r_box := Vector2(box.size.x, box.size.z).length() * 0.5
		var far_leaves := []
		for i in leaves.size():
			if i % int(round(1.0 / FAR_SHARE)) == 0: far_leaves.append(leaves[i])
		var mmi := _mmi(String(mi.name) + "_blades", leaves, blade, material, box)
		mmi.visibility_range_end = thin_end + r_box
		var mmi_far := _mmi(String(mi.name) + "_blades_far", far_leaves, blade, material_far, box)
		mmi_far.visibility_range_begin = thin_end + r_box
		mi.visible = false
		var src_tris: int = mi.mesh.get_faces().size() / 3
		tiles.append({"src": mi, "mmi": mmi, "far": mmi_far, "aabb": mmi.custom_aabb, "blades": leaves.size(), "leaves": leaves, "seated": false})
		stats.tiles += 1; stats.blades += leaves.size(); stats.src_tris += src_tris; stats.tris += leaves.size() * 8
		var gb := mmi.custom_aabb.grow(0.3)
		_union = gb if _boxes.is_empty() else _union.merge(gb)
		_boxes.append(gb)
	stats.build_ms = (Time.get_ticks_usec() - t0) / 1000.0
	stats["seated"] = 0; stats["seat_moved_cm"] = 0.0; stats["seat_miss"] = 0
	print("GRASS ", stats)

func _mmi(nm: String, leaves: Array, blade: Mesh, mat: Material, box: AABB) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_custom_data = true; mm.use_colors = true; mm.mesh = blade
	mm.instance_count = leaves.size()
	for i in leaves.size():
		mm.set_instance_transform(i, leaves[i][0]); mm.set_instance_color(i, leaves[i][1]); mm.set_instance_custom_data(i, leaves[i][2])
	var mmi := MultiMeshInstance3D.new(); mmi.name = nm; mmi.multimesh = mm
	mmi.material_override = mat
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED   # SDFGI must not voxelize the meadow as a solid (darkened the girl)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # self-shade from the root AO; saves every shadow pass
	mmi.custom_aabb = box
	add_child(mmi)
	return mmi

## The tile's shoots: consecutive vertices further than 3 cm apart start a new piece (the tiles are written blade by blade);
## a piece's lowest vertex is a root, deduplicated on a 2.5 cm grid (a blade is often written as several pieces).
## Blade length comes from the tile as a whole (its 5th to 95th percentile height), since pieces are often only part of a blade.
## Returns [[root, length, colour]] (colour white when the tile has no vertex colours).
func _roots(mi: MeshInstance3D) -> Array:
	var out := []
	var xf := mi.global_transform
	var seen := {}
	for s in mi.mesh.get_surface_count():
		var arrs: Array = mi.mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrs[Mesh.ARRAY_VERTEX]
		var cols = arrs[Mesh.ARRAY_COLOR]          # the dressing's per-blade vertex colour, if the tile has one
		var n := v.size()
		if n == 0: continue
		var ys := PackedFloat32Array()
		for i in range(0, n, 7): ys.append(v[i].y)
		ys.sort()
		var tile_h := clampf((ys[int(ys.size() * 0.95)] - ys[int(ys.size() * 0.05)]) * xf.basis.get_scale().y, 0.15, 0.6)
		var start := 0
		for i in range(1, n + 1):
			if i < n and v[i].distance_squared_to(v[i - 1]) < 0.0009: continue
			var lo := v[start]
			var csum := Color(0, 0, 0, 0)
			for k in range(start, i):
				if v[k].y < lo.y: lo = v[k]
				if cols is PackedColorArray and cols.size() == n: csum += cols[k]
			var col := Color(1, 1, 1) if csum.a <= 0.0 else Color(csum.r / csum.a, csum.g / csum.a, csum.b / csum.a)
			start = i
			var w := xf * lo
			var key := Vector2i(int(floor(w.x / 0.025)), int(floor(w.z / 0.025)))
			if seen.has(key): continue
			seen[key] = true
			out.append([w, tile_h, col])
	# seat on the ground: a piece's lowest vertex is the root only if the piece reaches the sand; pieces that are the upper part
	# of a blade float (Gary 28 Nov: "they are floating"). The tiles' blades stand on the sand, so the lowest vertex within a
	# 30 cm cell and its 8 neighbours is the ground there. The physics ray in seat_on_ground() refines this once colliders exist.
	var gmin := {}
	for r in out:
		var c := Vector2i(int(floor(r[0].x / 0.3)), int(floor(r[0].z / 0.3)))
		gmin[c] = minf(gmin.get(c, INF), r[0].y)
	for r in out:
		var c := Vector2i(int(floor(r[0].x / 0.3)), int(floor(r[0].z / 0.3)))
		var g: float = r[0].y
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				g = minf(g, gmin.get(c + Vector2i(dx, dz), INF))
		r[0].y = maxf(g, r[0].y - 0.5) - 0.02            # 2 cm into the sand
	# local density on a 20 cm grid: blade length follows it (meadow edges short and sparse, the core tall), no flat hedge top
	var cnt := {}
	for r in out:
		var c := Vector2i(int(floor(r[0].x / 0.2)), int(floor(r[0].z / 0.2)))
		cnt[c] = cnt.get(c, 0) + 1
	var vals := cnt.values(); vals.sort()
	var med: float = max(1.0, float(vals[int(vals.size() * 0.75)])) if vals.size() > 0 else 1.0
	for r in out:
		var c := Vector2i(int(floor(r[0].x / 0.2)), int(floor(r[0].z / 0.2)))
		r[1] = r[1] * clampf(0.3 + 0.75 * float(cnt[c]) / med, 0.3, 1.05)
	return out

## Seat every blade on the collider below it (one tile per physics frame, once): a ray from 40 cm above the root down to
## 60 cm below; a hit within that window moves the root to the hit, 2 cm into the sand. Misses keep the grid seat.
func _physics_process(_dt: float) -> void:
	for t in tiles:
		if t.seated: continue
		t.seated = true
		var space := get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.new(); q.collision_mask = seat_mask; q.hit_back_faces = false
		var leaves: Array = t.leaves
		var moved := 0.0; var hits := 0; var dy := 0.0
		var cache := {}
		for l in leaves:
			var xf: Transform3D = l[0]
			var key := Vector2i(int(floor(xf.origin.x / 0.02)), int(floor(xf.origin.z / 0.02)))
			var y = cache.get(key)
			if y == null:
				q.from = xf.origin + Vector3(0, 0.4, 0); q.to = xf.origin - Vector3(0, 0.6, 0)
				var h := space.intersect_ray(q)
				y = (h.position.y - 0.02) if not h.is_empty() else NAN
				cache[key] = y
			if is_nan(y): stats.seat_miss += 1; continue
			moved += absf(float(y) - xf.origin.y); dy += float(y) - xf.origin.y; hits += 1
			xf.origin.y = y; l[0] = xf
		_rebuild(t)
		stats.seated += hits
		stats["seat_dy_cm"] = snappedf((float(stats.get("seat_dy_cm", 0.0)) * (stats.seated - hits) + dy * 100.0) / maxf(stats.seated, 1), 0.01)   # + = moved up
		stats.seat_moved_cm = snappedf((stats.seat_moved_cm * (stats.seated - hits) + moved * 100.0) / maxf(stats.seated, 1), 0.01)
		return

func _rebuild(t: Dictionary) -> void:
	var leaves: Array = t.leaves
	var mm: MultiMesh = t.mmi.multimesh
	for i in leaves.size(): mm.set_instance_transform(i, leaves[i][0])
	var step := int(round(1.0 / FAR_SHARE))
	var mf: MultiMesh = t.far.multimesh
	for j in mf.instance_count: mf.set_instance_transform(j, leaves[j * step][0])

func set_enabled(on: bool) -> void:
	enabled = on
	for t in tiles:
		t.mmi.visible = on
		t.far.visible = on
		t.src.visible = not on

func _process(delta: float) -> void:
	if not enabled or material == null: return
	var tp := Time.get_ticks_usec()
	_t += delta
	var arr := []
	# the girl now and her fading trail
	if girl_fn != null:
		var g: Vector3 = girl_fn.call()
		if _t - _last_sample >= TRAIL_DT:
			_trail.push_front({"p": g, "t": _t}); _last_sample = _t
			if _trail.size() > TRAIL_N: _trail.pop_back()
		if girl_capsule_fn != null:
			# her whole body bends the grass: head, middle and feet along her capsule (she lies flat when swimming)
			var cap: Array = girl_capsule_fn.call()
			var ax: Vector3 = cap[1]; var hl: float = cap[2]
			for f in [-1.0, 0.0, 1.0]:
				var q: Vector3 = (cap[0] as Vector3) + ax * hl * f
				arr.append(Vector4(q.x, q.y - 0.1, q.z, 0.5))
		else:
			arr.append(Vector4(g.x, g.y - 0.15, g.z, 0.5))
		for s in _trail:
			var w := 0.4 * exp(-(_t - float(s.t)) / TRAIL_TAU)
			if w > 0.03: arr.append(Vector4(s.p.x, s.p.y - 0.15, s.p.z, w))
	# fish inside a meadow's box, nearest the camera first
	var cam := get_viewport().get_camera_3d()
	var cp := cam.global_position if cam else Vector3.ZERO
	# cheap tests first: near the camera (a pushed blade further than FISH_R is not seen moving), then the meadows' union box,
	# then each tile's box (precomputed, grown). The old loop tested every fish against every tile: thousands of AABB tests a frame.
	var fish := []
	var r2 := FISH_R * FISH_R
	for sc in schools:
		if not is_instance_valid(sc) or not "_cur" in sc: continue
		var cur: PackedVector3Array = sc._cur
		for p in cur:
			if p.distance_squared_to(cp) > r2 or not _union.has_point(p): continue
			for b in _boxes:
				if (b as AABB).has_point(p):
					fish.append(p); break
	fish.sort_custom(func(a, b): return a.distance_squared_to(cp) < b.distance_squared_to(cp))
	for i in mini(fish.size(), FISH_N):
		arr.append(Vector4(fish[i].x, fish[i].y, fish[i].z, 0.18))
	while arr.size() < PUSHERS: arr.append(Vector4.ZERO)
	arr.resize(PUSHERS)
	material.set_shader_parameter("pushers", PackedVector4Array(arr))
	# bounding sphere of the active pushers (most blades are far from all of them and skip the per-pusher loop)
	var lo := Vector3.INF; var hi := -Vector3.INF; var rmax := 0.0
	for v in arr:
		if v.w <= 0.0: continue
		lo = lo.min(Vector3(v.x, v.y, v.z)); hi = hi.max(Vector3(v.x, v.y, v.z)); rmax = maxf(rmax, v.w)
	if rmax > 0.0:
		var c := (lo + hi) * 0.5
		material.set_shader_parameter("push_bound", Vector4(c.x, c.y, c.z, (hi - lo).length() * 0.5 + rmax))
	else:
		material.set_shader_parameter("push_bound", Vector4(0, -1e6, 0, 0))
	stats["process_ms"] = snappedf(lerpf(float(stats.get("process_ms", 0.0)), (Time.get_ticks_usec() - tp) / 1000.0, 0.1), 0.001)
