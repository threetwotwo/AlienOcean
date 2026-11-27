## M32 game root: actor registry 0.2.0 (core; game root thread, 27 Nov 2026): who is where, for anyone who asks
## "what is near me?" (fish schools first: they need the girl; later the companion, the brain's points of interest,
## predators, vessels). Engine-free: plain positions in metres, no Nodes.
## Ported from Thalassa v20.19 style/runtime-senses.js: there, live fauna positions are synced once per tick BEFORE
## the brain, the companion and the renderer read them ("1:1 exact alignment"), and the brain builds points of interest
## as {id, kind, label, pos, priority, moving, selfRadius, maxRange} by scanning every list. Here the same record
## lives in one registry, written by its owner each tick and committed once.
## Double-buffered (0.2.0, Fable critique 27 Nov): owners write pending values with move(); readers only ever see the
## committed values (pos, vel, axis, half_len) and the committed grid, so nobody reads half a tick. A write after
## the commit of its tick is refused and counted in late_writes (tests fail on it).
## Reader records (view, perceived()) are fresh Dictionaries per commit, never edited afterwards: a reader on another
## thread (the fish school's worker) may keep last tick's list safely.
## Thalassa scanned every list per query; this keeps a uniform grid in x/z (cell metres) so a query costs only the
## cells it touches. Depth is not in the key (as M12 streaming), only in the distance. Distances are to the actor's
## surface: a sphere (radius) or a capsule (axis, half_len, radius).
## Use, per tick:  begin(); owners call move(id, pos, vel[, axis, half_len]); commit(tick); readers call near()/perceived().
class_name ActorRegistry
extends RefCounted

class Actor:
	extends RefCounted
	var id := ""
	var kind := ""            # "player", "predator", "companion", "fish", "vessel", ... (free text; readers filter)
	var label := ""
	var radius := 0.3         # Thalassa selfRadius (m)
	var priority := 0.5       # Thalassa POI priority (0..1)
	var moving := true        # false = static: not expected to move every tick (never reported stale)
	var max_range := 32.0     # Thalassa maxRange: how far away it is still worth noticing (m)
	# committed (what readers see)
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var axis := Vector3.ZERO  # capsule axis (unit), ZERO = a sphere
	var half_len := 0.0       # capsule half length along axis (m)
	var updated_tick := -1    # the last commit that took a write
	var view := {}            # {id, kind, pos, vel, radius[, axis, half_len]}: fresh each commit, never edited
	# pending (what owners wrote this tick)
	var _pos := Vector3.ZERO
	var _vel := Vector3.ZERO
	var _axis := Vector3.ZERO
	var _half_len := 0.0
	var _moved := false
	var _cell := Vector2i(0x7fffffff, 0)

	func reach() -> float:
		return radius + half_len

	## distance from p to the actor's surface (negative inside)
	func surface_dist(p: Vector3) -> float:
		if half_len <= 0.0 or axis == Vector3.ZERO: return p.distance_to(pos) - radius
		var s := clampf((p - pos).dot(axis), -half_len, half_len)
		return p.distance_to(pos + axis * s) - radius

var cell_size := 8.0
var actors := {}               # id -> Actor
var order: Array = []          # registration order, player first
var grid := {}                 # Vector2i -> Array of Actor (committed positions)
var tick := -1                 # the last committed tick
var open := false              # between begin() and commit()
var stale: Array = []          # moving actors not written since the last commit (an owner that forgot its tick)
var late_writes := 0           # writes outside begin()..commit() (refused)
var queries := 0               # since the last commit (diagnostics)
var max_reach := 0.0           # the largest radius + half_len: queries widen their cell box by it

## Start of the writers' phase.
func begin() -> void:
	open = true

func add(id: String, kind: String, radius := 0.3, opts := {}) -> Actor:
	if actors.has(id):
		push_error("ActorRegistry: id already registered: " + id); return actors[id]
	var a := Actor.new()
	a.id = id; a.kind = kind; a.radius = radius
	for k in opts: a.set(k, opts[k])
	a._pos = a.pos; a._vel = a.vel; a._axis = a.axis; a._half_len = a.half_len
	a._moved = true           # takes effect at the next commit, like any write
	actors[id] = a
	if kind == "player": order.push_front(a)
	else: order.append(a)
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

## An owner's write for this tick (pending until commit). half_len < 0 keeps the current one.
func move(id: String, pos: Vector3, vel: Vector3, axis := Vector3.ZERO, half_len := -1.0) -> void:
	if not open:
		late_writes += 1; return
	var a: Actor = actors[id]
	a._pos = pos; a._vel = vel
	if axis != Vector3.ZERO: a._axis = axis
	if half_len >= 0.0: a._half_len = half_len
	a._moved = true

## End of the writers' phase for tick t: pending -> committed, re-bucket, fresh reader records, stale list.
func commit(t: int) -> void:
	tick = t
	open = false
	stale.clear()
	max_reach = 0.0
	for a in order:
		if a._moved:
			a.pos = a._pos; a.vel = a._vel; a.axis = a._axis; a.half_len = a._half_len
			a.updated_tick = t
			a._moved = false
			_refresh_view(a)
		elif a.moving:
			stale.append(a.id)
		max_reach = maxf(max_reach, a.reach())
		_place(a)
	queries = 0

func player() -> Actor:
	return order[0] if order.size() > 0 and order[0].kind == "player" else null

## Actors whose surface is within radius of center, the player first, then nearest first.
## kinds empty = every kind. exclude_id skips the asker itself.
func near(center: Vector3, radius: float, kinds: Array = [], exclude_id := "", out: Array = []) -> Array:
	queries += 1
	out.clear()
	var r := radius + max_reach      # a centre may sit up to max_reach further out than its surface
	var c0 := _cell_of(center - Vector3(r, 0, r))
	var c1 := _cell_of(center + Vector3(r, 0, r))
	var found := []
	for cx in range(c0.x, c1.x + 1):
		for cz in range(c0.y, c1.y + 1):
			var bucket = grid.get(Vector2i(cx, cz))
			if bucket == null: continue
			for a in bucket:
				if a.id == exclude_id: continue
				if not kinds.is_empty() and not kinds.has(a.kind): continue
				var d: float = a.surface_dist(center)
				if d <= radius: found.append([d, a])
	found.sort_custom(_closer)
	for f in found: out.append(f[1])
	return out

## The fish school thread's feed: [{id, kind, pos, vel, radius[, axis, half_len]}], player first, within radius.
## The records are this commit's snapshots: safe to keep and read from another thread.
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
	if c == a._cell: return
	_unplace(a)
	a._cell = c
	if not grid.has(c): grid[c] = []
	grid[c].append(a)

func _unplace(a: Actor) -> void:
	var b = grid.get(a._cell)
	if b == null: return
	b.erase(a)
	if b.is_empty(): grid.erase(a._cell)

func _refresh_view(a: Actor) -> void:
	var v := {"id": a.id, "kind": a.kind, "pos": a.pos, "vel": a.vel, "radius": a.radius}
	if a.half_len > 0.0 and a.axis != Vector3.ZERO:
		v["axis"] = a.axis; v["half_len"] = a.half_len
	a.view = v
