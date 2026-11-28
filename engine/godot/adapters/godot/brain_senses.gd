## BrainSenses, Godot adapter 0.1.0 (M04 brain port, 28 Nov 2026): the girl's senses in the running game. Gathers what
## core/m04_body/sense_context.gd needs from the engine side, once per player tick:
##   actors     the ActorRegistry's committed actors near her (last tick's commit: the player phase runs before the
##              actors phase, as Thalassa's fauna sync ran before its brain)
##   schools    each FishSchool node's last snapshot of fish positions (_cur: replaced whole on the main thread when a
##              step is collected, never written in place, so reading it while the worker steps is safe)
##   landmarks  the authored place's rock heads and coral heads (DressCell items, re-read every LANDMARK_REFRESH ticks)
##   camera     the game camera's forward (the brain's focus-intent cue)
##   sight      one Jolt ray per POI through a WorldQuery that ignores her own body (budgeted in the core)
## ActorRig.tick calls sense(eye) and hands the result to the body rig.
extends RefCounted

const SenseContext := preload("res://core/m04_body/sense_context.gd")

var core = SenseContext.new()
var actors = null              # ActorRegistry
var self_id := "girl"
var schools: Array = []        # FishSchool nodes
var camera: Camera3D = null
var dress = null               # DressCell
var _landmark_tick := -1
const LANDMARK_REFRESH := 300  # ticks: re-read the place now and then (it is seated a frame after it is built)
var wq = null:                 # WorldQuery (the rig's, with her body excluded): the line-of-sight rays
	set(v): wq = v; core.world = v

func sense(eye: Vector3) -> Dictionary:
	if dress != null and is_instance_valid(dress) and (_landmark_tick < 0 or core.tick - _landmark_tick >= LANDMARK_REFRESH):
		core.landmarks = landmarks_of(dress)
		_landmark_tick = core.tick
	core.registry = actors; core.self_id = self_id
	var sc: Array = []
	for s in schools:
		if is_instance_valid(s) and s.sim != null:
			sc.append({"id": "%s_%d" % [s.species_id, s.seed_], "label": "Fish School", "positions": s._cur})
	var cf = -camera.global_basis.z.normalized() if camera != null and is_instance_valid(camera) else null
	return core.build(eye, cf, sc)

## Rock heads and coral heads of an authored place as static POIs (sand skirts, meadow tiles and rubble aprons are
## ground, not things to look at). The focal head with the gate is Thalassa's 'arch'.
static func landmarks_of(d) -> Array:
	var out := []
	for e in d.items:
		var p: String = e.p
		var kind: String = e.kind
		if kind != "rock" and kind != "coral": continue
		if "rubble" in p: continue
		var bb: AABB = d._aabb_world(e.node)
		if bb.size == Vector3.ZERO: continue
		var role := String(e.item.get("role", ""))
		var is_arch := "arch" in role or "gate" in role
		var lk := "arch" if is_arch else ("rock" if kind == "rock" else "coral")
		out.append({"id": "%s_%d" % [p, out.size()], "kind": lk, "label": role.get_slice(",", 0) if role != "" else p,
			"pos": bb.get_center(), "priority": 0.80 if is_arch else (0.70 if kind == "rock" else 0.72), "moving": false,
			"selfRadius": maxf(bb.size.x, bb.size.z) * 0.5, "maxRange": 54.0})
	return out
