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
@export var lod_dist := Vector2(12.0, 25.0)   # metres to the camera: LOD0 within x, LOD1 within y, LOD2 beyond (no shadow past 25 m, schoollab v47)
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
var vary_look := true                   # each fish its own size, beat rate, amplitude and slowly wandering pose
var _p_size := PackedFloat64Array()      # drawn size factor (on top of the sim's L), ~N(1, 0.10): ~11 % with L
var _p_rate := PackedFloat64Array()      # beat-rate factor, ~N(1, 0.06)
var _p_amp := PackedFloat64Array()       # swim amplitude factor, ~N(1, 0.10)
var _p_bc := PackedFloat64Array()        # where in its burst a phrase starts (0..1)
var _p_w := PackedFloat64Array()         # pose wander rates (curl, lean), rad/s
var _p_ph := PackedFloat64Array()        # pose wander phases
var _look_t := 0.0
var look_pitch_off := PackedFloat64Array()  # drawn pitch offset (rad), each fish's own
var look_yaw_off := PackedFloat64Array()  # drawn heading offset about up (rad), each fish's own
var _k_bank_fast := 0.0; var _k_head := 0.0; var _k_yaw := 0.0; var _k_v := 0.0; var _k_bank := 0.0; var _k_bc_up := 0.0; var _k_bc_down := 0.0
var _cap := 2.5
var _u_min := 0.0; var _f_umin := 1.0; var _amp_flat := true
var _beat_tab_u := PackedFloat64Array(); var _beat_tab_f := PackedFloat64Array()
var smooth_look := true                 # zero-twitch drawing (Thalassa); false = the raw sim heading, speed and turn rate
var look_fwd := PackedVector3Array()     # drawn heading
var look_yaw := PackedFloat64Array()     # drawn turn rate about up (rad/s, + = left)
var look_v := PackedFloat64Array()       # drawn swim speed (BL/s)
var look_bend := PackedFloat64Array()    # drawn body bend
var look_u := PackedFloat64Array()       # drawn wave speed (which swim table; BL/s)
var look_amp := PackedFloat64Array()     # drawn swim amplitude factor
var look_coast := PackedByteArray()      # 1 while the fish swims burst-and-coast phrases (below U_min, with hysteresis)
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
		if lod == 2: mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # far fish cast no shadow (schoollab v47, Gary 2 Nov)
		mi.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))   # fish roam; culled per fish below
		add_child(mi)
		_mm.append(mi)
	_spawn_outside_rock()
	_take_snapshot(); _take_snapshot()
	_bank.resize(n)
	_swim_ph.resize(n)
	for i in n: _swim_ph[i] = sim.phase[i]
	_bc_t.resize(n); _bc_k.resize(n)
	look_fwd.resize(n); look_yaw.resize(n); look_v.resize(n); look_bend.resize(n); look_u.resize(n); look_amp.resize(n)
	look_coast.resize(n)
	for i in n: look_fwd[i] = sim.e[i]; look_v[i] = sim.v[i]
	_vary_setup(n)
	_cap = params.get("bend_cap", 2.5)
	_swim_setup()
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
	var dt := _draw_dt
	_frame_consts(dt)
	var has_asset := not asset.is_empty()
	var lx: float = lod_dist.x * lod_dist.x; var ly: float = lod_dist.y * lod_dist.y
	var mms: Array = [_mm[0].multimesh, _mm[1].multimesh, _mm[2].multimesh]
	for i in n:
		var pos := _prev[i].lerp(_cur[i], alpha)
		_look(i, alpha)
		var r: float = bl * sim.L[i] * _p_size[i]
		# skip fish outside the view (plus a body length)
		var inside := true
		for pl in frustum:
			if (pl as Plane).distance_to(pos) > r: inside = false; break
		if not inside: continue
		var d2 := pos.distance_squared_to(cp)
		var lod := 0 if d2 < lx else (1 if d2 < ly else 2)
		var mm: MultiMesh = mms[lod]
		var k: int = counts[lod]
		mm.set_instance_transform(k, Transform3D(fish_basis(drawn_heading(i), _bank[i]).scaled(Vector3(r, r, r)), pos))
		if has_asset:
			mm.set_instance_custom_data(k, Color(_swim_ph[i], look_u[i], look_bend[i], look_amp[i]))
		else:
			mm.set_instance_custom_data(k, Color(_swim_ph[i], look_amp[i], look_bend[i], _d_s[i]))
		counts[lod] = k + 1
	for lod in 3: (mms[lod] as MultiMesh).visible_instance_count = counts[lod]
	main_ms += (Time.get_ticks_usec() - t0) / 1000.0

## Caches the export's swim numbers (U_min, beat table) for the per-frame drawing.
func _swim_setup() -> void:
	_beat_tab_u = PackedFloat64Array(); _beat_tab_f = PackedFloat64Array()
	if asset.is_empty(): return
	_u_min = CreatureMesh.u_min(asset.swim)
	_amp_flat = CreatureMesh.has_speed_envelopes(asset.swim)
	for e in asset.swim.get("wave", {}).get("envelopes_by_speed", []):
		_beat_tab_u.append(float(e.U_BLps)); _beat_tab_f.append(float(e.beat_Hz))
	_f_umin = _beat_u(_u_min) if _u_min > 0.0 else 1.0

## Per-frame easing constants (frame-rate independent), computed once a frame rather than once a fish.
func _frame_consts(dt: float) -> void:
	_look_t += dt
	_k_head = 1.0 - exp(-5.2 * dt); _k_yaw = 1.0 - exp(-6.5 * dt); _k_v = 1.0 - exp(-3.0 * dt); _k_bank = 1.0 - exp(-5.5 * dt); _k_bank_fast = 1.0 - exp(-14.0 * dt)
	_k_bc_up = 1.0 - exp(-dt / 0.1); _k_bc_down = 1.0 - exp(-dt / 0.15)

func _vary_setup(n: int) -> void:
	look_yaw_off.resize(n); look_pitch_off.resize(n)
	_p_size.resize(n); _p_rate.resize(n); _p_amp.resize(n); _p_bc.resize(n); _p_w.resize(4 * n); _p_ph.resize(4 * n)
	var r := RandomNumberGenerator.new(); r.seed = seed_ * 7741 + 3
	for i in n:
		var on := vary_look
		_p_size[i] = clampf(1.0 + 0.10 * r.randfn(), 0.8, 1.2) if on else 1.0
		_p_rate[i] = clampf(1.0 + 0.06 * r.randfn(), 0.88, 1.12) if on else 1.0
		_p_amp[i] = clampf(1.0 + 0.10 * r.randfn(), 0.8, 1.2) if on else 1.0
		_p_bc[i] = r.randf() * 0.9 if on else 0.0
		for j in 4:
			_p_w[4 * i + j] = r.randf_range(TAU / 10.0, TAU / 7.0) if j == 1 else r.randf_range(0.35, 1.0)   # sway period 7-10 s (v32)
			_p_ph[4 * i + j] = r.randf() * TAU

## What the viewer sees of fish i this frame (every fish, drawn or not, so filters never jump when a fish comes into view).
## Zero-twitch drawing, ported from Thalassa v20.19 wildlife-ecosystem.js ("speed deadband + slew-rate capped yaw +
## yawRate-based smooth banking"): the sim's heading carries the paper's per-step turning noise at 30 Hz, which drawn
## raw reads as twitching. The drawn heading follows it at 5.2/s, at most 2.15 rad/s (+3 when startled); the turn rate
## for bank and body bend comes from the drawn heading, clamped to 3.5 rad/s and eased at 6.5/s; the swim speed is eased
## at 3/s. The sim (positions, rules, checks) is untouched. smooth_look = false draws the raw sim (the old look).
func _look(i: int, alpha: float) -> void:
	var dt := _draw_dt
	var raw := _eprev[i].lerp(_ecur[i], alpha)
	if raw.length_squared() < 1e-12: raw = look_fwd[i] if look_fwd[i].length_squared() > 0.25 else Vector3.RIGHT
	raw = raw.normalized()
	var v: float = _d_v[i]
	var st: float = _d_s[i]
	var prev: Vector3 = look_fwd[i]
	var f := raw
	if smooth_look and prev.length_squared() > 0.25:
		var ang := prev.angle_to(raw)
		if ang > 1e-5:
			var stp := minf(ang * _k_head, (2.15 + 3.0 * st) * dt)
			f = prev.slerp(raw, stp / ang)
		else:
			f = prev
		var yaw_inst := 0.0
		var hp2 := prev.x * prev.x + prev.z * prev.z
		var hf2 := f.x * f.x + f.z * f.z
		if hp2 > 1e-8 and hf2 > 1e-8:
			# signed angle about up from prev to f in the horizontal plane (+ = left)
			yaw_inst = clampf(atan2(prev.z * f.x - prev.x * f.z, prev.x * f.x + prev.z * f.z) / dt, -3.5, 3.5)
		look_yaw[i] += (yaw_inst - look_yaw[i]) * _k_yaw
		look_v[i] += (v - look_v[i]) * _k_v
	else:
		look_yaw[i] = _d_yaw[i]
		look_v[i] = v
	look_fwd[i] = f
	var yaw: float = look_yaw[i]
	var vv: float = look_v[i]
	# each fish's own pose: a slow personal curl and roll that wander (Fable critique 28 Nov: "clones, same pose")
	var curl := 0.0; var lean := 0.0
	if vary_look:
		curl = 0.35 * sin(_look_t * _p_w[4 * i] + _p_ph[4 * i])
		lean = 0.12 * sin(_look_t * _p_w[4 * i + 1] + _p_ph[4 * i + 1])     # ~7 deg sway (schoollab v32), so the far wall glints
		# heading spread (key frame v7c critique 28 Nov: "it still shares one heading"): each fish points up to 15 deg
		# (SD ~10 deg) off the school's heading and up to 6 deg in pitch, wandering slowly; drawn only, the path is the sim's
		look_yaw_off[i] = 0.26 * sin(_look_t * _p_w[4 * i + 2] + _p_ph[4 * i + 2])
		look_pitch_off[i] = 0.10 * sin(_look_t * _p_w[4 * i + 3] + _p_ph[4 * i + 3])
	# bank into the turn: Thalassa roll = 0.22 x yaw rate, cap 0.40 rad, eased at 5.5/s
	# silver flash (schoollab v32, Gary 1 Nov "ripples of light that run across the school when it's alarmed"): a
	# startled or agitated fish rolls up to 60 deg toward its turn and back as the startle fades, so the alarm wave runs
	# across the school as flashes of flank (real silver schools flash because the fish roll, PLOS ONE 2023)
	var flash := (1.05 if yaw >= 0.0 else -1.05) * st
	var kb: float = _k_bank_fast if st > 0.2 else _k_bank
	_bank[i] += (clampf(yaw * 0.22 * bank_gain, -0.40, 0.40) + lean + flash - _bank[i]) * kb
	look_bend[i] = clampf(-yaw / maxf(vv, 0.3) + curl, -_cap, _cap)
	if not asset.is_empty():
		look_u[i] = _swim_drive(i, vv)
		look_amp[i] = _bc_k[i] * _amp_scale_u(look_u[i]) * _p_amp[i] * (1.0 + 0.5 * st)
	else:
		var fb: float = (4.0 * vv / sim.L[i] + 4.0) / 3.0
		look_amp[i] = clampf(0.5 * 0.3 * vv / maxf(fb, 0.1), 0.02, 0.12) * _p_amp[i] * (1.0 + 0.8 * st)   # Strouhal 0.3
		if smooth_look:
			_swim_ph[i] = fmod(_swim_ph[i] + TAU * fb * _p_rate[i] * dt, TAU)   # phase advanced at the drawn rate
		else:
			_swim_ph[i] = _ph_prev[i] + wrapf(_ph_cur[i] - _ph_prev[i], -PI, PI) * alpha
		look_u[i] = vv

## Beat (Hz) at U from the export, cached at _ready (CreatureMesh.beat_hz walks dictionaries; this is per fish per frame).
func _beat_u(U: float) -> float:
	var n := _beat_tab_u.size()
	if n < 2: return CreatureMesh.beat_hz(asset.swim, U)
	var j := 1
	while j < n - 1 and U > _beat_tab_u[j]: j += 1
	return maxf(0.3, _beat_tab_f[j - 1] + (_beat_tab_f[j] - _beat_tab_f[j - 1]) * (U - _beat_tab_u[j - 1]) / maxf(_beat_tab_u[j] - _beat_tab_u[j - 1], 1e-5))

func _amp_scale_u(U: float) -> float:
	return 1.0 if _amp_flat else CreatureMesh.amp_scale(asset.swim, U)

## The export's playback rule (r2) for fish i at speed v (BL/s): at or above steady.U_min, a steady wave at v (tables
## blended at v, beat at f(v)); below it, burst-and-coast phrases: BC_BEATS beats at f(U_min) on the U_min table, then
## a glide (amplitude eases out, phase held, the body straightens), the glide lengthening as the fish slows (duty =
## v / U_min, at least 0.25). A startled fish always beats. Returns the drawn speed U (which table the shader uses).
func _swim_drive(i: int, v: float) -> float:
	var um: float = _u_min
	var dt := _draw_dt
	# steady or phrases: with smooth_look the switch has hysteresis (into phrases below 0.9 U_min, back at U_min), so a
	# fish cruising at the threshold (trevally v0 1.4 BL/s vs U_min 1.45) no longer flips mode frame to frame
	var coast: bool
	if not smooth_look: coast = um > 0.0 and v < um
	elif look_coast[i] == 1: coast = v < um
	else: coast = um > 0.0 and v < 0.9 * um
	if _d_s[i] > 0.05: coast = false
	var rate: float = _p_rate[i]
	var f: float = _f_umin * rate
	var tb: float = BC_BEATS / f                          # burst length (s)
	# a phrase starts inside its beats (no jump into a glide), at the fish's own offset so neighbours don't sync
	if smooth_look and coast and look_coast[i] == 0: _bc_t[i] = _p_bc[i] * tb
	look_coast[i] = 1 if coast else 0
	if not coast:
		_bc_k[i] += (1.0 - _bc_k[i]) * _k_bc_up
		_swim_ph[i] = fmod(_swim_ph[i] + TAU * _beat_u(v) * rate * dt, TAU)
		return maxf(v, um)
	var period: float = tb / clampf(v / um, 0.25, 1.0)     # burst + glide
	_bc_t[i] = fmod(_bc_t[i] + dt, period)
	if _bc_t[i] < tb:
		_bc_k[i] += (1.0 - _bc_k[i]) * _k_bc_up
		_swim_ph[i] = fmod(_swim_ph[i] + TAU * f * dt, TAU)
	else:
		_bc_k[i] -= _bc_k[i] * _k_bc_down
		if _bc_k[i] > 0.3: _swim_ph[i] = fmod(_swim_ph[i] + TAU * f * dt, TAU)   # finish the stroke, then hold
	return um

## The heading fish i is drawn with: the smoothed heading plus its own yaw and pitch offsets.
func drawn_heading(i: int) -> Vector3:
	var f: Vector3 = look_fwd[i].rotated(Vector3.UP, look_yaw_off[i])
	var side := Vector3.UP.cross(f)
	if side.length_squared() > 1e-8: f = f.rotated(side.normalized(), look_pitch_off[i])
	return f

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
