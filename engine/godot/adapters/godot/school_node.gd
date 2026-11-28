## FishSchool 0.1.0 (Godot adapter for M31): one school in the world. Steps the engine-free sim (core/m31_school) at a
## fixed rate, on a worker thread by default, and draws every fish with one MultiMesh per LOD (fish/school_fish.gdshader
## carries the swim). Reads the world only through WorldQuery (floor, nearest surface) plus one swept ray per fish that
## is near rock, and the perceived actors (M08: the girl first) as {pos, vel, radius, kind}.
## Threading: world queries run on the main thread (physics), then the step runs on a WorkerThreadPool task while the
## frame renders, and the swept guard runs on the main thread when the task is collected. Drawing interpolates between
## the last two steps, so 30, 60 and 120 fps show the same school.
## Use: var s := FishSchool.new(); s.species_id = "trevally"; s.count = 160; s.home = Vector3(...); add_child(s)
##      s.actors = [{"pos": girl_pos, "vel": girl_vel, "radius": 0.3, "kind": "player"}]   (each frame, or set perceive)
class_name FishSchool
extends Node3D

const Sim := preload("res://core/m31_school/school_sim.gd")
const Species := preload("res://core/m31_school/school_species.gd")
const WorldQuery := preload("res://adapters/godot/world_query.gd")
const StandIn := preload("res://fish/standin_fish_mesh.gd")
const CreatureMesh := preload("res://fish/creature_school_mesh.gd")
const SHADER := preload("res://fish/school_fish.gdshader")

@export var species_id := "lagoon_baitfish"
@export var count := 0                  # 0 = the record's school_size
@export var seed_ := 1
@export var home := Vector3.ZERO        # metres, the school's home (its rock); the sim's origin
@export var tethered := true            # keep the record's home radius (false = roams, e.g. an open-water school)
@export var threaded := true
@export var body_m := -1.0              # metres; <= 0: the record's stand-in until the maker's glb gives it
@export var lod_dist := Vector2(12.0, 30.0)   # metres to the camera: LOD0 within x, LOD1 within y, LOD2 beyond
@export var look := {}                  # shader overrides (back_colour, stripe, ...)
@export var collision_mask := 1
@export var bank_gain := 1.0            # art multiplier on Thalassa's roll law (wildlife-ecosystem.js: 0.22 x yaw rate, cap 0.40 rad)

var sim
var params: Dictionary
var actors: Array = []
var perceive: Array[Node3D] = []
var perceive_radius := 0.25             # metres: the girl's body radius (a capsule along her motion)
var perceive_half_len := 0.55           # metres: half her length less the radius (a swimming child is ~1.4-1.6 m)        # nodes perceived as actors (velocity from their motion), added to `actors`
var water_y = null                      # Callable(x, z, t) -> float, e.g. WorldRoot.water.water_y
var current = null                      # Callable(p, t) -> Vector3
var paused := false
var wq
var seg_fn: Callable = segment_hit     # the swept guard's ray (tests may swap it)
var _acc := 0.0
var _task := -1
var _prev := PackedVector3Array()
var _cur := PackedVector3Array()
var _eprev := PackedVector3Array()
var _ecur := PackedVector3Array()
var _bank := PackedFloat64Array()
var _mm: Array[MultiMeshInstance3D] = []
var _mat: ShaderMaterial
var _perceive_last := {}
var _actors_next: Array = []
var actor_fn = null                     # optional Callable(sim_t) -> actors, evaluated at the step's own time (tests, cutscenes)
# drawing reads only these snapshots, taken when a step is collected (never the sim's arrays mid-step)
var _ph_prev := PackedFloat64Array()
var _ph_cur := PackedFloat64Array()
var _d_v := PackedFloat64Array()
var _d_s := PackedFloat64Array()
var _d_yaw := PackedFloat64Array()
var step_ms := 0.0                      # last step's cost on its thread (ms)
var main_ms := 0.0                      # this frame's main-thread cost (queries + guard + drawing), ms

var use_asset := true                   # draw the creature maker's export when the species record names one and it is present
var asset := {}                          # {meshes, swim, bl_m} of that export ({} = the stand-in)
var _swim_ph := PackedFloat64Array()     # drawing-side swim phase (the export's beat law), rad
var _bc_t := PackedFloat64Array()        # burst-and-coast: time into this fish's phrase (s); < 0 = steady swimming
var _bc_k := PackedFloat64Array()        # burst-and-coast: drawn amplitude factor (1 beating, eases to 0 in a glide)
const BC_BEATS := 2.0                    # beats per burst (export r2: below U_min the engine swims beats then a glide)

func _ready() -> void:
	var aid: String = Species.params(species_id).get("asset", "")
	if use_asset and CreatureMesh.available(aid):
		asset = CreatureMesh.load_species(aid, look)
		if not asset.is_empty() and body_m <= 0.0: body_m = asset.bl_m     # body length from the glb (agreed with the maker)
	params = Species.params(species_id, body_m)
	if not tethered: params.R_home = 0.0
	var n: int = count if count > 0 else params.school_size
	sim = Sim.new()
	sim.setup(params, n, seed_, params.bl_m, home)
	wq = WorldQuery.new(get_world_3d(), collision_mask)
	_mat = ShaderMaterial.new(); _mat.shader = SHADER
	for k in look: _mat.set_shader_parameter(k, look[k])
	for lod in 3:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = asset.meshes[lod] if not asset.is_empty() else StandIn.build(lod)
		mm.instance_count = n
		mm.visible_instance_count = 0
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		if asset.is_empty(): mi.material_override = _mat     # an export carries its own materials per surface
		mi.top_level = true
		mi.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))   # fish roam; culled per fish below
		add_child(mi)
		_mm.append(mi)
	_spawn_outside_rock()
	_take_snapshot(); _take_snapshot()
	_bank.resize(n)
	_swim_ph.resize(n)
	for i in n: _swim_ph[i] = sim.phase[i]
	_bc_t.resize(n); _bc_k.resize(n)
	var rb := RandomNumberGenerator.new(); rb.seed = seed_ * 31 + 5
	for i in n: _bc_t[i] = rb.randf() * 3.0; _bc_k[i] = 1.0      # staggered phrases, so the school doesn't pulse together

## Fish spawned behind rock (the school's start cloud overlapping a reef) move to free spots of the cloud (seeded).
func _spawn_outside_rock() -> void:
	if not is_inside_tree(): return
	var r := RandomNumberGenerator.new(); r.seed = seed_ * 7919 + 17
	for i in sim.N:
		var wp: Vector3 = sim.origin + sim.x[i] * sim.bl
		if segment_hit(home, wp).is_empty(): continue
		# a fish spawned behind rock moves to a free spot of the spawn cloud (not onto home: that packs them)
		var sp: float = sim.p.spread / 2.5
		for _try in 32:
			var q := Vector3(r.randf_range(-1, 1), r.randf_range(-0.3, 0.3), r.randf_range(-1, 1)) * sp * 2.0
			if segment_hit(home, sim.origin + q * sim.bl).is_empty():
				sim.x[i] = q
				break
	sim.x_prev = sim.x.duplicate()

func env() -> Dictionary:
	wq.top = home.y + 40.0
	var d := {"floor_height": wq.floor_height, "nearest_surface": wq.nearest_surface, "segment_hit": seg_fn}
	if water_y != null: d["water_y"] = water_y
	if current != null: d["current"] = current
	return d

## The swept guard's ray (world metres): {point, normal} of the first face from a to b, or {}.
func segment_hit(a: Vector3, b: Vector3) -> Dictionary:
	var rq := PhysicsRayQueryParameters3D.create(a, b, collision_mask)
	var h := get_world_3d().direct_space_state.intersect_ray(rq)
	return {} if h.is_empty() else {"point": h.position, "normal": h.normal}

func _snapshot_x() -> PackedVector3Array:
	var out := PackedVector3Array(); out.resize(sim.N)
	for i in sim.N: out[i] = sim.origin + sim.x[i] * sim.bl
	return out

func _update_actors(delta: float) -> void:
	var list := actors.duplicate()
	for nd in perceive:
		if not is_instance_valid(nd): continue
		var pnow := nd.global_position
		var last: Vector3 = _perceive_last.get(nd.get_instance_id(), pnow)
		_perceive_last[nd.get_instance_id()] = pnow
		var vel := (pnow - last) / maxf(delta, 1e-4)
		var ax := vel.normalized() if vel.length() > 0.05 else nd.global_basis.x.normalized()
		list.append({"pos": pnow, "vel": vel, "radius": perceive_radius, "axis": ax, "half_len": perceive_half_len, "kind": "player"})
	_actors_next = list      # handed to the sim only when no step is in flight (no race with the worker)

func _step_actors() -> Array:
	var list := _actors_next.duplicate()
	if actor_fn != null: list.append_array(actor_fn.call(sim.t))
	return list

func _collect() -> void:
	if _task >= 0:
		var tw := Time.get_ticks_usec()
		WorkerThreadPool.wait_for_task_completion(_task)
		wait_ms = (Time.get_ticks_usec() - tw) / 1000.0   # time the caller blocked on the worker (0 when it had a whole interval)
		_task = -1
		var t0 := Time.get_ticks_usec()
		sim.guard(seg_fn)
		main_ms += (Time.get_ticks_usec() - t0) / 1000.0
		_take_snapshot()

func _take_snapshot() -> void:
	_prev = _cur; _eprev = _ecur; _ph_prev = _ph_cur
	_cur = _snapshot_x(); _ecur = sim.e.duplicate(); _ph_cur = sim.phase.duplicate()
	_d_v = sim.v.duplicate(); _d_s = sim.s.duplicate(); _d_yaw = sim.yaw_rate.duplicate()

func _threaded_step() -> void:
	var t0 := Time.get_ticks_usec()
	sim.step({})
	step_ms = (Time.get_ticks_usec() - t0) / 1000.0

## Advance by delta seconds (called from _process; tests call it directly with a fixed delta).
var _draw_dt := 1.0 / 60.0
var draw_ms := 0.0
var wait_ms := 0.0                      # last collect's block on the worker step (not in main_ms)

## Advance the school by delta seconds. draw=false steps only (for a fixed physics tick); then call draw_now() once per
## rendered frame from _process.
func advance(delta: float, draw := true) -> void:
	_draw_dt = delta
	main_ms = 0.0
	wait_ms = 0.0
	if paused:
		if draw: _draw(1.0)
		return
	_update_actors(delta)
	_acc += delta
	if threaded:
		# pipelined: when a step's time is up, collect the step that ran during the last frame(s) and start the next,
		# so each step gets a whole sim interval on its worker; at most one in flight
		_acc = minf(_acc, 3.0 * sim.dt)
		if _acc >= sim.dt:
			_collect()
			_acc -= sim.dt
			# below 30 fps: one extra step here on the main thread keeps the school in real time (down to 15 fps)
			if _acc >= sim.dt:
				sim.actors = _step_actors()
				sim.step(env())
				_take_snapshot()
				_acc -= sim.dt
			sim.actors = _step_actors()
			var t0 := Time.get_ticks_usec()
			sim.world_queries(env())
			main_ms += (Time.get_ticks_usec() - t0) / 1000.0
			_task = WorkerThreadPool.add_task(_threaded_step, false, "fish school step")
		# drawn one step behind the sim (the step in flight), interpolated over its interval
		if draw: _draw(clampf(_acc / sim.dt, 0.0, 1.0))
	else:
		var guard := 0
		while _acc >= sim.dt and guard < 4:
			var t0 := Time.get_ticks_usec()
			sim.actors = _step_actors()
			sim.step(env())
			step_ms = (Time.get_ticks_usec() - t0) / 1000.0
			_take_snapshot()
			_acc -= sim.dt
			guard += 1
		if guard == 4: _acc = 0.0      # a hitch: drop time rather than spiral
		if draw: _draw(clampf(_acc / sim.dt, 0.0, 1.0))

## Draw once per rendered frame when advance() runs on a physics tick with draw=false. since_tick = render time since
## the last advance() (e.g. Engine.get_physics_interpolation_fraction() / Engine.physics_ticks_per_second).
func draw_now(since_tick := 0.0, frame_delta := 1.0 / 60.0) -> void:
	_draw_dt = frame_delta
	var keep := main_ms
	main_ms = 0.0
	_draw(clampf((_acc + since_tick) / sim.dt, 0.0, 1.0))
	draw_ms = main_ms
	main_ms = keep + draw_ms

## Finish any step in flight (tests, before reading the state).
func sync() -> void:
	_collect()

func _process(delta: float) -> void:
	advance(delta)

func _exit_tree() -> void:
	if _task >= 0: WorkerThreadPool.wait_for_task_completion(_task); _task = -1

func _draw(alpha: float) -> void:
	var t0 := Time.get_ticks_usec()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var cp := cam.global_position if cam else home
	var frustum: Array = cam.get_frustum() if cam else []
	var n: int = sim.N
	var counts := [0, 0, 0]
	var bl: float = sim.bl
	var cap: float = params.get("bend_cap", 2.5)
	for i in n:
		var pos := _prev[i].lerp(_cur[i], alpha)
		var fwd := _eprev[i].lerp(_ecur[i], alpha)
		if fwd.length() < 1e-6: fwd = Vector3.RIGHT
		fwd = fwd.normalized()
		var r: float = bl * sim.L[i]
		# skip fish outside the view (plus a body length)
		var inside := true
		for pl in frustum:
			if (pl as Plane).distance_to(pos) > r: inside = false; break
		if not inside: continue
		var dcam := pos.distance_to(cp)
		var lod := 0 if dcam < lod_dist.x else (1 if dcam < lod_dist.y else 2)
		# bank into the turn: Thalassa v20.19 wildlife-ecosystem.js (roll = 0.22 x yaw rate, cap 0.40 rad, eased at 5.5/s),
		# the tuning Gary saw in the prototype; replaces the earlier atan(v w / g) x 3 guess
		var v: float = _d_v[i]
		var yaw: float = _d_yaw[i]
		_bank[i] = lerpf(_bank[i], clampf(yaw * 0.22 * bank_gain, -0.40, 0.40), 1.0 - exp(-5.5 * _draw_dt))
		var bank: float = _bank[i]
		var basis := fish_basis(fwd, bank).scaled(Vector3(r, r, r))
		var mm := _mm[lod].multimesh
		var k: int = counts[lod]
		mm.set_instance_transform(k, Transform3D(basis, pos))
		var bend := clampf(-yaw / maxf(v, 0.3), -cap, cap)     # body curvature x L into the turn
		var amp: float
		var ph: float
		if not asset.is_empty():
			var ub: float = _swim_drive(i, v)
			ph = _swim_ph[i]
			amp = _bc_k[i] * CreatureMesh.amp_scale(asset.swim, ub) * (1.0 + 0.5 * _d_s[i])
			mm.set_instance_custom_data(k, Color(ph, ub, bend, amp))
			counts[lod] = k + 1
			continue
		else:
			var f: float = (4.0 * v / sim.L[i] + 4.0) / 3.0
			amp = clampf(0.5 * 0.3 * v / maxf(f, 0.1), 0.02, 0.12) * (1.0 + 0.8 * _d_s[i])   # Strouhal 0.3
			var dph := wrapf(_ph_cur[i] - _ph_prev[i], -PI, PI)
			ph = _ph_prev[i] + dph * alpha
		mm.set_instance_custom_data(k, Color(ph, amp, bend, _d_s[i]))
		counts[lod] = k + 1
	for lod in 3: _mm[lod].multimesh.visible_instance_count = counts[lod]
	main_ms += (Time.get_ticks_usec() - t0) / 1000.0

## The export's playback rule (r2) for fish i at speed v (BL/s): at or above steady.U_min, a steady wave at v (tables
## blended at v, beat at f(v)); below it, burst-and-coast phrases: BC_BEATS beats at f(U_min) on the U_min table, then
## a glide (amplitude eases out, phase held, the body straightens), the glide lengthening as the fish slows (duty =
## v / U_min, at least 0.25). A startled fish always beats. Returns the drawn speed U (which table the shader uses).
func _swim_drive(i: int, v: float) -> float:
	var sw: Dictionary = asset.swim
	var um: float = CreatureMesh.u_min(sw)
	var dt := _draw_dt
	if um <= 0.0 or v >= um or _d_s[i] > 0.05:
		_bc_k[i] = lerpf(_bc_k[i], 1.0, 1.0 - exp(-dt / 0.1))
		_swim_ph[i] = fmod(_swim_ph[i] + TAU * CreatureMesh.beat_hz(sw, v) * dt, TAU)
		return maxf(v, um)
	var f: float = CreatureMesh.beat_hz(sw, um)
	var tb: float = BC_BEATS / f                          # burst length (s)
	var period: float = tb / clampf(v / um, 0.25, 1.0)     # burst + glide
	_bc_t[i] = fmod(_bc_t[i] + dt, period)
	if _bc_t[i] < tb:
		_bc_k[i] = lerpf(_bc_k[i], 1.0, 1.0 - exp(-dt / 0.1))
		_swim_ph[i] = fmod(_swim_ph[i] + TAU * f * dt, TAU)
	else:
		_bc_k[i] = lerpf(_bc_k[i], 0.0, 1.0 - exp(-dt / 0.15))
		if _bc_k[i] > 0.3: _swim_ph[i] = fmod(_swim_ph[i] + TAU * f * dt, TAU)   # finish the stroke, then hold
	return um

## A fish's drawn frame: x = heading (head toward +x in the mesh), y = its back, rolled by bank (positive rolls the back
## toward its left, into a left turn), z = x cross y. Upright for a level heading (check S15; it was upside down to 28 Nov).
static func fish_basis(fwd: Vector3, bank: float) -> Basis:
	var side := Vector3.UP.cross(fwd)
	if side.length() < 1e-4: side = Vector3.FORWARD
	side = side.normalized()
	var up := fwd.cross(side).normalized().rotated(fwd, -bank)
	return Basis(fwd, up, fwd.cross(up).normalized())

func metrics() -> Dictionary:
	return sim.metrics()
