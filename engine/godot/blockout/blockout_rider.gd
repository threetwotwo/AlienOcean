## Blockout rider 0.2.0 (blockout kit): a creature stand-in that swims a scripted loop, for riding tests.
## 0.2.0 (Gary 28 Nov 07:20Z): species stand-ins (blockout/blockout_species.gd: dolphin, humpback, whale shark, manta,
## turtle) of real sizes, each swimming its own way (body wave up-down, side-to-side, wing flap, flipper strokes), with
## Thalassa's grab slots; 'scale' resizes any of them. species "" keeps the 0.1.0 generic 2.5 m stand-in.
## The loop (a racetrack; the generic one: 16 m straights, radius 5, 2.5 m climb / dive, bank 20 deg; species use their
## own path from the profile):
##   A straight with a dive    B left turn, banked    C straight with a climb    D left turn, banked
## Pose and swim are pure functions of time (frame_at(t), swim phase = omega t), so 30/60/120 Hz runs at the fixed tick
## land on the same poses.
## Read each tick: velocity (m/s), marker(name) -> Transform3D. Generic: saddle, hand_l, hand_r, foot_l, foot_r.
## Species: <slot>_hand_l, <slot>_hand_r, <slot>_body for every slot in slots(); the first slot also answers to
## saddle / hand_l / hand_r. Markers ride the swim wave (they move with the fin they hold). -Z forward, +Y up.
## Collision: one capsule (manta: a flat box) on layer 2 (not the floor layer).
extends AnimatableBody3D

const Species := preload("res://blockout/blockout_species.gd")

var L := 16.0
var R := 5.0
var H := 2.5
var BANK := deg_to_rad(20.0)
var LENGTH := 2.5
var RADIUS := 0.35
var MARKERS := {
	"saddle": [Vector3(0, 0.40, 0.10), Vector3.FORWARD],
	"hand_l": [Vector3(-0.16, 0.44, -0.45), Vector3.FORWARD],
	"hand_r": [Vector3(0.16, 0.44, -0.45), Vector3.FORWARD],
	"foot_l": [Vector3(-0.34, 0.12, 0.35), Vector3.FORWARD],
	"foot_r": [Vector3(0.34, 0.12, 0.35), Vector3.FORWARD],
}

var species := ""
var scale_k := 1.0
var prof := {}
var omega := 0.0
var _segs: Array = []        # [node, u]
var _wings: Array = []       # [node, ax(signed), u]
var _flippers: Array = []    # [pivot, side, front]
var _boxes: Array = []       # fin / fluke / flipper plates (part of the surface)
var _mk_nodes := {}          # name -> Marker3D
var _mk_def := {}            # name -> [u, x, y] (fractions of length)
var speed := 2.5
var origin := Vector3(0, -4, -6)
var t := 0.0
var velocity := Vector3.ZERO
var paused := false

func _init() -> void:
	sync_to_physics = true
	collision_layer = 2
	collision_mask = 0

func _ready() -> void:
	SeaFloorMap.mark_mover(self)   # moves: never frozen into the sea floor map (the water drew stale copies, Gary 28 Nov)
	var mat := ShaderMaterial.new(); mat.shader = preload("res://blockout/blockout_grey.gdshader")
	mat.set_shader_parameter("tint_amount", 0.5)
	if species != "":
		_build_species(mat)
		_apply()
		return
	var parts := [
		[CapsuleMesh, {"radius": RADIUS, "height": LENGTH}, Vector3.ZERO, Vector3(PI * 0.5, 0, 0)],
		[BoxMesh, {"size": Vector3(1.9, 0.06, 0.7)}, Vector3(0, -0.05, -0.05), Vector3.ZERO],      # pectoral fins
		[BoxMesh, {"size": Vector3(0.06, 0.5, 0.45)}, Vector3(0, 0.05, 1.35), Vector3.ZERO],       # tail fin
		[BoxMesh, {"size": Vector3(0.34, 0.08, 0.5)}, Vector3(0, 0.36, 0.10), Vector3.ZERO],       # saddle pad
		[SphereMesh, {"radius": 0.08, "height": 0.16}, Vector3(-0.2, 0.12, -1.0), Vector3.ZERO],    # eyes (which end is the head)
		[SphereMesh, {"radius": 0.08, "height": 0.16}, Vector3(0.2, 0.12, -1.0), Vector3.ZERO],
	]
	for pt in parts:
		var mi := MeshInstance3D.new(); var m: PrimitiveMesh = pt[0].new()
		for k in pt[1]: m.set(k, pt[1][k])
		mi.mesh = m; mi.position = pt[2]; mi.rotation = pt[3]; mi.material_override = mat
		add_child(mi)
	var cs := CollisionShape3D.new(); var cap := CapsuleShape3D.new(); cap.radius = RADIUS; cap.height = LENGTH
	cs.shape = cap; cs.rotation = Vector3(PI * 0.5, 0, 0)
	add_child(cs)
	for n in MARKERS:
		var mk := Marker3D.new(); mk.name = n; mk.position = MARKERS[n][0]
		add_child(mk)
	_apply()

func _physics_process(delta: float) -> void:
	if not paused: t += delta
	_apply()

func _apply() -> void:
	var f := frame_at(t)
	var par := get_parent() as Node3D
	global_transform = (par.global_transform if par != null and par.is_inside_tree() else Transform3D.IDENTITY) * f.xform
	velocity = f.velocity
	if species != "": _swim(t)

func marker(mname: String) -> Transform3D:
	if species != "":
		return _mk_nodes[mname].global_transform
	return global_transform * Transform3D(Basis.IDENTITY, MARKERS[mname][0])

func perimeter() -> float:
	return 2.0 * L + 2.0 * PI * R

## Pose at time tt: {xform, velocity, segment}. Local frame of the loop: starts at origin heading -Z.
func frame_at(tt: float) -> Dictionary:
	var s := fposmod(tt * speed, perimeter())
	var p := Vector3.ZERO
	var d := Vector3.ZERO      # d(position)/ds
	var bank := 0.0
	var seg := ""
	var turn := PI * R
	if s < L:                                  # A: straight toward -z, dive
		var u := s / L
		p = Vector3(0, -H * pow(sin(PI * u), 2), -s)
		d = Vector3(0, -H * PI * sin(TAU * u) / L, -1)
		seg = "A_dive"
	elif s < L + turn:                         # B: left turn round (-R, -L)
		var th := (s - L) / R
		p = Vector3(-R + R * cos(th), 0, -L - R * sin(th))
		d = Vector3(-sin(th), 0, -cos(th))
		bank = BANK * sin(th)
		seg = "B_turn"
	elif s < 2.0 * L + turn:                   # C: straight toward +z at x = -2R, climb
		var u := (s - L - turn) / L
		p = Vector3(-2.0 * R, H * pow(sin(PI * u), 2), -L + (s - L - turn))
		d = Vector3(0, H * PI * sin(TAU * u) / L, 1)
		seg = "C_climb"
	else:                                      # D: left turn round (-R, 0) back to the start
		var ph := (s - 2.0 * L - turn) / R
		p = Vector3(-R - R * cos(ph), 0, R * sin(ph))
		d = Vector3(sin(ph), 0, cos(ph))
		bank = BANK * sin(ph)
		seg = "D_turn"
	var fwd := d.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var up := right.cross(fwd)
	var up2 := up * cos(bank) - right * sin(bank)     # roll into the (left) turn
	var right2 := up2.cross(-fwd)
	return {"xform": Transform3D(Basis(right2, up2, -fwd), origin + p), "velocity": d * speed, "segment": seg}

# ---------------------------------------------------------------- species stand-ins
## Grab slot names of this species (empty for the generic stand-in).
func slots() -> Array:
	return prof.get("slots", {}).keys()

func _build_species(mat: Material) -> void:
	prof = Species.PROFILES[species]
	LENGTH = float(prof.length) * scale_k
	RADIUS = float(prof.r) * LENGTH
	speed = float(prof.speed)
	var pp: Dictionary = prof.path
	L = float(pp.L) * maxf(1.0, scale_k); R = float(pp.R) * maxf(1.0, scale_k); H = float(pp.H); BANK = deg_to_rad(float(pp.bank))
	omega = float(prof.w0) + float(prof.w1) * speed
	var len := LENGTH
	var mode := String(prof.mode)
	var flat := 0.45 if mode == "flap" else (0.62 if mode == "stroke" else 1.0)   # manta disc and turtle shell are flat
	var n := 16
	for i in n:
		var u := (i + 0.5) / n
		var r := Species.radius(prof, u) * len
		var seg := Node3D.new(); add_child(seg)
		var mi := MeshInstance3D.new(); var sm := SphereMesh.new(); sm.radius = 0.5; sm.height = 1.0; mi.mesh = sm
		mi.scale = Vector3(2.0 * r * (1.3 if mode == "stroke" else 1.0), 2.0 * r * flat, len / n * 3.2)   # long overlapping ellipsoids: a smooth body, not a caterpillar
		mi.material_override = mat; seg.add_child(mi)
		_segs.append([seg, u])
	var fins: Dictionary = prof.get("fins", {})
	var box := func(parent: Node3D, size: Vector3, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
		var b := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = size; b.mesh = bm
		b.position = pos; b.rotation = rot; b.material_override = mat; parent.add_child(b)
		_boxes.append(b)
		return b
	if fins.has("dorsal"):   # [u, height, chord] in lengths
		var f: Array = fins.dorsal
		var sg = _seg_at(f[0])
		box.call(sg, Vector3(0.012 * len, f[1] * len, f[2] * len), Vector3(0, Species.radius(prof, f[0]) * len + f[1] * len * 0.45, 0), Vector3(-0.35, 0, 0))
	if fins.has("flukes"):   # horizontal tail (cetaceans): [u, span]
		var f: Array = fins.flukes
		box.call(_seg_at(f[0]), Vector3(f[1] * len, 0.012 * len, 0.07 * len), Vector3(0, 0, 0.04 * len))
	if fins.has("tail"):     # vertical tail (sharks, manta's whip tail)
		var f: Array = fins.tail
		if mode == "flap": box.call(_seg_at(0.97), Vector3(0.01 * len, 0.01 * len, 0.5 * len), Vector3(0, 0, 0.3 * len))
		else: box.call(_seg_at(f[0]), Vector3(0.012 * len, f[1] * len, 0.08 * len), Vector3(0, 0.02 * len, 0.03 * len), Vector3(-0.5, 0, 0))
	if fins.has("pecs"):     # [u, span]
		var f: Array = fins.pecs
		for sd in [-1.0, 1.0]:
			var sp: float = f[1] * len
			box.call(_seg_at(f[0]), Vector3(sp, 0.012 * len, 0.06 * len * (2.0 if species == "humpback" else 1.0)),
				Vector3(sd * (Species.radius(prof, f[0]) * len + sp * 0.45), -0.03 * len, 0), Vector3(0, 0, sd * -0.35))
	if mode == "flap":       # wings: strips out along the span, each lifted by the wing wave every tick
		var half: float = float(prof.span) * 0.5 * scale_k
		var k := 7
		for sd in [-1.0, 1.0]:
			for j in k:
				var ax := (j + 0.5) / k
				var chord := len * 0.55 * (1.0 - 0.75 * ax)
				var w := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = Vector3(half / k * 1.05, 0.03 * len, chord); w.mesh = bm
				w.material_override = mat; add_child(w)
				_wings.append([w, sd * ax, 0.42])
	if mode == "stroke":     # flippers: [u_front, span_front, u_back, span_back]
		var f: Array = fins.flippers
		for fr in [true, false]:
			for sd in [-1.0, 1.0]:
				var u: float = f[0] if fr else f[2]
				var sp: float = (f[1] if fr else f[3]) * len
				var pv := Node3D.new(); add_child(pv)
				pv.position = Vector3(sd * Species.radius(prof, u) * len * 1.2, -0.02 * len, (u - 0.5) * len)
				box.call(pv, Vector3(sp, 0.025 * len, sp * (0.35 if fr else 0.6)), Vector3(sd * sp * 0.5, 0, 0))
				_flippers.append([pv, sd, fr])
	# head marker: two eyes so the head end reads
	for sd in [-1.0, 1.0]:
		var e := MeshInstance3D.new(); var es := SphereMesh.new(); es.radius = 0.02 * len; es.height = 0.04 * len; e.mesh = es
		e.material_override = mat; _seg_at(0.08).add_child(e)
		e.position = Vector3(sd * Species.radius(prof, 0.08) * len * 0.9, Species.radius(prof, 0.08) * len * 0.3, 0)
	# collision
	var cs := CollisionShape3D.new()
	if mode == "flap":
		var bs := BoxShape3D.new(); bs.size = Vector3(float(prof.span) * scale_k * 0.8, RADIUS * 2.0, len * 0.6); cs.shape = bs
	else:
		var cap := CapsuleShape3D.new(); cap.radius = RADIUS; cap.height = maxf(len * 0.85, RADIUS * 2.0 + 0.01); cs.shape = cap
		cs.rotation = Vector3(PI * 0.5, 0, 0)
	add_child(cs)
	# grab markers (Thalassa slots)
	var first := true
	for slot in prof.slots:
		for part in prof.slots[slot]:
			var nm := "%s_%s" % [slot, part]
			var mk := Marker3D.new(); mk.name = nm; add_child(mk)
			_mk_nodes[nm] = mk; _mk_def[nm] = prof.slots[slot][part]
			if first:
				var alias: String = {"hand_l": "hand_l", "hand_r": "hand_r", "body": "saddle"}[part]
				_mk_nodes[alias] = mk; _mk_def[alias] = prof.slots[slot][part]
		first = false
	MARKERS = {}
	for nm in _mk_def: MARKERS[nm] = [Vector3.ZERO, Vector3.FORWARD]

func _seg_at(u: float) -> Node3D:
	var best = _segs[0]
	for sgu in _segs:
		if absf(sgu[1] - u) < absf(best[1] - u): best = sgu
	return best[0]

## The swim pose at time tt: body midline, fins and grab markers follow the species' wave.
func _swim(tt: float) -> void:
	var ph := omega * tt
	var len := LENGTH
	var du := 0.02
	for sgu in _segs:
		var u: float = sgu[1]
		var d := Species.body_disp(prof, u, ph, len)
		var d2 := Species.body_disp(prof, u + du, ph, len)
		var slope := (d2 - d) / (du * len)          # d(disp)/dz
		var n: Node3D = sgu[0]
		n.position = Vector3(0, 0, (u - 0.5) * len) + d
		n.rotation = Vector3(-atan(slope.y), atan(slope.x), 0)
	for w in _wings:
		var ax: float = w[1]
		var half: float = float(prof.span) * 0.5 * scale_k
		var y := Species.wing_disp(prof, absf(ax), w[2], ph, half)
		var y2 := Species.wing_disp(prof, minf(1.0, absf(ax) + 0.05), w[2], ph, half)
		w[0].position = Vector3(ax * half, y, (0.42 - 0.5) * len + absf(ax) * len * 0.12)
		w[0].rotation = Vector3(0, 0, signf(ax) * atan((y2 - y) / (0.05 * half)))
	for fl in _flippers:
		var a := sin(ph + (0.0 if fl[2] else PI)) * float(prof.amp) * (1.0 if fl[2] else 0.5)
		fl[0].rotation = Vector3(0, fl[1] * 0.25 * cos(ph), fl[1] * a)
	for nm in _mk_def:
		var dfn: Array = _mk_def[nm]
		var u: float = dfn[0]
		var p := Vector3(dfn[1] * len, dfn[2] * len, (u - 0.5) * len) + Species.body_disp(prof, u, ph, len)
		if dfn.size() > 4: p.x = signf(dfn[1]) * minf(absf(p.x), float(dfn[4]))     # a broad surface: held no wider than this (m)
		if dfn.size() > 3: p.x += signf(dfn[1]) * float(dfn[3])     # palm clearance, metres at any size
		if String(prof.mode) == "flap":
			p.y += Species.wing_disp(prof, absf(dfn[1] * len) / (float(prof.span) * 0.5 * scale_k), u, ph, float(prof.span) * 0.5 * scale_k)
		_mk_nodes[nm].position = p

## The live body surface near p (Thalassa queryCreatureSurface): {dist (< 0 inside), normal, point} in world, {} when
## farther than r + 0.3. The swimming ellipsoid sections and the manta's wings, as built above.
func surface(p: Vector3, r: float) -> Dictionary:
	var tf: Transform3D = global_transform
	tf.basis = tf.basis.orthonormalized()
	var q := tf.affine_inverse() * p
	var len: float = LENGTH
	var best := {}
	if species == "":
		var half: float = maxf(0.0, len * 0.5 - RADIUS)
		var c := Vector3(0, 0, clampf(q.z, -half, half))
		var d := q - c
		var dl := d.length()
		var n := d / dl if dl > 1e-5 else Vector3.UP
		best = {"dist": dl - float(RADIUS), "n": n, "s": c + n * float(RADIUS)}
	else:
		var mode := String(prof.mode)
		var ph: float = omega * t
		var u := clampf(q.z / len + 0.5, 0.0, 1.0)
		var c := Vector3(0, 0, (u - 0.5) * len) + Species.body_disp(prof, u, ph, len)
		var flat := 0.45 if mode == "flap" else (0.62 if mode == "stroke" else 1.0)
		var rr := Species.radius(prof, u) * len
		var rx := maxf(0.01, rr * (1.3 if mode == "stroke" else 1.0))
		var ry := maxf(0.01, rr * flat)
		var d2 := Vector2(q.x - c.x, q.y - c.y)
		var e := sqrt(pow(d2.x / rx, 2) + pow(d2.y / ry, 2))
		var n := Vector3(d2.x / (rx * rx), d2.y / (ry * ry), 0.0)
		n = n.normalized() if n.length() > 1e-6 else Vector3.UP
		var sp := c + (Vector3(d2.x, d2.y, 0) / e if e > 1e-5 else Vector3(0, ry, 0))
		var dist := d2.length() * (1.0 - 1.0 / e) if e > 1e-5 else -ry
		var past := absf(q.z) - len * 0.5
		if past > 0.0: dist = Vector2(maxf(dist, 0.0), past).length()
		best = {"dist": dist, "n": n, "s": sp}
		if mode == "flap":
			# the wings: a plate along the span lifted by the wing wave, chord shrinking toward the tip
			var half_span: float = float(prof.span) * 0.5 * scale_k
			var ax := absf(q.x) / half_span
			if ax < 1.0:
				var zc := (0.42 - 0.5) * len + ax * len * 0.12
				var chord := len * 0.55 * (1.0 - 0.75 * ax)
				if absf(q.z - zc) < chord * 0.5:
					var yw := Species.wing_disp(prof, ax, 0.42, ph, half_span)
					var dy := q.y - yw
					var dw := absf(dy) - 0.015 * len
					if dw < float(best.dist):
						var nw := Vector3(0, signf(dy) if absf(dy) > 1e-5 else 1.0, 0)
						best = {"dist": dw, "n": nw, "s": Vector3(q.x, yw + nw.y * 0.015 * len, q.z)}
	var out := {"dist": float(best.dist), "normal": (tf.basis * best.n).normalized(), "point": tf * best.s}
	# the fins, flukes and flippers: thin plates, as boxes
	for b in _boxes:
		var bt: Transform3D = (b as Node3D).global_transform
		bt.basis = bt.basis.orthonormalized()
		var bq: Vector3 = bt.affine_inverse() * p
		var hs: Vector3 = ((b as MeshInstance3D).mesh as BoxMesh).size * 0.5
		var dq := bq.abs() - hs
		var dpos := Vector3(maxf(dq.x, 0.0), maxf(dq.y, 0.0), maxf(dq.z, 0.0))
		var outside := dpos.length()
		var dist := outside + minf(maxf(dq.x, maxf(dq.y, dq.z)), 0.0)
		if dist >= float(out.dist): continue
		var nl: Vector3
		if outside > 1e-6: nl = Vector3(signf(bq.x) * dpos.x, signf(bq.y) * dpos.y, signf(bq.z) * dpos.z) / outside
		elif dq.x >= dq.y and dq.x >= dq.z: nl = Vector3(signf(bq.x), 0, 0)
		elif dq.y >= dq.z: nl = Vector3(0, signf(bq.y), 0)
		else: nl = Vector3(0, 0, signf(bq.z))
		var nw: Vector3 = (bt.basis * nl).normalized()
		out = {"dist": dist, "normal": nw, "point": p - nw * dist}
	if float(out.dist) > r + 0.3: return {}
	return out

## Swim probe for tests: the tail tip's displacement, the wing tip's lift and the front flipper's angle at time tt.
func swim_probe(tt: float) -> Dictionary:
	var ph := omega * tt
	return {"tail": Species.body_disp(prof, 1.0, ph, LENGTH),
		"wing": Species.wing_disp(prof, 1.0, 0.42, ph, float(prof.get("span", 0.0)) * 0.5 * scale_k) if String(prof.get("mode", "")) == "flap" else 0.0,
		"flipper": sin(ph) * float(prof.get("amp", 0.0)) if String(prof.get("mode", "")) == "stroke" else 0.0}
