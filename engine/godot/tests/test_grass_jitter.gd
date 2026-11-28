## Grass no-jitter check (test level thread, 28 Nov 2026; Gary: "make sure no-jitter, good rule to apply everywhere").
## A stand-in girl swims a smooth arc through GrassField's pushers. Her body moves once per 60 Hz game tick, as in the game;
## frames are drawn at 30, 60, 120 and 144 Hz with +-10% frame-time noise. GrassField.jitter replays the push at world-fixed
## probes and measures the bend's acceleration per frame. The same swim with a perfectly continuous girl (no ticks) is the
## reference: smooth motion has real acceleration, jitter is acceleration beyond it. Each rate must stay within RATIO of
## the reference (p99 and max). Planted fault --fault stepped turns GrassField's tick interpolation off; it must be caught.
## Run: godot --headless --path . --script res://tests/test_grass_jitter.gd [-- stepped]
extends SceneTree

const RATIO := 1.35

func _initialize() -> void:
	_run.call_deferred()

func _swim(hz: float, stepped_body: bool, interp: bool) -> Dictionary:
	var g := GrassField.new(); root.add_child(g)
	g.material = ShaderMaterial.new()
	g.interpolate = interp
	var tick := 1.0 / 60.0
	var st := {"t": 0.0, "acc": 0.0, "p": Vector3.ZERO}
	var pos_at := func(t: float) -> Vector3: return Vector3(3.0 * sin(t * 0.25), 0.4, 3.0 * cos(t * 0.25) - 3.0)
	g.girl_fn = func(): return st.p
	g.girl_capsule_fn = func(): return [st.p, Vector3(0, 0, 1), 0.5]
	g.frac_fn = func(): return st.acc / tick if stepped_body else 1.0
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	for f in int(hz * 8.0):
		var dt: float = (1.0 / hz) * rng.randf_range(0.9, 1.1)
		st.acc += dt; st.t += dt
		if stepped_body:
			while st.acc >= tick:
				st.acc -= tick
				st.p = pos_at.call(st.t - st.acc)   # the body moves on ticks only
				g._tick_capsule()
		else:
			st.p = pos_at.call(st.t - tick)          # continuous, with the same one-tick lag
			g._tick_capsule()
		g._process(dt)
	var srt := g._jerks.slice(int(hz * 0.25)); srt.sort()   # skip the first quarter second (the swim starting from rest)
	var n := srt.size()
	var out := {"p99": srt[int(n * 0.99)] if n > 0 else 0.0, "max": srt[n - 1] if n > 0 else 0.0}
	g.queue_free()
	return out

func _run() -> void:
	await process_frame
	var fault := "stepped" in OS.get_cmdline_user_args()
	var ok := true
	var rows := []
	for hz: float in [30.0, 60.0, 120.0, 144.0]:
		var ref := _swim(hz, false, true)
		var got := _swim(hz, true, not fault)
		var r99: float = got.p99 / maxf(ref.p99, 1e-6); var rmax: float = got.max / maxf(ref.max, 1e-6)
		rows.append({"hz": hz, "p99_mm": snappedf(got.p99, 0.01), "ref_p99_mm": snappedf(ref.p99, 0.01), "ratio_p99": snappedf(r99, 0.01), "ratio_max": snappedf(rmax, 0.01)})
		if r99 > RATIO or rmax > RATIO: ok = false
	var verdict := (not ok) if fault else ok
	print(("PASS" if verdict else "FAIL"), " J1 grass no-jitter", (" (fault stepped: caught)" if fault and verdict else ""), " ", rows)
	quit(0 if verdict else 1)
