## M02 Layered moves, core 0.2.0: GDScript port of Thalassa v20.19 core/mover.js LayeredMove + the layered-move
## half of MoverComponent.step (Mover 2.0 style). Stackable, timed or persistent velocity modifiers per mode.
## Differences from the JS: ids are required or come from a counter (the JS used Date.now() + Math.random()).
extends RefCounted

const ADDITIVE := "AdditiveVelocity"
const OVERRIDE := "OverrideVelocity"

class LayeredMove:
	var id := ""
	var kind := "generic"
	var mix_mode := "AdditiveVelocity"
	var duration := 0.35        # <= 0 means persistent until removed
	var elapsed := 0.0
	var priority := 1
	var decay_power := 1.5
	var velocity := Vector3.ZERO
	var accel = null            # Vector3 or null
	var mode_filter: Array = []
	var evaluate_fn = null      # Callable(dt, move, sync, ctx) -> {mix_mode, delta_vel | velocity} or null
	var finished := false

	func active_for(mode_name: String) -> bool:
		if finished: return false
		return mode_filter.is_empty() or mode_filter.has(mode_name)

	func evaluate(dt: float, sync: Dictionary, ctx: Dictionary):
		if finished: return null
		if evaluate_fn != null:
			return evaluate_fn.call(dt, self, sync, ctx)
		var alpha := pow(clampf(1.0 - elapsed / duration, 0.0, 1.0), decay_power) if duration > 0.0 else 1.0
		if accel != null:
			return {"mix_mode": mix_mode, "delta_vel": accel * alpha * dt}
		return {"mix_mode": mix_mode, "velocity": velocity * alpha}

	func advance(dt: float) -> void:
		elapsed += dt
		if duration > 0.0 and elapsed >= duration:
			finished = true

var moves: Array = []
var _counter := 0

func queue(m: LayeredMove) -> LayeredMove:
	if m.id == "":
		_counter += 1; m.id = "lm_%d" % _counter
	for i in moves.size():
		if moves[i].id == m.id:
			moves[i] = m
			return m
	moves.append(m)
	return m

func remove(id: String) -> bool:
	for i in moves.size():
		if moves[i].id == id:
			moves.remove_at(i)
			return true
	return false

## MoverComponent.step part 1: combined proposal {override_velocity (Vector3 or null), layered_delta_vel, applied}.
func evaluate(dt: float, mode_name: String, sync: Dictionary, ctx: Dictionary) -> Dictionary:
	var add := Vector3.ZERO
	var override_vel = null
	var applied := []
	var i := moves.size() - 1
	while i >= 0:
		var lm: LayeredMove = moves[i]
		if lm.finished:
			moves.remove_at(i); i -= 1; continue
		if lm.active_for(mode_name):
			var res = lm.evaluate(dt, sync, ctx)
			if res != null:
				applied.append(lm.kind)
				if res.mix_mode == OVERRIDE and res.has("velocity"):
					override_vel = res.velocity
				elif res.has("delta_vel"):
					add += res.delta_vel
				elif res.has("velocity"):
					add += res.velocity * dt
		lm.advance(dt)
		if lm.finished: moves.remove_at(i)
		i -= 1
	return {"override_velocity": override_vel, "layered_delta_vel": add, "applied": applied}

## createOceanCurrentLayeredMove: persistent fluid advection (Swimming x1.15 / 0.85, Wading x0.42 / 0.32).
static func ocean_current(get_current: Callable) -> LayeredMove:
	var m := LayeredMove.new()
	m.id = "ocean_current"; m.kind = "OceanCurrent"; m.duration = 0.0; m.priority = 0
	m.mode_filter = ["Swimming", "Wading", "PilotSubmersible"]
	m.evaluate_fn = func(dt: float, _m, sync: Dictionary, ctx: Dictionary):
		if ctx.get("paused", false): return null
		var p: Vector3 = sync.position
		if sync.movement_mode == "Swimming" and p.y >= sync.get("surface_y", 0.0) - 0.25: return null
		var cur: Vector3 = get_current.call(p, ctx.get("total_time", 0.0))
		var sh := 1.15 if sync.movement_mode == "Swimming" else 0.42
		var sv := 0.85 if sync.movement_mode == "Swimming" else 0.32
		return {"mix_mode": ADDITIVE, "delta_vel": Vector3(cur.x * sh, cur.y * sv, cur.z * sh) * dt}
	return m

## createImpulseLayeredMove: a short decaying push (dash, current jet, bump recoil).
static func impulse(kind: String, dir: Vector3, magnitude: float, duration: float = 0.32, filter: Array = ["Swimming"]) -> LayeredMove:
	var m := LayeredMove.new()
	var n := dir.normalized() if dir.length() > 0.0 else Vector3.ZERO
	m.kind = kind; m.duration = duration; m.decay_power = 1.8; m.mode_filter = filter
	m.accel = n * magnitude / maxf(0.08, duration)
	return m
