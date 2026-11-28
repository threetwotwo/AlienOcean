## M04 Body, core 0.2.0: GDScript port of Thalassa v20.19 core/character-brain.js (CharacterBrain): the breath pacemaker
## (40 % inhale / 60 % exhale) that paces glances and weight shifts, the vision organ (forward cone, line of sight, dwell,
## hysteresis, warm episodic memory, camera-centre intent), the hearing organ (range cap, refractory and per-kind
## cooldowns, urgent interrupts), objective focus for jumps and water crossings, idle contrapposto, the swim hand brush.
## Golden-checked against the JS by tests/test_golden_brain.gd (recording tests/golden/brain_trace.mjs).
## ctx: the JS keys with Vector3 for [x, y, z]; Callables for getFloorHeight(x, z) -> float,
##   queryNearestSurface(p, r, filter) -> {point, normal[, id]} or {} (filter(p: Vector3, n: Vector3) -> bool; the JS
##   filter took six numbers), checkLineOfSight(from, to, poi) -> bool. colliders: [{x, y, z, r}].
## Not ported (we have no ship): line of sight against the Pelagos hull and ship bulkheads (JS sections A and D; D also
## read VESSEL_DESCRIPTORS, which the JS never imported), the deck wall / rail touch (5A, needs ctx.vessel and an
## interior mesh query), getState()'s formatting. The JS set the mood twice per update; the first value was overwritten
## before anything read it, so only the second is ported.
## exact = true reproduces the JS (the golden test); false adds the upgrades marked FIX below (the rig passes
## thalassa_exact through).
extends RefCounted

const BM := preload("res://core/m04_body/body_math.gd")

var exact := false
var config := {
	"visionRangeM": 54.0, "deckVisionRangeM": 19.5, "hearingRangeM": 24.0, "deckHearingRangeM": 12.0,
	"visionHalfFovYaw": 0.94, "visionHalfFovPitch": 0.62, "maxGlanceBlend": 0.62,
	"focusMinDwell": 5.5, "focusMaxDwellWonder": 12.5, "focusMaxDwellScene": 9.2, "focusHysteresis": 0.36,
	"headTurnCooldownSec": 2.3, "sideReversalCooldownSec": 5.2, "soundRefractorySec": 4.6,
	"soundPerKindCooldownSec": 12.0, "soundInterruptIntensity": 0.78,
	"memoryWarmFloorScene": 0.44, "memoryWarmFloorLiving": 0.66, "memoryRefreshMoveM": 4.5, "memoryDecayHalfSec": 55.0,
	"touchReachMin": 0.16, "touchReachMax": 0.56, "idleHipShiftM": 0.014, "idleShiftBreaths": 2,
}

var clock := 0.0
var idle_time := 0.0
var state := "poised_idle"
var mood := "serene"

# breath pacemaker
var breath_phase := 0.0
var breath_cycle_count := 0
var breath_freq_spring = BM.CritSpring1D.new(0.21)
var breath_amp_spring = BM.CritSpring1D.new(1.0)
var breath_signal := 0.0
var breath_inflection := false
var _last_breath_stage := 0
var exertion := 0.0          # FIX (upgrade): effort the breath still carries (fast to build, slow to pay back)

# attention
var poi_memory := {}         # id -> Mem
var intent_dwell := {}       # id -> s of camera-centre dwell
var objective_focus = null   # {label, pos, dir, timer}
var objective_post_cooldown := 0.0
var active_focus = null      # Dictionary (see _make_focus)
var last_focus_pos = null
var last_scan_dir = null
var focus_hold_timer := 0.0
var scan_beat_timer := 0.0
var head_turn_cooldown := 0.0
var side_reversal_cooldown := 0.0
var last_gaze_side := 0
var memory_familiar_count := 0
var visible_poi_count := 0
var sustained_turn_time := 0.0
var spin_suppress_timer := 0.0

# hearing
var sound_events: Array = []
var sound_cooldown := 0.0
var sound_kind_cooldowns := {}
var last_sound_kind = null
var last_sound_age := 99.0

var gaze_dir_spring = BM.CritSpring3D.new(Vector3(0, 0, -1))
var gaze_dir_init := false
var gaze_blend_spring = BM.CritSpring1D.new(0.0)
var head_tilt_spring = BM.CritSpring1D.new(0.0)
var torso_curio_spring = BM.CritSpring1D.new(0.0)
var hip_shift_spring = BM.CritSpring1D.new(0.0)
var ready_lean_spring = BM.CritSpring1D.new(0.0)
var idle_look_yaw_spr = BM.CritSpring1D.new(0.0)
var idle_look_pitch_spr = BM.CritSpring1D.new(0.0)

class Mem:
	var seen_sec := 0.0
	var total_seen_sec := 0.0
	var familiarity := 0.0
	var visit_count := 0
	var cooldown := 0.0
	var last_seen_at := -999.0
	var last_known_pos = null
	var last_dist = null

class TouchHand:
	var weight_spring = BM.CritSpring1D.new(0.0)
	var pos_spring = BM.CritSpring3D.new(Vector3.ZERO)
	var norm_spring = BM.CritSpring3D.new(Vector3.ZERO)
	var active := false
	var phase := "idle"
	var notice_timer := 0.0
	var notice_needed := 0.55
	var reach_progress := 0.0
	var rest_timer := 0.0
	var cooldown_timer := 0.0
	var mode := "none"
	var surface_id = null
	var rail_tangent_world = null
	var nearest_dist_m = null
	var locked_world_pt = null
	var locked_world_nrm = null
	var initialized := false
	func _init(norm_x: float) -> void:
		norm_spring.x = Vector3(norm_x, 0, 0)

var touch := {"L": TouchHand.new(1.0), "R": TouchHand.new(-1.0)}
var dominant_touch_hand = null

var idle_hip_side := 1
var _next_shift_cycle := 2
var _next_glance_cycle := 1
var idle_glance_yaw_goal := 0.0
var idle_glance_pitch_goal := 0.0
var last_output := {}

static func _cl(v: float, a: float, b: float) -> float:
	return a if v < a else (b if v > b else v)

## math.js smoothstep (works with e0 > e1, as the JS relies on)
static func _ss(e0: float, e1: float, x: float) -> float:
	var t := _cl((x - e0) / (e1 - e0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

static func _acos(x: float) -> float:
	return acos(_cl(x, -1.0, 1.0))

static func _f(v, dflt := 0.0) -> float:
	## JS `x || d` for numbers: null, 0 and NaN take the default
	if v == null: return dflt
	var f := float(v)
	return dflt if (f == 0.0 or is_nan(f)) else f

static func _b(v) -> bool:
	## JS truthiness for flags that may be missing or null
	return v != null and bool(v)

static func _call_ok(c) -> bool:
	return c is Callable and (c as Callable).is_valid()

## Hearing organ: a directional world-space sound.
func register_sound_event(kind: String, world_pos: Vector3, intensity := 0.65, max_age := 1.8) -> void:
	if not is_finite(world_pos.x): return
	if sound_events.size() >= 6: sound_events.pop_front()
	var k := kind if kind != "" else "sound"
	last_sound_kind = k
	last_sound_age = 0.0
	sound_events.append({"kind": k, "pos": world_pos, "intensity": _cl(intensity, 0.1, 1.0), "age": 0.0, "maxAge": maxf(0.6, max_age)})

## Lock the head on a transition objective (jump, plunge, dive) and drop any side glance.
## Thalassa engageObjectiveFocus(label, targetPos, targetDir, holdSec): hold her gaze on a target the game names (the
## player's interact target). Safe to call every tick while the target stands; the hold runs out hold_sec after the last call.
func engage_objective_focus(label: String, target_pos = null, target_dir = null, hold_sec := 0.55) -> void:
	var lbl := label if label != "" else "OBJECTIVE"
	if not exact and objective_focus != null and objective_focus.label == lbl:
		# FIX (upgrade): the JS re-ran the whole engage on every call, snapping the gaze blend, head tilt and curiosity
		# springs to 0 each tick, so a per-tick caller pinned them there and the first call popped them. A repeat call for
		# the same objective now only refreshes its target and hold.
		objective_focus.pos = target_pos
		objective_focus.dir = BM.nrm(target_dir) if target_dir != null else null
		objective_focus.timer = maxf(float(objective_focus.timer), maxf(0.15, hold_sec))
		objective_post_cooldown = maxf(objective_post_cooldown, 0.55)
		return
	if active_focus != null:
		active_focus = null
		focus_hold_timer = 0.0
	idle_glance_yaw_goal = 0.0
	idle_glance_pitch_goal = 0.0
	if exact:
		gaze_blend_spring.reset(0.0)
		head_tilt_spring.reset(0.0)
		torso_curio_spring.reset(0.0)
	# not exact: no snap; the springs glide to the objective's goals in update() (a reset is a one-tick pop of the head)
	# soft: a target the game names, turned to at a glance's pace (not the jump / water-transition snap; see gaze_hl)
	objective_focus = {"label": lbl, "pos": target_pos, "soft": not exact,
		"dir": BM.nrm(target_dir) if target_dir != null else null, "timer": maxf(0.15, hold_sec)}
	objective_post_cooldown = maxf(objective_post_cooldown, 0.55)

func _has_line_of_sight(head_pos: Vector3, poi: Dictionary, mode: String, ctx: Dictionary) -> bool:
	if poi.get("pos") == null: return false
	var los = ctx.get("checkLineOfSight")
	if _call_ok(los):
		return bool(los.call(head_pos, poi.pos, poi))
	var target: Vector3 = poi.pos
	var dvec := target - head_pos
	var dist := dvec.length()
	if dist < 0.35: return true
	var u := dvec / dist
	# B. terrain height-field ray march (skips the last 0.85 m so a seabed object doesn't hide itself)
	var fh = ctx.get("getFloorHeight")
	if _call_ok(fh) and mode != "deck_walk":
		var end_t := maxf(0.25, dist - 0.85)
		var steps := int(_cl(ceilf(end_t / 1.4), 4, 28))
		for s in range(1, steps + 1):
			var t := (float(s) / steps) * end_t
			var p := head_pos + u * t
			var fy: float = fh.call(p.x, p.z)
			if is_finite(fy) and p.y < fy - 0.15: return false
	# C. ray-sphere occlusion by world obstacles
	var cols = ctx.get("colliders")
	if cols is Array and cols.size() > 0 and mode != "deck_walk":
		var self_pad := _f(poi.get("selfRadius"), 0.75) + 0.55
		for c in cols:
			var cc := Vector3(c.x, c.y, c.z)
			if target.distance_to(cc) <= c.r + self_pad: continue
			var oc := head_pos - cc
			var b_val := oc.dot(u)
			var r_eff: float = c.r * 0.92
			var c_val := oc.dot(oc) - r_eff * r_eff
			var disc := b_val * b_val - c_val
			if disc > 0.0:
				var t_hit := -b_val - sqrt(disc)
				if t_hit > 0.25 and t_hit < dist - 0.65: return false
	return true

func _side_from_yaw(y: float) -> int:
	if y > 0.16: return 1
	if y < -0.16: return -1
	return 0

func _get_or_create_memory(id: String) -> Mem:
	var m = poi_memory.get(id)
	if m == null:
		m = Mem.new()
		poi_memory[id] = m
	return m

func _record_focus_end(focus, completed: bool, head_pos: Vector3) -> void:
	if focus == null: return
	if focus.pos != null:
		last_scan_dir = BM.nrm(focus.pos - head_pos)
	if focus.side != 0:
		last_gaze_side = focus.side
	if not focus.isSound and focus.id != "":
		var mem := _get_or_create_memory(focus.id)
		var dwell: float = focus.dwell
		var max_dwell := maxf(2.5, _f(focus.maxDwell, 8.0))
		var dwell_frac := _cl(dwell / max_dwell, 0.15, 1.0)
		var is_living: bool = focus.kind == "kora" or focus.kind == "fauna" or focus.kind == "vessel"
		mem.total_seen_sec += dwell
		mem.last_seen_at = clock
		mem.last_known_pos = focus.pos
		if focus.dist != null and is_finite(focus.dist): mem.last_dist = focus.dist
		if completed or dwell >= 1.1:
			mem.visit_count += 1
			var fam_gain: float = (0.38 if is_living else 0.48) if completed else (0.22 if is_living else 0.30) * dwell_frac
			mem.familiarity = _cl(mem.familiarity + fam_gain, 0.0, 1.0)
		var cd: float = (10.5 if is_living else 16.0) if completed else (lerpf(4.2, 8.8, dwell_frac) if is_living else lerpf(6.0, 12.5, dwell_frac))
		mem.cooldown = maxf(mem.cooldown, cd)
		mem.seen_sec = 0.0
	head_turn_cooldown = maxf(head_turn_cooldown, 1.85 if completed else 1.35)
	if last_gaze_side != 0:
		side_reversal_cooldown = maxf(side_reversal_cooldown, 3.8 if completed else 4.6)

## 40 % eased inhale, 60 % exhale that settles into an end-of-breath rest
static func eval_asymmetric_breath(phase: float) -> float:
	var p := fposmod(phase, 1.0)
	if p < 0.40:
		return 0.5 - 0.5 * cos(PI * (p / 0.40))
	var u := (p - 0.40) / 0.60
	return 0.5 + 0.5 * cos(PI * pow(u, 0.88))

func _max_dwell_for_kind(kind, familiarity := 0.0) -> float:
	var base: float = config.focusMaxDwellWonder if (kind == "kora" or kind == "fauna" or kind == "vessel") else config.focusMaxDwellScene
	return lerpf(base, base * 0.56, _cl(familiarity, 0.0, 1.0))

static func _v(ctx: Dictionary, key: String, dflt: Vector3) -> Vector3:
	var v = ctx.get(key)
	return BM.nrm(v) if v != null else dflt

## Step the breath pacemaker, the sense organs and the attention arbiter. ctx may be empty.
func update(dt: float, ctx: Dictionary) -> Dictionary:
	var sdt := _cl(dt, 0.0001, 0.05)
	clock += sdt
	var mode: String = ctx.get("mode", "deck_walk") if ctx.get("mode") != null else "deck_walk"
	var head_pos: Vector3 = ctx.get("headPos") if ctx.get("headPos") != null else Vector3.ZERO
	var body_fwd := _v(ctx, "bodyFwd", Vector3(0, 0, -1))
	var body_right := _v(ctx, "bodyRight", Vector3(1, 0, 0))
	var body_up := _v(ctx, "bodyUp", Vector3(0, 1, 0))
	var desired_look := _v(ctx, "desiredLookDir", body_fwd)
	var speed := _f(ctx.get("speed"))
	var des_speed: float = float(ctx.desSpeed) if ctx.get("desSpeed") != null else speed
	var yaw_rate := _f(ctx.get("yawRate"))
	var ship_roll := _f(ctx.get("shipRoll"))
	var impact_shake := _f(ctx.get("impactShake"))
	var pois: Array = ctx.pois if ctx.get("pois") is Array else []
	var airborne := _b(ctx.get("isAirborne"))

	# 1. breath pacemaker (paces idle shifts, glances and when a fixation may end)
	var goal_freq := 0.30 if mood == "alert" else (0.28 if mood == "playful" else (0.185 if mood == "wonder" else 0.21))
	var goal_amp := 1.22 if mood == "wonder" else (1.25 if mood == "playful" else (1.15 if mood == "alert" else 1.0))
	if not exact:
		# FIX (upgrade, breath): Thalassa paced the breath by mood only, so a sprint breathed like a stroll until speed
		# crossed 1.75 m/s, then jumped to the playful rate. Effort now drives it continuously and the breath pays the
		# effort back slowly after she stops (builds over ~2.5 s, settles over ~9 s), up to ~28 breaths a minute.
		var eff := _f(ctx.get("effort"), -1.0)
		if eff < 0.0: eff = _cl((speed - 0.3) / (3.4 if mode == "swim" else 2.6), 0.0, 1.0)
		eff = _cl(eff, 0.0, 1.0)
		exertion += (eff - exertion) * BM.expk(1.0 / (2.5 if eff > exertion else 9.0), sdt)
		goal_freq = maxf(goal_freq, 0.21 + 0.26 * exertion)
		goal_amp = maxf(goal_amp, 1.0 + 0.45 * exertion)
	var breath_freq: float = breath_freq_spring.step(goal_freq, 1.1, sdt)
	var breath_amp: float = breath_amp_spring.step(goal_amp, 1.1, sdt)
	breath_phase += breath_freq * sdt
	if breath_phase >= 1.0:
		breath_phase -= floorf(breath_phase)
		breath_cycle_count += 1
	breath_signal = eval_asymmetric_breath(breath_phase)
	var stage := 0 if breath_phase < 0.38 else (1 if breath_phase < 0.90 else 2)
	breath_inflection = stage != _last_breath_stage and (stage == 1 or stage == 0)
	_last_breath_stage = stage
	var breath_centered := (breath_signal - 0.5) * 2.0

	# 2. proprioception and breath-synced idle contrapposto
	var is_still := speed < 0.08 and des_speed < 0.08 and absf(yaw_rate) < 0.22
	if is_still: idle_time += sdt
	else: idle_time = maxf(0.0, idle_time - sdt * 3.0)
	var ready_goal := _cl((des_speed - speed) * 0.018, -0.02, 0.028)
	var ready_lean: float = ready_lean_spring.step(ready_goal, 0.34, sdt)
	head_turn_cooldown = maxf(0.0, head_turn_cooldown - sdt)
	side_reversal_cooldown = maxf(0.0, side_reversal_cooldown - sdt)
	if side_reversal_cooldown <= 0.0 and active_focus == null:
		last_gaze_side = 0
	for k in sound_kind_cooldowns.keys():
		var rem: float = sound_kind_cooldowns[k] - sdt
		if rem <= 0.0: sound_kind_cooldowns.erase(k)
		else: sound_kind_cooldowns[k] = rem
	last_sound_age = minf(99.0, last_sound_age + sdt)
	if mode == "deck_walk" and idle_time > 1.5:
		if breath_cycle_count >= _next_shift_cycle and breath_inflection:
			_next_shift_cycle = breath_cycle_count + int(config.idleShiftBreaths)
			idle_hip_side = -idle_hip_side
		if active_focus != null:
			idle_glance_yaw_goal = 0.0
			idle_glance_pitch_goal = 0.0
		elif head_turn_cooldown <= 0.0 and breath_cycle_count >= _next_glance_cycle and breath_inflection:
			_next_glance_cycle = breath_cycle_count + 2
			var w := sin(breath_cycle_count * 1.618 + 0.4)
			var cand_yaw := _cl(w * 0.34, -0.34, 0.34) if absf(w) > 0.30 else 0.0
			var cand_side := _side_from_yaw(cand_yaw)
			if cand_side != 0 and last_gaze_side != 0 and cand_side == -last_gaze_side and side_reversal_cooldown > 0.0:
				cand_yaw = 0.0     # reversal cooldown: settle to centre instead of swinging across
			idle_glance_yaw_goal = cand_yaw
			idle_glance_pitch_goal = cos(breath_cycle_count * 1.17) * 0.08
			if cand_yaw != 0.0:
				var final_side := _side_from_yaw(cand_yaw)
				if final_side != 0:
					last_gaze_side = final_side
					side_reversal_cooldown = maxf(side_reversal_cooldown, config.sideReversalCooldownSec)
				head_turn_cooldown = maxf(head_turn_cooldown, config.headTurnCooldownSec)
	else:
		idle_glance_yaw_goal = 0.0
		idle_glance_pitch_goal = 0.0
		_next_glance_cycle = breath_cycle_count + 1
	var hip_goal: float = idle_hip_side * config.idleHipShiftM if (mode == "deck_walk" and idle_time > 1.4) else 0.0
	var idle_hip_shift: float = hip_shift_spring.step(hip_goal, 1.05, sdt)
	var idle_glance_yaw: float = idle_look_yaw_spr.step(idle_glance_yaw_goal, 0.85, sdt)
	var idle_glance_pitch: float = idle_look_pitch_spr.step(idle_glance_pitch_goal, 0.85, sdt)

	# 3. hearing organ: hard range cap, nearer first, refractory gate
	sound_cooldown = maxf(0.0, sound_cooldown - sdt)
	var hear_range: float = config.deckHearingRangeM if mode == "deck_walk" else config.hearingRangeM
	var best_sound = null
	var best_sound_score := 0.0
	var best_sound_dist := INF
	for i in range(sound_events.size() - 1, -1, -1):
		var ev: Dictionary = sound_events[i]
		ev.age += sdt
		if ev.age >= ev.maxAge:
			sound_events.remove_at(i)
			continue
		var d := head_pos.distance_to(ev.pos)
		if d < 0.55 or d > hear_range: continue
		var freshness: float = 1.0 - ev.age / ev.maxAge
		var near_u := _cl(1.0 - d / hear_range, 0.0, 1.0)
		var prox := (0.30 * near_u + 0.70 * near_u * near_u) / (0.35 + 0.22 * d)
		var sc: float = prox * freshness * (0.65 + 0.35 * ev.intensity)
		if sc > best_sound_score:
			best_sound_score = sc; best_sound = ev; best_sound_dist = d

	# 4. vision organ + warm episodic memory
	var familiar_cnt := 0
	var decay_rate := 1.0 / maxf(20.0, _f(config.memoryDecayHalfSec, 55.0) * 1.45)
	for id in poi_memory:
		var mem: Mem = poi_memory[id]
		mem.cooldown = maxf(0.0, mem.cooldown - sdt)
		var focused_now: bool = active_focus != null and not active_focus.isSound and active_focus.id == id
		if not focused_now:
			if mem.cooldown <= 0.0:
				mem.seen_sec = maxf(0.0, mem.seen_sec - sdt * 0.35)
			if clock - mem.last_seen_at > 12.0 and mem.familiarity > 0.0:
				mem.familiarity = maxf(0.0, mem.familiarity - sdt * decay_rate)
		if mem.familiarity > 0.25: familiar_cnt += 1
	memory_familiar_count = familiar_cnt

	var vision_range: float = config.deckVisionRangeM if mode == "deck_walk" else config.visionRangeM
	var vis_fwd := _v(ctx, "visionFwd", desired_look)
	var vis_right := _v(ctx, "visionRight", body_right)
	var vis_up := _v(ctx, "visionUp", body_up)
	var cam_fwd := _v(ctx, "cameraFwd", vis_fwd)
	var max_yaw: float = config.visionHalfFovYaw
	var max_pitch: float = config.visionHalfFovPitch
	var scan_ref: Vector3 = last_scan_dir if last_scan_dir != null else (BM.nrm(gaze_dir_spring.x) if gaze_dir_init else vis_fwd)
	var abs_yaw_rate := absf(yaw_rate)

	if objective_focus != null:
		objective_focus.timer -= sdt
		if objective_focus.timer <= 0.0: objective_focus = null
	if objective_post_cooldown > 0.0:
		objective_post_cooldown = maxf(0.0, objective_post_cooldown - sdt)
	var critical := airborne or _f(ctx.get("jumpAnticip")) > 0.08 or _b(ctx.get("inCriticalTransition")) or ctx.get("objectiveFocus") != null
	if critical:
		var obj: Dictionary = ctx.objectiveFocus if ctx.get("objectiveFocus") != null else {}
		objective_focus = {"label": obj.get("label", "JUMP ARC" if airborne else "WATER TRANSITION"),
			"pos": obj.get("pos"), "dir": BM.nrm(obj.dir) if obj.get("dir") != null else desired_look,
			"timer": maxf(0.20, _f(obj.get("holdSec"), 0.25))}
		objective_post_cooldown = maxf(objective_post_cooldown, 0.55)
		if active_focus != null:
			active_focus = null
			focus_hold_timer = 0.0
		idle_glance_yaw_goal = 0.0
		idle_glance_pitch_goal = 0.0
	var objective_active := objective_focus != null

	var best_poi = null
	var best_poi_score := 0.0
	var best_poi_dist := INF
	var best_poi_angle := 0.0
	var best_poi_side := 0
	var best_poi_fam := 0.0
	var best_poi_intent := false
	var current_score := 0.0
	var current_valid := false
	var visible_count := 0
	var steady_camera := abs_yaw_rate < 0.85
	var seen_ids := {}

	if not objective_active:
		for poi in pois:
			if poi == null or poi.get("pos") == null: continue
			var pid: String = str(poi.id)
			var to_p: Vector3 = poi.pos - head_pos
			var d := to_p.length()
			var eff_range := minf(vision_range, _f(poi.get("maxRange"), vision_range))
			if d < 0.32 or d > eff_range: continue
			var dir := to_p / d
			var f := dir.dot(vis_fwd)
			var r := dir.dot(vis_right)
			var u := dir.dot(vis_up)
			var is_current: bool = active_focus != null and not active_focus.isSound and active_focus.id == pid
			if f < (0.44 if is_current else 0.52): continue
			if mode == "deck_walk" and dir.dot(body_fwd) < 0.18: continue
			if not is_current and dir.dot(desired_look) < 0.48: continue
			var signed_yaw := atan2(r, f)
			var rel_yaw := absf(signed_yaw)
			var rel_pitch := absf(atan2(u, Vector2(f, r).length()))
			var ellip_r := Vector2(rel_yaw / (max_yaw * 1.08 if is_current else max_yaw), rel_pitch / (max_pitch * 1.08 if is_current else max_pitch)).length()
			if ellip_r > 1.0: continue
			if not _has_line_of_sight(head_pos, poi, mode, ctx):
				if is_current:
					active_focus.occludedSec += sdt
					# hold the last seen place (never track through rock) and lose it after a 0.35 s grace
					if active_focus.occludedSec < 0.35:
						current_valid = true
						current_score = active_focus.priority * 0.45
				continue
			visible_count += 1
			seen_ids[pid] = true
			var mem := _get_or_create_memory(pid)
			var kind = poi.get("kind")
			var is_living: bool = _b(poi.get("moving")) or kind == "kora" or kind == "fauna" or kind == "vessel"
			var cam_angle := _acos(dir.dot(cam_fwd))
			var is_fauna: bool = kind == "fauna"
			var is_kora: bool = _b(poi.get("koraLocked"))
			var i_dwell: float = intent_dwell.get(pid, 0.0)
			if cam_angle < 0.38 and steady_camera: i_dwell = minf(2.5, i_dwell + sdt)
			else: i_dwell = maxf(0.0, i_dwell - sdt * 2.2)
			intent_dwell[pid] = i_dwell
			var intent_max := (26.0 if is_fauna else 8.5) if mode == "deck_walk" else 24.0
			var strong_intent := (i_dwell >= 0.24 and cam_angle < 0.30 and d < intent_max) or ((is_fauna or is_kora) and i_dwell >= 0.16 and cam_angle < 0.36 and d < 24.0)
			if not is_current and mem.familiarity > 0.10 and mem.last_known_pos != null:
				var moved_m: float = (poi.pos as Vector3).distance_to(mem.last_known_pos)
				if is_living and moved_m > _f(config.memoryRefreshMoveM, 4.5):
					mem.familiarity *= 0.48
					mem.cooldown = minf(mem.cooldown, 2.0)
					mem.last_known_pos = poi.pos
				elif mem.last_dist != null and mem.last_dist != 0.0 and d < mem.last_dist * 0.62 and d < (4.5 if mode == "deck_walk" else 14.0):
					mem.familiarity *= 0.52
					mem.cooldown = minf(mem.cooldown, 1.6)
					mem.last_dist = d
			if mem.cooldown > 0.0 and not is_current and not strong_intent: continue
			var cand_side := _side_from_yaw(signed_yaw)
			var opposite := last_gaze_side != 0 and cand_side != 0 and cand_side == -last_gaze_side
			var near_ref := (9.0 if is_fauna else 4.0) if mode == "deck_walk" else 9.0
			var dist_factor := 1.0 / (1.0 + pow(d / near_ref, 1.45))
			var cam_core := _ss(0.52, 0.04, cam_angle)
			var foveal := maxf(_ss(1.0, 0.0, ellip_r) * 0.62, cam_core)
			var center_factor := (0.16 if is_living else 0.10) + (0.84 if is_living else 0.90) * pow(foveal, 1.45)
			var fauna_bonus := (1.12 + 0.42 * _ss(26.0, 3.5, d) + 0.24 * _ss(0.42, 0.08, cam_angle)) if is_fauna else 1.0
			var kora_bonus := 1.22 if is_kora else 1.0
			var intent_boost := 1.0 + 1.55 * _ss(0.08, 0.60, i_dwell) * _ss(0.38, 0.05, cam_angle) * _ss(intent_max + 4.0, 2.0, d)
			var prio_factor := 0.65 + 0.35 * _cl(_f(poi.get("priority"), 0.7), 0.2, 1.0)
			var max_dwell := _max_dwell_for_kind(kind, mem.familiarity)
			var warm_floor: float = config.memoryWarmFloorLiving if is_living else config.memoryWarmFloorScene
			var fam_factor := lerpf(1.0, warm_floor, _cl(mem.familiarity, 0.0, 1.0))
			var session_fresh := _cl(1.0 - mem.seen_sec / (max_dwell * 1.25), 0.45, 1.0)
			var novelty := maxf(0.88, fam_factor * session_fresh) if strong_intent else fam_factor * session_fresh
			var flow_angle := _acos(dir.dot(scan_ref))
			var flow_bonus := (1.0 + 0.18 * sin(_cl((flow_angle - 0.14) / 0.64, 0.0, 1.0) * PI)) if (not is_current and flow_angle > 0.14 and flow_angle < 0.78) else 1.0
			var sc := dist_factor * prio_factor * center_factor * novelty * flow_bonus * intent_boost * fauna_bonus * kora_bonus
			var angle_deg := rad_to_deg(_acos(f))
			if is_current:
				current_valid = true
				current_score = sc
				active_focus.occludedSec = 0.0
				active_focus.pos = poi.pos
				active_focus.dist = d
				active_focus.priority = sc
				active_focus.angleDeg = angle_deg
				active_focus.side = cand_side
				active_focus.familiarity = mem.familiarity
				if cand_side != 0: last_gaze_side = cand_side
			if not is_current and opposite and side_reversal_cooldown > 0.0 and not strong_intent: continue
			if sc > best_poi_score:
				best_poi_score = sc; best_poi = poi; best_poi_dist = d; best_poi_angle = angle_deg
				best_poi_side = cand_side; best_poi_fam = mem.familiarity; best_poi_intent = strong_intent
	for k in intent_dwell.keys():
		if not seen_ids.has(k):
			var nv: float = intent_dwell[k] - sdt * 2.5
			if nv <= 0.01: intent_dwell.erase(k)
			else: intent_dwell[k] = nv
	visible_poi_count = visible_count

	# central attention arbitration
	focus_hold_timer = maxf(0.0, focus_hold_timer - sdt)
	scan_beat_timer = maxf(0.0, scan_beat_timer - sdt)
	if abs_yaw_rate > 0.38: sustained_turn_time = minf(2.0, sustained_turn_time + sdt)
	else: sustained_turn_time = maxf(0.0, sustained_turn_time - sdt * 2.2)
	var active_turning := abs_yaw_rate > 0.62
	var sustained_turning := sustained_turn_time > 0.50

	if active_focus != null and not active_focus.isSound:
		if not current_valid or sustained_turning or objective_active:
			_record_focus_end(active_focus, false, head_pos)
			active_focus = null
			focus_hold_timer = 0.0
			scan_beat_timer = 0.55 if sustained_turning else 0.75
		else:
			active_focus.dwell += sdt
			var md := _f(active_focus.maxDwell)
			if md == 0.0: md = _max_dwell_for_kind(active_focus.kind, active_focus.familiarity)
			var mem := _get_or_create_memory(active_focus.id)
			mem.seen_sec += sdt
			if (mem.seen_sec >= md and breath_inflection) or mem.seen_sec >= md + 3.0:
				_record_focus_end(active_focus, true, head_pos)
				active_focus = null
				focus_hold_timer = 0.0
				scan_beat_timer = 1.05 + (breath_cycle_count % 3) * 0.22
	elif active_focus != null and active_focus.isSound and (focus_hold_timer <= 0.0 or objective_active):
		_record_focus_end(active_focus, true, head_pos)
		active_focus = null
		scan_beat_timer = 0.85

	# sound orienting reflex (not during objective focus or its settle)
	var sound_accepted := false
	if not objective_active and objective_post_cooldown <= 0.0 and best_sound != null and best_sound_score > 0.045 and sound_cooldown <= 0.0 and not active_turning:
		var kind_cd: float = sound_kind_cooldowns.get(best_sound.kind, 0.0)
		var urgent: bool = _f(best_sound.intensity) >= float(config.soundInterruptIntensity)
		var snd_dir := BM.nrm(best_sound.pos - head_pos)
		var snd_yaw := atan2(snd_dir.dot(vis_right), maxf(0.05, snd_dir.dot(vis_fwd)))
		var snd_side := _side_from_yaw(snd_yaw)
		var snd_opposite := last_gaze_side != 0 and snd_side != 0 and snd_side == -last_gaze_side
		var kora_mem = poi_memory.get("kora_01") if best_sound.kind == "kora_chirp" else null
		var kora_known: bool = kora_mem != null and (kora_mem.cooldown > 0.0 or (clock - kora_mem.last_seen_at) < 11.0)
		var can_orient: bool = (kind_cd <= 0.0) if urgent else (kind_cd <= 0.0 and active_focus == null and head_turn_cooldown <= 0.0 and not (snd_opposite and side_reversal_cooldown > 0.0) and not kora_known)
		if can_orient:
			if active_focus != null:
				_record_focus_end(active_focus, false, head_pos)
			active_focus = _make_focus("snd_" + best_sound.kind, best_sound.kind, String(best_sound.kind).to_upper(), best_sound.pos,
				best_sound_dist, best_sound_score, true, 2.8, snd_side, 0.0, rad_to_deg(_acos(snd_dir.dot(vis_fwd))))
			focus_hold_timer = 2.8
			sound_cooldown = config.soundRefractorySec
			var per_kind: float = _f(config.soundPerKindCooldownSec, 12.0) if best_sound.kind == "kora_chirp" else (5.0 if urgent else 9.0)
			sound_kind_cooldowns[best_sound.kind] = per_kind
			head_turn_cooldown = maxf(head_turn_cooldown, config.headTurnCooldownSec)
			if snd_side != 0:
				last_gaze_side = snd_side
				side_reversal_cooldown = maxf(side_reversal_cooldown, config.sideReversalCooldownSec)
			sound_accepted = true

	if not objective_active and objective_post_cooldown <= 0.0 and not sound_accepted and not active_turning and not sustained_turning and best_poi != null and best_poi_score > 0.12 and (head_turn_cooldown <= 0.0 or best_poi_intent):
		var bid: String = str(best_poi.id)
		var no_focus_ready := active_focus == null and (scan_beat_timer <= 0.0 or best_poi_intent)
		var cur_dwell_ok: bool = active_focus == null or active_focus.dwell >= 0.85 or _f(active_focus.dist) > best_poi_dist * 1.65
		var intent_switch: bool = best_poi_intent and cur_dwell_ok and active_focus != null and bid != active_focus.id and best_poi_score > current_score * 1.15
		if not exact and intent_switch and active_focus.isSound and clock - active_focus.born < 0.85:
			# FIX (stress J9 focus): a sound focus has no score and never gains dwell, so a camera-centred target took
			# the head back the very next tick (a one-tick turn to the knock, kind cooldowns spent). The sound gets the
			# same 0.85 s a look gets before an intent switch may take over.
			intent_switch = false
		var can_switch: bool = active_focus != null and not active_focus.isSound and focus_hold_timer <= 0.0 and bid != active_focus.id and best_poi_score > current_score * (1.0 + config.focusHysteresis) + 0.05
		if no_focus_ready or can_switch or intent_switch:
			if (can_switch or intent_switch) and active_focus != null:
				_record_focus_end(active_focus, false, head_pos)
			var max_dwell := _max_dwell_for_kind(best_poi.get("kind"), best_poi_fam)
			var min_dwell := lerpf(config.focusMinDwell, 3.2, _cl(best_poi_fam, 0.0, 1.0))
			var bk = best_poi.get("kind")
			active_focus = _make_focus(bid, bk if (bk != null and bk != "") else "poi", str(best_poi.get("label", bid)) if best_poi.get("label") else bid,
				best_poi.pos, best_poi_dist, best_poi_score, false, max_dwell, best_poi_side, best_poi_fam, best_poi_angle)
			focus_hold_timer = min_dwell
			head_turn_cooldown = maxf(head_turn_cooldown, 1.1 if best_poi_intent else float(config.headTurnCooldownSec))
			if best_poi_side != 0:
				last_gaze_side = best_poi_side
				side_reversal_cooldown = maxf(side_reversal_cooldown, config.sideReversalCooldownSec)

	if active_focus != null and active_focus.pos != null:
		last_focus_pos = active_focus.pos
		last_scan_dir = BM.nrm(active_focus.pos - head_pos)

	var move_suppress := (1.0 - _ss(3.60, 5.40, speed)) if mode == "swim" else (1.0 - _ss(1.45, 2.30, speed))
	var turn_suppress := 1.0 - _ss(0.40, 1.15, abs_yaw_rate)
	var want_blend := 0.0
	if active_focus != null and not objective_active:
		want_blend = _cl(config.maxGlanceBlend * (1.04 if active_focus.isSound else 0.98) * move_suppress * turn_suppress, 0.0, 0.66)
	var blend_hl := 0.07 if objective_active else (0.44 if want_blend > gaze_blend_spring.x else 0.56)
	var gaze_blend: float = gaze_blend_spring.step(want_blend, blend_hl, sdt)

	var eff_focus_pos = null
	if not objective_active and active_focus != null: eff_focus_pos = active_focus.pos
	elif not objective_active and gaze_blend > 0.008: eff_focus_pos = last_focus_pos
	var raw_gaze := desired_look
	if objective_active:
		if objective_focus.pos != null:
			raw_gaze = BM.nrm(objective_focus.pos - head_pos)
		elif objective_focus.dir != null:
			raw_gaze = objective_focus.dir
		if not exact:
			# FIX (upgrade): the game's interact target can sit behind her; held in the neck's reach as glances are
			# (see the J9 note below), else the gaze spring flips and resets in one tick.
			if mode == "swim": raw_gaze = _within_reach(raw_gaze, vis_fwd, vis_right, vis_up, REACH_PITCH_SWIM)
			else: raw_gaze = _within_reach(raw_gaze, body_fwd, body_right, body_up, REACH_PITCH_LAND)
	elif eff_focus_pos != null and gaze_blend > 0.005:
		var to_focus := BM.nrm(eff_focus_pos - head_pos)
		if active_focus != null and not active_focus.isSound and active_focus.dwell > 1.6:
			var inspect_u := _ss(1.6, 3.8, active_focus.dwell)
			var drift_scale := 1.0 if (active_focus.kind == "vessel" or active_focus.kind == "arch" or active_focus.kind == "cave") else 0.55
			var micro_yaw := sin(clock * 0.72 + 0.5) * 0.042 * inspect_u * drift_scale
			var micro_pitch := cos(clock * 0.53 + 1.4) * 0.026 * inspect_u * drift_scale
			to_focus = BM.nrm(to_focus + (vis_right * micro_yaw + vis_up * micro_pitch))
		if not exact:
			# FIX (stress J9 gaze): a sound behind her blended the gaze through the back of her head (2.8 rad from the
			# chest) and the flip past -0.25 below reset the gaze spring in one tick. The eyes go where the neck can
			# take them: the focus direction is held inside the neck's reach. On land that is reach from the upright
			# body; swimming prone the chest faces the sand and the head is extended to look ahead, so it is reach
			# from where she looks.
			if mode == "swim": to_focus = _within_reach(to_focus, vis_fwd, vis_right, vis_up, REACH_PITCH_SWIM)
			else: to_focus = _within_reach(to_focus, body_fwd, body_right, body_up, REACH_PITCH_LAND)
		raw_gaze = BM.nrm(desired_look.lerp(to_focus, gaze_blend))
	elif mode == "deck_walk" and objective_post_cooldown <= 0.0 and (absf(idle_glance_yaw) > 0.003 or absf(idle_glance_pitch) > 0.003):
		raw_gaze = BM.nrm(desired_look + (body_right * idle_glance_yaw + body_up * idle_glance_pitch))

	if not gaze_dir_init or gaze_dir_spring.x.dot(raw_gaze) < -0.25:
		gaze_dir_spring.reset(raw_gaze)
		gaze_dir_init = true
	# FIX (stress J9, per-tick interact target): the 0.09 s objective half-life swung the head 8-10 rad/s onto a target
	# 1.5 rad off; it is meant for the jump arc. A soft (game-named) objective takes the whole look over (a glance takes
	# 0.6 of it), so it turns at the idle pace: 0.18 s still swung the head 4.9 rad/s standing (B46), 0.30 s 3.3.
	var obj_fast: bool = objective_active and not objective_focus.get("soft", false)
	var gaze_hl := 0.09 if obj_fast else (0.30 if objective_active else (0.18 if active_turning else (0.44 if eff_focus_pos != null else 0.30)))
	var gaze_dir_world := BM.nrm(gaze_dir_spring.step(raw_gaze, gaze_hl, sdt))

	# curiosity head tilt and upper-chest orienting
	var tilt_goal := 0.0
	var torso_goal := 0.0
	if eff_focus_pos != null and gaze_blend > 0.02:
		var to_f := BM.nrm(eff_focus_pos - head_pos)
		var rel_r := to_f.dot(vis_right)
		var rel_f := maxf(0.1, to_f.dot(vis_fwd))
		var rel_yaw_f := atan2(rel_r, rel_f)
		var side_sign := 1.0 if rel_r >= 0.0 else -1.0
		var focus_scale := _cl(gaze_blend / maxf(0.1, config.maxGlanceBlend), 0.0, 1.0)
		var wonder: bool = active_focus != null and (active_focus.kind == "kora" or active_focus.kind == "fauna")
		tilt_goal = (0.044 if wonder else 0.026) * side_sign * focus_scale
		torso_goal = _cl(rel_yaw_f * gaze_blend * 0.25, -0.18, 0.18)
	elif mode == "deck_walk" and absf(idle_glance_yaw) > 0.02:
		tilt_goal = idle_glance_yaw * 0.05
		torso_goal = idle_glance_yaw * 0.18
	var head_tilt: float = head_tilt_spring.step(tilt_goal, 0.78, sdt)
	var torso_yaw: float = torso_curio_spring.step(torso_goal, 0.68, sdt)

	# 5. touch: the swim glide-brush (one hand, below the shoulder, walls / arches / rocks only)
	var touch_out := {"L": _touch_idle(), "R": _touch_idle()}
	if abs_yaw_rate > 0.32: spin_suppress_timer = 0.48
	else: spin_suppress_timer = maxf(0.0, spin_suppress_timer - sdt)
	var turn_touch_ok := abs_yaw_rate < 0.24 and spin_suppress_timer <= 0.01
	if mode == "swim":
		var swim_axis_y := _v(ctx, "swimAxisY", body_up)
		var qns = ctx.get("queryNearestSurface")
		var allow := _call_ok(qns) and not _b(ctx.get("sprinting")) and speed <= 2.8 and not (_f(ctx.get("btnPhase")) > 0.05)
		var filt := func(_p: Vector3, n: Vector3) -> bool: return absf(n.y) < 0.38
		var raw := {"L": null, "R": null}
		for key in ["L", "R"]:
			var side := -1.0 if key == "L" else 1.0
			var ts: TouchHand = touch[key]
			var sh_w = ctx.get("shoulderL" if key == "L" else "shoulderR")
			if sh_w == null: sh_w = head_pos + (body_right * (side * 0.132) + swim_axis_y * -0.14)
			var holding := ts.phase == "reaching" or ts.phase == "resting"
			var max_r := 0.46 if holding else 0.42
			ts.nearest_dist_m = null
			if not allow: continue
			var probe: Vector3 = sh_w + (vis_right * (side * 0.24) + (desired_look * 0.18 + Vector3(0, -0.14, 0)))
			var hit = qns.call(probe, 0.34, filt)
			if not (hit is Dictionary) or hit.get("point") == null or hit.get("normal") == null: continue
			var pt: Vector3 = hit.point + hit.normal * 0.026
			var to_pt: Vector3 = pt - sh_w
			var reach_d := to_pt.length()
			ts.nearest_dist_m = reach_d
			if reach_d < 0.18 or reach_d > max_r: continue
			if to_pt.y < -0.28 or to_pt.y > -0.02: continue
			if to_pt.dot(hit.normal) / maxf(1e-4, reach_d) > -0.45: continue
			var side_dot := to_pt.dot(vis_right) * side
			if side_dot < 0.04 or side_dot > 0.34 or to_pt.dot(desired_look) < 0.04: continue
			if holding and ts.locked_world_nrm != null and ts.locked_world_pt != null:
				if (hit.normal as Vector3).dot(ts.locked_world_nrm) < 0.85 or pt.distance_to(ts.locked_world_pt) > 0.18: continue
			if holding:
				ts.locked_world_pt = pt
				ts.locked_world_nrm = hit.normal
			raw[key] = {"kind": "swim", "id": hit.get("id", "underwater_surface"), "mode": "swim_glide", "pointWorld": pt,
				"normalWorld": hit.normal, "tangentWorld": null, "liftVecWorld": hit.normal, "reachD": reach_d}
		var fin := _arbitrate_single_hand(raw.L, raw.R)
		_step_tactile_hand("L", fin[0], ctx.get("restHandWorldL"), false, turn_touch_ok, body_up, sdt, touch_out)
		_step_tactile_hand("R", fin[1], ctx.get("restHandWorldR"), false, turn_touch_ok, body_up, sdt, touch_out)

	# 6. mood and behavioural state
	var crouch := _f(ctx.get("crouchBlend"))
	if impact_shake > 0.18 or absf(ship_roll) > 0.12: mood = "alert"
	elif airborne or speed > 1.75: mood = "playful"
	elif active_focus != null and (active_focus.kind == "fauna" or active_focus.kind == "kora"): mood = "wonder"
	elif active_focus != null and gaze_blend > 0.08: mood = "curious"
	else: mood = "serene"
	if impact_shake > 0.18 or absf(ship_roll) > 0.12: state = "alert_brace"
	elif airborne: state = "athletic_jump"
	elif crouch > 0.45: state = "crouch_prowl" if speed > 0.12 else "crouch_inspect"
	elif mode == "swim": state = "fluid_swim" if speed > 0.85 else "tread_water"
	elif speed > 1.75: state = "athletic_run"
	elif speed > 0.12: state = "graceful_walk"
	elif active_focus != null and gaze_blend > 0.10: state = "curious_inspect"
	else: state = "poised_idle"

	last_output = {
		"state": state, "mood": mood,
		"breathPhase": breath_phase, "breathSignal": breath_signal, "breathCentered": breath_centered,
		"breathRate": breath_freq * TAU, "breathAmp": breath_amp, "breathCycle": breath_cycle_count,
		"breathInflection": breath_inflection, "exertion": exertion,
		"gazeDirWorld": gaze_dir_world, "gazeBlend": gaze_blend,
		"headTiltRad": _cl(head_tilt, -0.055, 0.055), "torsoCuriosityYaw": _cl(torso_yaw, -0.24, 0.24),
		"idleHipShift": idle_hip_shift, "anticipationCrouch": 0.0, "anticipationLean": ready_lean,
		"touchL": touch_out.L, "touchR": touch_out.R,
		# FIX: the JS output had no objectiveFocusActive, so ik-rig.js read undefined and never used its fast transition
		# neck (0.095 s). Reported only off exact (the golden body runs keep the JS behaviour through the quiet brain).
		"objectiveFocusActive": objective_active and not exact,
		"objectiveFast": obj_fast and not exact,      # the rig's fast neck (jump arc, water transition), not a soft target
		"focusPos": active_focus.pos if active_focus != null else null,
		"focusId": active_focus.id if active_focus != null else null,
		"focusLabel": active_focus.label if active_focus != null else null,
		"focusKind": active_focus.kind if active_focus != null else null,
		"focusIsSound": active_focus != null and active_focus.isSound,
		"focusDwell": active_focus.dwell if active_focus != null else 0.0,
		"visiblePoiCount": visible_poi_count, "visionRangeM": vision_range, "hearingRangeM": hear_range,
		"soundCount": sound_events.size(), "headTurnCooldown": head_turn_cooldown,
		"sideReversalCooldown": side_reversal_cooldown, "lastGazeSide": last_gaze_side,
		"memoryCount": poi_memory.size(), "memoryFamiliarCount": memory_familiar_count,
	}
	return last_output

## d held inside a yaw / pitch window of the frame (bf, br, bu): body_rig solve_head's limits less a margin for the gaze
## spring and the lerp toward the look direction
const REACH_YAW := 0.92
const REACH_PITCH_SWIM := Vector2(-0.80, 0.80)     # from the look direction
const REACH_PITCH_LAND := Vector2(-0.48, 0.54)     # from the upright body (neck -0.54..0.60)
static func _within_reach(d: Vector3, bf: Vector3, br: Vector3, bu: Vector3, pl: Vector2) -> Vector3:
	var f := d.dot(bf); var r := d.dot(br); var u := d.dot(bu)
	var yaw := atan2(r, f)
	var pitch := atan2(u, Vector2(f, r).length())
	if absf(yaw) <= REACH_YAW and pitch >= pl.x and pitch <= pl.y: return d
	yaw = clampf(yaw, -REACH_YAW, REACH_YAW)
	pitch = clampf(pitch, pl.x, pl.y)
	return BM.nrm(bf * (cos(pitch) * cos(yaw)) + br * (cos(pitch) * sin(yaw)) + bu * sin(pitch))

func _make_focus(id: String, kind, label: String, pos: Vector3, dist: float, priority: float, is_sound: bool, max_dwell: float,
		side: int, familiarity: float, angle_deg: float) -> Dictionary:
	return {"id": id, "kind": kind, "label": label, "pos": pos, "dist": dist, "priority": priority, "isSound": is_sound,
		"dwell": 0.0, "maxDwell": max_dwell, "occludedSec": 0.0, "born": clock, "side": side, "familiarity": familiarity, "angleDeg": angle_deg}

static func _touch_idle() -> Dictionary:
	return {"weight": 0.0, "targetWorld": null, "normalWorld": null, "railTangentWorld": null, "mode": "none", "surfaceId": null,
		"phase": "idle", "reachProgress": 0.0}

## one hand brushes or rests, the other stays relaxed
func _arbitrate_single_hand(cand_l, cand_r) -> Array:
	var hold_l: bool = touch.L.phase == "reaching" or touch.L.phase == "resting"
	var hold_r: bool = touch.R.phase == "reaching" or touch.R.phase == "resting"
	if hold_l and cand_l != null and not hold_r: dominant_touch_hand = "L"; return [cand_l, null]
	if hold_r and cand_r != null and not hold_l: dominant_touch_hand = "R"; return [null, cand_r]
	if cand_l != null and cand_r != null:
		var sl: float = cand_l.reachD - (0.05 if dominant_touch_hand == "L" else 0.0)
		var sr: float = cand_r.reachD - (0.05 if dominant_touch_hand == "R" else 0.0)
		if sl <= sr: dominant_touch_hand = "L"; return [cand_l, null]
		dominant_touch_hand = "R"
		return [null, cand_r]
	if cand_l != null: dominant_touch_hand = "L"; return [cand_l, null]
	if cand_r != null: dominant_touch_hand = "R"; return [null, cand_r]
	if not hold_l and not hold_r: dominant_touch_hand = null
	return [null, null]

## idle -> noticing -> reaching -> resting -> withdrawing -> cooldown
func _step_tactile_hand(key: String, cand, rest_world, urgent: bool, turn_ok: bool, body_up: Vector3, sdt: float, touch_out: Dictionary) -> void:
	var ts: TouchHand = touch[key]
	if ts.cooldown_timer > 0.0: ts.cooldown_timer = maxf(0.0, ts.cooldown_timer - sdt)
	var ac = cand if (cand != null and (turn_ok or urgent)) else null
	match ts.phase:
		"cooldown":
			ts.reach_progress = maxf(0.0, ts.reach_progress - sdt * 1.65)
			if ts.cooldown_timer <= 0.0 and ts.weight_spring.x < 0.02:
				ts.phase = "idle"; ts.surface_id = null
		"idle":
			ts.reach_progress = maxf(0.0, ts.reach_progress - sdt * 1.65)
			if ac != null and ts.cooldown_timer <= 0.0:
				ts.phase = "noticing"; ts.surface_id = ac.id; ts.notice_timer = 0.0
				ts.notice_needed = 0.08 if urgent else 0.30
		"noticing":
			if ac == null:
				ts.phase = "idle"; ts.notice_timer = 0.0; ts.surface_id = null
			else:
				ts.surface_id = ac.id
				ts.notice_timer += sdt
				if ts.notice_timer >= ts.notice_needed:
					ts.phase = "reaching"; ts.reach_progress = 0.0; ts.rest_timer = 0.0
					ts.locked_world_pt = ac.pointWorld; ts.locked_world_nrm = ac.normalWorld
					if not ts.initialized or ts.weight_spring.x < 0.02:
						ts.pos_spring.reset(rest_world if rest_world != null else ac.pointWorld)
						ts.norm_spring.reset(ac.normalWorld)
						ts.initialized = true
		"reaching":
			if ac == null:
				ts.phase = "withdrawing"
			else:
				ts.surface_id = ac.id
				ts.reach_progress = minf(1.0, ts.reach_progress + sdt * (2.4 if urgent else 1.45))
				if ts.reach_progress >= 0.99:
					ts.phase = "resting"; ts.rest_timer = 0.0
		"resting":
			if ac == null:
				ts.phase = "withdrawing"
			else:
				ts.surface_id = ac.id; ts.reach_progress = 1.0; ts.rest_timer += sdt
		"withdrawing":
			ts.reach_progress = maxf(0.0, ts.reach_progress - sdt * 1.65)
			if ts.weight_spring.x < 0.025:
				ts.phase = "cooldown"; ts.cooldown_timer = 0.70; ts.surface_id = null
				ts.locked_world_pt = null; ts.locked_world_nrm = null
	var want_w := 0.0
	var tgt = null
	var nrm = null
	var t_mode := ts.mode
	var surf_id = ts.surface_id
	if (ts.phase == "reaching" or ts.phase == "resting") and ac != null:
		var ease := _ss(0.0, 1.0, ts.reach_progress)
		var lift := sin(ease * PI) * (0.018 if ac.kind == "rail" else 0.010)
		var up_v: Vector3 = ac.liftVecWorld if ac.get("liftVecWorld") != null else body_up
		tgt = ac.pointWorld + up_v * lift
		nrm = ac.normalWorld
		t_mode = ac.get("mode", "wall_low")
		surf_id = ac.id
		want_w = ease * 0.92
	var w_hl := (0.14 if urgent else 0.24) if want_w > ts.weight_spring.x else 0.26
	var w: float = ts.weight_spring.step(want_w, w_hl, sdt)
	var o: Dictionary = touch_out[key]
	if tgt != null and nrm != null:
		if not ts.initialized:
			ts.pos_spring.reset(rest_world if rest_world != null else tgt)
			ts.norm_spring.reset(nrm)
			ts.initialized = true
		var sm_pos: Vector3 = ts.pos_spring.step(tgt, 0.12 if urgent else 0.20, sdt)
		var sm_nrm := BM.nrm(ts.norm_spring.step(nrm, 0.24, sdt))
		o.weight = _cl(w, 0.0, 1.0); o.targetWorld = sm_pos; o.normalWorld = sm_nrm
		o.railTangentWorld = ac.get("tangentWorld") if ac != null else null
		o.mode = t_mode; o.surfaceId = surf_id; o.phase = ts.phase
		o.reachProgress = roundf(ts.reach_progress * 100.0) / 100.0
	else:
		o.weight = _cl(w, 0.0, 1.0)
		o.phase = ts.phase
		if w > 0.02 and ts.initialized:
			o.targetWorld = ts.pos_spring.step(rest_world, 0.22, sdt) if rest_world != null else ts.pos_spring.x
			o.normalWorld = BM.nrm(ts.norm_spring.x)
			o.railTangentWorld = ts.rail_tangent_world
			o.mode = ts.mode
			o.surfaceId = ts.surface_id
	ts.active = o.weight > 0.14
	ts.mode = o.mode
	ts.surface_id = o.surfaceId
