## Bubbles 0.1.0 (bubbles thread, 28 Nov 2026): every air bubble under water, one MultiMesh (look/bubble.gdshader) fed by
## Thalassa's bubble sources, PORTED from Gary's Thalassa v20.19 (style/runtime.js spawnBubble call sites, style/particles.js)
## and drawn with the Unreal-era bubbles v4 look. A GameRoot plug (plug_tick in the "plugs" phase, after the girl moved).
## Sources (Thalassa -> here):
##  - exhale (runtime.js "gentle rising scuba exhale bubbles", every 0.11-0.19 s while sound.isExhaling) -> the breath
##    master clock (M04, PR #153): an exhale begun with the head under water (body_rig.underwater_exhales) lets air go along
##    the breath curve itself (count follows the drop of breathSignal, so most leaves mid-exhale), from the nose (65 %,
##    a jet aimed down and forward, as nostrils point) and the mouth; bigger and more with exertion; a blurp at the onset
##  - onSprintBurst (7 bubbles behind the kick) and onSprintTrail (behind her while sprinting) -> the swimmer's
##    sprint_burst_cd / sprinting, at her feet; real kicks only take air down near the surface, so deep ones carry 35 %
##  - onSplash (16-20 bubbles at a plunge) -> the swimmer's on_splash hook: plunging in drags a cloud of air down that then
##    rises; surfacing sheds a few from the body
##  - creatures (KORA impeller, sub wakes and vents are not in the Godot slice yet; fish and turtles do not blow bubbles)
##    -> the blockout stand-ins: a dolphin lets a blowhole stream go now and then, a humpback a rare bubble blast
##  - emit() / emit_burst(): the one entry point for any later source (vents, seagrass pearling, sand-puff gas, the sub)
## A bubble is one record in a ring of SLOTS; its whole life is a closed-form function of age (core/m34_bubbles/
## bubble_motion.gd), drawn at the render time between physics ticks. Births are spread over the tick they fall in, so a
## stream is even at 30, 60 or 120 Hz (no tick banding). Its cap (the surface over it, or the ceiling a ray finds) is set
## at birth: it rests there for a dwell and pops.
class_name Bubbles
extends MultiMeshInstance3D

const BM := preload("res://core/m34_bubbles/bubble_motion.gd")
const SLOTS := 2048
const REBASE_S := 900.0            # the shader's time base moves on every 15 min (float precision); records follow
const MAX_LIFE := 40.0             # s: a bubble that never reaches a cap dissolves
const NOSE := Vector3(0.0, -0.018, -0.088)    # head frame (z back): stand-in points on the mannequin's head
const MOUTH := Vector3(0.0, -0.052, -0.074)

var services = null
var girl = null                    # ActorRig
var riders: Array = []             # blockout creature stand-ins [{node, species, next, until, rate}]
var epoch := 0.0
var slot := 0
var live := 0                      # births so far (tests)
var births := {}                   # source -> count (tests, films)
var log_on := false                # tests: keep every birth record in 'log'
var log: Array = []
var plug_us := 0.0                 # last plug_tick's cost (microseconds)
var rng := RandomNumberGenerator.new()
var _xf: Array = []                # per slot: Transform3D record (t0 relative to epoch)
var _rec_t0 := PackedFloat64Array()
var _rec_end := PackedFloat64Array()
var _prev_t := 0.0
var _prev_head := Transform3D()
var _have_head := false
var _exh := {"on": false, "sig": 0.0, "n": 0.0, "total": 0.0}
var _seen_exhales := -1
var _last_cd := 0.0
var _trail := 0.0
var _splashes: Array = []
var _motes = null
var exhale_style := "lush"         # style choice "Exhale bubbles" (Gary picked lush 28 Nov): lush (fuller plume) | calm (real, thin stream); AO_EXHALE=calm
var stress_rate := 0.0             # AO_BUBBLE_STRESS=<bubbles/s>: a plume 1.5 m in front of the camera (speed worst case)
var _stress_acc := 0.0

func _init() -> void:
	name = "Bubbles"
	rng.seed = 0x5eed
	if OS.get_environment("AO_EXHALE") != "": exhale_style = OS.get_environment("AO_EXHALE")
	stress_rate = float(OS.get_environment("AO_BUBBLE_STRESS")) if OS.get_environment("AO_BUBBLE_STRESS") != "" else 0.0
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	var q := QuadMesh.new(); q.size = Vector2(1, 1)
	mm.mesh = q
	mm.instance_count = SLOTS
	mm.custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))   # placed in the shader
	multimesh = mm
	var mat := ShaderMaterial.new(); mat.shader = load("res://look/bubble.gdshader")
	mat.render_priority = 2          # after the underwater view (0) and the marine snow (1)
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	layers = 1 << 3                  # the eye's own layer (as the motes: the floor map's captures skip it)
	_xf.resize(SLOTS)
	_rec_t0.resize(SLOTS); _rec_end.resize(SLOTS)
	var dead := Transform3D(Basis(), Vector3.ZERO)
	for i in SLOTS:
		_xf[i] = dead
		_rec_t0[i] = -1e9; _rec_end[i] = -1e9
		mm.set_instance_transform(i, dead)
		mm.set_instance_custom_data(i, Color(0, -1, 0, 1))
		mm.set_instance_color(i, Color(0, 0, 0, 0))

# ------------------------------------------------------------------ plug
func plug_ready(s) -> void:
	services = s
	var gr := get_parent()
	if gr != null and "girl" in gr: girl = gr.girl
	if girl != null and girl.body != null:
		girl.body._env_dict["on_splash"] = _on_splash     # the swimmer's own hook (swimmer_locomotion._splash)
	if gr != null and "blockout_gym" in gr and gr.blockout_gym.has("stations"):
		for st in gr.blockout_gym.stations:
			var rd = st.result.get("rider")
			if rd != null and rd.species in ["dolphin", "humpback"]:
				riders.append({"node": rd, "species": rd.species, "next": 3.0 + rng.randf() * 6.0, "until": -1.0})
	if s != null and s.world_root != null: _motes = s.world_root.get_node_or_null("Motes")

func plug_tick(dt: float, s) -> void:
	var us0 := Time.get_ticks_usec()
	services = s
	var t: float = s.clock.t
	if t - epoch > REBASE_S: _rebase(REBASE_S)
	if girl != null and not girl.pose.is_empty(): _girl_sources(dt, t)
	for sp in _splashes: _splash_burst(sp[0], sp[1], sp[2], t - dt * 0.5)
	_splashes.clear()
	for r in riders: _rider_source(r, dt, t)
	if stress_rate > 0.0: _stress(dt, t)
	_prev_t = t
	plug_us = Time.get_ticks_usec() - us0

func _process(_d: float) -> void:
	if services == null or services.clock == null: return
	var c = services.clock
	var since: float = 0.0 if c.paused else Engine.get_physics_interpolation_fraction() * c.dt
	var now: float = c.t + since
	var mat := material_override as ShaderMaterial
	mat.set_shader_parameter("now", now - epoch)
	mat.set_shader_parameter("drift_now", drift_at(now))

## the water's own displacement (current + the swell's orbit) shared with the marine snow, at a fixed 2 m depth so it is
## one function of time for birth and draw alike
func drift_at(t: float) -> Vector3:
	return _motes.drift_at(t, 2.0) if _motes != null else Vector3.ZERO

# ------------------------------------------------------------------ births
## One bubble: born at p (world) at absolute sim time t, leaving at v (m/s), radius a_mm. cap: the y it stops under
## (NAN = find it: the surface over p, or a ceiling a ray finds); kind 1 = a ceiling (rests longer, flatter).
func emit(p: Vector3, v: Vector3, a_mm: float, t: float, cap := NAN, kind := -1, source := "api") -> Dictionary:
	var wy := _water_y(p)
	if p.y >= wy - 0.01: return {}
	if is_nan(cap):
		var cp := find_cap(p)
		cap = cp.y; kind = cp.kind
	if kind < 0: kind = 0
	var a0 := clampf(a_mm, 0.05, 20.0) * 0.001
	var w := BM.rise(a_mm)
	var tau := BM.jet_tau(a_mm)
	var a_cap := BM.grown(a0, wy - p.y, wy - cap)
	var t_cap := BM.time_to_cap(p.y, v.y, a_cap, w, tau, cap)
	var dwell := rng.randf_range(0.03, 0.6) if kind == 0 else rng.randf_range(3.0, 8.0)
	var t_end := minf(t_cap + dwell, MAX_LIFE)
	var i := slot
	slot = (slot + 1) % SLOTS
	var xf := Transform3D(Basis(v, drift_at(t), Vector3(t - epoch, a0, cap)), p)
	_xf[i] = xf; _rec_t0[i] = t; _rec_end[i] = t + t_end
	multimesh.set_instance_transform(i, xf)
	multimesh.set_instance_custom_data(i, Color(t_cap, t_end, w, tau))
	var seed := rng.randf()
	multimesh.set_instance_color(i, Color(seed, float(kind), 0.0, 1.0))
	live += 1
	births[source] = births.get(source, 0) + 1
	var rec := {"slot": i, "p0": p, "v0": v, "a0": a0, "w": w, "tau": tau, "cap_y": cap, "a_cap": a_cap, "t_cap": t_cap,
		"t_end": t_end, "seed": seed, "t0": t, "kind": kind, "source": source}
	if log_on: log.append(rec)
	return rec

## n bubbles in a ball of radius r round c, leaving at v (+- spread m/s), radii a_lo..a_hi mm (log-uniform), born
## spread over [t0, t1]; one cap ray for the lot
func emit_burst(c: Vector3, r: float, n: int, v: Vector3, spread: float, a_lo: float, a_hi: float, t0: float, t1: float, source := "api") -> void:
	if n <= 0: return
	var cp := find_cap(c)
	for k in n:
		var off := Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * (r * 0.5)
		var vv := v + Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * spread
		var tt := lerpf(t0, t1, (k + rng.randf()) / n)
		emit(c + off, vv, _log_uniform(a_lo, a_hi), tt, cp.y, cp.kind, source)

## where a bubble rising from p stops: a ceiling (world geometry, layer 1) under the surface, else the surface
func find_cap(p: Vector3) -> Dictionary:
	var wy := _water_y(p)
	if services != null and services.world != null:
		var h: Dictionary = services.world.ray(p + Vector3(0, 0.02, 0), Vector3(p.x, wy, p.z))
		if not h.is_empty(): return {"y": float(h.position.y), "kind": 1}
	return {"y": wy, "kind": 0}

func _water_y(p: Vector3) -> float:
	if services == null or services.water == null: return LagoonWaterField.SURFACE_Y
	return services.water_y(p.x, p.z)

func _log_uniform(lo: float, hi: float) -> float:
	return exp(lerpf(log(lo), log(hi), rng.randf()))

## exhaled bubble sizes: mostly 0.8-3 mm, some 3-6, a few 6-10 mm blurps (more of the big ones with exertion)
func _exhale_size(ex: float) -> float:
	var u := rng.randf()
	if exhale_style == "lush":      # fuller: more 3-6 mm and cap bubbles to 12 mm
		if u < 0.14 + 0.06 * ex: return _log_uniform(6.0, 12.0)
		if u < 0.45 + 0.10 * ex: return _log_uniform(3.0, 6.0)
		return _log_uniform(0.8, 3.0)
	if u < 0.05 + 0.06 * ex: return _log_uniform(6.0, 10.0)
	if u < 0.30 + 0.10 * ex: return _log_uniform(3.0, 6.0)
	return _log_uniform(0.8, 3.0)

func _rebase(by: float) -> void:
	epoch += by
	for i in SLOTS:
		if _rec_end[i] + 1.0 < epoch - by: continue        # long dead
		var xf: Transform3D = _xf[i]
		xf.basis.z.x -= by
		_xf[i] = xf
		multimesh.set_instance_transform(i, xf)

# ------------------------------------------------------------------ sources
func _girl_sources(dt: float, t: float) -> void:
	var pose: Dictionary = girl.pose
	var head: Transform3D = pose.headMat
	if not _have_head: _prev_head = head; _have_head = true
	var bo: Dictionary = girl.brig.brain_out
	var s = girl.body.motor.swimmer
	var vel: Vector3 = s.vel
	var wy := _water_y(head.origin)
	var head_under := head.origin.y < wy - 0.03
	# exhale: begun under water (the breath clock's hook), then the air follows the breath's own fall
	var n_ex: int = girl.brig.underwater_exhales
	if _seen_exhales >= 0 and n_ex > _seen_exhales:
		var amp := float(bo.get("breathAmp", 1.0)); var ex := float(bo.get("exertion", 0.0))
		_exh = {"on": true, "sig": float(bo.get("breathSignal", 1.0)), "n": 0.0, "total": (26.0 * amp + 22.0 * ex) * (2.6 if exhale_style == "lush" else 1.0), "ex": ex}
		for k in 1 + int(ex * 2.0):     # the onset blurp
			_exhale_one(head, head, vel, t - dt, t, 1.0, _log_uniform(4.0, 7.5))
	_seen_exhales = n_ex
	if _exh.on:
		var ph := float(bo.get("breathPhase", 0.0)); var sig := float(bo.get("breathSignal", 0.0))
		if ph < 0.4 or not head_under:
			_exh.on = false
		else:
			_exh.n += maxf(_exh.sig - sig, 0.0) * _exh.total
			_exh.sig = sig
			while _exh.n >= 1.0:
				_exh.n -= 1.0
				_exhale_one(_prev_head, head, vel, t - dt, t, rng.randf(), _exhale_size(_exh.ex))
	# the kick burst and the sprint trail, at her feet
	var eye_under: bool = s.pos.y < wy - 0.1
	if eye_under and pose.has("legL"):
		var feet: Vector3 = (pose.legL.ik.eff + pose.legR.ik.eff) * 0.5
		var depth_k := lerpf(1.0, 0.35, smoothstep(0.3, 1.5, wy - feet.y))
		var fwd := vel.normalized() if vel.length() > 0.3 else -head.basis.z
		if s.sprint_burst_cd > _last_cd + 0.01:
			var n := int(round(10.0 * depth_k))
			emit_burst(feet - fwd * 0.25, 0.35, n, -fwd * 1.2 + Vector3(0, 0.2, 0), 0.25, 1.0, 4.5, t - dt, t, "sprint_burst")
		if s.sprinting:
			_trail += dt * 7.0 * depth_k
			while _trail >= 1.0:
				_trail -= 1.0
				var f := rng.randf()
				emit(feet - fwd * 0.2 + Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * 0.12, -vel * 0.15 + Vector3(0, 0.1, 0),
					_log_uniform(0.8, 3.5), t - dt * (1.0 - f), NAN, -1, "sprint_trail")
	_last_cd = s.sprint_burst_cd
	_prev_head = head

## one exhaled bubble at fraction f through the tick (head pose interpolated): nose (65 %) or mouth
func _exhale_one(h0: Transform3D, h1: Transform3D, vel: Vector3, ta: float, tb: float, f: float, a_mm: float) -> void:
	var h := h0.interpolate_with(h1, f)
	var nose := rng.randf() < 0.65
	var local := NOSE if nose else MOUTH
	local.x += rng.randfn() * (0.006 if nose else 0.012)
	var p := h * local
	var fwd := -h.basis.z.normalized(); var up := h.basis.y.normalized()
	var aim := (fwd * 0.45 - up * 0.55).normalized() if nose else (fwd * 0.85 - up * 0.2).normalized()
	var v := aim * rng.randf_range(0.30, 0.55) + vel * 0.3 + Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * 0.05
	emit(p, v, a_mm, lerpf(ta, tb, f), NAN, -1, "exhale")

func _on_splash(p: Vector3, impact: float, into: bool) -> void:
	_splashes.append([p, impact, into])

func _splash_burst(p: Vector3, impact: float, into: bool, t: float) -> void:
	var wy := _water_y(p)
	if into:      # the plunge drags a cloud of air down with her, which then rises
		var n := int(clampf(25.0 + 10.0 * impact, 25.0, 70.0))
		var c := Vector3(p.x, wy - 0.3, p.z)
		emit_burst(c, 0.7, n, Vector3(0, -0.35 * impact, 0), 0.35, 0.5, 9.0, t, t + 0.25, "plunge")
	else:         # surfacing sheds a few from the body
		emit_burst(Vector3(p.x, wy - 0.35, p.z), 0.5, 12, Vector3(0, 0.25, 0), 0.15, 0.6, 3.0, t - 0.1, t, "surfacing")

## blockout stand-ins: a dolphin's blowhole stream (real when they whistle, ~1-2 s), a humpback's rare bubble blast
func _rider_source(r: Dictionary, dt: float, t: float) -> void:
	var rd: Node3D = r.node
	if not is_instance_valid(rd): return
	var L: float = rd.LENGTH
	var blow: Vector3 = rd.global_transform * Vector3(0.0, 0.09 * L, -0.34 * L)
	if blow.y > _water_y(blow) - 0.1: return
	var vel: Vector3 = rd.velocity
	if t >= r.next and r.until < 0.0:
		if r.species == "dolphin":
			r.until = t + rng.randf_range(0.8, 1.8)
		else:
			emit_burst(blow, 0.4, 40, vel * 0.4 + Vector3(0, 0.6, 0), 0.4, 2.0, 12.0, t - dt, t + 0.3, "humpback_blast")
			r.next = t + rng.randf_range(25.0, 40.0)
	if r.until >= 0.0:
		var n := int(dt * 28.0 + rng.randf())
		for k in n:
			emit(blow + Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * 0.01, vel * 0.5 + Vector3(0, 0.5, 0),
				_log_uniform(0.8, 4.0), t - dt * rng.randf(), NAN, -1, "dolphin_stream")
		if t > r.until:
			r.until = -1.0
			r.next = t + rng.randf_range(7.0, 14.0)

## speed worst case: a steady plume of mixed sizes 1.5 m in front of the eye (fills the ring at ~50 bubbles/s)
func _stress(dt: float, t: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null: return
	var c := cam.global_position - cam.global_transform.basis.z * 1.5 + Vector3(0, -0.6, 0)
	_stress_acc += dt * stress_rate
	while _stress_acc >= 1.0:
		_stress_acc -= 1.0
		emit(c + Vector3(rng.randfn(), 0.0, rng.randfn()) * 0.15, Vector3(0, 0.1, 0), _exhale_size(0.5), t - dt * rng.randf(), NAN, -1, "stress")
