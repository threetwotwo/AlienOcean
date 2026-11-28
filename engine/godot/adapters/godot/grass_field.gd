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

var material: ShaderMaterial
var tiles: Array = []               # [{src: MeshInstance3D, mmi: MultiMeshInstance3D, aabb: AABB, blades: int}]
var stats := {"tiles": 0, "blades": 0, "src_tris": 0, "tris": 0, "build_ms": 0.0}
var girl_fn = null                  # Callable() -> Vector3 (her centre); null = no girl
var schools: Array = []             # FishSchool nodes (their _cur positions are world space)
var enabled := true
var _trail: Array = []              # [{p: Vector3, t: float}]
var _t := 0.0
var _last_sample := -1.0
var _rng := RandomNumberGenerator.new()

static func blade_mesh(segments := 4) -> ArrayMesh:
	## one blade, 1 m tall (scaled per instance), 8 mm wide at the root tapering to a point; a slight natural curl forward.
	## UV.y = 0 root .. 1 tip (the shader's height share).
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows := []
	for i in segments + 1:
		var h := float(i) / segments
		var w := 0.008 * (1.0 - 0.35 * h) * (1.0 if i < segments else 0.0)
		rows.append([h, w, 0.08 * h * h])
	for i in segments:
		var a: Array = rows[i]; var b: Array = rows[i + 1]
		var p0 := Vector3(-a[1] * 0.5, a[0], a[2]); var p1 := Vector3(a[1] * 0.5, a[0], a[2])
		var p2 := Vector3(-b[1] * 0.5, b[0], b[2]); var p3 := Vector3(b[1] * 0.5, b[0], b[2])
		for q in [[p0, a[0]], [p1, a[0]], [p2, b[0]], [p1, a[0]], [p3, b[0]], [p2, b[0]]]:
			st.set_normal(Vector3(0, 0, -1)); st.set_uv(Vector2(0.5, q[1])); st.add_vertex(q[0])
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
		# each root is a shoot of 2-4 leaves fanning from one point (turtle grass grows this way), longest in the middle
		var leaves := []
		for r in roots:
			var p: Vector3 = r[0] + Vector3(_rng.randf_range(-0.015, 0.015), 0.0, _rng.randf_range(-0.015, 0.015))
			var L0: float = r[1] * _rng.randf_range(0.8, 1.25)
			var yaw0 := _rng.randf() * TAU
			var hue := clampf(0.5 + 0.35 * sin(p.x * 1.7 + 2.0 * sin(p.z * 1.3)) * cos(p.z * 1.1) + _rng.randf_range(-0.12, 0.12), 0.0, 1.0)
			var n := _rng.randi_range(2, 4)
			for k in n:
				var side := float(k) - (n - 1) * 0.5
				var L := L0 * (1.0 - 0.18 * absf(side)) * _rng.randf_range(0.9, 1.1)
				var b := Basis(Vector3.UP, yaw0 + side * 0.35 + _rng.randf_range(-0.15, 0.15)) * Basis(Vector3.RIGHT, -side * 0.12 + _rng.randf_range(-0.08, 0.08))
				leaves.append([Transform3D(b.scaled(Vector3(1.0, L, 1.0)), p + b.x * side * 0.004), Color(_rng.randf() * TAU, _rng.randf_range(0.7, 1.4), clampf(hue + _rng.randf_range(-0.05, 0.05), 0.0, 1.0), L)])
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_custom_data = true; mm.mesh = blade
		mm.instance_count = leaves.size()
		var lo := Vector3.INF; var hi := -Vector3.INF
		for i in leaves.size():
			mm.set_instance_transform(i, leaves[i][0]); mm.set_instance_custom_data(i, leaves[i][1])
			var o: Vector3 = (leaves[i][0] as Transform3D).origin
			lo = lo.min(o); hi = hi.max(o + Vector3(0, (leaves[i][1] as Color).a, 0))
		var mmi := MultiMeshInstance3D.new(); mmi.name = String(mi.name) + "_blades"; mmi.multimesh = mm
		mmi.material_override = material
		mmi.custom_aabb = AABB(lo - Vector3(0.5, 0.2, 0.5), hi - lo + Vector3(1.0, 0.4, 1.0))
		add_child(mmi)
		mi.visible = false
		var src_tris: int = mi.mesh.get_faces().size() / 3
		tiles.append({"src": mi, "mmi": mmi, "aabb": mmi.custom_aabb, "blades": leaves.size()})
		stats.tiles += 1; stats.blades += leaves.size(); stats.src_tris += src_tris; stats.tris += leaves.size() * 8
	stats.build_ms = (Time.get_ticks_usec() - t0) / 1000.0
	print("GRASS ", stats)

## The tile's blades: consecutive vertices further than 3 cm apart start a new blade (the tiles are written blade by blade);
## a blade's root is its lowest vertex, its length the reach from the root to its furthest vertex. Returns [[root, length]].
func _roots(mi: MeshInstance3D) -> Array:
	var out := []
	var xf := mi.global_transform
	for s in mi.mesh.get_surface_count():
		var v: PackedVector3Array = mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		var n := v.size()
		if n == 0: continue
		var start := 0
		for i in range(1, n + 1):
			if i < n and v[i].distance_squared_to(v[i - 1]) < 0.0009: continue
			# blade [start, i)
			var lo := v[start]
			for k in range(start, i):
				if v[k].y < lo.y: lo = v[k]
			var reach := 0.0
			for k in range(start, i, 2):
				reach = maxf(reach, v[k].distance_to(lo))
			if reach > 0.04:
				out.append([xf * lo, reach * xf.basis.get_scale().y])
			start = i
	return out

func set_enabled(on: bool) -> void:
	enabled = on
	for t in tiles:
		t.mmi.visible = on
		t.src.visible = not on

func _process(delta: float) -> void:
	if not enabled or material == null: return
	_t += delta
	var arr := []
	# the girl now and her fading trail
	if girl_fn != null:
		var g: Vector3 = girl_fn.call()
		if _t - _last_sample >= TRAIL_DT:
			_trail.push_front({"p": g, "t": _t}); _last_sample = _t
			if _trail.size() > TRAIL_N: _trail.pop_back()
		arr.append(Vector4(g.x, g.y - 0.15, g.z, 0.45))
		for s in _trail:
			var w := 0.4 * exp(-(_t - float(s.t)) / TRAIL_TAU)
			if w > 0.03: arr.append(Vector4(s.p.x, s.p.y - 0.15, s.p.z, w))
	# fish inside a meadow's box, nearest the camera first
	var cam := get_viewport().get_camera_3d()
	var cp := cam.global_position if cam else Vector3.ZERO
	var fish := []
	for sc in schools:
		if not is_instance_valid(sc) or not "_cur" in sc: continue
		var cur: PackedVector3Array = sc._cur
		for p in cur:
			for t in tiles:
				if (t.aabb as AABB).grow(0.3).has_point(p):
					fish.append(p); break
	fish.sort_custom(func(a, b): return a.distance_squared_to(cp) < b.distance_squared_to(cp))
	for i in mini(fish.size(), FISH_N):
		arr.append(Vector4(fish[i].x, fish[i].y, fish[i].z, 0.18))
	while arr.size() < PUSHERS: arr.append(Vector4.ZERO)
	arr.resize(PUSHERS)
	material.set_shader_parameter("pushers", PackedVector4Array(arr))
