## M32 game root: headless stress test (game root thread, 27 Nov 2026).
## Run: godot --headless --fixed-fps <30|60|120> --path . --script res://tests/test_game_root.gd -- --rate R
##        [--monkey N] [--monkey-secs S] [--fault late_write|clock|grid] [--only R1] [--crowd 200] [--out file.json]
## Builds the whole GameRoot (world root, stand-in lagoon floor, streamer, the girl's motor + body rig + mannequin,
## camera, fish schools when the M31 module is in the build) plus a crowd of test actors written through the plug
## path, and checks every tick:
##   G1 tick order   the phases ran exactly as GameRoot.TICK_ORDER
##   G2 registry     the player's committed record is where the girl is now; no actor left stale; views match
##   G3 queries      near() returns exactly the brute-force set (5 random probes a tick), the player first
##   G4 clock        t == tick * dt exactly; hours == start + t * rate (after jumps); one step per tick
##   G5 water        tide level == Tide.height(hours) (within the re-light interval), the water_y global and the
##                   girl's own water reading agree with it
##   G6 body         no NaN, girl not inside geometry, unmounted girl does not move
##   G7 schools      each school's perceived list is the registry's, the player first when in range
##   G8 streaming    the girl's cell is live once the streamer has settled
##   G9 leaks        node count flat after warm-up; registry size constant through add/remove churn
##   G10 contract    no late registry writes; unknown plug mounts refused; pause runs only clock + world, nothing moves;
##                   mean tick under 5 ms (cloud CPU, headless; the fish schools' own phase is reported, not counted:
##                   the school module owns its budget)
## Rates: the simulation tick is fixed (60 Hz), so 30/60/120 fps must end in the same place (tests/compare_rates.py m32).
## Planted faults (must FAIL): late_write (a plug moves the girl's record after the commit), clock (a plug steps the
## clock a second time), grid (an actor's position changed behind the registry's back).
## Brute-force checks (G3, G7) use their own distance code, not the registry's.
extends SceneTree

const Packet := preload("res://core/m01_input/input_packet.gd")

var rate := 60
var out_path := ""
var fault := ""
var only := ""
var monkey_runs := 0
var monkey_secs := 120.0
var crowd_n := 200
var cases := []
var ci := -1
var cur := {}
var g: GameRoot
var crowd: Node
var rng := RandomNumberGenerator.new()
var results := []
var fails := {}
var nodes_at_warm := -1
var prev_girl := Vector3.INF
var girl_was_mounted := true
var hours_anchor := {}
var school_steps := {}
var max_tick_ms := 0.0
var ticks := 0
var done := false
var sum_ms := 0.0
var fauna_ms := 0.0
var paused_ticks := 0
var wall := 0.0

class Crowd:
	## a plug that owns N test actors (fish-sized to whale-sized), moving on seeded paths of sim time
	extends Node
	var n := 200
	var fault := ""
	var seeds: Array = []
	var plug_mount := ""
	func _init(count: int, f: String) -> void:
		n = count; fault = f; name = "TestCrowd"; add_to_group("game_plug")
		var r := RandomNumberGenerator.new(); r.seed = 77
		for i in n: seeds.append([r.randf_range(-60, 60), r.randf_range(0.2, 3.8), r.randf_range(-60, 60), r.randf_range(0.05, 0.6), r.randf_range(2, 25), r.randf_range(0.1, 2.5)])
	func plug_ready(services) -> void:
		for i in n: _add(services, i)
		for i in 5:   # static actors (rocks with a presence, a moored buoy): never written, never stale
			services.actors.add("static_%d" % i, "landmark", 1.5, {"pos": Vector3(-40 + 20 * i, 1.0, 30), "moving": false})
	func _add(services, i: int) -> void:
		var sd: Array = seeds[i]
		var opts := {}
		if i % 7 == 0: opts = {"axis": Vector3(1, 0, 0), "half_len": sd[5] * 2.0}   # long bodies as capsules
		services.actors.add("crowd_%d" % i, "predator" if i % 10 == 0 else "fish", sd[5], opts)
	func plug_write_actors(services) -> void:
		var t: float = services.clock.t
		if services.clock.tick % 120 == 0:      # churn: five actors leave and come back in the same tick
			for j in 5:
				var i: int = (services.clock.tick / 120 * 5 + j) % n
				services.actors.remove("crowd_%d" % i); _add(services, i)
		for i in n:
			var sd: Array = seeds[i]
			var w: float = sd[3]; var r: float = sd[4]
			var p := Vector3(sd[0] + r * cos(w * t + i), sd[1], sd[2] + r * sin(w * t + i))
			var v := Vector3(-r * w * sin(w * t + i), 0, r * w * cos(w * t + i))
			services.actors.move("crowd_%d" % i, p, v, v.normalized() if i % 7 == 0 else Vector3.ZERO)
	func plug_tick(_dt: float, services) -> void:
		if fault == "late_write":
			var pl = services.actors.player()
			services.actors.move("girl", pl.pos + Vector3(0.3, 0, 0), pl.vel)
		elif fault == "clock" and services.clock.tick % 97 == 0:
			services.clock.step()
		elif fault == "grid" and services.clock.tick % 89 == 0:
			var a = services.actors.get_actor("crowd_3")
			a.pos += Vector3(40, 0, 40)          # behind the registry's back: the grid still holds the old cell

func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		match a[i]:
			"--rate": rate = int(a[i + 1])
			"--out": out_path = a[i + 1]
			"--fault": fault = a[i + 1]
			"--only": only = a[i + 1]
			"--monkey": monkey_runs = int(a[i + 1])
			"--monkey-secs": monkey_secs = float(a[i + 1])
			"--crowd": crowd_n = int(a[i + 1])
	Engine.physics_ticks_per_second = 60
	Engine.max_physics_steps_per_frame = 8
	_case("R1 swim a wide circle, look around (60 s)", 60.0, {"hps": 0.0},
		func(t, _r):
			var k = Packet.new(); k.move = Vector2(0.35, 0.9); k.look = Vector2(0.4, 0.15 * sin(t)); k.thrust = 1.0 if int(t / 7.0) % 2 == 0 else 0.0
			k.ascend = int(t / 11.0) % 3 == 0; k.descend = int(t / 13.0) % 3 == 1; k.descend_amount = 1.0 if k.descend else 0.0
			return k)
	_case("R2 rise to the surface and tread through a fast day (40 s, 1 game day per 120 s)", 40.0, {"hps": 24.0 / 120.0, "hour": 5.0},
		func(t, _r):
			var k = Packet.new(); k.ascend = t < 10.0; k.move = Vector2(0, 0.4) if t > 12.0 else Vector2.ZERO; k.look = Vector2(0.6, 0.0)
			return k)
	_case("R3 every mount switched off and on in turn while swimming (42 s)", 42.0, {"hps": 0.05, "mount_cycle": true},
		func(t, _r):
			var k = Packet.new(); k.move = Vector2(0.2, 1.0); k.look = Vector2(0.3, 0.0); return k)
	_case("R4 pause for 3 s mid-swim, then carry on (12 s)", 12.0, {"hps": 0.1, "pause": [4.0, 7.0]},
		func(t, _r):
			var k = Packet.new(); k.move = Vector2(0, 0.8); k.look = Vector2(0.2, 0.0); return k)
	for m in monkey_runs:
		_case("RM monkey %d (%d s, random input, mounts, clock jumps)" % [m, int(monkey_secs)], monkey_secs, {"hps": 0.02, "monkey": 1000 + m},
			func(t, r):
				var k = Packet.new()
				var s := floori(t / 1.5)   # input changes every 1.5 s of SIM time: same at every render rate
				r.seed = s * 7919 + 13
				k.move = Vector2(r.randf_range(-1, 1), r.randf_range(-1, 1)).limit_length(1.0)
				k.look = Vector2(r.randf_range(-1.5, 1.5), r.randf_range(-0.6, 0.6))
				k.thrust = 1.0 if r.randf() < 0.25 else 0.0
				k.ascend = r.randf() < 0.2; k.descend = r.randf() < 0.2; k.descend_amount = 1.0 if k.descend else 0.0
				return k)
	if only != "": cases = cases.filter(func(c): return c.name.begins_with(only))
	_next.call_deferred()     # the root must be in the tree so GameRoot._ready runs on add_child

func _case(name: String, dur: float, opts: Dictionary, input: Callable) -> void:
	cases.append({"name": name, "dur": dur, "opts": opts, "input": input})

func _next() -> void:
	if g != null:
		_finish_case()
		g.queue_free(); g = null
	ci += 1
	if ci >= cases.size():
		_report(); done = true; return
	cur = cases[ci]
	fails = {}; nodes_at_warm = -1; prev_girl = Vector3.INF; girl_was_mounted = true; school_steps = {}; max_tick_ms = 0.0; ticks = 0
	sum_ms = 0.0; fauna_ms = 0.0; paused_ticks = 0; wall = 0.0
	g = GameRoot.new()
	g.start_hour = float(cur.opts.get("hour", 12.0))
	g.hours_per_second = float(cur.opts.get("hps", 0.0))
	g.use_sea = false
	g.spawn_feet = Vector3(0, 1.6, 18)
	g.schools = [{"species": "trevally", "home": Vector3(4, 2.0, 8), "seed": 3}, {"species": "trevally", "home": Vector3(-30, 2.0, -20), "seed": 4}]
	var mr := RandomNumberGenerator.new()
	var inp: Callable = cur.input
	g.input_source = func(t): return inp.call(t, mr)
	root.add_child(g)
	crowd = Crowd.new(crowd_n, fault); g.add_child(crowd)
	if not g.register_plug(crowd): _fail("G10", "crowd plug refused")
	var probe := Crowd.new(0, ""); probe.name = "MountProbe"; g.add_child(probe)
	print("(the next ERROR line is expected: an unknown mount must be refused)")
	if g.register_plug(probe, "no_such_mount"): _fail("G10", "unknown mount accepted")
	probe.queue_free()
	hours_anchor = {"t": 0.0, "h": g.clock.hours}
	g.ticked.connect(_check)

func _fail(code: String, msg: String) -> void:
	if not fails.has(code): fails[code] = {"n": 0, "first": "t=%.2f %s" % [g.clock.t, msg]}
	fails[code].n += 1

func _check(tick: int) -> void:
	ticks += 1
	var t := g.clock.t
	var paused := g.clock.paused
	if paused: paused_ticks += 1
	if ticks > 30 and not paused:
		var own: float = g.stats.tick_ms - float(g.stats.phase_ms.get("fauna", 0.0))   # the root's own cost; schools own theirs
		max_tick_ms = maxf(max_tick_ms, own); sum_ms += own; fauna_ms += float(g.stats.phase_ms.get("fauna", 0.0))
	# G1
	var want_trace: Array = ["clock", "world"] if paused else GameRoot.TICK_ORDER
	if g.trace != want_trace: _fail("G1", "phases %s" % [g.trace])
	# G2
	var pl = g.actors.player()
	if pl == null or pl.id != "girl": _fail("G2", "no player first")
	elif pl.pos.distance_to(g.girl.centre()) > 1e-4: _fail("G2", "girl record %s vs girl %s" % [pl.pos, g.girl.centre()])
	elif pl.view.pos != pl.pos: _fail("G2", "view out of date")
	if not paused and not g.actors.stale.is_empty(): _fail("G2", "stale %s" % [g.actors.stale.slice(0, 3)])
	if g.actors.late_writes > 0: _fail("G10", "%d registry writes after the commit" % g.actors.late_writes); g.actors.late_writes = 0
	# G3: brute force with the test's own surface distance
	for q in 5:
		rng.seed = tick * 31 + q
		var c := Vector3(rng.randf_range(-70, 70), rng.randf_range(0, 4), rng.randf_range(-70, 70))
		if q == 0: c = g.girl.centre() + Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3))
		var r := rng.randf_range(2, 30)
		var got := {}
		var lst: Array = g.actors.near(c, r)
		for a in lst: got[a.id] = true
		var want := _brute(c, r, [])
		if got.size() != want.size() or not got.keys().all(func(k): return want.has(k)):
			_fail("G3", "near(%s, %.1f) %d vs brute %d" % [c, r, got.size(), want.size()]); break
		if want.has("girl") and lst[0].id != "girl": _fail("G3", "player not first")
	# G4
	if absf(t - g.clock.tick * g.clock.dt) > 1e-9 or g.clock.tick != ticks - paused_ticks: _fail("G4", "t %.6f tick %d ticks %d" % [t, g.clock.tick, ticks - paused_ticks])
	var want_h: float = hours_anchor.h + (t - hours_anchor.t) * g.clock.hours_per_second
	if absf(g.clock.hours - want_h) > 1e-6: _fail("G4", "hours %.5f want %.5f" % [g.clock.hours, want_h])
	# G5
	var tide_want := LagoonWaterField.SURFACE_Y + Tide.height(g.clock.hours, Tide.GAIN.calm_lagoon)
	var lvl: float = g.world_root.water.level
	if absf(lvl - tide_want) > 1e-6: _fail("G5", "level %.4f tide %.4f" % [lvl, tide_want])
	var gy = RenderingServer.global_shader_parameter_get("water_y")
	if gy != null and absf(float(gy) - lvl) > 1e-5: _fail("G5", "water_y global %s vs level %.4f" % [gy, lvl])
	var ls: Dictionary = g.girl.body.last_sense
	if g.mounts.is_mounted("girl") and not paused and not ls.is_empty() and absf(float(ls.water_y) - lvl) > (0.15 if g.world_root.water.waves else 1e-5): _fail("G5", "girl reads %.4f vs %.4f" % [ls.water_y, lvl])
	# G6
	var gp: Vector3 = g.girl.body.global_position
	if not (is_finite(gp.x) and is_finite(gp.y) and is_finite(gp.z)): _fail("G6", "girl NaN")
	elif g.girl.body.penetrating(0.03): _fail("G6", "girl inside geometry at %s" % gp)
	var frozen := paused or (not g.mounts.is_mounted("girl") and not girl_was_mounted)
	if frozen and prev_girl != Vector3.INF and gp.distance_to(prev_girl) > 1e-6: _fail("G6", "girl moved while paused/unmounted")
	girl_was_mounted = g.mounts.is_mounted("girl"); prev_girl = gp
	# G7: each school holds exactly the player/predators near its home (brute force), as this tick's committed records
	if not paused and g.mounts.is_mounted("fauna"):
		for s in g.school_nodes:
			var want := _brute(s.home, g.school_sense_radius, ["player", "predator"])
			var ids := {}
			for v in s.actors:
				ids[v.id] = true
				var a = g.actors.get_actor(v.id)
				if a == null or v.pos != a.pos: _fail("G7", "school holds a stale record of %s" % v.id); break
			if ids.size() != want.size() or not ids.keys().all(func(k): return want.has(k)): _fail("G7", "school sees %d, brute %d" % [ids.size(), want.size()])
			elif want.has("girl") and s.actors[0].id != "girl": _fail("G7", "player not first for the school")
	# G8
	if t > 3.0 and g.mounts.is_mounted("streaming"):
		var k := CellStreamer.key(floori(gp.x / g.streamer.streamer.cell_size), floori(gp.z / g.streamer.streamer.cell_size))
		if not g.streamer.streamer.live.has(k): _fail("G8", "girl cell %s not live" % k)
	# G9
	if t >= 5.0 and nodes_at_warm < 0: nodes_at_warm = _count(g)
	if g.actors.order.size() != crowd_n + 6: _fail("G9", "registry size %d" % g.actors.order.size())
	# pause window
	if cur.opts.has("pause"):
		var pw: Array = cur.opts.pause
		var wt: float = t + paused_ticks / 60.0      # wall time of the case (sim time stops while paused)
		g.clock.paused = wt >= pw[0] and wt < pw[1]
		if wt >= cur.dur: _end_case(); return
	# mounts and clock jumps
	if cur.opts.get("mount_cycle", false):
		var keys: Array = FeatureMounts.DEFAULT_MOUNTS.keys()
		var slot := floori(t / 3.0)
		for i in keys.size(): g.mounts.set_mount(keys[i], not (slot % keys.size() == i and slot % 2 == 1))
	if cur.opts.has("monkey"):
		rng.seed = floori(t / 4.0) * 104729 + int(cur.opts.monkey)
		var keys: Array = FeatureMounts.DEFAULT_MOUNTS.keys()
		if tick % 240 == 0:
			for k2 in keys: g.mounts.set_mount(k2, rng.randf() > 0.15)
		if tick % 1800 == 0 and tick > 0:
			g.clock.set_hours(rng.randf_range(0.0, 48.0)); hours_anchor = {"t": t, "h": g.clock.hours}
	if t >= cur.dur and not cur.opts.has("pause"): _end_case()

func _end_case() -> void:
	g.ticked.disconnect(_check)
	_next.call_deferred()

## which actors' surfaces lie within r of c (the test's own sphere/capsule distance, not the registry's)
func _brute(c: Vector3, r: float, kinds: Array) -> Dictionary:
	var out := {}
	for a in g.actors.order:
		if not kinds.is_empty() and not kinds.has(a.kind): continue
		var q: Vector3 = a.pos
		if a.half_len > 0.0 and a.axis != Vector3.ZERO:
			var u: float = clampf((c - a.pos).dot(a.axis), -a.half_len, a.half_len)
			q = a.pos + a.axis * u
		if c.distance_to(q) - a.radius <= r: out[a.id] = true
	return out

func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children(): c += _count(ch)
	return c

func _finish_case() -> void:
	var leak := _count(g) - nodes_at_warm
	if nodes_at_warm > 0 and absi(leak) > 2: _fail("G9", "node count grew by %d" % leak)
	var counted := ticks - 30 - paused_ticks
	var mean := sum_ms / maxf(counted, 1)
	if mean > 5.0: _fail("G10", "mean tick %.2f ms over 5 ms" % mean)
	var ok := fails.is_empty()
	var end: Vector3 = g.girl.body.global_position
	results.append({"name": cur.name, "ok": ok, "end": [end.x, end.y, end.z], "ticks": ticks, "fails": fails,
		"max_tick_ms": snappedf(max_tick_ms, 0.01), "mean_tick_ms": snappedf(mean, 0.001), "mean_fauna_ms": snappedf(fauna_ms / maxf(counted, 1), 0.001), "schools": g.school_nodes.size()})
	print("%s %s  end %s  tick mean %.2f / max %.2f ms (+ schools %d: %.2f ms)" % ["PASS" if ok else "FAIL", cur.name, end, mean, max_tick_ms, g.school_nodes.size(), fauna_ms / maxf(counted, 1)])
	for k in fails: print("   %s x%d  first: %s" % [k, fails[k].n, fails[k].first])

func _report() -> void:
	var all_ok := results.all(func(r): return r.ok)
	print("M32 game root @ %d fps: %d/%d cases pass%s" % [rate, results.filter(func(r): return r.ok).size(), results.size(), "" if fault == "" else " (planted fault " + fault + ")"])
	if out_path != "":
		var f := FileAccess.open(out_path, FileAccess.WRITE); f.store_string(JSON.stringify({"rate": rate, "fault": fault, "results": results})); f.close()
	quit(0 if all_ok else 1)

func _process(_d: float) -> bool:
	return false
