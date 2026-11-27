## M32 game root: actor registry 0.1.0 (core; game root thread, 27 Nov 2026): who is where, for anyone who asks
## "what is near me?" (fish schools first: they need the girl; later the companion, the brain's points of interest,
## predators, vessels). Engine-free: plain positions in metres, no Nodes.
## Ported from Thalassa v20.19 style/runtime-senses.js: there, live fauna positions are synced once per tick BEFORE
## the brain, the companion and the renderer read them ("1:1 exact alignment"), and the brain builds points of interest
## as {id, kind, label, pos, priority, moving, selfRadius, maxRange} by scanning every list. Here the same record
## lives in one registry, written by its owner each tick and committed once, so readers never see half a tick.
## Thalassa scanned every list per query; this keeps a uniform grid in x/z (cell metres) so a query costs only the
## cells it touches. Depth is not in the key (as M12 streaming), only in the distance.
## Use, per tick:  owners call move(id, pos, vel[, axis]); then commit(tick); then readers call near() / perceived().
class_name ActorRegistry
extends RefCounted

class Actor:
	extends RefCounted
	var id := ""
	var kind := ""            # "player", "predator", "companion", "fish", "vessel", ... (free text; readers filter)
	var label := ""
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var radius := 0.3         # Thalassa selfRadius (m)
	var axis := Vector3.ZERO  # body axis for a capsule (unit), ZERO = a sphere
	var half_len := 0.0       # capsule half length along axis (m)
	var priority := 0.5       # Thalassa POI priority (0..1)
	var moving := true
	var max_range := 32.0     # Thalassa maxRange: how far away it is still worth noticing (m)
	var updated_tick := -1    # the last commit that saw it moved
	var moved := false        # written since the last commit
	var cell := Vector2i(0x7fffffff, 0)
	## the record handed to readers, refreshed on commit (shape agreed with the fish school thread):
	## {id, kind, pos, vel, radius, axis, half_len}. Readers must not keep it past the tick.
	var view := {}

var cell_size := 8.0
var actors := {}               # id -> Actor
var order: Array = []          # registration order, player first
var grid := {}                 # Vector2i -> Array of Actor
var tick := -1
var stale: Array = []          # ids not moved since the last commit (an owner that forgot its tick)
var queries := 0               # since the last commit (diagnostics)
var max_radius := 0.0          # the largest actor radius: queries widen their cell box by it

func add(id: String, kind: String, radius := 0.3, opts := {}) -> Actor:
	assert(not actors.has(id), "actor id already registered: " + id)
	var a := Actor.new()
	a.id = id; a.kind = kind; a.radius = radius
	for k in opts: a.set(k, opts[k])
	actors[id] = a
	if kind == "player": order.push_front(a)
	else: order.append(a)
	a.moved = true            # a new actor counts as written for the next commit
	max_radius = maxf(max_radius, a.radius)
	_place(a)
	_refresh_view(a)
	return a

func remove(id: String) -> void:
	if not actors.has(id): return
	var a: Actor = actors[id]
	_unplace(a)
	order.erase(a)
	actors.erase(id)

func has(id: String) -> bool:
	return actors.has(id)

func get_actor(id: String) -> Actor:
	return actors.get(id)

func move(id: String, pos: Vector3, vel: Vector3, axis := Vector3.ZERO) -> void:
	var a: Actor = actors[id]
	a.pos = pos; a.vel = vel
	if axis != Vector3.ZERO: a.axis = axis
	a.moved = true

## End of the writers' phase for tick t: re-bucket moved actors, refresh their reader records, list stale ones.
func commit(t: int) -> void:
	tick = t
	stale.clear()
	for a in order:
		if a.moved: a.updated_tick = t
		else: stale.append(a.id)
		a.moved = false
		max_radius = maxf(max_radius, a.radius)
		_place(a)
		_refresh_view(a)
	queries = 0

func player() -> Actor:
	return order[0] if order.size() > 0 and order[0].kind == "player" else null

## Actors within radius of center (sphere test on centre distance minus the actor's own radius), the player first,
## then nearest first. kinds empty = every kind. exclude_id skips the asker itself.
func near(center: Vector3, radius: float, kinds: Array = [], exclude_id := "", out: Array = []) -> Array:
	queries += 1
	out.clear()
	var reach := radius + max_radius      # an actor counts by its surface, so its centre may sit max_radius further out
	var c0 := _cell_of(center - Vector3(reach, 0, reach))
	var c1 := _cell_of(center + Vector3(reach, 0, reach))
	var found := []
	for cx in range(c0.x, c1.x + 1):
		for cz in range(c0.y, c1.y + 1):
			var bucket = grid.get(Vector2i(cx, cz))
			if bucket == null: continue
			for a in bucket:
				if a.id == exclude_id: continue
				if not kinds.is_empty() and not kinds.has(a.kind): continue
				var d: float = a.pos.distance_to(center) - a.radius
				if d <= radius: found.append([d, a])
	found.sort_custom(_closer)
	for f in found: out.append(f[1])
	return out

## The fish school thread's feed: [{id, kind, pos, vel, radius, axis, half_len}], player first, within radius.
func perceived(center: Vector3, radius: float, kinds: Array = ["player", "predator"]) -> Array:
	var res := []
	for a in near(center, radius, kinds): res.append(a.view)
	return res

## Thalassa getCharacterSenseContext POI record: {id, kind, label, pos, priority, moving, selfRadius, maxRange}
func pois(center: Vector3, radius: float, kinds: Array = [], exclude_id := "") -> Array:
	var res := []
	for a in near(center, radius, kinds, exclude_id):
		if a.pos.distance_to(center) <= maxf(radius, a.max_range):
			res.append({"id": a.id, "kind": a.kind, "label": a.label, "pos": a.pos, "priority": a.priority,
				"moving": a.moving, "selfRadius": a.radius, "maxRange": a.max_range})
	return res

static func _closer(p: Array, q: Array) -> bool:
	## the player first, then nearest first
	var pp: bool = p[1].kind == "player"; var qp: bool = q[1].kind == "player"
	if pp != qp: return pp
	return p[0] < q[0]

func _cell_of(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / cell_size), floori(p.z / cell_size))

func _place(a: Actor) -> void:
	var c := _cell_of(a.pos)
	if c == a.cell: return
	_unplace(a)
	a.cell = c
	if not grid.has(c): grid[c] = []
	grid[c].append(a)

func _unplace(a: Actor) -> void:
	var b = grid.get(a.cell)
	if b == null: return
	b.erase(a)
	if b.is_empty(): grid.erase(a.cell)

func _refresh_view(a: Actor) -> void:
	var v := a.view
	v["id"] = a.id; v["kind"] = a.kind; v["pos"] = a.pos; v["vel"] = a.vel; v["radius"] = a.radius
	if a.half_len > 0.0 and a.axis != Vector3.ZERO:
		v["axis"] = a.axis; v["half_len"] = a.half_len
	else:
		v.erase("axis"); v.erase("half_len")
