## M04 Body, core 0.2.0: what the brain is fed. Adapted from Thalassa v20.19 style/runtime-senses.js
## getCharacterSenseContext: the points of interest around her as {id, kind, label, pos, priority, moving, selfRadius,
## maxRange}, the camera's forward, and a line-of-sight test. Engine-free: the adapter (adapters/godot/brain_senses.gd)
## hands in plain data, the ActorRegistry and a WorldQuery (contract in core/README.md: ray(from, to) -> {} when clear).
## Sources, as Thalassa's lists map onto ours:
##   actors     the ActorRegistry's actors around her as Thalassa POI records: companion -> 'kora' (Thalassa's KORA),
##              fish / predator -> 'fauna', vessels as they are. The grid query (registry.near) runs every ACTOR_SCAN
##              ticks and keeps the MAX_ACTORS nearest; their committed positions are read every tick.
##   schools    Thalassa pushed every 4th fish of its one fish list plus the closest fish. Our schools are 40-160 fish
##              each, so a school is one POI at its centre ('fauna', 0.83, as Thalassa's fish) plus its closest fish
##              (0.87, maxRange 20, as Thalassa's closest fish).
##   landmarks  static reef pieces (rock heads, the arch, coral heads) in place of Thalassa's archList / caveNodes /
##              thermalVents.
## Left out (we have none): the ship interior POIs, Nautilus / Pelagos vessels, the hull fields, KORA's locked target.
## Budget (the brain runs in the player phase of every game tick): at most MAX_POIS, nearest first; line of sight is one
## ray per POI, cached LOS_REFRESH ticks and at most LOS_RAYS new rays per tick; a POI not yet tested counts as hidden.
## (Thalassa scanned every list every tick; with the game root's 200-actor crowd that cost ~1 ms a tick here.)
extends RefCounted

const VISION_RANGE := 54.0       # Thalassa visionRangeM (the brain caps each POI at its own maxRange too)
const MAX_POIS := 16
const MAX_ACTORS := 10
const ACTOR_SCAN := 12            # ticks between grid queries (5 Hz)
const LOS_RAYS := 4
const LOS_REFRESH := 6
const KIND_MAP := {"companion": "kora", "fish": "fauna", "predator": "fauna", "fauna": "fauna", "vessel": "vessel"}

var world = null                # WorldQuery: ray(from, to) -> {position, normal} or {} (null = everything visible)
var landmarks: Array = []       # POI records, static
var registry = null             # ActorRegistry
var self_id := ""
var _actors: Array = []         # the nearest actors at the last scan (registry Actor objects)
var tick := 0
var rays_this_tick := 0
var _los := {}                  # id -> [tick tested, visible]
var rays_total := 0             # diagnostics

## The sense dictionary body_rig.update_swim takes: {pois, cameraFwd, checkLineOfSight}.
## head: her eye. schools: [{id, label, positions}].
func build(head: Vector3, camera_fwd, schools: Array) -> Dictionary:
	tick += 1
	rays_this_tick = 0
	var pois: Array = []
	if registry != null:
		if tick % ACTOR_SCAN == 1 or ACTOR_SCAN <= 1:
			_actors = registry.near(head, VISION_RANGE, [], self_id).slice(0, MAX_ACTORS)
		for a in _actors:
			if registry.actors.get(a.id) != a: continue     # removed since the scan
			if a.pos.distance_to(head) > maxf(VISION_RANGE, a.max_range): continue
			pois.append({"id": a.id, "kind": KIND_MAP.get(a.kind, a.kind), "label": a.label, "pos": a.pos,
				"priority": a.priority, "moving": a.moving, "selfRadius": a.radius, "maxRange": a.max_range})
	for sc in schools:
		var pts: PackedVector3Array = sc.positions
		if pts.is_empty(): continue
		var c := Vector3.ZERO
		var best_d := 18.0          # Thalassa: the closest fish within 18 m
		var best := -1
		for i in pts.size():
			c += pts[i]
			var d := pts[i].distance_to(head)
			if d < best_d: best_d = d; best = i
		c /= pts.size()
		if c.distance_to(head) <= 44.0:
			pois.append({"id": "%s_school" % sc.id, "kind": "fauna", "label": sc.get("label", "Fish School"), "pos": c,
				"priority": 0.83, "moving": true, "selfRadius": 1.5, "maxRange": 44.0})
		if best >= 0:
			pois.append({"id": "%s_fish" % sc.id, "kind": "fauna", "label": "Reef Fish", "pos": pts[best],
				"priority": 0.87, "moving": true, "selfRadius": 0.2, "maxRange": 20.0})
	for lm in landmarks:
		if (lm.pos as Vector3).distance_to(head) <= minf(VISION_RANGE, float(lm.get("maxRange", VISION_RANGE))):
			pois.append(lm)
	if pois.size() > MAX_POIS:
		pois.sort_custom(func(a, b): return (a.pos as Vector3).distance_squared_to(head) < (b.pos as Vector3).distance_squared_to(head))
		pois.resize(MAX_POIS)
	var out := {"pois": pois, "checkLineOfSight": check_los}
	if camera_fwd != null: out["cameraFwd"] = camera_fwd
	return out

## brain checkLineOfSight(from, to, poi): one ray that stops short of the target by its own radius (a rock's POI sits at
## its centre, inside its own collision), cached and budgeted.
func check_los(from: Vector3, to: Vector3, poi: Dictionary) -> bool:
	if world == null: return true
	var id := String(poi.get("id", ""))
	var c = _los.get(id)
	if c != null and tick - int(c[0]) < LOS_REFRESH: return c[1]
	if rays_this_tick >= LOS_RAYS:
		return c[1] if c != null else false
	rays_this_tick += 1
	rays_total += 1
	var d := to - from
	var L := d.length()
	var stop := float(poi.get("selfRadius", 0.3)) + 0.3
	var vis := true
	if L > stop + 0.05:
		vis = world.ray(from, from + d * ((L - stop) / L)).is_empty()
	_los[id] = [tick, vis]
	if _los.size() > 256: _los.clear()     # ids that left long ago (respawned fish, removed actors)
	return vis
