## M23 harness: shared test worlds 0.1.0 (static boxes + an analytic water env). Used by every gameplay test.
## Kinds: ramp {angle}, step {h}, shore {waves}, pool {waves, current}, cave {s}, wall, overhang.
extends RefCounted

const Env := preload("res://core/m23_harness/test_env.gd")

## Pictures: when a material is set here, every box also gets a visible mesh (tools/motion_film.gd sets it).
static var visual_material: Material = null

static func box(parent: Node3D, center: Vector3, size: Vector3, rot_x_deg: float = 0.0) -> void:
	var sb := StaticBody3D.new()
	if visual_material != null:
		var mi := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = size; mi.mesh = bm
		mi.material_override = visual_material
		sb.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new(); bs.size = size
	cs.shape = bs
	sb.add_child(cs)
	sb.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(rot_x_deg)), center)
	sb.collision_layer = 1
	parent.add_child(sb)

static func ramp(parent: Node3D, top: Vector3, length: float, angle_deg: float, width: float) -> Vector3:
	# a slab going down toward -z from 'top' (top edge), returns the bottom edge point
	var a := deg_to_rad(angle_deg)
	var dir := Vector3(0, -sin(a), -cos(a))
	var mid := top + dir * length * 0.5 + Vector3(0, -0.25 * cos(a), 0.25 * sin(a))
	box(parent, mid, Vector3(width, 0.5, length), -angle_deg)
	return top + dir * length

## Builds the named test world under 'world' and returns its water env (level -1000 = no water).
static func build(world: Node3D, kind: String, p: Dictionary):
	var env = Env.new()
	env.level = -1000.0
	match kind:
		"ramp":   # flat approach at y=0 for z in [0, 6], ramp rising toward -z, plateau
			box(world, Vector3(0, -0.25, 3), Vector3(10, 0.5, 6), 0)
			var a := deg_to_rad(p.angle)
			var L := 6.0
			var top := Vector3(0, L * sin(a), -L * cos(a))
			box(world, Vector3(0, top.y * 0.5 - 0.25 * cos(a), top.z * 0.5 - 0.25 * sin(a)), Vector3(10, 0.5, L), p.angle)
			box(world, Vector3(0, top.y - 0.25, top.z - 5), Vector3(10, 0.5, 10), 0)
		"step":
			box(world, Vector3(0, -0.25, 0), Vector3(10, 0.5, 20), 0)
			box(world, Vector3(0, p.h * 0.5, -8), Vector3(10, p.h, 10), 0)
		"shore":  # dry beach y=+1, 12 deg slope down to -6, flat sea floor; water at 0
			env.level = 0.0
			env.wave_amp = p.get("waves", 0.0)
			box(world, Vector3(0, 0.75, 5), Vector3(40, 0.5, 10), 0)
			var bottom := ramp(world, Vector3(0, 1.0, 0), 7.0 / sin(deg_to_rad(12.0)), 12.0, 40.0)
			box(world, Vector3(0, bottom.y - 0.25, bottom.z - 30), Vector3(40, 0.5, 60), 0)
		"pool":
			env.level = 0.0
			env.wave_amp = p.get("waves", 0.0)
			box(world, Vector3(0, -20.25, -20), Vector3(200, 0.5, 200), 0)
			if p.has("current"):
				env.current_vec = p.current
		"cave":   # wall across the pool at z=-5 with a square tube (inner side s) through it, centre y=-10
			env.level = 0.0
			box(world, Vector3(0, -20.25, -20), Vector3(200, 0.5, 200), 0)
			var s: float = p.s
			var L := 20.0
			var zc := -5.0 - L * 0.5
			var th := 2.0
			box(world, Vector3(0, -10 + s * 0.5 + th * 0.5, zc), Vector3(s + 2 * th, th, L), 0)   # roof
			box(world, Vector3(0, -10 - s * 0.5 - th * 0.5, zc), Vector3(s + 2 * th, th, L), 0)   # floor
			box(world, Vector3(-s * 0.5 - th * 0.5, -10, zc), Vector3(th, s, L), 0)               # left
			box(world, Vector3(s * 0.5 + th * 0.5, -10, zc), Vector3(th, s, L), 0)                # right
			# the wall plate around the entrance (closes the way around)
			var W := 60.0
			box(world, Vector3(0, -10 + s * 0.5 + (W * 0.5) * 0.5, -5.0 - th * 0.5), Vector3(W, W * 0.5, th), 0)
			box(world, Vector3(0, -10 - s * 0.5 - (W * 0.5) * 0.5, -5.0 - th * 0.5), Vector3(W, W * 0.5, th), 0)
			box(world, Vector3(-s * 0.5 - W * 0.25, -10, -5.0 - th * 0.5), Vector3(W * 0.5, s, th), 0)
			box(world, Vector3(s * 0.5 + W * 0.25, -10, -5.0 - th * 0.5), Vector3(W * 0.5, s, th), 0)
		"wall":   # open floor with a long wall along x = 1.0 (camera against a wall)
			box(world, Vector3(0, -0.25, 0), Vector3(40, 0.5, 40), 0)
			box(world, Vector3(1.0 + 0.5, 2.0, 0), Vector3(1.0, 4.0, 40), 0)
		"overhang":   # low ceiling at 1.75 m over a 6 x 6 m patch, open floor around it
			box(world, Vector3(0, -0.25, 0), Vector3(40, 0.5, 40), 0)
			box(world, Vector3(0, 1.75 + 0.25, 0), Vector3(6, 0.5, 6), 0)
	return env
