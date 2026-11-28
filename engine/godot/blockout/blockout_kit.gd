## Blockout kit 0.1.0 (blockout thread, 28 Nov 2026): the ONE set of plain grey test shapes, in metres, for fast iteration
## and stress tests (motion, body, camera, riding, senses, terrain contact). Gary 28 Nov 06:50Z: "blockouts to be used for
## testing/fast iteration". Replaces the inside of tests/harness/test_worlds.gd (kept as a shim: same kinds, same params,
## same Worlds.build(world, kind, p) -> env), so every existing test runs in the kit unchanged.
##
## Use:   var r := BlockoutKit.build(world, "stool", {"h": 0.45})
##        r.env      analytic water (tests/harness/test_env.gd; level -1000 = dry)
##        r.markers  {name: Transform3D} in world space; origin = the point, -Z = the facing direction, +Y = up.
##                   Every kind has "start" (where to put her feet / eye). The same markers exist as Marker3D nodes.
##        r.pois     [Node3D] points of interest (senses kind); BlockoutKit.pois(world) -> [{pos, kind, name, alive}]
##        r.rider    the creature stand-in (ride kind), else null
## Conventions: she starts near the origin and heads toward -Z; dry floors are at y 0, water surfaces at y 0.
## Collision: static boxes / one trimesh (rough) on layer 1; the rider is an AnimatableBody3D on layer 2 (so floor rays and
## the girl's own capsule don't hit the creature she is riding). Every shape also gets a grey mesh with the metre grid.
##
## Kinds (params with defaults; heights for the 1.38 m girl):
##  ground   ramp {angle} . ramp_side {angle=30} . step {h} . stairs {n=8, rise=0.17, tread=0.28} . ledge {h=0.5}
##           drop {h=1.0} . gap {w=0.8} . beam {w=0.2} . rough {seed=7, lo=0.05, hi=0.15} . shore {waves}
##  walls    wall . wall_corner . overhang {h=1.75} . mantle {h=1.0} . ceiling {size=200} . cave / tube {s, size=200}
##  water    pool {depth=20, size=200, waves, current} . lagoon_pool (pool, depth 2.4)
##  rest     stool {h=0.45} . bench {h=0.45} . bunk {top=0.5, clear=0.9}
##  actors   ride {species="" | dolphin | humpback | whale_shark | manta | turtle, scale=1, depth=20, speed=2.5 (generic)}
##           . senses
## The water surface thread owns the reef drop-off / terrain LOOK stress world (core/world/bathymetry.gd); the ledge and
## drop kinds here are body-motion cases only.
class_name BlockoutKit
extends RefCounted

const Env := preload("res://tests/harness/test_env.gd")
const Rider := preload("res://blockout/blockout_rider.gd")
const Poi := preload("res://blockout/blockout_poi.gd")
const Species := preload("res://blockout/blockout_species.gd")
const GREY_SHADER := preload("res://blockout/blockout_grey.gdshader")

const KINDS := ["ramp", "ramp_side", "step", "stairs", "ledge", "drop", "gap", "beam", "rough", "shore", "wall",
	"wall_corner", "overhang", "mantle", "ceiling", "cave", "tube", "pool", "lagoon_pool", "stool", "bench", "bunk",
	"ride", "senses"]
const WATER_KINDS := ["shore", "pool", "lagoon_pool", "ceiling", "cave", "tube", "ride"]

static var _grey: ShaderMaterial = null
## Planted fault for tests/test_blockout.gd: every seat / mattress is built this much too low (must be caught).
static var fault_seat_drop := 0.0

static func grey_material() -> ShaderMaterial:
	if _grey == null:
		_grey = ShaderMaterial.new(); _grey.shader = GREY_SHADER
	return _grey

# ---------------------------------------------------------------- primitives
## A static box. rot_x_deg tilts it about X (a ramp toward -z), rot_z_deg about Z (a slope across).
static func box(parent: Node3D, center: Vector3, size: Vector3, rot_x_deg: float = 0.0, rot_z_deg: float = 0.0) -> StaticBody3D:
	var sb := StaticBody3D.new()
	var mi := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = size; mi.mesh = bm
	mi.material_override = grey_material()
	sb.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new(); bs.size = size
	cs.shape = bs
	sb.add_child(cs)
	var b := Basis(Vector3.RIGHT, deg_to_rad(rot_x_deg))
	if rot_z_deg != 0.0: b = Basis(Vector3.BACK, deg_to_rad(rot_z_deg)) * b
	sb.transform = Transform3D(b, center)
	sb.collision_layer = 1
	parent.add_child(sb)
	return sb

static func ramp(parent: Node3D, top: Vector3, length: float, angle_deg: float, width: float) -> Vector3:
	# a slab going down toward -z from 'top' (top edge), returns the bottom edge point
	var a := deg_to_rad(angle_deg)
	var dir := Vector3(0, -sin(a), -cos(a))
	var mid := top + dir * length * 0.5 + Vector3(0, -0.25 * cos(a), 0.25 * sin(a))
	box(parent, mid, Vector3(width, 0.5, length), -angle_deg)
	return top + dir * length

## A marker: origin at p, facing (-Z) toward 'facing' (horizontal or not), up +Y unless 'up' is given.
static func mark(r: Dictionary, parent: Node3D, mname: String, p: Vector3, facing: Vector3 = Vector3.FORWARD, up: Vector3 = Vector3.UP) -> void:
	var f := facing.normalized()
	var x := up.cross(-f).normalized()       # right = up x back
	var y := (-f).cross(x).normalized()
	var t := Transform3D(Basis(x, y, -f), p)
	var m := Marker3D.new(); m.name = mname; m.transform = t
	parent.add_child(m)
	r.markers[mname] = parent.global_transform * t if parent.is_inside_tree() else t
	r.marker_nodes[mname] = m

static func floor_slab(parent: Node3D, size: float = 40.0, y: float = 0.0) -> void:
	box(parent, Vector3(0, y - 0.25, 0), Vector3(size, 0.5, size))

# ---------------------------------------------------------------- build
## Builds the named kind under 'world'. Returns {env, markers, marker_nodes, pois, rider, kind}.
static func build(world: Node3D, kind: String, p: Dictionary = {}) -> Dictionary:
	var env = Env.new()
	env.level = -1000.0
	var r := {"env": env, "markers": {}, "marker_nodes": {}, "pois": [], "rider": null, "kind": kind}
	var drop := fault_seat_drop
	match kind:
		"ramp":   # flat approach at y=0 for z in [0, 6], ramp rising toward -z, plateau
			box(world, Vector3(0, -0.25, 3), Vector3(10, 0.5, 6), 0)
			var a := deg_to_rad(float(p.angle))
			var L := 6.0
			var top := Vector3(0, L * sin(a), -L * cos(a))
			box(world, Vector3(0, top.y * 0.5 - 0.25 * cos(a), top.z * 0.5 - 0.25 * sin(a)), Vector3(10, 0.5, L), float(p.angle))
			box(world, Vector3(0, top.y - 0.25, top.z - 5), Vector3(10, 0.5, 10), 0)
			mark(r, world, "start", Vector3(0, 0, 4))
		"ramp_side":   # walk along -z ACROSS a slope that rises toward -x; the line x = 0 is at y 0
			var a: float = float(p.get("angle", 30.0))
			var ar := deg_to_rad(a)
			box(world, Vector3(0, -0.25, 3), Vector3(12, 0.5, 6), 0)
			box(world, Vector3(0, -0.25 / cos(ar), -7), Vector3(12, 0.5, 14), 0, -a)
			box(world, Vector3(0, -0.25, -19), Vector3(12, 0.5, 10), 0)
			mark(r, world, "start", Vector3(0, 0, 4))
		"step":
			box(world, Vector3(0, -0.25, 0), Vector3(10, 0.5, 20), 0)
			box(world, Vector3(0, float(p.h) * 0.5, -8), Vector3(10, float(p.h), 10), 0)
			mark(r, world, "start", Vector3(0, 0, 2))
			mark(r, world, "edge", Vector3(0, float(p.h), -3))
		"mantle":   # a chest-high block to grab and climb (a step with a grab marker on its lip)
			var h: float = float(p.get("h", 1.0))
			box(world, Vector3(0, -0.25, 0), Vector3(10, 0.5, 20), 0)
			box(world, Vector3(0, h * 0.5, -8), Vector3(10, h, 10), 0)
			mark(r, world, "start", Vector3(0, 0, 0))
			mark(r, world, "grab", Vector3(0, h, -3))
		"stairs":   # a flight of n steps (rise r, tread d) going up toward -z from z=0, plateau on top
			box(world, Vector3(0, -0.25, 3), Vector3(10, 0.5, 6), 0)
			var n: int = p.get("n", 8)
			var rs: float = p.get("rise", 0.17)
			var d: float = p.get("tread", 0.28)
			for i in n:
				var h := rs * (i + 1)
				box(world, Vector3(0, h * 0.5, -d * (i + 0.5)), Vector3(10, h, d), 0)
			box(world, Vector3(0, rs * n * 0.5, -d * n - 5), Vector3(10, rs * n, 10), 0)
			mark(r, world, "start", Vector3(0, 0, 3))
		"ledge", "drop":   # start on a platform (top y h), walk off its edge at z = -2 onto the floor at y 0
			var h: float = float(p.get("h", 0.5 if kind == "ledge" else 1.0))
			box(world, Vector3(0, -0.25, -6), Vector3(12, 0.5, 24), 0)
			box(world, Vector3(0, h * 0.5, 2), Vector3(12, h, 8), 0)
			mark(r, world, "start", Vector3(0, h, 4))
			mark(r, world, "edge", Vector3(0, h, -2))
		"gap":   # take-off platform (top y 0) to z = -2, a gap w wide over a 2 m pit, landing platform beyond
			var w: float = float(p.get("w", 0.8))
			box(world, Vector3(0, -1.0, 2), Vector3(10, 2.0, 8), 0)
			box(world, Vector3(0, -1.0, -2 - w - 5), Vector3(10, 2.0, 10), 0)
			box(world, Vector3(0, -2.25, -2 - w * 0.5), Vector3(10, 0.5, w + 2), 0)   # pit floor
			mark(r, world, "start", Vector3(0, 0, 4))
			mark(r, world, "edge", Vector3(0, 0, -2))
			mark(r, world, "land", Vector3(0, 0, -2 - w))
		"beam":   # start pad, a beam w wide and 8 m long (top y 0) over a 1.5 m pit, end pad
			var w: float = float(p.get("w", 0.2))
			box(world, Vector3(0, -0.15, 3), Vector3(4, 0.3, 6), 0)
			box(world, Vector3(0, -0.1, -4), Vector3(w, 0.2, 8), 0)
			box(world, Vector3(0, -0.15, -11), Vector3(4, 0.3, 6), 0)
			box(world, Vector3(0, -1.75, -4), Vector3(8, 0.5, 30), 0)   # pit floor
			mark(r, world, "start", Vector3(0, 0, 3))
			mark(r, world, "beam_end", Vector3(0, 0, -8))
		"rough":   # flat approach z in [2, 6], then a 16 x 16 m field of grown bumps 5-15 cm high
			_rough(world, int(p.get("seed", 7)), float(p.get("lo", 0.05)), float(p.get("hi", 0.15)))
			mark(r, world, "start", Vector3(0, 0, 4))
		"shore":  # dry beach y=+1, 12 deg slope down to -6, flat sea floor; water at 0
			env.level = 0.0
			env.wave_amp = p.get("waves", 0.0)
			box(world, Vector3(0, 0.75, 5), Vector3(40, 0.5, 10), 0)
			var bottom := ramp(world, Vector3(0, 1.0, 0), 7.0 / sin(deg_to_rad(12.0)), 12.0, 40.0)
			box(world, Vector3(0, bottom.y - 0.25, bottom.z - 30), Vector3(40, 0.5, 60), 0)
			mark(r, world, "start", Vector3(0, 1.0, 4))
		"pool", "lagoon_pool":
			env.level = 0.0
			env.wave_amp = p.get("waves", 0.0)
			var depth: float = float(p.get("depth", 2.4 if kind == "lagoon_pool" else 20.0))
			var size: float = float(p.get("size", 200.0))
			box(world, Vector3(0, -depth - 0.25, -size * 0.1), Vector3(size, 0.5, size), 0)
			if p.has("current"):
				env.current_vec = p.current
			mark(r, world, "start", Vector3(0, -minf(1.0, depth * 0.5), 0))
			mark(r, world, "floor", Vector3(0, -depth, -2))
		"cave", "tube":   # wall across the pool at z=-5 with a square tube (inner side s) through it, centre y=-10
			env.level = 0.0
			var size: float = float(p.get("size", 200.0))
			box(world, Vector3(0, -20.25, -size * 0.1), Vector3(size, 0.5, size), 0)
			var s: float = float(p.get("s", 1.0))
			var L := 20.0
			var zc := -5.0 - L * 0.5
			var th := 2.0
			box(world, Vector3(0, -10 + s * 0.5 + th * 0.5, zc), Vector3(s + 2 * th, th, L), 0)   # roof
			box(world, Vector3(0, -10 - s * 0.5 - th * 0.5, zc), Vector3(s + 2 * th, th, L), 0)   # floor
			box(world, Vector3(-s * 0.5 - th * 0.5, -10, zc), Vector3(th, s, L), 0)               # left
			box(world, Vector3(s * 0.5 + th * 0.5, -10, zc), Vector3(th, s, L), 0)                # right
			# the wall plate around the entrance (closes the way around)
			var W := minf(60.0, size * 0.6)
			box(world, Vector3(0, -10 + s * 0.5 + (W * 0.5) * 0.5, -5.0 - th * 0.5), Vector3(W, W * 0.5, th), 0)
			box(world, Vector3(0, -10 - s * 0.5 - (W * 0.5) * 0.5, -5.0 - th * 0.5), Vector3(W, W * 0.5, th), 0)
			box(world, Vector3(-s * 0.5 - W * 0.25, -10, -5.0 - th * 0.5), Vector3(W * 0.5, s, th), 0)
			box(world, Vector3(s * 0.5 + W * 0.25, -10, -5.0 - th * 0.5), Vector3(W * 0.5, s, th), 0)
			mark(r, world, "start", Vector3(0, -10, 2))
			mark(r, world, "mouth", Vector3(0, -10, -5))
		"wall":   # open floor with a long wall along x = 1.0 (walk along it, touching it)
			box(world, Vector3(0, -0.25, 0), Vector3(40, 0.5, 40), 0)
			box(world, Vector3(1.0 + 0.5, 2.0, 0), Vector3(1.0, 4.0, 40), 0)
			mark(r, world, "start", Vector3(0.6, 0, 8))
		"wall_corner":   # the wall along x = 1.0 meets a wall across at z = -6: an inside corner at (1, -6)
			box(world, Vector3(0, -0.25, 0), Vector3(40, 0.5, 40), 0)
			box(world, Vector3(1.5, 2.0, 7), Vector3(1.0, 4.0, 26), 0)
			box(world, Vector3(-9.0, 2.0, -6.5), Vector3(22.0, 4.0, 1.0), 0)
			mark(r, world, "start", Vector3(0.6, 0, 6))
			mark(r, world, "corner", Vector3(1.0, 0, -6), Vector3(1, 0, -1))
		"ceiling":   # pool with a 10 x 10 m slab at y = -5 (its underside), to swim up into
			env.level = 0.0
			var size: float = float(p.get("size", 200.0))
			box(world, Vector3(0, -20.25, -size * 0.1), Vector3(size, 0.5, size), 0)
			box(world, Vector3(0, -4.75, 0), Vector3(10, 0.5, 10), 0)
			mark(r, world, "start", Vector3(0, -8, 0))
			mark(r, world, "underside", Vector3(0, -5, 0), Vector3.FORWARD)
		"overhang":   # low ceiling (underside at h) over a 6 x 6 m patch, open floor around it
			var h: float = float(p.get("h", 1.75))
			box(world, Vector3(0, -0.25, 0), Vector3(40, 0.5, 40), 0)
			box(world, Vector3(0, h + 0.25, 0), Vector3(6, 0.5, 6), 0)
			mark(r, world, "start", Vector3(0, 0, 6))
		"stool":   # a 35 x 35 cm stool, seat top at h, 1.5 m ahead; sit facing back toward the start (+z)
			var h: float = float(p.get("h", 0.45)) - drop
			floor_slab(world, 20.0)
			box(world, Vector3(0, h * 0.5, -1.5), Vector3(0.35, h, 0.35))
			mark(r, world, "start", Vector3(0, 0, 2))
			mark(r, world, "seat", Vector3(0, h, -1.5), Vector3.BACK)
			mark(r, world, "approach", Vector3(0, 0, -0.95), Vector3.FORWARD)
		"bench":   # 1.6 m bench (seat 0.42 deep, top at h) with a 0.45 m back, against nothing; sit facing +z
			var h: float = float(p.get("h", 0.45)) - drop
			floor_slab(world, 20.0)
			var zc := -2.0
			box(world, Vector3(0, h - 0.03, zc), Vector3(1.6, 0.06, 0.42))                 # seat board
			box(world, Vector3(-0.75, (h - 0.06) * 0.5, zc), Vector3(0.08, h - 0.06, 0.38))   # legs (end frames)
			box(world, Vector3(0.75, (h - 0.06) * 0.5, zc), Vector3(0.08, h - 0.06, 0.38))
			box(world, Vector3(0, h + 0.225, zc - 0.21 - 0.03), Vector3(1.6, 0.45, 0.06))     # back
			mark(r, world, "start", Vector3(0, 0, 2))
			for i in 3:
				mark(r, world, ["seat_l", "seat_c", "seat_r"][i], Vector3(-0.5 + 0.5 * i, h, zc + 0.02), Vector3.BACK)
			mark(r, world, "back", Vector3(0, h + 0.25, zc - 0.21), Vector3.BACK)
		"bunk":   # lower bunk: 2.0 x 0.9 m mattress, top at 'top' (0.5), pillow at +x, upper bunk underside 'clear' above
			var top: float = float(p.get("top", 0.5)) - drop
			var clear: float = float(p.get("clear", 0.9))
			floor_slab(world, 20.0)
			var zc := -2.0
			box(world, Vector3(0, top * 0.5, zc), Vector3(2.0, top, 0.9))                       # frame + mattress
			box(world, Vector3(0, 1.1, zc - 0.5), Vector3(2.2, 2.2, 0.1))                       # wall behind
			box(world, Vector3(1.05, (top + clear + 0.1) * 0.5, zc), Vector3(0.1, top + clear + 0.1, 0.9))   # head board
			box(world, Vector3(-1.05, (top + clear + 0.1) * 0.5, zc), Vector3(0.1, top + clear + 0.1, 0.9))  # foot board
			box(world, Vector3(0, top + clear + 0.05, zc), Vector3(2.0, 0.1, 0.9))              # upper bunk (underside top+clear)
			box(world, Vector3(0.8, top + 0.06, zc), Vector3(0.32, 0.12, 0.55))                  # pillow
			mark(r, world, "start", Vector3(0, 0, 1))
			# lie: centre of the mattress, -Z (forward) toward the pillow end, +Y up out of the mattress (face up)
			mark(r, world, "lie", Vector3(0, top, zc), Vector3.RIGHT)
			mark(r, world, "pillow", Vector3(0.8, top + 0.12, zc), Vector3.RIGHT)
			mark(r, world, "sit", Vector3(0, top, zc + 0.3), Vector3.BACK)
		"ride":   # deep pool and the creature stand-in on its scripted loop
			env.level = 0.0
			var depth: float = float(p.get("depth", 20.0))
			var size: float = float(p.get("size", 200.0))
			box(world, Vector3(0, -depth - 0.25, -size * 0.1), Vector3(size, 0.5, size), 0)
			var rd = Rider.new()
			rd.name = "Rider"
			rd.species = String(p.get("species", ""))
			rd.scale_k = float(p.get("scale", 1.0))
			rd.speed = float(p.get("speed", 2.5))
			var down := 4.0
			if rd.species != "":   # keep the whole loop under water: climb height + body + 2 m
				var pr: Dictionary = Species.PROFILES[rd.species]
				down = float(pr.path.H) + float(pr.r) * float(pr.length) * rd.scale_k + 2.0
			rd.origin = p.get("origin", Vector3(0, -down, -6))
			world.add_child(rd)
			r.rider = rd
			mark(r, world, "start", Vector3(0, -2, 2))
		"senses":   # open floor; a fixed object ahead, a creature circling, an object behind her, a sound source
			floor_slab(world, 40.0)
			r.pois.append(_poi(world, "ahead", "object", Vector3(0, 1.0, -8)))
			var m = _poi(world, "circler", "creature", Vector3(4, 1.0, -6))
			m.circle_radius = 3.0; m.circle_speed = 1.0
			r.pois.append(m)
			r.pois.append(_poi(world, "behind", "object", Vector3(0, 1.0, 6)))
			var s = _poi(world, "knock", "sound", Vector3(-6, 0.5, -4))
			s.sound_period = 3.0; s.sound_len = 0.5
			r.pois.append(s)
			mark(r, world, "start", Vector3(0, 0, 0))
		_:
			push_error("BlockoutKit: unknown kind '%s' (known: %s)" % [kind, ", ".join(KINDS)])
	return r

static func _poi(world: Node3D, pname: String, kind: String, at: Vector3) -> Node3D:
	var n = Poi.new()
	n.name = "Poi_" + pname
	n.poi_name = pname
	n.kind = kind
	n.position = at
	n.home = at
	world.add_child(n)
	return n

## Every point of interest under 'root' as plain data: [{pos, kind, name, alive}] (read each tick).
static func pois(root: Node) -> Array:
	var out: Array = []
	if not root.is_inside_tree(): return out
	for n in root.get_tree().get_nodes_in_group(Poi.GROUP):
		if root.is_ancestor_of(n):
			out.append(n.as_dict())
	return out

## Rough field: bumps 'grown' by seeded scattering (random radius 0.3-0.8 m, height lo..hi, max-combined so peaks keep
## their height), sampled on a 12.5 cm grid into one trimesh collision and one mesh. Flat for z > 2 (the approach).
static func _rough(world: Node3D, seed_: int, lo: float, hi: float) -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = seed_
	var bumps: Array = []
	for i in 260:
		bumps.append([Vector2(rng.randf_range(-8, 8), rng.randf_range(-14, 1.5)), rng.randf_range(0.3, 0.8), rng.randf_range(lo, hi)])
	var step := 0.125
	var nx := int(16.0 / step) + 1
	var nz := int(20.0 / step) + 1
	var hts := PackedFloat32Array(); hts.resize(nx * nz)
	for j in nz:
		for i in nx:
			var x := -8.0 + i * step
			var z := 6.0 - j * step
			var h := 0.0
			for b in bumps:
				var d: float = (Vector2(x, z) - b[0]).length() / b[1]
				if d < 1.0:
					h = maxf(h, b[2] * (0.5 + 0.5 * cos(PI * d)))   # raised-cosine dome, exact peak b[2]
			if z > 2.0: h = 0.0
			hts[j * nx + i] = h
	var verts := PackedVector3Array()
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var P := func(i: int, j: int) -> Vector3: return Vector3(-8.0 + i * step, hts[j * nx + i], 6.0 - j * step)
	for j in nz - 1:
		for i in nx - 1:
			var a: Vector3 = P.call(i, j); var b: Vector3 = P.call(i + 1, j)
			var c: Vector3 = P.call(i, j + 1); var d: Vector3 = P.call(i + 1, j + 1)
			for v in [a, c, b, b, c, d]:   # clockwise seen from above (Godot's front face)
				verts.append(v); st.add_vertex(v)
	st.generate_normals()
	var sb := StaticBody3D.new(); sb.name = "Rough"
	var mi := MeshInstance3D.new(); mi.mesh = st.commit(); mi.material_override = grey_material()
	sb.add_child(mi)
	var cs := CollisionShape3D.new(); var sh := ConcavePolygonShape3D.new()
	sh.backface_collision = true
	sh.set_faces(verts); cs.shape = sh
	sb.add_child(cs)
	sb.collision_layer = 1
	world.add_child(sb)
	box(world, Vector3(0, -0.75, -4), Vector3(16, 1.0, 20))   # solid under the skin (nothing falls through a seam)
