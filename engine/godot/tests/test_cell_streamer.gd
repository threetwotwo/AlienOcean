## Headless test for M12 core. Run: godot --headless --path . --script res://tests/test_cell_streamer.gd
## Paths: a swim (2 m/s, wandering) and a fast-sub run (25 m/s) across a 4 x 4 km world, 30 updates/s.
## Pass: the viewer's own cell and every cell within 32 m are live before she gets there (no pop inside fog);
## live and far counts stay flat (bounded); after the game-start fill, no single update asks for more than 12 new live cells.
## Planted fault: lookahead 0 and live radius 20 m must FAIL the fast-sub run (proves the test can fail).
extends SceneTree

func run(name: String, speed: float, wander: float, s: CellStreamer) -> Dictionary:
	var x := 0.0; var z := 0.0; var heading := 0.6
	var dt := 1.0 / 30.0
	var t := 0.0
	var res := {"name": name, "misses": 0, "max_live": 0, "max_far": 0, "max_burst": 0, "updates": 0}
	var rng := RandomNumberGenerator.new(); rng.seed = 11
	while x < 4000.0 and z < 4000.0 and t < 4000.0:
		heading += rng.randf_range(-wander, wander) * dt
		heading = clampf(heading, 0.2, 1.4)
		var vx := cos(heading) * speed; var vz := sin(heading) * speed
		var plan := s.update([{"x": x, "z": z, "vx": vx, "vz": vz}])
		if res.updates > 0:   # the first update is the game-start fill, which may show a start screen
			res.max_burst = maxi(res.max_burst, plan.load_live.size())
		x += vx * dt; z += vz * dt; t += dt
		res.updates += 1
		# every cell within 32 m of the new position must already be live
		for c in s._cells_in(x, z, 32.0):
			if not s.live.has(CellStreamer.key(c[0], c[1])):
				res.misses += 1
		res.max_live = maxi(res.max_live, s.live.size())
		res.max_far = maxi(res.max_far, s.far.size())
	return res

func verdict(r: Dictionary) -> bool:
	return r.misses == 0 and r.max_live <= 40 and r.max_far <= 120 and r.max_burst <= 12

func _init():
	var ok := true
	for spec in [["swim 2 m/s", 2.0, 1.5], ["fast sub 25 m/s", 25.0, 0.4]]:
		var r := run(spec[0], spec[1], spec[2], CellStreamer.new())
		var p := verdict(r)
		ok = ok and p
		print("%s  %s  misses=%d max_live=%d max_far=%d max_burst=%d updates=%d" % ["PASS" if p else "FAIL", r.name, r.misses, r.max_live, r.max_far, r.max_burst, r.updates])
	var bad := CellStreamer.new(); bad.lookahead_s = 0.0; bad.live_radius = 20.0
	var rb := run("planted fault (no lookahead, 20 m ring)", 25.0, 0.4, bad)
	var caught := not verdict(rb)
	print("%s  planted fault %s (misses=%d)" % ["PASS" if caught else "FAIL", "caught" if caught else "NOT caught", rb.misses])
	ok = ok and caught
	print("RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
