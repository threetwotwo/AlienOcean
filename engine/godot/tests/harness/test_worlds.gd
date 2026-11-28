## M23 harness: shared test worlds 0.2.0, now a shim over the blockout kit (blockout/blockout_kit.gd, 28 Nov 2026), so
## there is one kit. Same kinds, same params, same build(world, kind, p) -> env as 0.1.0; every kit kind works here too
## (stool, bench, bunk, gap, beam, rough, ledge, drop, mantle, wall_corner, ramp_side, lagoon_pool, ride, senses).
## For markers, points of interest and the rider call BlockoutKit.build() directly (it returns them all).
extends RefCounted

const Kit := preload("res://blockout/blockout_kit.gd")

## Pictures: when a material is set here, every kit mesh in the world is drawn with it instead of the blockout grey
## (tools/motion_film.gd and tests/test_body_stress.gd set it).
static var visual_material: Material = null
## The last build's full kit result (markers, pois, rider), for tests that want more than the env.
static var last: Dictionary = {}

static func box(parent: Node3D, center: Vector3, size: Vector3, rot_x_deg: float = 0.0) -> void:
	Kit.box(parent, center, size, rot_x_deg)
	if visual_material != null: _paint(parent)

static func ramp(parent: Node3D, top: Vector3, length: float, angle_deg: float, width: float) -> Vector3:
	var e := Kit.ramp(parent, top, length, angle_deg, width)
	if visual_material != null: _paint(parent)
	return e

## Builds the named test world under 'world' and returns its water env (level -1000 = no water).
static func build(world: Node3D, kind: String, p: Dictionary):
	last = Kit.build(world, kind, p)
	if visual_material != null: _paint(world)
	return last.env

static func _paint(n: Node) -> void:
	for c in n.get_children():
		if c is MeshInstance3D and c.material_override == Kit.grey_material(): c.material_override = visual_material
		_paint(c)
