## M33 Interact, picker 0.1.0 (core, engine-agnostic: no nodes, no Input). Chooses the one thing the girl can act on and
## runs the tap / hold progress for it. Port of Thalassa v20.19 runtime.js getInteractionPrompt() + hud-overlay.js prompt
## timing (fade in 0.45 s, optional auto-fade), upgraded: Thalassa's prompt picks by a fixed priority list per mode; here every
## target scores by distance and by how near the camera's centre it sits, so the camera chooses (God of War style: look at it).
##
## No jitter rule (Gary 28 Nov): a target only replaces the current one when it beats it by SWITCH_MARGIN, and the current one
## is kept until it leaves its range by KEEP_MARGIN, so a prompt never flickers between two targets or on a range edge.
##
## Target = Dictionary {id: String, pos: Vector3, verb: String, range: float (m), hold: float (s, 0 = tap), enabled: bool}.
extends RefCounted

const SWITCH_MARGIN := 0.25        # score a challenger needs above the current target
const KEEP_MARGIN := 1.25          # range factor before the current target is dropped (enter at 1.0)
const VIEW_COS := 0.50             # outside ~60 degrees from the view centre a target is not offered
const FADE_IN := 0.45              # Thalassa hud-overlay prompt fade in (s)
const FADE_OUT := 0.30

var current := {}                  # the picked target ({} = none)
var progress := 0.0                # hold progress 0..1 for the current target
var alpha := 0.0                   # prompt opacity 0..1 (fades, never pops)
var completed_id := ""             # set on the tick an action completes, else ""
var _held_prev := false
var _latched := false             # a hold completed: wait for release before the next one

## Score of one target for an eye looking along fwd (unit). < 0 = not offered.
static func score(t: Dictionary, eye: Vector3, fwd: Vector3, range_k := 1.0) -> float:
	if not t.get("enabled", true): return -1.0
	var d: Vector3 = t.pos - eye
	var dist := d.length()
	var r: float = t.get("range", 2.5) * range_k
	if dist > r: return -1.0
	var c := 1.0 if dist < 1e-4 else fwd.dot(d / dist)
	if c < VIEW_COS: return -1.0
	return (1.0 - dist / r) * 0.5 + (c - VIEW_COS) / (1.0 - VIEW_COS) * 0.5

## One tick. held = interact button down now. Returns the picked target ({} = none).
func step(dt: float, targets: Array, eye: Vector3, fwd: Vector3, held: bool) -> Dictionary:
	completed_id = ""
	var cur_score := -1.0
	if not current.is_empty():
		var still = null
		for t in targets:
			if t.id == current.id: still = t; break
		cur_score = score(still, eye, fwd, KEEP_MARGIN) if still != null else -1.0
		if still != null: current = still
		if cur_score < 0.0: current = {}
	var best := {}
	var best_s := -1.0
	for t in targets:
		var s := score(t, eye, fwd)
		if s > best_s: best_s = s; best = t
	if not best.is_empty() and (current.is_empty() or (best.id != current.id and best_s > cur_score + SWITCH_MARGIN)):
		progress = 0.0
		current = best
	# progress: a tap target completes on the press; a hold target fills while held and drains when let go
	var pressed := held and not _held_prev
	_held_prev = held
	if not held: _latched = false
	if current.is_empty():
		progress = maxf(0.0, progress - dt * 3.0)
	else:
		var hold: float = current.get("hold", 0.0)
		if hold <= 0.0:
			if pressed: completed_id = current.id
		elif held and not _latched:
			progress = minf(1.0, progress + dt / hold)
			if progress >= 1.0:
				completed_id = current.id; progress = 0.0; _latched = true   # one completion per press
		elif not held:
			progress = maxf(0.0, progress - dt * 2.5)
	var target_a := 1.0 if not current.is_empty() else 0.0
	var rate := (1.0 / FADE_IN) if target_a > alpha else (1.0 / FADE_OUT)
	alpha = move_toward(alpha, target_a, dt * rate)
	return current

func reset() -> void:
	current = {}; progress = 0.0; alpha = 0.0; completed_id = ""; _held_prev = false; _latched = false
