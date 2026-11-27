## STAND-IN fish mesh for schools (not a creature asset): used only until the creature maker's fish glb for the species
## lands in assets/creatures/<species>/ (first: trevally). A fusiform body of revolution with a forked tail, dorsal,
## anal and pectoral fins and eyes, one body length long, head toward +x, centred on mid-body, y up, side = z.
## COLOR channels carry zones for the school shader: r = fin (0/1), g = eye (0/1), b = body position s (0 snout .. 1 tail).
## lod 0 ~ 700 triangles, lod 1 ~ 250, lod 2 ~ 60 (a few quads that keep the silhouette and the tail beat).
extends RefCounted

static func build(lod: int = 0, depth := 0.28, width := 0.12) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: int = [18, 10, 5][lod]
	var segs: int = [14, 8, 4][lod]
	var u_end := 0.86                  # body ends at the caudal peduncle; the tail fin carries on to 1.0
	var prof := func(u: float) -> Vector2:
		# half depth, half width along the body (u 0 snout .. u_end peduncle): blunt head, deepest at 0.33, slim peduncle
		var a := pow(clampf(u / 0.33, 0.0, 1.0), 0.55)
		var b := pow(clampf((u_end - u) / (u_end - 0.33), 0.0, 1.0), 1.1)
		var shape := a * (0.22 + 0.78 * b) if u > 0.33 else a
		return Vector2(depth * 0.5 * maxf(shape, 0.0) + 0.012, width * 0.5 * maxf(shape, 0.0) + 0.008)
	var grid := []
	for ri in rings + 1:
		var u: float = u_end * float(ri) / rings
		var pr: Vector2 = prof.call(u)
		var row := []
		for si in segs:
			var a: float = TAU * si / segs
			row.append(Vector3(0.5 - u, cos(a) * pr.x - 0.012 * u, sin(a) * pr.y))
		grid.append(row)
	for ri in rings:
		for si in segs:
			var a0: Vector3 = grid[ri][si]; var a1: Vector3 = grid[ri][(si + 1) % segs]
			var b0: Vector3 = grid[ri + 1][si]; var b1: Vector3 = grid[ri + 1][(si + 1) % segs]
			_tri(st, a0, b0, a1, 0.0, 0.0); _tri(st, a1, b0, b1, 0.0, 0.0)
	# snout and peduncle caps
	var tipf := Vector3(0.5 + 0.01, 0.0, 0.0)
	var tipb := Vector3(0.5 - u_end - 0.005, -0.012 * u_end, 0.0)
	for si in segs:
		_tri(st, tipf, grid[0][si], grid[0][(si + 1) % segs], 0.0, 0.0)
		_tri(st, tipb, grid[rings][(si + 1) % segs], grid[rings][si], 0.0, 0.0)
	# forked caudal fin (two lobes), dorsal, anal, pectorals: thin double-sided plates
	var xp := 0.5 - u_end + 0.02
	_fin(st, [Vector3(xp, 0.0, 0), Vector3(-0.5, depth * 0.62, 0), Vector3(-0.42, 0.02, 0)])
	_fin(st, [Vector3(xp, -0.02, 0), Vector3(-0.42, -0.02, 0), Vector3(-0.5, -depth * 0.58, 0)])
	_fin(st, [Vector3(0.12, depth * 0.47, 0), Vector3(-0.02, depth * 0.78, 0), Vector3(-0.2, depth * 0.36, 0)])
	_fin(st, [Vector3(-0.08, -depth * 0.40, 0), Vector3(-0.24, -depth * 0.32, 0), Vector3(-0.14, -depth * 0.58, 0)])
	if lod < 2:
		for sd in [-1.0, 1.0]:
			_fin(st, [Vector3(0.24, -0.03, sd * width * 0.42), Vector3(0.1, -0.06, sd * width * 0.95), Vector3(0.12, -0.02, sd * width * 0.5)])
		# eyes: a small disc each side, big and dark (readability first, Finding Nemo)
		var er := depth * 0.11
		var ec := Vector3(0.36, depth * 0.07, 0)
		var n_e := 8 if lod == 0 else 5
		for sd in [-1.0, 1.0]:
			var c := ec + Vector3(0, 0, sd * width * 0.42)
			for k in n_e:
				var a0 := TAU * k / n_e; var a1 := TAU * (k + 1) / n_e
				var p0 := c + Vector3(cos(a0) * er, sin(a0) * er, sd * 0.004)
				var p1 := c + Vector3(cos(a1) * er, sin(a1) * er, sd * 0.004)
				var cc := c + Vector3(0, 0, sd * 0.012)
				if sd > 0: _tri(st, cc, p0, p1, 0.0, 1.0)
				else: _tri(st, cc, p1, p0, 0.0, 1.0)
	st.generate_normals()
	return st.commit()

static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, fin: float, eye: float) -> void:
	for q in [a, b, c]:
		st.set_color(Color(fin, eye, clampf(0.5 - q.x, 0.0, 1.0), 1.0))
		st.add_vertex(q)

static func _fin(st: SurfaceTool, pts: Array) -> void:
	_tri(st, pts[0], pts[1], pts[2], 1.0, 0.0)
	_tri(st, pts[0], pts[2], pts[1], 1.0, 0.0)
