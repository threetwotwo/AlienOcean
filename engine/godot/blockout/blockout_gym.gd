## Blockout gym 0.1.0 (blockout kit): every kit station in one world, for the blockout stress scene, films and playing
## it by hand. Dry stations stand in a row with their floors 2.5 m above the water (above any tide); the water stations
## stand in a second row behind them, their surfaces at the world's water level. Each station has a sign and a "start".
## build() returns {env, stations: [{label, kind, p, node, result, start: Transform3D, water: bool}]}.
class_name BlockoutGym
extends RefCounted

const Kit := preload("res://blockout/blockout_kit.gd")
const Env := preload("res://tests/harness/test_env.gd")
const GAP := 4.0
const DRY_LIFT := 2.5

## [label, kind, params]: the girl body thread's list (28 Nov), heights for the 1.38 m girl.
const DRY := [
	["step 5 cm", "step", {"h": 0.05}], ["step 10 cm", "step", {"h": 0.10}], ["step 20 cm", "step", {"h": 0.20}],
	["step 30 cm", "step", {"h": 0.30}], ["step 50 cm", "step", {"h": 0.50}], ["stairs 17/28", "stairs", {}],
	["ramp 15", "ramp", {"angle": 15.0}], ["ramp 30", "ramp", {"angle": 30.0}], ["ramp 60", "ramp", {"angle": 60.0}],
	["slope across 30", "ramp_side", {"angle": 30.0}], ["ledge 0.5 m", "ledge", {"h": 0.5}], ["drop 1 m", "drop", {"h": 1.0}],
	["gap 0.4", "gap", {"w": 0.4}], ["gap 0.8", "gap", {"w": 0.8}], ["gap 1.2", "gap", {"w": 1.2}],
	["beam 10 cm", "beam", {"w": 0.1}], ["beam 20 cm", "beam", {"w": 0.2}], ["rough 5-15 cm", "rough", {}],
	["wall", "wall", {}], ["wall corner", "wall_corner", {}], ["low ceiling 1.75", "overhang", {"h": 1.75}],
	["mantle 1.0", "mantle", {"h": 1.0}], ["stool 45", "stool", {}], ["bench", "bench", {}], ["bunk", "bunk", {}],
	["senses", "senses", {}],
]
const WET := [
	["lagoon pool 2.4 m", "lagoon_pool", {"size": 60.0}], ["pool 20 m", "pool", {"size": 40.0}],
	["ceiling slab -5 m", "ceiling", {"size": 30.0}], ["tube 0.8", "tube", {"s": 0.8, "size": 40.0}],
	["tube 1.0", "tube", {"s": 1.0, "size": 40.0}], ["ride", "ride", {"size": 50.0}], ["shore", "shore", {}],
]

static func build(parent: Node3D, water_level: float = 0.0, dry: Array = DRY, wet: Array = WET) -> Dictionary:
	var env = Env.new()
	env.level = water_level
	var out := {"env": env, "stations": []}
	var root := Node3D.new(); root.name = "BlockoutGym"
	parent.add_child(root)
	var dry_row := _row(root, dry, false)
	var wet_row := _row(root, wet, true)
	# dry row along +x at z 0, lifted; wet row behind it (toward -z), at the water level
	var cursor := 0.0
	var dry_min_z := 0.0
	for st in dry_row:
		var a: AABB = st.aabb
		st.node.position = Vector3(cursor - a.position.x, water_level + DRY_LIFT, 0)
		cursor += a.size.x + GAP
		dry_min_z = minf(dry_min_z, a.position.z)
	cursor = 0.0
	var wet_max_z := -INF
	for st in wet_row: wet_max_z = maxf(wet_max_z, st.aabb.end.z)
	for st in wet_row:
		var a: AABB = st.aabb
		st.node.position = Vector3(cursor - a.position.x, water_level, dry_min_z - GAP - wet_max_z)
		cursor += a.size.x + GAP
	for st in dry_row + wet_row:
		for mn in st.result.marker_nodes:
			st.result.markers[mn] = st.result.marker_nodes[mn].global_transform
		st.start = st.result.markers.get("start", st.node.global_transform)
		var lab := Label3D.new(); lab.text = st.label; lab.pixel_size = 0.01; lab.font_size = 64
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED; lab.outline_size = 12
		lab.position = st.node.to_local(st.start.origin) + Vector3(0, 2.4, 0)
		st.node.add_child(lab)
		out.stations.append(st)
	return out

static func _row(root: Node3D, list: Array, water: bool) -> Array:
	var row: Array = []
	for e in list:
		var n := Node3D.new(); n.name = String(e[0]).replace(" ", "_").replace(".", "_").replace("/", "_")
		root.add_child(n)
		var res: Dictionary = Kit.build(n, e[1], e[2])
		row.append({"label": e[0], "kind": e[1], "p": e[2], "node": n, "result": res, "water": water,
			"aabb": footprint(n), "start": Transform3D.IDENTITY})
	return row

## Local AABB of every collision box / trimesh under n (n's own frame).
static func footprint(n: Node3D) -> AABB:
	var acc := AABB()
	var first := true
	for sb in n.get_children():
		if not (sb is CollisionObject3D): continue
		for cs in sb.get_children():
			if not (cs is CollisionShape3D) or cs.shape == null: continue
			var local: AABB
			if cs.shape is BoxShape3D:
				local = AABB(-cs.shape.size * 0.5, cs.shape.size)
			elif cs.shape is ConcavePolygonShape3D:
				var f: PackedVector3Array = cs.shape.get_faces()
				local = AABB(f[0], Vector3.ZERO)
				for v in f: local = local.expand(v)
			else:
				continue
			var a: AABB = (sb.transform * cs.transform) * local
			if first: acc = a; first = false
			else: acc = acc.merge(a)
	return acc
