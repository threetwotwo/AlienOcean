## M02 body activities 0.1.0 (rest-ride thread, 28 Nov 2026): the motor side of resting (sit on a stool or a bench,
## sit on a bunk's edge and lie down) and riding a creature. Thalassa v20.19 runs these in style/runtime.js
## (enterPelagosRest / leavePelagosRest / stepPelagosRest), style/runtime-interactions.js (startCreatureRide /
## stepCreatureRide: creature_latch -> creature_ride -> creature_release) and core/wildlife-ecosystem.js
## (findNearestRidable, startRide, stepActiveRide, releaseRide).
## The motor calls step() every tick. While the act HOLDS her the swimmer is not integrated: the act places the eye
## (swimmer.pos), the velocity and the view, and the body rig (core/m04_body/body_rig.gd) solves the matching pose
## from swimmer.act (kind, phase, progress, markers). While she walks to a seat the act only steers her input.
## ADAPTED: Thalassa puts her in the seat under a 0.42 s camera glide and switches the body pose at its end (a pop);
## here she walks to the seat, turns, steps back and sits, and every pose change is blended by the rig.
## Markers are Transform3D with -Z the facing and +Y up (blockout kit convention).
extends RefCounted

# Thalassa findNearestRidable reach (m, eye to the creature / grab station): manta 3.6, turtle 2.65, dolphin 3.25,
# whale shark 4.2 (dorsal, tail) / 4.0 (pectoral fins). The humpback is not in Thalassa: as the whale shark.
const REACH := {"manta": 3.6, "turtle": 2.65, "dolphin": 3.25, "whale_shark": 4.2, "humpback": 4.2, "": 3.0}
const FIN_REACH := 4.0
const CALM_SPEED := 3.4        # Thalassa: no latching while faster than 3.4 m/s (or sprinting)
# Not in Thalassa (its creatures have one size): refuse what she cannot hold or ride
const RIDE_MIN_LEN := 1.0      # m: shorter than this the creature cannot carry a 1.38 m girl
const GRIP_SPAN_MAX := 0.95    # m between the two grips: both hands cannot hold wider than that (arms 0.47 m + shoulders)
const LATCH_DUR := {"whale_shark": 1.25, "humpback": 1.25}     # else 1.02 (Thalassa startRide)
const RELEASE_DUR := {"whale_shark": 0.92, "humpback": 0.92}   # else 0.82
const RIDE_EYE_UP := 0.30      # eye above the slot's body point (Thalassa riderLoc: dorsal + 0.32 / scale)
const SIDE_EYE_UP := 0.20      # pectoral-fin slots

# rest
const SIT_DUR := 1.5           # walk pose -> seated: steps back (first 45 %), then lowers (from 25 %)
const STAND_DUR := 1.5         # the sit run backwards
const LIE_DUR := 1.9           # bunk edge -> lying
const HANDOFF_DUR := 0.45      # her own standing snapshot -> the live walk pose
const SEAT_EYE_UP := 0.62      # seated eye above the seat top (pelvis 0.075 + spine 0.473 + head)
const SEAT_EYE_FWD := 0.06
const STAND_OFF := 0.45        # where she stands to sit: this far in front of the seat point
const APPROACH_SPEED := 0.75   # walk input while going to the seat
const TURN_RATE := 2.2         # rad/s, turning round to sit (the camera's own limit is 2.4 x 1.45)
const LOOK_LIMIT := {"stool": 1.85, "bench": 1.85, "bunk": 1.85}

var kind := ""                 # "", "rest", "ride"
var phase := ""
var phase_t := 0.0             # s in this phase
var refused := ""              # why the last request was refused ("" accepted)
var want := ""                 # queued request: stand, lie, rise, release
# rest
var spec := {}                 # {kind, seat: Transform3D, lie, pillow, extent: Vector2(left, right of the seat point)}
var waypoints: Array = []
var stand_eye := Vector3.ZERO
var stand_yaw := 0.0
var seat_yaw := 0.0
var look_yaw := 0.0
var look_pitch := 0.0
var stuck_t := 0.0
var best_d := INF
var lie_w := 0.0               # 0 seated .. 1 lying (the rig reads it)
# ride
var rider = null
var slot := ""
var slot_class := ""           # "fin" (vertical fin, both flanks), "side" (pectoral fin), "top" (back / shell rim)
var ride_side := 1
var start_pos := Vector3.ZERO
var start_rel := Vector3.ZERO  # where she was, in the creature's frame (the latch glide runs in it)
var start_vel := Vector3.ZERO
var start_yaw := 0.0
var start_pitch := 0.0
var anchor := Vector3.ZERO
var release_vel := Vector3.ZERO
var latch_dur := 1.02
var release_dur := 0.82
var cooldown := 0.0
var clock := 0.0

func active() -> bool:
	return kind != ""

## true while the act places her (the swimmer is not integrated)
func holding() -> bool:
	if kind == "ride": return true
	return kind == "rest" and not (phase in ["approach", "turn"])

## 0..1 progress of the current transition phase
func u() -> float:
	var d := phase_dur()
	return clampf(phase_t / d, 0.0, 1.0) if d > 0.0 else 1.0

func phase_dur() -> float:
	match phase:
		"sit": return SIT_DUR
		"stand": return STAND_DUR
		"lie", "rise": return LIE_DUR
		"handoff": return HANDOFF_DUR
		"latch": return latch_dur
		"release": return release_dur
	return 0.0

static func quintic(x: float) -> float:
	var t := clampf(x, 0.0, 1.0)
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)

## How far the body has gone down into the seat at sit progress x (0 standing .. 1 seated); stand runs it backwards.
## The rig uses the same curve for the pelvis, so the eye and the body move together.
static func sit_lower(x: float) -> float:
	return quintic((x - 0.25) / 0.75)

static func _yaw_of(d: Vector3) -> float:
	return atan2(-d.x, -d.z)

func _go(p: String) -> void:
	phase = p
	phase_t = 0.0

# ---------------------------------------------------------------- rest
## Sit down (stool / bench) or lie down (bunk: sit on the edge first). sp: {kind, seat, lie, pillow, extent}.
func request_rest(sp: Dictionary, s) -> bool:
	refused = ""
	if kind != "":
		refused = "busy"
		return false
	if not s.shore_grounded or s.shore_is_airborne or s.wade_blend > 0.1:
		refused = "not standing on dry ground"
		return false
	spec = sp.duplicate()
	if not spec.has("extent"): spec.extent = Vector2(0.2, 0.2)
	kind = "rest"
	var seat: Transform3D = spec.seat
	seat_yaw = _yaw_of(-seat.basis.z)
	_plan_route(s.pos)
	_go("approach")
	stuck_t = 0.0; best_d = INF
	lie_w = 0.0
	want = "lie" if spec.kind == "bunk" and spec.get("lie_down", true) else ""
	return true

func request_stand() -> void:
	if kind == "rest": want = "stand"

func request_lie() -> void:
	if kind == "rest" and spec.kind == "bunk": want = "lie"

func request_rise() -> void:
	if kind == "rest": want = "rise"

func stand_point() -> Vector3:
	var seat: Transform3D = spec.seat
	var f := -seat.basis.z
	f.y = 0.0
	return seat.origin + f.normalized() * STAND_OFF

## The way to the seat: straight to the stand point when she is in front of it; from behind or beside it, round
## the end of the seat first (the furniture's width from spec.extent), so she never walks into it.
func _plan_route(from: Vector3) -> void:
	var seat: Transform3D = spec.seat
	var f := -seat.basis.z; f.y = 0.0; f = f.normalized()
	var r := Vector3.UP.cross(-f).normalized()        # her right when seated (marker +X)
	var sp := stand_point()
	waypoints = []
	var rel := from - seat.origin
	if rel.dot(f) < STAND_OFF - 0.1:
		var ext: Vector2 = spec.extent
		# round the nearer end
		var lat_r: float = ext.y + 0.55
		var lat_l: float = ext.x + 0.55
		var x: float = rel.dot(r)
		var side := 1.0 if absf(x - lat_r) <= absf(x + lat_l) else -1.0
		var lat: float = lat_r if side > 0.0 else lat_l
		var corner_back := seat.origin + r * side * lat + f * minf(rel.dot(f), -0.1)
		var corner_front := seat.origin + r * side * lat + f * (STAND_OFF + 0.35)
		if rel.dot(f) < -0.1: waypoints.append(corner_back)
		waypoints.append(corner_front)
	waypoints.append(sp)

func _step_rest(dt: float, s, inp: Dictionary) -> bool:
	var seat: Transform3D = spec.seat
	match phase:
		"approach":
			var tgt: Vector3 = waypoints[0]
			var d := Vector2(tgt.x - s.pos.x, tgt.z - s.pos.z)
			var last: bool = waypoints.size() == 1
			if d.length() < (0.06 if last else 0.3):
				waypoints.pop_front()
				best_d = INF; stuck_t = 0.0
				if waypoints.is_empty():
					_go("turn")
					return _step_rest(dt, s, inp)
				return _step_rest(dt, s, inp)
			var want_yaw := atan2(-d.x, -d.y)
			var err := wrapf(want_yaw - s.target_yaw, -PI, PI)
			inp.yaw_delta = clampf(err, -TURN_RATE * 1.4 * dt, TURN_RATE * 1.4 * dt)
			inp.pitch_delta = -s.target_pitch * minf(1.0, 4.0 * dt)
			var go := clampf(d.length() / 0.5, 0.18, 1.0) * APPROACH_SPEED if last else APPROACH_SPEED
			inp.forward = go * clampf(cos(err) * 1.4 - 0.4, 0.0, 1.0)
			inp.right = 0.0; inp.up = 0.0; inp.boost = false; inp.jump_held = false
			# give up when she makes no progress for 4 s (blocked)
			if d.length() < best_d - 0.02: best_d = d.length(); stuck_t = 0.0
			else: stuck_t += dt
			if stuck_t > 4.0:
				refused = "blocked on the way to the seat"
				_end()
			return false
		"turn":
			var err2 := wrapf(seat_yaw - s.target_yaw, -PI, PI)
			# eased: full rate far off, slowing over the last 0.4 rad (no snap at the end of the turn)
			var rate := TURN_RATE * clampf(absf(err2) / 0.4, 0.15, 1.0)
			inp.yaw_delta = clampf(err2, -rate * dt, rate * dt)
			inp.pitch_delta = -s.target_pitch * minf(1.0, 4.0 * dt)
			inp.forward = 0.0; inp.right = 0.0; inp.up = 0.0; inp.boost = false; inp.jump_held = false
			var spd := Vector2(s.vel.x, s.vel.z).length()
			if absf(err2) < 0.01 and spd < 0.04 and phase_t > 0.5:
				stand_eye = s.pos
				stand_yaw = s.yaw
				look_yaw = 0.0
				look_pitch = s.pitch
				_go("sit")
				return _step_rest(0.0, s, inp)
			return false
	# held from here: the eye follows the body
	_look(dt, s, inp)
	var e_seat := _seat_eye()
	match phase:
		"sit":
			s.pos = stand_eye.lerp(e_seat, sit_lower(u()))
			if u() >= 1.0: _go("seated")
		"seated":
			s.pos = e_seat
			if want == "stand" and phase_t > 0.3: want = ""; _go("stand")
			elif want == "lie" and phase_t > 0.3 and spec.kind == "bunk": want = ""; _go("lie")
		"stand":
			s.pos = stand_eye.lerp(e_seat, sit_lower(1.0 - u()))
			if u() >= 1.0: _go("handoff")
		"handoff":
			s.pos = stand_eye
			if u() >= 1.0:
				s.vel = Vector3.ZERO
				s.shore_vel_xz = Vector2.ZERO; s.shore_desired_vel_xz = Vector2.ZERO; s.shore_accel_xz = Vector2.ZERO
				_end()
				return true
		"lie":
			lie_w = quintic(u())
			s.pos = e_seat.lerp(_lie_eye(), lie_w)
			if u() >= 1.0: lie_w = 1.0; _go("lying")
		"lying":
			s.pos = _lie_eye()
			if (want == "rise" or want == "stand") and phase_t > 0.3:
				if want == "rise": want = ""
				_go("rise")
		"rise":
			lie_w = 1.0 - quintic(u())
			s.pos = e_seat.lerp(_lie_eye(), lie_w)
			if u() >= 1.0: lie_w = 0.0; _go("seated")
	s.vel = Vector3.ZERO
	return true

## The view while held: the camera's yaw / pitch become a look relative to the seat (Thalassa lookYaw / lookPitch,
## clamped to the station's yaw limit); standing up eases the look back to the seat's facing.
func _look(dt: float, s, inp: Dictionary) -> void:
	var lim: float = LOOK_LIMIT.get(spec.kind, 1.85)
	var cam_yaw: float = s.target_yaw + inp.get("yaw_delta", 0.0)
	var cam_pitch: float = s.target_pitch + inp.get("pitch_delta", 0.0)
	var want_y := clampf(wrapf(cam_yaw - seat_yaw, -PI, PI), -lim, lim)
	var want_p := clampf(cam_pitch, -0.8, 0.8)
	if phase in ["stand", "handoff"]:
		want_y = 0.0
		want_p = 0.0
	var k := 1.0 - exp(-6.0 * dt)
	look_yaw += (want_y - look_yaw) * k
	look_pitch += (want_p - look_pitch) * k
	s.yaw = wrapf(seat_yaw + look_yaw, -PI, PI)
	s.target_yaw = s.yaw
	s.pitch = look_pitch
	s.target_pitch = look_pitch

func _seat_eye() -> Vector3:
	var seat: Transform3D = spec.seat
	return seat.origin + seat.basis.y.normalized() * SEAT_EYE_UP - seat.basis.z.normalized() * SEAT_EYE_FWD

func _lie_eye() -> Vector3:
	var lie: Transform3D = spec.get("lie", spec.seat)
	return lie.origin + lie.basis.y.normalized() * 0.26 - lie.basis.z.normalized() * 0.66

# ---------------------------------------------------------------- ride
## The grab slot of creature 'rd' nearest to her eye, its reach and class. {} when the creature has no slots.
static func pick_slot(rd, eye: Vector3) -> Dictionary:
	var best := {}
	var names: Array = rd.slots()
	if names.is_empty(): names = ["saddle"]
	for sl in names:
		var body_pt: Vector3 = rd.marker(sl + "_body" if sl != "saddle" else "saddle").origin
		var d := eye.distance_to(body_pt)
		if best.is_empty() or d < best.dist:
			best = {"slot": sl, "dist": d}
	return best

static func slot_class_of(species: String, sl: String) -> String:
	if sl.begins_with("pec"): return "side"
	if species == "dolphin": return "fin"
	if species == "whale_shark" and sl in ["dorsal", "tail"]: return "flank"
	return "top"

## Thalassa findNearestRidable + startRide. Refuses (refused says why) when she is out of reach, too fast, the
## creature is too small to carry her, or its grips are wider apart than her arms can hold.
func request_ride(rd, s) -> bool:
	refused = ""
	if kind != "": refused = "busy"; return false
	if cooldown > 0.02: refused = "cooling down"; return false
	if rd == null: refused = "no creature"; return false
	var sp: String = String(rd.species)
	var length: float = float(rd.LENGTH)
	if length < RIDE_MIN_LEN:
		refused = "too small to ride (%.2f m)" % length
		return false
	var pk := pick_slot(rd, s.pos)
	var sl: String = pk.slot
	var cls := slot_class_of(sp, sl)
	var reach: float = FIN_REACH if cls == "side" and sp == "whale_shark" else float(REACH.get(sp, 3.0))
	if pk.dist > reach:
		refused = "out of reach (%.2f m > %.2f m)" % [pk.dist, reach]
		return false
	if s.vel.length() > CALM_SPEED or s.sprinting:
		refused = "too fast to latch"
		return false
	var hl: Vector3 = rd.marker(_mk(sl, "hand_l")).origin
	var hr: Vector3 = rd.marker(_mk(sl, "hand_r")).origin
	if hl.distance_to(hr) > GRIP_SPAN_MAX:
		refused = "grips too far apart (%.2f m)" % hl.distance_to(hr)
		return false
	rider = rd
	slot = sl
	slot_class = cls
	var tf: Transform3D = rd.global_transform
	var rel: Vector3 = s.pos - tf.origin
	# Thalassa: the side she came from; the stand-in's flank grips are built for her right flank (whale shark)
	ride_side = 1 if cls == "flank" else (1 if rel.dot(tf.basis.x) >= 0.0 else -1)
	start_pos = s.pos
	start_rel = _rider_xf().affine_inverse() * s.pos
	start_vel = s.vel
	start_yaw = s.yaw
	start_pitch = s.pitch
	latch_dur = LATCH_DUR.get(sp, 1.02)
	release_dur = RELEASE_DUR.get(sp, 0.82)
	kind = "ride"
	want = ""
	_go("latch")
	anchor = _anchor()
	return true

func _mk(sl: String, part: String) -> String:
	if sl == "saddle": return part if part != "body" else "saddle"
	return "%s_%s" % [sl, part]

func release() -> void:
	if kind == "ride" and phase != "release": want = "release"

## Thalassa riderLoc: the eye above the slot's body point (the stand-in's chest / hips rest marker)
func _anchor() -> Vector3:
	var tf: Transform3D = rider.global_transform
	var bp: Vector3 = rider.marker(_mk(slot, "body")).origin
	return bp + tf.basis.y.normalized() * (SIDE_EYE_UP if slot_class == "side" else RIDE_EYE_UP)

func _rider_xf() -> Transform3D:
	var tf: Transform3D = rider.global_transform
	tf.basis = tf.basis.orthonormalized()
	return tf

const LATCH_CLEAR := 0.16      # m: her body's half-thickness plus a margin, kept off the creature while she glides in
## How far to lift the gliding eye so the body hanging from it stays off the creature: her body runs from the eye
## down (treading water) and swings back along the creature as she settles (the ride pose). Lifted along the
## creature's up by the deepest of a few points along it (a point below the creature's axis does not count: lifting
## would not free it), so the lift stays continuous as the deepest point changes (weighted by where the point is,
## not by the surface normal, which jumps at a fin's edge).
func _latch_clear(eye: Vector3, tf: Transform3D, uu: float) -> Vector3:
	if not rider.has_method("surface"): return Vector3.ZERO
	var up := tf.basis.y
	var hang := Vector3.DOWN.slerp((tf.basis.z * 0.85 - up * 0.5).normalized(), uu)
	var lift := 0.0
	for i in 6:
		var q: Vector3 = eye + hang * (0.12 + 0.22 * i)
		var sf: Dictionary = rider.surface(q, LATCH_CLEAR)
		if sf.is_empty(): continue
		var pen: float = (LATCH_CLEAR - float(sf.dist)) * smoothstep(-0.15, 0.15, (q - tf.origin).dot(up))
		lift = maxf(lift, pen)
	return up * lift

func creature_yaw() -> float:
	var v: Vector3 = rider.velocity
	if Vector2(v.x, v.z).length() < 0.05: return _yaw_of(-rider.global_transform.basis.z)
	return _yaw_of(v)

func creature_pitch() -> float:
	var f: Vector3 = -rider.global_transform.basis.z.normalized()
	return asin(clampf(f.y, -1.0, 1.0))

func _step_ride(dt: float, s) -> bool:
	anchor = _anchor()
	var cv: Vector3 = rider.velocity
	if want == "release" and phase != "release":
		want = ""
		_begin_release()
	match phase:
		"latch":
			# Thalassa stepCreatureRide latch: quintic glide from where she was to the anchor, arcing up and to her side
			# FIX: Thalassa glides between WORLD points while the creature swims on, so from ahead of it she is pulled back
			# through its head; here the glide runs in the creature's own frame (it carries her along) and her hanging
			# body is lifted off its surface.
			var pt := u()
			var uu := quintic(pt)
			var bell := sin(uu * PI)
			var tf := _rider_xf()
			var a_rel: Vector3 = tf.affine_inverse() * anchor
			var arc_h := clampf(start_rel.distance_to(a_rel) * 0.14, 0.10, 0.42)
			var p_rel: Vector3 = start_rel.lerp(a_rel, uu) + Vector3(ride_side * arc_h * 0.55, arc_h, 0.0) * bell
			var p: Vector3 = tf * p_rel
			var lc := _latch_clear(p, tf, uu)
			s.pos = p + lc * (1.0 - smoothstep(0.72, 1.0, pt))
			var u_yaw := smoothstep(0.06, 0.96, pt)
			s.yaw = wrapf(start_yaw + wrapf(creature_yaw() - start_yaw, -PI, PI) * u_yaw, -PI, PI)
			s.target_yaw = s.yaw
			s.pitch = lerpf(start_pitch, clampf(creature_pitch() - 0.06, -0.35, 0.35), u_yaw * 0.55)
			s.target_pitch = s.pitch
			s.vel = start_vel.lerp(cv, uu)
			if pt >= 1.0: _go("ride")
		"ride":
			s.pos = anchor
			s.vel = cv
			s.yaw = creature_yaw()
			s.target_yaw = s.yaw
			s.pitch = lerpf(s.pitch, clampf(creature_pitch() - 0.06, -0.35, 0.35) * 0.55, 1.0 - exp(-4.0 * dt))
			s.target_pitch = s.pitch
		"release":
			var rt := u()
			var push := smoothstep(0.0, 0.24, rt)
			var glide := lerpf(1.0, 0.52, smoothstep(0.28, 1.0, rt))
			var cur := release_vel * (lerpf(0.45, 1.0, push) * glide)
			s.pos += cur * dt
			s.vel = cur
			if rt >= 1.0:
				s.vel = release_vel * 0.52
				cooldown = 1.15
				_end()
	return true

## Thalassa releaseRide: let go up and out to her side, keeping about half the creature's momentum
func _begin_release() -> void:
	var tf: Transform3D = rider.global_transform
	var fwd := -tf.basis.z.normalized()
	var up := tf.basis.y.normalized()
	var right := tf.basis.x.normalized()
	var is_tail := slot == "tail"
	var side_push := -0.62 if slot == "pec_left" else (0.62 if slot == "pec_right" else (ride_side * 0.56 if slot_class in ["fin", "flank"] else 0.0))
	var fwd_push := -0.24 if is_tail else 0.36
	var dir := (fwd * fwd_push + up * 0.72 + right * side_push + Vector3(0, 0.16, 0)).normalized()
	var cv: Vector3 = rider.velocity
	var k := 0.25 if is_tail else 0.48
	release_vel = Vector3(cv.x * k, cv.y * 0.25, cv.z * k) + dir * 1.95
	_go("release")

# ---------------------------------------------------------------- tick
func _end() -> void:
	kind = ""
	phase = ""
	phase_t = 0.0
	want = ""
	rider = null
	lie_w = 0.0

## One tick. inp is the motor's input dictionary (may be rewritten: walking to a seat). Returns true when the act
## held her this tick (the motor must not integrate the swimmer).
func step(dt: float, s, inp: Dictionary) -> bool:
	clock += dt
	if cooldown > 0.0: cooldown = maxf(0.0, cooldown - dt)
	if kind == "": return false
	phase_t += dt
	if kind == "rest": return _step_rest(dt, s, inp)
	if kind == "ride":
		if rider == null or not is_instance_valid(rider):
			_end()
			return false
		return _step_ride(dt, s)
	return false
