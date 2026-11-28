## Island terrain 0.1.0 (adapters/godot; water surface thread, 28 Nov 2026): the eroded atoll from the World Sketch /
## erosion work (world/erosion/handover: rec500's island grown by erosion/1, bake 29; 600 m at 1 m, and the sunken
## volcano's flank round it, 3.2 km at 8 m) as drawn seabed, the "real ground" case of the reef drop-off stress test
## (Gary: "refer to earlier work regarding erosion/world sketch stuff ... a simple world is sufficient, but with
## rigourous cases for stress testing"). The analytic sectors (core/world/bathymetry.gd) are the clean cases; this is
## the messy one: chutes cut through the wall, scree fans, old shorelines at Maldives depths, a blue hole.
## Reads <dir>/island.json (format alien-ocean/height-grid/1: int16 grids, row = +z, made from the bake by
## plans/water_surface/reef_nov28/island_to_godot.py) and draws the island at 2 m and the flank at 16 m. The flank was
## eroded deeper than the island's edge (30-80 m at the square's border), so within 150 m of the square it is eased onto
## the island's edge. Placed with `origin` (where the island frame's 0, 0 goes, Godot x z) so the drawn floor tiles sit
## on its 4 m platform; under them it dips DIP m as ReefTerrain does. Paint and material as ReefTerrain.
class_name IslandTerrain
extends Node3D

const DIP := 0.4
const ISLAND_STEP := 2          # draw every 2nd island cell (2 m)
const FLANK_STEP := 2           # and every 2nd flank cell (16 m)
const EASE_M := 150.0

var surface_y := 4.0
var origin := Vector2(-75.0, -100.0)     # the island frame's 0, 0 in Godot x z (puts the drawn tiles on its 4 m platform)
var keep_under := Rect2(-51.0, -51.0, 102.0, 102.0)
var grids := []                          # [{nx, nz, cell, x0, z0, h: PackedFloat32Array}]

func load_grids(dir: String) -> bool:
	var meta = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("island.json")))
	if meta == null: push_error("IslandTerrain: no island.json in " + dir); return false
	for g in meta.grids:
		var buf := FileAccess.get_file_as_bytes(dir.path_join(g.file))
		var n := int(g.nx) * int(g.nz)
		if buf.size() != n * 2: push_error("IslandTerrain: %s is %d bytes, want %d" % [g.file, buf.size(), n * 2]); return false
		var h := PackedFloat32Array(); h.resize(n)
		for k in n: h[k] = buf.decode_s16(k * 2) * float(g.scale)
		grids.append({"nx": int(g.nx), "nz": int(g.nz), "cell": float(g.cell), "x0": float(g.x0), "z0": float(g.z0), "h": h})
	return grids.size() == 2

static func _sample(g: Dictionary, x: float, z: float) -> float:
	## bilinear height (m, sea level 0) in the island frame, clamped at the grid's edge
	var fx := clampf((x - g.x0) / g.cell, 0.0, g.nx - 1.001); var fz := clampf((z - g.z0) / g.cell, 0.0, g.nz - 1.001)
	var i := int(fx); var j := int(fz); var tx := fx - i; var tz := fz - j
	var h: PackedFloat32Array = g.h
	var a := lerpf(h[j * g.nx + i], h[j * g.nx + i + 1], tx)
	var b := lerpf(h[(j + 1) * g.nx + i], h[(j + 1) * g.nx + i + 1], tx)
	return lerpf(a, b, tz)

func height(x: float, z: float) -> float:
	## m above sea level at island-frame (x, z): the island inside its square, the flank eased onto it outside
	var isl: Dictionary = grids[0]
	var lo := Vector2(isl.x0, isl.z0); var hi: Vector2 = lo + Vector2(isl.nx - 1, isl.nz - 1) * isl.cell
	var cx := clampf(x, lo.x, hi.x); var cz := clampf(z, lo.y, hi.y)
	var d := Vector2(x - cx, z - cz).length()
	if d <= 0.0: return _sample(isl, x, z)
	var f := _sample(grids[1], x, z)
	var edge := _sample(isl, cx, cz) - _sample(grids[1], cx, cz)
	return f + edge * (1.0 - smoothstep(0.0, EASE_M, d))

func build(water_y: float) -> void:
	surface_y = water_y
	var isl: Dictionary = grids[0]; var fl: Dictionary = grids[1]
	var lo := Vector2(isl.x0, isl.z0); var hi: Vector2 = lo + Vector2(isl.nx - 1, isl.nz - 1) * isl.cell
	_mesh("IslandSeabed", lo, hi, isl.cell * ISLAND_STEP, Rect2())
	var flo := Vector2(fl.x0, fl.z0); var fhi: Vector2 = flo + Vector2(fl.nx - 1, fl.nz - 1) * fl.cell
	_mesh("IslandFlank", flo, fhi, fl.cell * FLANK_STEP, Rect2(lo, hi - lo).grow(-fl.cell * FLANK_STEP))   # the flank under the island cut out
	print("ISLAND grids %dx%d at %.0f m + %dx%d at %.0f m, origin %s" % [isl.nx, isl.nz, isl.cell, fl.nx, fl.nz, fl.cell, origin])

func _under(x: float, z: float) -> float:
	var dx := maxf(maxf(keep_under.position.x - x, x - keep_under.end.x), 0.0)
	var dz := maxf(maxf(keep_under.position.y - z, z - keep_under.end.y), 0.0)
	return 1.0 - clampf(maxf(dx, dz) / 4.0, 0.0, 1.0)

func _mesh(nm: String, lo: Vector2, hi: Vector2, step: float, hole: Rect2) -> void:
	var nx := int(floorf((hi.x - lo.x) / step)) + 1; var nz := int(floorf((hi.y - lo.y) / step)) + 1
	var pos := PackedVector3Array(); pos.resize(nx * nz)
	for j in nz:
		for i in nx:
			var x := lo.x + i * step; var z := lo.y + j * step
			var gx := x + origin.x; var gz := z + origin.y
			var y := surface_y + height(x, z)
			if hole.has_area() and hole.grow(step).has_point(Vector2(x, z)): y -= 3.0     # the flank's skirt under the island
			pos[j * nx + i] = Vector3(gx, y - DIP * _under(gx, gz), gz)
	var nrm := PackedVector3Array(); nrm.resize(pos.size())
	var col := PackedColorArray(); col.resize(pos.size())
	for j in nz:
		for i in nx:
			var a := pos[j * nx + mini(i + 1, nx - 1)] - pos[j * nx + maxi(i - 1, 0)]
			var b := pos[mini(j + 1, nz - 1) * nx + i] - pos[maxi(j - 1, 0) * nx + i]
			var n := b.cross(a).normalized()
			if n.y < 0.0: n = -n
			nrm[j * nx + i] = n
			col[j * nx + i] = _paint(pos[j * nx + i], n)
	var idx := PackedInt32Array()
	for j in nz - 1:
		for i in nx - 1:
			if hole.has_area() and hole.has_point(Vector2(lo.x + (i + 0.5) * step, lo.y + (j + 0.5) * step)): continue
			var a0 := j * nx + i; var a1 := a0 + 1; var b0 := a0 + nx; var b1 := b0 + 1
			idx.append_array([a0, a1, b0, a1, b1, b0])
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos; arr[Mesh.ARRAY_NORMAL] = nrm; arr[Mesh.ARRAY_COLOR] = col; arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new(); m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new(); mi.name = nm; mi.mesh = m
	var mat := ShaderMaterial.new(); mat.shader = load("res://look/seabed_surface.gdshader")
	mi.material_override = mat
	add_child(mi)
	var shape := ConcavePolygonShape3D.new(); shape.set_faces(m.get_faces())
	var sb := StaticBody3D.new(); sb.name = nm + "Collision"
	var cs := CollisionShape3D.new(); cs.shape = shape; sb.add_child(cs); add_child(sb)

func _paint(p: Vector3, n: Vector3) -> Color:
	## ReefTerrain's paint, everywhere a reef: sand on the flats, rubble and crust at the reef flat's depth, rock on the
	## steep, sediment settling on the deep slope
	var nz := 0.5 + 0.25 * sin(p.x * 0.37 + 1.3 * sin(p.z * 0.21)) + 0.25 * sin(p.z * 0.29 + 1.1 * sin(p.x * 0.17))
	var sand := ReefTerrain.SAND_D.lerp(ReefTerrain.SAND_C, clampf(nz, 0.0, 1.0))
	var steep := 1.0 - smoothstep(0.55, 0.85, n.y)
	var d := surface_y - p.y
	var flat := smoothstep(0.0, 1.0, d) * (1.0 - smoothstep(2.2, 3.4, d))
	var rubble := ReefTerrain.CRUST.lerp(ReefTerrain.ROCK, 0.5 + 0.5 * ReefTerrain._hash(floorf(p.x * 0.7), floorf(p.z * 0.7)))
	var c := sand
	c = c.lerp(rubble.lerp(sand, 0.35), flat)
	c = c.lerp(ReefTerrain.ROCK.lerp(ReefTerrain.ROCK_CREV, ReefTerrain._hash(floorf(p.x), floorf(p.z))), steep)
	c = c.lerp(sand * 0.8, smoothstep(40.0, 120.0, d) * (1.0 - steep * 0.5))
	if d < 0.0: c = ReefTerrain.SAND_C                    # dry land: bare sand for now
	return Color(c.x, c.y, c.z)
