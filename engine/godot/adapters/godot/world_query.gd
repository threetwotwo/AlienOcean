## WorldQuery, Godot adapter 0.1.0: the one place gameplay asks Jolt about the world (contract in core/README.md).
## Used by the player body (M02), the camera spring arm (M03) and the body rig's no-clip limbs (M04), which each
## built their own rays and sphere tests before.
##   ray_down(x, z, top, depth) -> intersect_ray result ({} = nothing)
##   floor_height(x, z) -> float (-INF = no floor), from `top` (set by the owner, e.g. above the actor) down 80 m
##   floor_normal(x, z) -> Vector3
##   nearest_surface(p, r, filter = null) -> {dist, normal, point} or {}; filter(point, normal) -> bool may reject it
##   point_solid(p) -> bool   ray(from, to) -> {position, normal} or {}
extends RefCounted

var world: World3D
var mask := 1
var exclude: Array[RID] = []
var top := 0.0              # where floor rays start; the owner keeps it above the actor each tick
var depth := 80.0

func _init(w: World3D = null, collision_mask := 1) -> void:
	world = w
	mask = collision_mask

func ray_down(x: float, z: float, from_y: float, dist := 80.0) -> Dictionary:
	var rq := PhysicsRayQueryParameters3D.create(Vector3(x, from_y, z), Vector3(x, from_y - dist, z), mask, exclude)
	return world.direct_space_state.intersect_ray(rq)

func floor_height(x: float, z: float) -> float:
	var h := ray_down(x, z, top, depth)
	return h.position.y if not h.is_empty() else -INF

func floor_normal(x: float, z: float) -> Vector3:
	var h := ray_down(x, z, top, depth)
	return h.normal if not h.is_empty() else Vector3.UP

func nearest_surface(p: Vector3, r: float, filter = null) -> Dictionary:
	var q := PhysicsShapeQueryParameters3D.new()
	var sp := SphereShape3D.new()
	sp.radius = r
	q.shape = sp
	q.transform = Transform3D(Basis(), p)
	q.collision_mask = mask
	q.exclude = exclude
	var info := world.direct_space_state.get_rest_info(q)
	if info.is_empty(): return {}
	var pt: Vector3 = info.point
	var n: Vector3 = info.normal
	if filter == null or filter.call(pt, n):
		return {"dist": p.distance_to(pt), "normal": n, "point": pt}
	# The single rest contact was rejected (e.g. the floor under a foot that is also touching a wall): look through
	# every contact and keep the nearest the filter accepts. Normals point out of the geometry.
	var pairs := world.direct_space_state.collide_shape(q, 16)
	var inside := point_solid(p)
	var best := {}
	for i in range(1, pairs.size(), 2):
		var b: Vector3 = pairs[i]
		var d := p.distance_to(b)
		if d < 1e-5: continue
		var nn: Vector3 = (b - p) / d if inside else (p - b) / d
		if filter.call(b, nn) and (best.is_empty() or d < best.dist):
			best = {"dist": d, "normal": nn, "point": b}
	return best

## point_solid(p) -> bool: p is inside world geometry (lets a caller tell "touching" from "buried").
func point_solid(p: Vector3) -> bool:
	var pq := PhysicsPointQueryParameters3D.new()
	pq.position = p
	pq.collision_mask = mask
	pq.exclude = exclude
	return world.direct_space_state.intersect_point(pq, 1).size() > 0

## ray(from, to) -> {position, normal} or {}
func ray(from: Vector3, to: Vector3) -> Dictionary:
	var rq := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
	return world.direct_space_state.intersect_ray(rq)

## The dictionary of Callables the ported cores take as env.
func as_env() -> Dictionary:
	return {"floor_height": floor_height, "floor_normal": floor_normal, "nearest_surface": nearest_surface, "point_solid": point_solid, "ray": ray}
