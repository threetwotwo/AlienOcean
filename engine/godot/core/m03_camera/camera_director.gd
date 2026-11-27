## M03 Camera director, core 0.1.0 (engine-agnostic logic). One camera, no cuts.
## Shots are data (boom length, shoulder offset, pivot height, fov). The director owns yaw/pitch (from look input),
## blends between shots continuously (boom shortens along the same line, pivot slides to the eye, fov eases), and
## keeps the camera out of geometry and off the water line using a probe the adapter supplies.
## 3P -> 1P is the boom reaching 0 at the eye; the body fades out as the camera passes inside 0.45 m of the head.
extends RefCounted

const SHOT_TABLE := {
	"explore":      {"boom": 3.2, "side": 0.45, "lift": 0.25, "fov": 70.0, "pitch_bias": -0.12},
	"swim":         {"boom": 4.0, "side": 0.30, "lift": 0.10, "fov": 74.0, "pitch_bias": -0.05},
	"first_person": {"boom": 0.0, "side": 0.0,  "lift": 0.0,  "fov": 74.0, "pitch_bias": 0.0},
	"observe":      {"boom": 0.0, "side": 0.0,  "lift": 0.0,  "fov": 50.0, "pitch_bias": 0.0},
}

var shots: Dictionary = SHOT_TABLE.duplicate(true)
var blend_time := 0.7          # s for a full shot change
var pitch_min := -1.35
var pitch_max := 1.35
var radius := 0.18             # camera collision sphere (near plane + margin)
var anticipation_radius := 0.6 # m: wide probe that sees obstacles early
var pull_in_k := 20.0          # 1/s: boom draws in toward the anticipated free length
var max_boom_speed := 27.0     # m/s: the boom never changes faster (0.45 m per tick at 60 Hz)
var graze_tilt := 0.1         # rad: tilted anticipation probes
var lookahead := [0.1, 0.2, 0.3] # s: the boom line is also probed where look input and motion will put it
var hard_snaps := 0            # times the lens had to be pulled out of geometry at once (should stay 0)
var ease_out_k := 3.0          # 1/s: boom grows back slowly
var water_gap := 0.2           # keep the lens this far from the water line (no half-above/half-below frame)
var fade_start := 0.45         # m from the eye where the body starts fading
var fade_end := 0.2

var yaw := 0.0
var pitch := -0.1
var shot := "explore"
var from_shot := "explore"
var blend := 1.0               # 0 = from_shot, 1 = shot
var boom_now := 3.2            # boom this tick
var free_len := 5.0            # smoothed free length along the boom line
var max_boom := 5.0            # longest boom any shot uses (probe length)
var cam_pos := Vector3.ZERO
var started := false
var dbg := {}
var prev_eye := Vector3.ZERO

static func _smooth(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

func request(name: String) -> void:
	if name == shot or not shots.has(name):
		return
	# start the new blend from wherever the current blend is (no jump when a blend is interrupted)
	var cur := _params()
	shots["_from"] = cur
	from_shot = "_from"
	shot = name
	blend = 0.0

func _params() -> Dictionary:
	var a: Dictionary = shots[from_shot]
	var b: Dictionary = shots[shot]
	var w := _smooth(blend)
	var out := {}
	for k in b:
		out[k] = lerpf(a[k], b[k], w)
	return out

## actor: {eye: Vector3 (head point), feet: Vector3}; look: rad/s; probe.call(from, to, radius) -> safe fraction 0..1;
## overlap.call(pos, radius) -> true if a sphere there touches geometry; water_y: surface height (or -INF).
## While the boom is still drawing in, a wall may stand between eye and lens for a moment: the renderer fades
## occluders (M03 adapter), the lens itself never enters geometry. Returns {pos, yaw, pitch, fov, body_alpha, boom}.
func update(dt: float, actor: Dictionary, look: Vector2, probe: Callable, water_y: float, overlap: Callable) -> Dictionary:
	blend = minf(1.0, blend + dt / blend_time)
	yaw = wrapf(yaw - look.x * dt, -PI, PI)
	pitch = clampf(pitch + look.y * dt, pitch_min, pitch_max)
	var p := _params()
	var eye: Vector3 = actor.eye
	var fwd := Vector3(-sin(yaw) * cos(pitch + p.pitch_bias), sin(pitch + p.pitch_bias), -cos(yaw) * cos(pitch + p.pitch_bias))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var pivot: Vector3 = eye + Vector3.UP * p.lift + right * p.side
	# the pivot itself must be reachable from the eye (shoulder offset into a wall)
	var pf: float = probe.call(eye, pivot, radius)
	pivot = eye.lerp(pivot, pf)
	var want: float = p.boom
	# free length along the boom line, probed to the longest boom any shot uses (independent of the blend, so the
	# shot's own boom stays exact and continuous; collision only ever shortens it)
	var probe_len := max_boom
	var line_end: Vector3 = pivot - fwd * probe_len
	var hard_free: float = probe_len * probe.call(pivot, line_end, radius)
	# wide probe: the largest radius that does not already touch geometry at the pivot (a probe that starts
	# inside a wall would see nothing)
	var r_soft := anticipation_radius
	while r_soft > radius * 1.5 and overlap.call(pivot, r_soft):
		r_soft *= 0.7
	var soft_free: float = minf(hard_free, probe_len * probe.call(pivot, line_end, r_soft))
	# anticipation in time: where will the boom line be if the stick and the body keep doing what they do now?
	# Drawing in toward that length early is what keeps the pull-in under max_boom_speed when a wall swings in.
	var vel: Vector3 = (eye - prev_eye) / dt if started and dt > 0.0 else Vector3.ZERO
	if vel.length() > 20.0: vel = Vector3.ZERO   # a teleport (respawn, dock) is not motion
	prev_eye = eye
	# anticipation in space: the boom line tilted a little up, down and to each side. A surface the line is about
	# to graze (a ceiling a few cm above the lens) is hit by the tilted line at a distance that changes smoothly,
	# so the boom is already short before a tiny turn makes the real line collide.
	for d in [Vector2(0, graze_tilt), Vector2(0, -graze_tilt), Vector2(graze_tilt, 0), Vector2(-graze_tilt, 0)]:
		var pt: float = pitch + p.pitch_bias + d.y
		var ft := Vector3(-sin(yaw + d.x) * cos(pt), sin(pt), -cos(yaw + d.x) * cos(pt))
		soft_free = minf(soft_free, probe_len * probe.call(pivot, pivot - ft * probe_len, radius))
	for tau in lookahead:
		var yp: float = yaw - look.x * tau
		var pp: float = clampf(pitch + look.y * tau, pitch_min, pitch_max) + p.pitch_bias
		var fp := Vector3(-sin(yp) * cos(pp), sin(pp), -cos(yp) * cos(pp))
		var pv: Vector3 = pivot + vel * tau
		var reach: float = probe.call(pivot, pv, radius)
		pv = pivot.lerp(pv, reach)
		soft_free = minf(soft_free, probe_len * probe.call(pv, pv - fp * probe_len, radius * 1.5))
	if not started:
		free_len = soft_free; started = true
	else:
		var k := pull_in_k if soft_free < free_len else ease_out_k
		var target := free_len + (soft_free - free_len) * (1.0 - exp(-k * dt))
		free_len = move_toward(free_len, target, max_boom_speed * dt)   # continuous: never a cut
	boom_now = minf(want, free_len)
	# the lens never enters geometry: the boom is clamped to the hard free length every tick. That length moves
	# continuously as the view turns, so this is a fast pull-in, not a cut; the wide probe above makes it rare.
	if boom_now > hard_free:
		if boom_now - hard_free > 0.25:
			hard_snaps += 1
		boom_now = hard_free
		free_len = hard_free
	var pos: Vector3 = pivot - fwd * boom_now
	# water line: lift or drop the lens off the surface toward the side the eye is on
	if water_y > -1e8 and absf(pos.y - water_y) < water_gap:
		var side := 1.0 if eye.y >= water_y else -1.0
		var target_y := water_y + side * water_gap
		var to := Vector3(pos.x, target_y, pos.z)
		var f: float = probe.call(pos, to, radius)
		pos = pos.lerp(to, f)
	cam_pos = pos
	dbg = {"pf": pf, "hard": hard_free, "soft": soft_free, "free": free_len, "boom": boom_now, "pivot": pivot, "r_soft": r_soft}
	var d := pos.distance_to(eye)
	var alpha := clampf((d - fade_end) / (fade_start - fade_end), 0.0, 1.0)
	return {"pos": pos, "yaw": yaw, "pitch": pitch + p.pitch_bias, "fov": p.fov, "body_alpha": alpha, "boom": boom_now, "blend": blend}
