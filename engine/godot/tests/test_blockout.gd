## Blockout kit test 0.1.0 (blockout/): every kit kind built and MEASURED by physics rays (not trusted from the code),
## the rider's loop, the senses points, grey mode keeping collision identical, and motion cases run inside the blockout
## gym (the blockout stress scene) through the real motor, so the same cases can be compared at 30/60/120 Hz.
## Run: godot --headless --fixed-fps 60 --path . --script res://tests/test_blockout.gd -- [--tick 60] [--rate 60]
##        [--fault seat|grey] [--out /tmp/blk_60.json]
## exit 0 = all pass. --fault seat builds every seat 5 cm low, --fault grey makes grey mode drop collision: both must FAIL.
## Pass checks (written first): kit heights / widths / angles within 5 mm / 1 cm / 0.5 deg of the asked value; every kind
## has a "start" marker with an orthonormal frame; rider ground speed 2.5 m/s +-1 %, velocity = d(position)/dt within
## 5 cm/s, climbs and dives 2.5 m, banks 18-20 deg, saddle up never under 0.75 of world up; senses: 4 points, one behind,
## the circler moves at 1 m/s, the sound pulses; grey mode: collision snapshot identical, all level meshes grey, keep
## group untouched, originals restored on toggle-off; gym motion cases pass as the motor tests do.
extends SceneTree

const Kit := preload("res://blockout/blockout_kit.gd")
const Gym := preload("res://blockout/blockout_gym.gd")
const Grey := preload("res://blockout/grey_mode.gd")
const Packet := preload("res://core/m01_input/input_packet.gd")
const Body := preload("res://adapters/godot/player_body.gd")
const Motor := preload("res://core/m02_motor/player_motor.gd")

var tick := 60
var rate := 60
var fault := ""
var out_path := ""
var results: Array = []

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		match a[i]:
			"--tick": tick = int(a[i + 1])
			"--rate": rate = int(a[i + 1])
			"--fault": fault = a[i + 1]
			"--out": out_path = a[i + 1]
	Engine.physics_ticks_per_second = tick
	Engine.max_physics_steps_per_frame = 8
	if fault == "seat": Kit.fault_seat_drop = 0.05
	if fault == "grey": Grey.fault_drop_collision = true
	print("BLOCKOUT test: tick=%d rate=%d fault=%s" % [tick, rate, fault])
	_run.call_deferred()

func _res(name: String, ok: bool, msg: String, end := Vector3.ZERO) -> void:
	results.append({"name": name, "ok": ok, "msg": msg, "end": [end.x, end.y, end.z]})
	print("%s  %s  (%s)" % ["PASS" if ok else "FAIL", name, msg])

func _frames(n: int) -> void:
	for i in n: await physics_frame

# ---------------------------------------------------------------- rays
func _space() -> PhysicsDirectSpaceState3D:
	return root.get_world_3d().direct_space_state

func _ray(from: Vector3, to: Vector3, mask := 1) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, mask)
	q.hit_from_inside = false
	return _space().intersect_ray(q)

func _down(p: Vector3, up := 3.0) -> float:   # height of the first surface under p + up
	var h := _ray(p + Vector3(0, up, 0), p - Vector3(0, 30, 0))
	return h.position.y if not h.is_empty() else -INF

func _up(p: Vector3) -> float:
	var h := _ray(p, p + Vector3(0, 30, 0))
	return h.position.y if not h.is_empty() else INF

func _near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol

# ---------------------------------------------------------------- run
func _run() -> void:
	await _kit_cases()
	await _rider_case()
	await _senses_case()
	await _grey_case()
	await _gym_motion()
	await _game_mode()
	_finish()

func _world() -> Node3D:
	var w := Node3D.new(); root.add_child(w)
	return w

func _drop(w: Node3D) -> void:
	root.remove_child(w); w.free()

func _kit_cases() -> void:
	# every kind builds, has collision and a start marker with an orthonormal frame
	for k in Kit.KINDS:
		var w := _world()
		var r := Kit.build(w, k, {"angle": 30.0, "h": 0.3, "s": 1.0})
		var n_shapes := w.find_children("*", "CollisionShape3D", true, false).size()
		var ok: bool = n_shapes > 0 and r.markers.has("start")
		var worst := 0.0
		for m in r.markers:
			var b: Basis = r.markers[m].basis
			var bb := b * b.transposed()
			worst = maxf(worst, (bb.x - Vector3.RIGHT).length() + (bb.y - Vector3.UP).length() + (bb.z - Vector3.BACK).length())
		ok = ok and worst < 1e-4
		_res("K0 %s builds" % k, ok, "%d shapes, %d markers, frame err %.6f" % [n_shapes, r.markers.size(), worst])
		_drop(w)
	# measured: each case builds its world, waits for physics, measures with rays
	var cases := [
		["K1 stool seat 0.45", "stool", {}, func(r): var y := _down(r.markers.seat.origin); return [_near(y, 0.45, 0.005), "seat %.3f" % y]],
		["K1 bench seats 0.45", "bench", {}, func(r):
			var ys := [_down(r.markers.seat_l.origin), _down(r.markers.seat_c.origin), _down(r.markers.seat_r.origin)]
			var back := _ray(r.markers.seat_c.origin + Vector3(0, 0.25, 0.1), r.markers.seat_c.origin + Vector3(0, 0.25, -1))
			return [ys.all(func(y): return _near(y, 0.45, 0.005)) and not back.is_empty(), "seats %s back %s" % [ys, not back.is_empty()]]],
		["K1 bunk top 0.5, clear 0.9, pillow end", "bunk", {}, func(r):
			var top := _down(r.markers.lie.origin, 0.05); var ceil := _up(r.markers.lie.origin + Vector3(0, 0.05, 0))
			var head: Vector3 = -r.markers.lie.basis.z
			var pil := _down(r.markers.lie.origin + head * 0.8, 0.3)
			return [_near(top, 0.5, 0.005) and _near(ceil - top, 0.9, 0.005) and pil > top + 0.08, "top %.3f clear %.3f pillow %.3f" % [top, ceil - top, pil]]],
		["K2 overhang 1.75", "overhang", {"h": 1.75}, func(r): var y := _up(Vector3(0, 0.1, 0)); return [_near(y, 1.75, 0.005), "ceiling %.3f" % y]],
		["K2 mantle lip 1.0", "mantle", {"h": 1.0}, func(r): var y := _down(r.markers.grab.origin + Vector3(0, 0, -0.2)); return [_near(y, 1.0, 0.005), "lip %.3f" % y]],
		["K2 wall corner at x 1.0, z -6", "wall_corner", {}, func(r):
			var hx := _ray(Vector3(0, 1, 0), Vector3(5, 1, 0)); var hz := _ray(Vector3(0, 1, 0), Vector3(0, 1, -10))
			return [not hx.is_empty() and not hz.is_empty() and _near(hx.position.x, 1.0, 0.005) and _near(hz.position.z, -6.0, 0.005), "x %.3f z %.3f" % [hx.get("position", Vector3.INF).x, hz.get("position", Vector3.INF).z]]],
		["K2 ceiling slab underside -5", "ceiling", {}, func(r): var y := _up(Vector3(0, -8, 0)); return [_near(y, -5.0, 0.005), "underside %.3f" % y]],
		["K3 lagoon pool floor -2.4", "lagoon_pool", {}, func(r): var y := _down(Vector3(0, -1, 0), 0.5); return [_near(y, -2.4, 0.005), "floor %.3f" % y]],
		["K3 pool floor -20", "pool", {}, func(r): var y := _down(Vector3(0, -1, 0), 0.5); return [_near(y, -20.0, 0.005), "floor %.3f" % y]],
		["K4 stairs 8 x 17 cm on 28 cm", "stairs", {}, func(r):
			var bad := 0
			for i in 8:
				if not _near(_down(Vector3(0, 0, -0.28 * (i + 0.5))), 0.17 * (i + 1), 0.005): bad += 1
			return [bad == 0, "%d of 8 treads off" % bad]],
		["K4 ledge 0.5 then floor", "ledge", {"h": 0.5}, func(r):
			var a := _down(Vector3(0, 0, 0)); var b := _down(Vector3(0, 0, -3))
			return [_near(a, 0.5, 0.005) and _near(b, 0.0, 0.005), "top %.3f floor %.3f" % [a, b]]],
		["K4 drop 1.0 then floor", "drop", {"h": 1.0}, func(r):
			var a := _down(Vector3(0, 0, 0)); var b := _down(Vector3(0, 0, -3))
			return [_near(a, 1.0, 0.005) and _near(b, 0.0, 0.005), "top %.3f floor %.3f" % [a, b]]],
		["K5 ramp side 30 deg", "ramp_side", {"angle": 30.0}, func(r):
			var a := _down(Vector3(-1, 0, -7)); var b := _down(Vector3(1, 0, -7)); var c := _down(Vector3(0, 0, -7))
			var ang := rad_to_deg(atan2(a - b, 2.0))
			return [_near(ang, 30.0, 0.5) and _near(c, 0.0, 0.005), "%.2f deg, centre line %.3f" % [ang, c]]],
		["K6 rough bumps 5-15 cm", "rough", {}, func(r):
			var mx := 0.0; var bumpy := 0; var n := 0
			for i in 60:
				for j in 60:
					var y := _down(Vector3(-7.5 + i * 0.25, 0, 1.5 - j * 0.25), 1.0)
					mx = maxf(mx, y); n += 1
					if y > 0.02: bumpy += 1
			return [mx <= 0.152 and mx >= 0.12 and float(bumpy) / n > 0.3, "max %.3f, %d%% bumpy" % [mx, int(100.0 * bumpy / n)]]],
	]
	for st in [0.05, 0.10, 0.20, 0.30, 0.50]:
		var hh: float = st
		cases.append(["K4 step %d cm" % int(hh * 100), "step", {"h": hh}, func(r): var y := _down(Vector3(0, 0, -4)); return [_near(y, hh, 0.005), "top %.3f" % y]])
	for ang in [15.0, 30.0, 60.0]:
		var aa: float = ang
		cases.append(["K5 ramp %d deg" % int(aa), "ramp", {"angle": aa}, func(r):
			var z1 := -1.0; var z2 := -2.0
			var y1 := _down(Vector3(0, 0, z1), 6.0); var y2 := _down(Vector3(0, 0, z2), 6.0)
			var got := rad_to_deg(atan2(y2 - y1, absf(z2 - z1)))
			return [_near(got, aa, 0.5), "%.2f deg" % got]])
	for gw in [0.4, 0.8, 1.2]:
		var ww: float = gw
		cases.append(["K7 gap %.1f m" % ww, "gap", {"w": ww}, func(r):
			var z := -2.0 + 0.0025; var first := INF; var last := -INF
			while z > -5.0:
				if _down(Vector3(0, 0, z), 1.0) < -0.5:
					first = minf(first, -z); last = maxf(last, -z)
				z -= 0.005
			var width := last - first + 0.005
			return [_near(width, ww, 0.01), "gap %.3f" % width]])
	for bw in [0.1, 0.2]:
		var bb: float = bw
		cases.append(["K7 beam %d cm" % int(bb * 100), "beam", {"w": bb}, func(r):
			var on := 0
			for i in 200:
				if _down(Vector3(-0.5 + i * 0.005 + 0.0025, 0, -4), 1.0) > -0.05: on += 1
			return [_near(on * 0.005, bb, 0.01), "beam %.3f" % (on * 0.005)]])
	for ts in [0.8, 1.0]:
		var ss: float = ts
		cases.append(["K7 tube %.1f m" % ss, "tube", {"s": ss}, func(r):
			var l := _ray(Vector3(0, -10, -10), Vector3(-5, -10, -10)); var rr := _ray(Vector3(0, -10, -10), Vector3(5, -10, -10))
			var u := _ray(Vector3(0, -10, -10), Vector3(0, -5, -10)); var d := _ray(Vector3(0, -10, -10), Vector3(0, -15, -10))
			var wx: float = rr.position.x - l.position.x; var wy: float = u.position.y - d.position.y
			return [_near(wx, ss, 0.005) and _near(wy, ss, 0.005), "%.3f x %.3f" % [wx, wy]]])
	for c in cases:
		var w := _world()
		var r := Kit.build(w, c[1], c[2])
		await _frames(2)
		var o: Array = c[3].call(r)
		_res(c[0], o[0], o[1])
		_drop(w)

func _rider_case() -> void:
	var w := _world()
	var r := Kit.build(w, "ride", {})
	var rd = r.rider
	var per: float = rd.perimeter() / rd.speed
	var dt := 1.0 / tick
	var prev: Vector3 = rd.global_position
	var worst_v := 0.0; var worst_hs := 0.0; var min_up := 1.0; var max_bank := 0.0
	var ymin := INF; var ymax := -INF
	var samples: Array = []
	await physics_frame
	prev = rd.global_position
	var steps := int(round(per * 2.0 * tick))
	for i in steps:
		await physics_frame
		var p: Vector3 = rd.global_position
		var fd := (p - prev) / dt
		var v: Vector3 = rd.velocity
		# compare the finite difference with the mean of this and the last velocity (central): exact on straights
		worst_v = maxf(worst_v, (fd - v).length() if i > 0 else 0.0)
		worst_hs = maxf(worst_hs, absf(Vector2(v.x, v.z).length() - rd.speed))
		var sad: Transform3D = rd.marker("saddle")
		min_up = minf(min_up, sad.basis.y.dot(Vector3.UP))
		var fwd: Vector3 = -sad.basis.z
		var flat_right := fwd.cross(Vector3.UP).normalized()
		max_bank = maxf(max_bank, rad_to_deg(asin(clampf(-sad.basis.y.dot(flat_right), -1, 1))))
		ymin = minf(ymin, p.y - rd.origin.y); ymax = maxf(ymax, p.y - rd.origin.y)
		var tt: float = rd.t
		if absf(tt * 2.0 - round(tt * 2.0)) < 1e-4: samples.append([tt, sad.origin])
		prev = p
	var end: Vector3 = rd.marker("saddle").origin
	# finite differences on the curve lag the tangent by half a tick: allow speed x curvature x dt / 2 plus the climb
	var fd_tol: float = 0.05 + rd.speed * rd.speed / rd.R * dt
	_res("R1 rider ground speed 2.5 m/s", worst_hs < 0.025, "worst off %.4f m/s" % worst_hs, end)
	_res("R2 rider velocity = d(position)/dt", worst_v < fd_tol, "worst %.3f m/s (limit %.3f)" % [worst_v, fd_tol], end)
	_res("R3 rider climbs and dives 2.5 m", ymax > 2.45 and ymin < -2.45, "y %+.2f .. %+.2f" % [ymin, ymax], end)
	_res("R4 rider banks 18-20 deg, saddle stays up", max_bank > 18.0 and max_bank < 20.5 and min_up > 0.75, "bank %.1f deg, min up %.2f" % [max_bank, min_up], end)
	var mk_ok := true
	for m in rd.MARKERS: mk_ok = mk_ok and rd.marker(m).origin.is_finite()
	_res("R5 rider has saddle, hands, feet", mk_ok and rd.MARKERS.size() == 5, "%s" % [rd.MARKERS.keys()], end)
	results[-1]["samples"] = samples.map(func(s): return [s[0], s[1].x, s[1].y, s[1].z])
	_drop(w)

func _senses_case() -> void:
	var w := _world()
	Kit.build(w, "senses", {})
	await _frames(2)
	var a := Kit.pois(w)
	var kinds := a.map(func(d): return d.kind)
	var behind := a.filter(func(d): return d.pos.z > 1.0).size()
	var c0: Vector3 = a.filter(func(d): return d.name == "circler")[0].pos
	var snd0: bool = a.filter(func(d): return d.kind == "sound")[0].alive
	await _frames(tick)            # 1 s later
	var b := Kit.pois(w)
	var circ: Dictionary = b.filter(func(d): return d.name == "circler")[0]
	var snd1: bool = b.filter(func(d): return d.kind == "sound")[0].alive
	var moved: float = (circ.pos - c0).length()
	_res("S1 senses: 4 points, one behind, circler moves 1 m/s, sound pulses",
		a.size() == 4 and kinds.has("creature") and kinds.has("sound") and behind == 1 and moved > 0.9 and moved < 1.0 + 1e-3
		and _near(circ.velocity.length(), 1.0, 1e-3) and snd0 and not snd1,
		"%d points %s, behind %d, moved %.3f m, sound %s->%s" % [a.size(), kinds, behind, moved, snd0, snd1])
	_drop(w)

# ---------------------------------------------------------------- grey mode
func _snapshot(n: Node) -> Array:
	var out: Array = []
	for cs in n.find_children("*", "CollisionShape3D", true, false):
		var s: Shape3D = cs.shape
		var sig := ""
		if s is BoxShape3D: sig = "box %s" % s.size
		elif s is CapsuleShape3D: sig = "cap %s %s" % [s.radius, s.height]
		elif s is ConcavePolygonShape3D: sig = "tri %d" % s.get_faces().size()
		out.append("%s|%s|%s|%s|%s" % [n.get_path_to(cs), cs.global_transform, cs.disabled, sig, cs.get_parent().collision_layer])
	return out

func _grey_case() -> void:
	var w := _world()
	var gym := Gym.build(w, 0.0)
	for st in gym.stations:
		if st.result.rider != null: st.result.rider.paused = true   # a still rider, so its capsule compares too
	# a dressed piece of 'level' with its own look, particles, and one node grey mode must leave alone
	var dressed := MeshInstance3D.new(); dressed.mesh = SphereMesh.new()
	var own := StandardMaterial3D.new(); own.albedo_color = Color(0.8, 0.5, 0.2); dressed.material_override = own
	w.add_child(dressed)
	var fx := GPUParticles3D.new(); w.add_child(fx)
	var keep := MeshInstance3D.new(); keep.mesh = BoxMesh.new(); keep.add_to_group(Grey.KEEP_GROUP)
	var keep_mat := StandardMaterial3D.new(); keep.material_override = keep_mat; w.add_child(keep)
	await _frames(2)
	var before := _snapshot(w)
	var rep := Grey.apply([w], true)
	await _frames(2)
	var during := _snapshot(w)
	var all_grey := true
	for g in w.find_children("*", "GeometryInstance3D", true, false):
		if g is GPUParticles3D or g == keep or g is Label3D: continue
		if g.material_override != Kit.grey_material(): all_grey = false
	var ok_on: bool = before == during and all_grey and not fx.visible and keep.material_override == keep_mat
	_res("G1 grey mode on: same collision, level grey, fx hidden, keep untouched", ok_on,
		"%d shapes same=%s, grey=%s, %s" % [before.size(), before == during, all_grey, rep])
	Grey.apply([w], false)
	await _frames(1)
	var after := _snapshot(w)
	_res("G2 grey mode off: originals back", after == before and dressed.material_override == own and fx.visible,
		"same=%s own material back=%s fx visible=%s" % [after == before, dressed.material_override == own, fx.visible])
	_res("G3 gym has every station", gym.stations.size() == Gym.DRY.size() + Gym.WET.size(), "%d stations" % gym.stations.size())
	_drop(w)

# ---------------------------------------------------------------- motion in the gym (blockout stress scene)
func _pk(move := Vector2.ZERO, yaw := 0.0, pitch := 0.0) -> Object:
	var k = Packet.new(); k.move = move; k.cam_yaw = yaw; k.cam_pitch = pitch
	return k

func _gym_motion() -> void:
	var w := _world()
	var gym := Gym.build(w, 0.0)
	var by := {}
	for st in gym.stations: by[st.label] = st
	await _frames(2)
	var fwd := func(_t): return _pk(Vector2(0, 1))
	var mcases := [
		["M1 gym step 10 cm climbs", "step 10 cm", 6.0, fwd, func(o, e): return [e.z < -4.0 and _near(e.y, 0.10, 0.08), "end z %.2f y %.2f" % [e.z, e.y]]],
		["M1 gym step 50 cm refuses", "step 50 cm", 6.0, fwd, func(o, e): return [e.z > -3.2, "end z %.2f" % e.z]],
		["M1 gym stairs climbs", "stairs 17/28", 10.0, fwd, func(o, e): return [e.y > 1.2, "end y %.2f" % e.y]],
		["M1 gym ramp 30 climbs", "ramp 30", 14.0, fwd, func(o, e): return [e.y > 2.7, "end y %.2f" % e.y]],
		["M1 gym ramp 60 refuses", "ramp 60", 8.0, fwd, func(o, e): return [e.y < 1.0, "end y %.2f" % e.y]],
		["M1 gym low ceiling walks under", "low ceiling 1.75", 10.0, fwd, func(o, e): return [e.z < -4.0, "end z %.2f" % e.z]],
		["M2 gym tube 1.0 passes", "tube 1.0", 14.0, fwd, func(o, e): return [e.z < -26.0, "end z %.2f" % e.z]],
		["M2 gym tube 0.8 refuses", "tube 0.8", 10.0, fwd, func(o, e): return [e.z > -6.5, "end z %.2f" % e.z]],
		["M2 gym lagoon pool swims over the sand", "lagoon pool 2.4 m", 7.0, func(_t): return _pk(Vector2(0, 1), 0.0, -0.4),
			func(o, e): return [o.min_y > -2.4 - 0.05 and e.z < -10.0, "min y %.2f, end z %.2f" % [o.min_y, e.z]]],
	]
	var dt := 1.0 / tick
	for c in mcases:
		var st: Dictionary = by[c[1]]
		var start: Vector3 = st.start.origin
		if c[1].begins_with("tube"): start += Vector3(0, -0.42, 0)
		var body = Body.new()
		w.add_child(body)
		body.global_position = start + Vector3(0, 0.05 if not st.water else 0.0, 0)
		if st.water: body.motor.mode = Motor.Mode.SWIM
		var env = gym.env
		await _frames(2)
		var t := 0.0
		var o := {"min_y": INF}
		while t < c[2] - 1e-6:
			await physics_frame
			body.tick(dt, c[3].call(t), env, t)
			t += dt
			var lp: Vector3 = st.node.to_local(body.global_position)
			o.min_y = minf(o.min_y, lp.y)
			if not body.global_position.is_finite(): break
		var e: Vector3 = st.node.to_local(body.global_position)      # station (kit) coordinates, as the motor tests use
		var res: Array = c[4].call(o, e)
		_res(c[0], res[0], res[1], body.global_position)
		w.remove_child(body); body.free()
	_drop(w)

# ---------------------------------------------------------------- the game in blockout mode (AO_BLOCKOUT=1)
func _game_mode() -> void:
	var GR: Script = load("res://adapters/godot/game_root.gd")
	var g = GR.new()
	g.blockout = true; g.blockout_station = "stool 45"; g.use_camera = false; g.use_sea = false; g.with_mannequin = false
	g.input_source = func(_t): return _pk()
	root.add_child(g)
	await _frames(int(tick * 1.5))
	var st: Dictionary = g.blockout_gym.stations.filter(func(x): return x.label == "stool 45")[0]
	var d0: float = (g.girl.body.global_position - st.start.origin).length()
	var play = g.get_node("BlockoutPlay")
	play.go(play.stations.find(g.blockout_gym.stations.filter(func(x): return x.label == "pool 20 m")[0]))
	await _frames(tick)
	var pst: Dictionary = play.stations[play.i]
	var d1: float = (g.girl.body.global_position - pst.start.origin).length()
	g.grey_toggle.set_grey(true)
	var greyed: bool = Grey.is_on([g.lagoon])
	g.grey_toggle.set_grey(false)
	_res("P1 game in blockout mode: spawns on the stool station, F6 moves her to the pool, F7 grey on/off",
		d0 < 0.5 and d1 < 1.5 and g.girl.mode_name() != "" and greyed and not Grey.is_on([g.lagoon]),
		"stool start off %.2f m, pool start off %.2f m (%s), grey %s" % [d0, d1, g.girl.mode_name(), greyed], g.girl.body.global_position)
	root.remove_child(g); g.queue_free()
	await _frames(1)

func _finish() -> void:
	var npass := results.filter(func(r): return r.ok).size()
	print("BLOCKOUT tick %d rate %d: %d/%d PASS%s" % [tick, rate, npass, results.size(), "  (planted fault %s)" % fault if fault != "" else ""])
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		f.store_string(JSON.stringify({"rate": rate, "tick": tick, "fault": fault, "results": results}, "  "))
	quit(0 if npass == results.size() else 1)
