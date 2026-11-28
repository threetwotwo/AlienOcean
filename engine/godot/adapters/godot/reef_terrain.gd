## Reef terrain 0.1.0 (adapters/godot; water surface thread, 28 Nov 2026): the drawn seabed from the lagoon's edge out
## over the reef flat, down the drop-off and the fore-reef slope to the deep, built from core/world/bathymetry.gd (the
## water reads the same shape in look/sea_bathy.gdshaderinc, so seabed and water colour agree). Gary: "for lagoon,
## sculpt dropoffs to the deep open water, stress test the looks in the transitions."
## A polar mesh round the lagoon's centre: rings close together over the reef (1.25 m) and wider in the lagoon and the
## deep, ANGLES segments round. Under the drawn floor tiles (keep_under: a rect in x z) it dips DIP m below the tiles
## so the two never fight. Painted per vertex for look/seabed_surface.gdshader (COLOR = albedo): sand on the flats,
## coral rubble and crust on the reef flat, reef rock on the wall and in the spurs, sand settling in the grooves.
## Collision: a coarser copy of the reef zone (every other ring and segment), so the girl meets the wall.
## Stand-in for the dressed reef: the lagoon-dressing thread dresses it (corals, rock, rubble) like the key frame.
## Cost to watch on the Mac: ~150k vertices in one mesh (LOD rings later).
class_name ReefTerrain
extends Node3D

const ANGLES := 768
const DIP := 0.4
const SAND_D := Vector3(0.768, 0.604, 0.361)     # #e3cca2 linear (world bible sand_d)
const SAND_C := Vector3(0.871, 0.753, 0.527)     # #f0e1c0 linear (sand)
const ROCK := Vector3(0.191, 0.168, 0.133)       # #797265 linear (reef rock)
const ROCK_CREV := Vector3(0.113, 0.102, 0.081)  # #5f5a50 linear
const CRUST := Vector3(0.397, 0.254, 0.270)      # #a98a8e linear (coralline crust)

var bathy: Bathymetry
var surface_y := 4.0                 # the still water's level (world y)
var keep_under := Rect2(-51.0, -51.0, 102.0, 102.0)   # the drawn floor tiles (x, z)
var r_in := 44.0
var r_out := 1600.0
var mesh_instance: MeshInstance3D

func build(b: Bathymetry, water_y: float) -> void:
	bathy = b; surface_y = water_y
	if b.radius <= 0.0: return
	var radii := _radii()
	var nr := radii.size()
	var pos := PackedVector3Array(); pos.resize(nr * ANGLES)
	for i in nr:
		var r: float = radii[i]
		for j in ANGLES:
			var th := TAU * j / ANGLES
			var x := b.centre.x + r * cos(th); var z := b.centre.y + r * sin(th)
			var y := surface_y - b.depth(x, z) - DIP * _under(x, z)
			pos[i * ANGLES + j] = Vector3(x, y, z)
	var nrm := PackedVector3Array(); nrm.resize(pos.size())
	var col := PackedColorArray(); col.resize(pos.size())
	for i in nr:
		for j in ANGLES:
			var k := i * ANGLES + j
			var a := pos[mini(i + 1, nr - 1) * ANGLES + j] - pos[maxi(i - 1, 0) * ANGLES + j]      # outward
			var c := pos[i * ANGLES + (j + 1) % ANGLES] - pos[i * ANGLES + (j - 1 + ANGLES) % ANGLES]   # round
			var n := c.cross(a).normalized()
			if n.y < 0.0: n = -n
			nrm[k] = n
			col[k] = _paint(pos[k], n)
	var idx := PackedInt32Array()
	for i in nr - 1:
		for j in ANGLES:
			var j1 := (j + 1) % ANGLES
			var a0 := i * ANGLES + j; var a1 := i * ANGLES + j1; var b0 := (i + 1) * ANGLES + j; var b1 := (i + 1) * ANGLES + j1
			idx.append_array([a0, b0, a1, a1, b0, b1])
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos; arr[Mesh.ARRAY_NORMAL] = nrm; arr[Mesh.ARRAY_COLOR] = col; arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new(); m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh_instance = MeshInstance3D.new(); mesh_instance.name = "ReefSeabed"; mesh_instance.mesh = m
	var mat := ShaderMaterial.new(); mat.shader = load("res://look/seabed_surface.gdshader")
	mesh_instance.material_override = mat
	add_child(mesh_instance)
	_collision(pos, radii)
	print("REEF %d rings x %d, %d vertices, reef flat at %.0f m" % [nr, ANGLES, pos.size(), b.radius])

func _radii() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var r := r_in
	var reef_a := bathy.radius * 0.94 - Bathymetry.BACK_M - 10.0
	var reef_b := bathy.radius * 1.06 + Bathymetry.FLAT_M + Bathymetry.SPUR_OUT + 40.0   # the crest and the steep walls
	var step := 1.25
	while r < r_out:
		out.append(r)
		if r < reef_a: r += clampf((reef_a - r) * 0.25, 1.25, 6.0)
		elif r < reef_b: r += 1.25
		else:
			step = minf(step * 1.035, 40.0); r += step
	out.append(r_out)
	return out

func _under(x: float, z: float) -> float:
	## 1 under the drawn tiles (and 4 m round them), 0 away from them
	var dx := maxf(maxf(keep_under.position.x - x, x - keep_under.end.x), 0.0)
	var dz := maxf(maxf(keep_under.position.y - z, z - keep_under.end.y), 0.0)
	return 1.0 - clampf(maxf(dx, dz) / 4.0, 0.0, 1.0)

static func _hash(x: float, z: float) -> float:
	return fposmod(sin(x * 12.9898 + z * 78.233) * 43758.5453, 1.0)

func _paint(p: Vector3, n: Vector3) -> Color:
	var nz := 0.5 + 0.25 * sin(p.x * 0.37 + 1.3 * sin(p.z * 0.21)) + 0.25 * sin(p.z * 0.29 + 1.1 * sin(p.x * 0.17))
	var sand := SAND_D.lerp(SAND_C, clampf(nz, 0.0, 1.0))
	var steep := 1.0 - smoothstep(0.55, 0.85, n.y)          # wall faces
	var d := surface_y - p.y
	var flat := smoothstep(0.0, 1.5, d) * (1.0 - smoothstep(Bathymetry.REEF_FLAT_D + 0.6, Bathymetry.REEF_FLAT_D + 2.0, d))   # the reef flat's depth
	var rr := (Vector2(p.x, p.z) - bathy.centre).length()
	var on_reef := smoothstep(bathy.radius * 0.85, bathy.radius * 0.95, rr)
	var rubble := CRUST.lerp(ROCK, 0.5 + 0.5 * _hash(floorf(p.x * 0.7), floorf(p.z * 0.7)))
	var c := sand
	c = c.lerp(rubble.lerp(sand, 0.35), flat * on_reef)                   # the reef flat: rubble and crust over sand
	c = c.lerp(ROCK.lerp(ROCK_CREV, _hash(floorf(p.x), floorf(p.z))), steep * on_reef)   # the wall: reef rock
	var deep := smoothstep(40.0, 120.0, d)                                    # the deep slope: sediment settles again
	c = c.lerp(sand * 0.8, deep * (1.0 - steep * 0.5))
	return Color(c.x, c.y, c.z)

func _collision(pos: PackedVector3Array, radii: PackedFloat32Array) -> void:
	var faces := PackedVector3Array()
	var nr := radii.size()
	for i in range(0, nr - 2, 2):
		if radii[i] > bathy.radius * 1.1 + 400.0: break
		for j in range(0, ANGLES, 2):
			var j1 := (j + 2) % ANGLES
			var a0 := pos[i * ANGLES + j]; var a1 := pos[i * ANGLES + j1]
			var b0 := pos[(i + 2) * ANGLES + j]; var b1 := pos[(i + 2) * ANGLES + j1]
			faces.append_array([a0, b0, a1, a1, b0, b1])
	var shape := ConcavePolygonShape3D.new(); shape.set_faces(faces)
	var sb := StaticBody3D.new(); sb.name = "ReefCollision"
	var cs := CollisionShape3D.new(); cs.shape = shape; sb.add_child(cs)
	add_child(sb)
